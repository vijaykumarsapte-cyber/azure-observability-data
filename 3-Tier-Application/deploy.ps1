[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$AksName,
    [string]$AcrName,
    [string]$KeyVaultName,
    [string]$ImageTag
)

$ErrorActionPreference = 'Stop'
# PowerShell 7 can promote native stderr output to terminating errors before
# the script checks $LASTEXITCODE. Keep native failures under explicit control.
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Join-Path $PSScriptRoot '3-Tier-Application'
$dockerRoot = Join-Path $projectRoot 'Docker'
$k8sRoot = Join-Path $projectRoot 'k8s'
$tfvarsPath = Join-Path $PSScriptRoot 'terraform.tfvars'
$spcPatchPath = $null

function Read-Tfvar([string]$Name) {
    if (-not (Test-Path -LiteralPath $tfvarsPath)) { return $null }
    $line = Get-Content -LiteralPath $tfvarsPath | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
    if ($line -and $line -match '=\s*"([^"]+)"') { return $Matches[1] }
    return $null
}

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')" }
}

function Get-AzValue([string[]]$Arguments) {
    $value = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')" }
    return (($value | Out-String).Trim())
}

function Assert-ServiceHasEndpoints([string]$Namespace, [string]$Service) {
    $json = & kubectl get endpoints $Service -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) { throw "Could not read service endpoints for $Namespace/$Service" }
    $endpoint = ($json | ConvertFrom-Json).subsets
    if (-not $endpoint -or -not $endpoint[0].addresses) { throw "Service $Namespace/$Service has no ready pod endpoints" }
    Write-Host "PASS service endpoints: $Namespace/$Service"
}

function Wait-DeploymentRollout([string]$Deployment, [string]$Namespace, [string]$Label) {
    $result = & kubectl rollout status "deployment/$Deployment" -n $Namespace --timeout=5m 2>&1
    $rolloutExitCode = $LASTEXITCODE
    $result | ForEach-Object { Write-Host $_ }
    if ($rolloutExitCode -eq 0) { return }

    Write-Warning "Rollout failed for $Namespace/$Deployment. Collecting pod diagnostics."
    & kubectl get pods -n $Namespace -l "app=$Label" -o wide
    & kubectl describe pods -n $Namespace -l "app=$Label"
    & kubectl get events -n $Namespace --sort-by=.lastTimestamp
    $pods = & kubectl get pods -n $Namespace -l "app=$Label" -o name 2>$null
    foreach ($pod in $pods) {
        if ($pod) {
            Write-Host "Recent logs: $Namespace/$pod"
            & kubectl logs $pod -n $Namespace --all-containers --tail=80
            if ($LASTEXITCODE -ne 0) {
                & kubectl logs $pod -n $Namespace --all-containers --previous --tail=80
            }
        }
    }
    throw "Rollout did not complete for $Namespace/$Deployment. Review the pod diagnostics above; no pod was force-deleted."
}

try {
    if (-not (Test-Path -LiteralPath $k8sRoot)) { throw "Kubernetes manifests not found: $k8sRoot" }
    foreach ($tool in @('docker', 'az', 'kubectl')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found. Install it and restart VS Code." }
    }

    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { Read-Tfvar 'subscription_id' }
    $baseRg = Read-Tfvar 'resource_group_name'
    $environment = Read-Tfvar 'environment'
    $ResourceGroup = if ($ResourceGroup) { $ResourceGroup } elseif ($baseRg -and $environment) { "$baseRg-$environment" } else { $null }
    $AksName = if ($AksName) { $AksName } else { Read-Tfvar 'aks_cluster_name' }
    $AcrName = if ($AcrName) { $AcrName } else { Read-Tfvar 'acr_name' }
    $KeyVaultName = if ($KeyVaultName) { $KeyVaultName } else { Read-Tfvar 'key_vault_name' }
    foreach ($entry in @(@('ResourceGroup',$ResourceGroup),@('AksName',$AksName),@('AcrName',$AcrName),@('KeyVaultName',$KeyVaultName))) {
        if (-not $entry[1]) { throw "Could not determine $($entry[0]); pass it as a parameter or set it in terraform.tfvars." }
    }

    if ($SubscriptionId) { Invoke-Checked az @('account','set','--subscription',$SubscriptionId) }
    $account = Get-AzValue @('account','show','--query','id','-o','tsv')
    Write-Host "Using subscription $account and existing resource group $ResourceGroup"
    # Avoid docker info's Go-template path; some Docker Desktop/CLI builds fail
    # while dereferencing optional daemon fields. `docker version` confirms the
    # selected engine is reachable and lets us give a useful startup message.
    $dockerVersion = & docker version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Desktop is installed, but its Linux engine is not reachable. Start Docker Desktop, wait for it to finish starting, select the desktop-linux context if needed (docker context use desktop-linux), then rerun .\deploy.ps1.'
    }
    $dockerVersion | ForEach-Object { Write-Host $_ }
    $null = Get-AzValue @('aks','show','--resource-group',$ResourceGroup,'--name',$AksName,'--query','name','-o','tsv')
    $loginServer = Get-AzValue @('acr','show','--name',$AcrName,'--resource-group',$ResourceGroup,'--query','loginServer','-o','tsv')
    $identityClientId = Get-AzValue @('aks','show','--resource-group',$ResourceGroup,'--name',$AksName,'--query','identityProfile.kubeletidentity.clientId','-o','tsv')
    $identityObjectId = Get-AzValue @('aks','show','--resource-group',$ResourceGroup,'--name',$AksName,'--query','identityProfile.kubeletidentity.objectId','-o','tsv')
    $tenantId = Get-AzValue @('account','show','--query','tenantId','-o','tsv')
    if (-not $identityClientId -or $identityClientId -eq 'None') { throw 'AKS did not return a kubelet managed identity client ID required by the existing Key Vault CSI setup.' }
    if (-not $identityObjectId -or $identityObjectId -eq 'None') { throw 'AKS did not return a kubelet managed identity object ID required to verify Key Vault access.' }

    $keyVaultUsesRbac = Get-AzValue @('keyvault','show','--name',$KeyVaultName,'--query','properties.enableRbacAuthorization','-o','tsv')
    if ($keyVaultUsesRbac -ne 'true') {
        $policyJson = Get-AzValue @('keyvault','show','--name',$KeyVaultName,'--query','properties.accessPolicies','-o','json')
        $policies = @($policyJson | ConvertFrom-Json)
        $csiPolicy = $policies | Where-Object { $_.objectId -eq $identityObjectId } | Select-Object -First 1
        if (-not $csiPolicy -or @($csiPolicy.permissions.secrets) -notcontains 'Get') {
            throw "Key Vault '$KeyVaultName' does not grant secret Get to AKS kubelet identity object ID $identityObjectId. Grant the existing identity access with: az keyvault set-policy --name $KeyVaultName --object-id $identityObjectId --secret-permissions get list"
        }
    }

    $tag = if ($ImageTag) { $ImageTag } else { 'deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    if ($tag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') { throw 'ImageTag contains characters not allowed in a Docker tag.' }
    $images = @(
        @{ Name='frontend'; Context=(Join-Path $dockerRoot 'frontend'); Deployment='frontend'; Namespace='frontend'; Container='frontend' },
        @{ Name='backend'; Context=(Join-Path $dockerRoot 'backend'); Deployment='backend'; Namespace='backend'; Container='backend' },
        @{ Name='database'; Context=(Join-Path $dockerRoot 'database'); Deployment='postgres'; Namespace='database'; Container='postgres' }
    )

    Write-Host "Building and pushing images to $loginServer with tag $tag"
    Invoke-Checked az @('acr','login','--name',$AcrName)
    foreach ($image in $images) {
        $path = "$loginServer/observability-$($image.Name):$tag"
        Invoke-Checked docker @('build','--tag',$path,$image.Context)
        Invoke-Checked docker @('push',$path)
        $image.TaggedImage = $path
    }

    Write-Host 'Connecting kubectl to the existing AKS cluster'
    Invoke-Checked az @('aks','get-credentials','--resource-group',$ResourceGroup,'--name',$AksName,'--overwrite-existing')

    Write-Host 'Applying the existing application manifests'
    Invoke-Checked kubectl @('apply','-f',(Join-Path $k8sRoot 'namespaces.yaml'))
    foreach ($namespace in @('database','backend','frontend')) {
        $folder = Join-Path $k8sRoot $namespace
        Invoke-Checked kubectl @('apply','-f',(Join-Path $folder 'configmap.yaml'))
        Invoke-Checked kubectl @('apply','-f',(Join-Path $folder 'service.yaml'))
    }
    Invoke-Checked kubectl @('apply','-f',(Join-Path $k8sRoot 'database/db-password-secret.yaml'))
    Invoke-Checked kubectl @('apply','-f',(Join-Path $k8sRoot 'backend/db-password-secret.yaml'))

    # Use the existing AKS kubelet identity and Key Vault from live configuration.
    # No secret values are read or written by this script.
    $spcPatch = @{ spec = @{ parameters = @{
        userAssignedIdentityID = $identityClientId
        tenantId = $tenantId
        keyvaultName = $KeyVaultName
    } } } | ConvertTo-Json -Depth 5 -Compress
    $spcPatchPath = Join-Path ([System.IO.Path]::GetTempPath()) ("aks-spc-patch-" + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($spcPatchPath, $spcPatch, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($namespace in @('database','backend')) {
        Invoke-Checked kubectl @('patch','secretproviderclass','db-password','-n',$namespace,'--type','merge','--patch-file',$spcPatchPath)
    }
    Remove-Item -LiteralPath $spcPatchPath -Force
    $spcPatchPath = $null
    foreach ($namespace in @('database','backend','frontend')) {
        Invoke-Checked kubectl @('apply','-f',(Join-Path (Join-Path $k8sRoot $namespace) 'deployment.yaml'))
    }

    foreach ($image in $images) {
        Invoke-Checked kubectl @('set','image',"deployment/$($image.Deployment)","$($image.Container)=$($image.TaggedImage)",'-n',$image.Namespace)
    }
    Wait-DeploymentRollout 'postgres' 'database' 'postgres'
    Invoke-Checked kubectl @('exec','deployment/postgres','-n','database','--','pg_isready','-U','postgres','-d','goalsdb')
    Wait-DeploymentRollout 'backend' 'backend' 'backend'
    Wait-DeploymentRollout 'frontend' 'frontend' 'frontend'

    Assert-ServiceHasEndpoints 'database' 'postgres'
    Assert-ServiceHasEndpoints 'backend' 'backend'
    Assert-ServiceHasEndpoints 'frontend' 'frontend'

    Write-Host "`nPods and services:"
    Invoke-Checked kubectl @('get','pods,services','-n','database','-o','wide')
    Invoke-Checked kubectl @('get','pods,services','-n','backend','-o','wide')
    Invoke-Checked kubectl @('get','pods,services','-n','frontend','-o','wide')

    Write-Host "`nIngress resources (if configured):"
    $ingressJson = & kubectl get ingress --all-namespaces -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not query Kubernetes Ingress resources.' }
    $ingresses = ($ingressJson | ConvertFrom-Json).items
    if (-not $ingresses -or $ingresses.Count -eq 0) {
        Write-Host 'No Ingress objects are configured; the frontend LoadBalancer service is the public entry point.'
    } else {
        $ingresses | ForEach-Object {
            if (-not $_.status.loadBalancer.ingress) { throw "Ingress $($_.metadata.namespace)/$($_.metadata.name) has no assigned address." }
        }
        $ingresses | ForEach-Object { Write-Host "PASS ingress address: $($_.metadata.namespace)/$($_.metadata.name) -> $(($_.status.loadBalancer.ingress | ForEach-Object { if ($_.ip) { $_.ip } else { $_.hostname } }) -join ', ')" }
    }
    $lb = $null
    for ($attempt = 1; $attempt -le 30 -and -not $lb; $attempt++) {
        $lbJson = & kubectl get service frontend -n frontend -o json
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the frontend LoadBalancer service.' }
        $lb = ($lbJson | ConvertFrom-Json).status.loadBalancer.ingress | Select-Object -First 1
        if (-not $lb) { Start-Sleep -Seconds 10 }
    }
    if (-not $lb) {
        throw 'Frontend LoadBalancer did not receive an external address within five minutes. Check: kubectl get service frontend -n frontend -w'
    } else {
        $endpointHost = if ($lb.ip) { $lb.ip } else { $lb.hostname }
        $baseUrl = "http://$endpointHost"
        Write-Host "Frontend URL: $baseUrl"
        $frontendOk = $false
        $apiOk = $false
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            try {
                $page = Invoke-WebRequest -Uri $baseUrl -TimeoutSec 10 -UseBasicParsing
                if ($page.StatusCode -eq 200 -and $page.Content -match 'Track Your Goals') { $frontendOk = $true }
                $api = Invoke-RestMethod -Uri "$baseUrl/api/goals" -TimeoutSec 10
                if ($api.success -eq $true) { $apiOk = $true }
                if ($frontendOk -and $apiOk) { break }
            } catch { Start-Sleep -Seconds 10 }
        }
        if (-not $frontendOk) { throw 'Frontend HTTP check failed (expected the application page with status 200).' }
        Write-Host 'PASS frontend HTTP check'
        if (-not $apiOk) { throw 'Backend/PostgreSQL API check failed at /api/goals. Review backend and database pod logs.' }
        Write-Host 'PASS backend API and PostgreSQL integration check'
    }

    Write-Host "`nDeployment completed. Image tag: $tag"
} catch {
    Write-Error $_
    exit 1
} finally {
    if ($spcPatchPath -and (Test-Path -LiteralPath $spcPatchPath)) {
        Remove-Item -LiteralPath $spcPatchPath -Force -ErrorAction SilentlyContinue
    }
}
