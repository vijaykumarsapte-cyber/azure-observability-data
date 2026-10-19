[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$AksCluster,
    [string]$AcrName,
    [string]$KeyVaultName,
    [string]$TenantId,
    [string]$KeyVaultIdentityClientId,
    [string]$ImageTag,
    [switch]$RunTerraform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Warning $Message }
function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it and sign in/configure it, then rerun."
    }
}
function Invoke-AzJson([string[]]$Arguments, [string]$FailureMessage) {
    $result = & az @Arguments --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage`n$($result -join "`n")" }
    try { return ($result -join "`n" | ConvertFrom-Json -Depth 100) }
    catch { throw "Azure CLI returned invalid JSON while $FailureMessage" }
}
function Invoke-Kubectl([string[]]$Arguments, [string]$FailureMessage) {
    & kubectl @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (kubectl exit code $LASTEXITCODE). Check the preceding output and run: kubectl describe / kubectl logs." }
}
function Invoke-ReviewedTerraformPlan([string]$SelectedSubscriptionId) {
    if (-not $RunTerraform) {
        Write-Host 'Terraform skipped. Existing Azure resources will be reused. Use -RunTerraform only when infrastructure changes are required.'
        return
    }
    Write-Step 'Planning optional Terraform infrastructure changes'
    Assert-Command 'terraform'
    if (-not (Test-Path -LiteralPath (Join-Path $terraformRoot 'main.tf'))) { throw "-RunTerraform was requested but no Terraform root was found at '$terraformRoot'." }
    Push-Location $terraformRoot
    try {
        & terraform init -input=false -lockfile=readonly
        if ($LASTEXITCODE -ne 0) { throw 'terraform init failed. Review provider/backend errors; no infrastructure was applied.' }
        & terraform validate
        if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed. Fix configuration before continuing.' }
        & terraform plan -input=false "-var=subscription_id=$SelectedSubscriptionId" -out=$terraformPlanPath
        if ($LASTEXITCODE -ne 0) { throw 'terraform plan failed. No infrastructure was applied.' }
        & terraform show -json $terraformPlanPath | Set-Content -LiteralPath $terraformJsonPath -Encoding utf8
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $terraformJsonPath)) { throw 'Could not read the Terraform plan as JSON. No infrastructure was applied.' }
        $plan = Get-Content -LiteralPath $terraformJsonPath -Raw | ConvertFrom-Json -Depth 100
        $changes = @($plan.resource_changes | Where-Object { $_.change.actions -contains 'delete' })
        if ($changes.Count -gt 0) {
            $addresses = ($changes | ForEach-Object address) -join ', '
            throw "Terraform plan includes deletion or replacement for: $addresses. Deployment stopped; no infrastructure was applied. Review and revise Terraform separately."
        }
        Write-Host "`nTerraform plan (review before approval):" -ForegroundColor Yellow
        & terraform show $terraformPlanPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not display Terraform plan. No infrastructure was applied.' }
        $approval = Read-Host 'Type APPLY to approve this reviewed, non-destructive Terraform plan; anything else skips infrastructure changes'
        if ($approval -cne 'APPLY') { Write-Host 'Terraform apply skipped; continuing with existing infrastructure.' }
        else {
            & terraform apply -input=false $terraformPlanPath
            if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed. Review Terraform/Azure output and state before retrying.' }
        }
    } finally { Pop-Location }
}

$projectRoot = $PSScriptRoot
$dockerRoot = Join-Path $projectRoot 'Docker'
$k8sRoot = Join-Path $projectRoot 'k8s'
$terraformRoot = Split-Path -Parent $projectRoot
$tempManifestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("goal-tracker-k8s-" + [guid]::NewGuid().ToString('N'))
$terraformPlanPath = Join-Path ([System.IO.Path]::GetTempPath()) ("goal-tracker-" + [guid]::NewGuid().ToString('N') + '.tfplan')
$terraformJsonPath = "$terraformPlanPath.json"

try {
    Write-Step 'Checking local prerequisites'
    Assert-Command 'az'
    Assert-Command 'kubectl'
    Assert-Command 'docker'
    if (-not (Test-Path -LiteralPath $k8sRoot -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $dockerRoot 'frontend\Dockerfile')) -or
        -not (Test-Path -LiteralPath (Join-Path $dockerRoot 'backend\Dockerfile'))) {
        throw "Expected Docker and Kubernetes project files were not found under '$projectRoot'. Run this script from the checked-out project directory."
    }

    Write-Step 'Verifying Azure login and subscription'
    $account = Invoke-AzJson @('account','show') 'checking Azure CLI login'
    if (-not $account.id) { throw 'Azure CLI has no active subscription. Run az login and select a subscription.' }
    if ($SubscriptionId) {
        & az account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) { throw "Cannot select subscription '$SubscriptionId'. Check its ID and your access." }
        $account = Invoke-AzJson @('account','show') 'verifying selected Azure subscription'
    }
    $SubscriptionId = [string]$account.id
    Write-Host "Subscription: $($account.name) ($SubscriptionId)"

    # Infrastructure is an explicit, reviewed opt-in. This runs before AKS/ACR discovery so it can
    # provision infrastructure only when the operator requested it and approved the shown plan.
    Invoke-ReviewedTerraformPlan $SubscriptionId

    Write-Step 'Finding and verifying the existing AKS cluster'
    if ($AksCluster) {
        if (-not $ResourceGroup) { throw 'When -AksCluster is specified, also specify -ResourceGroup.' }
        $cluster = Invoke-AzJson @('aks','show','--name',$AksCluster,'--resource-group',$ResourceGroup) "reading AKS cluster '$AksCluster'"
    } else {
        $clusters = @(Invoke-AzJson @('aks','list') 'listing AKS clusters')
        if ($ResourceGroup) { $clusters = @($clusters | Where-Object resourceGroup -eq $ResourceGroup) }
        if ($clusters.Count -eq 0) { throw 'No AKS cluster was found in the selected subscription/resource group. Confirm the subscription, or supply -ResourceGroup and -AksCluster.' }
        if ($clusters.Count -gt 1) { throw "Found multiple AKS clusters. Rerun with -ResourceGroup '<resource-group>' -AksCluster '<cluster-name>'." }
        $cluster = Invoke-AzJson @('aks','show','--name',[string]$clusters[0].name,'--resource-group',[string]$clusters[0].resourceGroup) 'reading the selected AKS cluster'
        $ResourceGroup = [string]$cluster.resourceGroup
        $AksCluster = [string]$cluster.name
    }
    if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS cluster '$AksCluster' state is '$($cluster.provisioningState)', expected Succeeded." }
    Write-Host "AKS: $AksCluster (resource group: $ResourceGroup, location: $($cluster.location))"

    Write-Step 'Finding and verifying the existing Azure Container Registry'
    if (-not $AcrName) {
        $manifestText = Get-Content -LiteralPath (Join-Path $k8sRoot 'frontend\deployment.yaml') -Raw
        if ($manifestText -match 'image:\s*([\w.-]+)\.azurecr\.io/') { $AcrName = $Matches[1] }
    }
    if (-not $AcrName) {
        $registries = @(Invoke-AzJson @('acr','list') 'listing Azure Container Registries')
        if ($registries.Count -eq 1) { $AcrName = [string]$registries[0].name }
        elseif ($registries.Count -gt 1) { throw "Found multiple ACRs and no registry could be derived from the manifests. Rerun with -AcrName '<registry-name>'." }
        else { throw 'No ACR was found. Create or select an existing registry first; this script will not create one.' }
    }
    $acr = Invoke-AzJson @('acr','show','--name',$AcrName) "reading ACR '$AcrName'"
    if ($acr.provisioningState -ne 'Succeeded') { throw "ACR '$AcrName' state is '$($acr.provisioningState)', expected Succeeded." }
    $loginServer = [string]$acr.loginServer
    Write-Host "ACR: $AcrName ($loginServer)"

    if (-not $ImageTag) {
        $ImageTag = Get-Date -Format 'yyyyMMddHHmmss'
        try {
            $gitCommit = (& git -C $projectRoot rev-parse --short=8 HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $gitCommit) { $ImageTag = "$ImageTag-$($gitCommit.Trim())" }
        } catch { }
    }
    if ($ImageTag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') { throw "Image tag '$ImageTag' is invalid for a Docker tag." }

    Write-Step 'Checking AKS access and ACR image-pull access'
    & az aks get-credentials --resource-group $ResourceGroup --name $AksCluster --overwrite-existing
    if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve AKS credentials. Grant this identity AKS Cluster User (or equivalent) access, then retry.' }
    Invoke-Kubectl @('cluster-info') 'checking Kubernetes API access'
    $checkAcr = & az aks check-acr --resource-group $ResourceGroup --name $AksCluster --acr $loginServer 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AKS node identity cannot pull from '$loginServer'. Assign AcrPull to the AKS kubelet identity, then rerun. No role assignment was changed. Details: $($checkAcr -join ' ')"
    }
    $databaseDeploymentSource = Get-Content -LiteralPath (Join-Path $k8sRoot 'database\deployment.yaml') -Raw
    if ($databaseDeploymentSource -match 'image:\s*([\w.-]+\.azurecr\.io)/') {
        $databaseRegistryServer = $Matches[1]
        if ($databaseRegistryServer -ne $loginServer) {
            $databaseAcrCheck = & az aks check-acr --resource-group $ResourceGroup --name $AksCluster --acr $databaseRegistryServer 2>&1
            if ($LASTEXITCODE -ne 0) { throw "The existing PostgreSQL image uses '$databaseRegistryServer', which AKS cannot pull. Preserve/restore that registry's AcrPull access; the database image will not be changed by this script. Details: $($databaseAcrCheck -join ' ')" }
        }
    }

    Write-Step 'Verifying Key Vault CSI configuration and DB-PASSWORD secret'
    $keyVaultManifest = Get-Content -LiteralPath (Join-Path $k8sRoot 'backend\db-password-secret.yaml') -Raw
    if (-not $KeyVaultName -and $keyVaultManifest -match '(?m)^\s+keyvaultName:\s*([^\s#]+)') { $KeyVaultName = $Matches[1].Trim('"') }
    if (-not $TenantId -and $keyVaultManifest -match '(?m)^\s+tenantId:\s*([^\s#]+)') { $TenantId = $Matches[1].Trim('"') }
    if (-not $KeyVaultIdentityClientId -and $keyVaultManifest -match '(?m)^\s+userAssignedIdentityID:\s*([^\s#]+)') { $KeyVaultIdentityClientId = $Matches[1].Trim('"') }
    if (-not $KeyVaultName -or -not $TenantId -or -not $KeyVaultIdentityClientId) {
        throw 'Key Vault name, tenant ID, or CSI user-assigned identity client ID is missing. Supply -KeyVaultName, -TenantId, and -KeyVaultIdentityClientId.'
    }
    $kv = Invoke-AzJson @('keyvault','show','--name',$KeyVaultName) "reading Key Vault '$KeyVaultName'"
    if ($kv.properties.tenantId -and $kv.properties.tenantId -ne $TenantId) { throw "Key Vault '$KeyVaultName' belongs to a different tenant than the configured SecretProviderClass. Correct -TenantId before deployment." }
    $secret = & az keyvault secret show --vault-name $KeyVaultName --name 'DB-PASSWORD' --query id --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $secret) { throw "Key Vault '$KeyVaultName' does not expose secret DB-PASSWORD to this identity. Grant secret read access and verify the secret exists; its value is never printed." }
    $addonEnabled = [bool]$cluster.addonProfiles.azureKeyvaultSecretsProvider.enabled
    if (-not $addonEnabled) { throw "AKS does not report the Azure Key Vault Secrets Store CSI add-on enabled. Enable it on the existing cluster and attach/grant the configured identity; this script will not change cluster infrastructure." }
    $crd = & kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io --ignore-not-found -o name 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $crd) { throw 'The SecretProviderClass CRD is unavailable. Enable the AKS Key Vault CSI add-on and retry.' }
    # Write verified identity and vault settings into temporary manifest copies rather than altering tracked files.
    if ($TenantId -notmatch '^[0-9a-fA-F-]{36}$' -or $KeyVaultIdentityClientId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'TenantId and KeyVaultIdentityClientId must be GUIDs.' }
    Write-Host "Key Vault: $KeyVaultName; DB-PASSWORD exists (value not displayed)."
    Write-Warn 'Confirm the configured user-assigned identity is attached to the AKS node pool and can read this Key Vault secret.'

    Write-Step "Building and pushing application images to $loginServer"
    & az acr login --name $AcrName
    if ($LASTEXITCODE -ne 0) { throw "ACR login failed. Confirm AcrPush permission for the signed-in identity and retry." }
    $images = [ordered]@{
        frontend = "$loginServer/observability-frontend`:$ImageTag"
        backend  = "$loginServer/observability-backend`:$ImageTag"
    }
    $builds = @(
        @{ Name='frontend'; Context=(Join-Path $dockerRoot 'frontend'); Dockerfile=(Join-Path $dockerRoot 'frontend\Dockerfile') },
        @{ Name='backend'; Context=(Join-Path $dockerRoot 'backend'); Dockerfile=(Join-Path $dockerRoot 'backend\Dockerfile') }
    )
    foreach ($build in $builds) {
        $image = $images[$build.Name]
        Write-Host "Building $($build.Name): $image"
        & docker build --pull --platform linux/amd64 --file $build.Dockerfile --tag $image $build.Context
        if ($LASTEXITCODE -ne 0) { throw "Docker build failed for $($build.Name). Check the Dockerfile, dependency access, and Docker Desktop status." }
        & docker push $image
        if ($LASTEXITCODE -ne 0) { throw "Push failed for $($build.Name). Recheck ACR login, network access, and AcrPush role." }
    }

    Write-Step 'Preparing Kubernetes manifests'
    New-Item -ItemType Directory -Path $tempManifestRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $k8sRoot 'namespaces.yaml') -Destination $tempManifestRoot
    Copy-Item -LiteralPath (Join-Path $k8sRoot 'networkpolicies.yaml') -Destination $tempManifestRoot
    foreach ($folder in 'frontend','backend','database') {
        $source = Join-Path $k8sRoot $folder
        $dest = Join-Path $tempManifestRoot $folder
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Filter '*.yaml') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ($folder -eq 'frontend') { $content = $content -replace '(?m)^\s*image:\s*[^\r\n]+', "          image: $($images.frontend)" }
            if ($folder -eq 'backend') {
                $content = $content -replace '(?m)^\s*image:\s*[^\r\n]+', "          image: $($images.backend)"
                $content = $content -replace '(?m)^\s+keyvaultName:\s*[^\r\n]+', "    keyvaultName: $KeyVaultName"
                $content = $content -replace '(?m)^\s+tenantId:\s*[^\r\n]+', "    tenantId: `"$TenantId`""
                $content = $content -replace '(?m)^\s+userAssignedIdentityID:\s*[^\r\n]+', "    userAssignedIdentityID: `"$KeyVaultIdentityClientId`""
            }
            if ($folder -eq 'database') {
                $content = $content -replace '(?m)^\s+keyvaultName:\s*[^\r\n]+', "    keyvaultName: $KeyVaultName"
                $content = $content -replace '(?m)^\s+tenantId:\s*[^\r\n]+', "    tenantId: `"$TenantId`""
                $content = $content -replace '(?m)^\s+userAssignedIdentityID:\s*[^\r\n]+', "    userAssignedIdentityID: `"$KeyVaultIdentityClientId`""
            }
            Set-Content -LiteralPath (Join-Path $dest $file.Name) -Value $content -Encoding utf8
        }
    }

    Write-Step 'Applying private backend/database services and the public frontend service'
    Invoke-Kubectl @('apply','-f',(Join-Path $tempManifestRoot 'namespaces.yaml')) 'creating application namespaces'
    Invoke-Kubectl @('apply','-f',(Join-Path $tempManifestRoot 'networkpolicies.yaml')) 'applying backend/database ingress restrictions'
    foreach ($ns in 'database','backend','frontend') {
        if ($ns -ne 'database') {
            Invoke-Kubectl @('apply','-f',(Join-Path $tempManifestRoot $ns)) "applying $ns Kubernetes resources"
            continue
        }
        $dbDeploymentPath = Join-Path $tempManifestRoot 'database\deployment.yaml'
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $tempManifestRoot 'database') -File -Filter '*.yaml' | Where-Object Name -ne 'deployment.yaml') {
            Invoke-Kubectl @('apply','-f',$file.FullName) 'applying database service/configuration'
        }
        $existingDbDeployment = & kubectl -n database get deployment postgres --ignore-not-found -o name 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not check for an existing PostgreSQL Deployment.' }
        if ($existingDbDeployment) {
            Write-Host 'Existing PostgreSQL Deployment found; preserving its image and pod template to avoid an unplanned database restart.'
        } else {
            Invoke-Kubectl @('apply','-f',$dbDeploymentPath) 'creating the PostgreSQL Deployment from the existing manifest'
        }
    }
    foreach ($pair in @(@{Namespace='backend';Deployment='backend'},@{Namespace='frontend';Deployment='frontend'})) {
        $imageKey = $pair.Namespace
        Invoke-Kubectl @('-n',$pair.Namespace,'set','image',"deployment/$($pair.Deployment)","$($pair.Deployment)=$($images[$imageKey])") "updating $($pair.Deployment) image"
    }

    Write-Step 'Verifying rollout and network exposure'
    foreach ($pair in @(@{Namespace='database';Deployment='postgres'},@{Namespace='backend';Deployment='backend'},@{Namespace='frontend';Deployment='frontend'})) {
        Invoke-Kubectl @('-n',$pair.Namespace,'rollout','status',"deployment/$($pair.Deployment)",'--timeout=5m') "waiting for $($pair.Deployment) rollout"
    }
    $backendType = & kubectl -n backend get service backend -o jsonpath='{.spec.type}'
    if ($LASTEXITCODE -ne 0 -or $backendType -ne 'ClusterIP') { throw "Backend service must be ClusterIP (private); found '$backendType'." }
    $databaseType = & kubectl -n database get service postgres -o jsonpath='{.spec.type}'
    if ($LASTEXITCODE -ne 0 -or $databaseType -ne 'ClusterIP') { throw "Database service must be ClusterIP (private); found '$databaseType'." }
    $frontendType = & kubectl -n frontend get service frontend -o jsonpath='{.spec.type}'
    if ($LASTEXITCODE -ne 0 -or $frontendType -ne 'LoadBalancer') { throw "Frontend service must be LoadBalancer; found '$frontendType'." }
    $frontendIp = ''
    for ($attempt=0; $attempt -lt 30 -and -not $frontendIp; $attempt++) {
        $frontendIp = [string](& kubectl -n frontend get service frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null)
        $frontendIp = $frontendIp.Trim()
        if (-not $frontendIp) {
            $frontendIp = [string](& kubectl -n frontend get service frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null)
            $frontendIp = $frontendIp.Trim()
        }
        if (-not $frontendIp) { Start-Sleep -Seconds 10 }
    }
    if (-not $frontendIp) { throw 'Frontend LoadBalancer address was not assigned within five minutes. Run kubectl -n frontend describe service frontend and inspect AKS subnet/NSG permissions.' }
    $frontendUrl = "http://$frontendIp"
    $verified = $false
    for ($attempt=0; $attempt -lt 12 -and -not $verified; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri "$frontendUrl/api/goals" -TimeoutSec 10
            if ($response.success -eq $true) { $verified = $true }
        } catch { Start-Sleep -Seconds 10 }
    }
    if (-not $verified) {
        Invoke-Kubectl @('-n','frontend','get','pods,svc') 'collecting frontend diagnostics'
        Invoke-Kubectl @('-n','backend','get','pods,svc') 'collecting backend diagnostics'
        Invoke-Kubectl @('-n','database','get','pods,svc') 'collecting database diagnostics'
        throw "The frontend endpoint '$frontendUrl/api/goals' did not return a successful response. Inspect pod logs and Key Vault/DB connectivity."
    }

    Write-Host "`nDeployment succeeded." -ForegroundColor Green
    Write-Host "Frontend: $frontendUrl"
    Write-Host "Backend service: backend.backend.svc.cluster.local:8080 (ClusterIP)"
    Write-Host "Database service: postgres.database.svc.cluster.local:5432 (ClusterIP)"
    Write-Host "Frontend/backend images use tag: $ImageTag"
    Write-Warn 'The existing PostgreSQL manifest has no persistent volume. Database data may be lost if its pod is replaced or rescheduled.'
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host 'Troubleshooting commands:' -ForegroundColor Yellow
    Write-Host '  kubectl get pods,svc -n frontend; kubectl get pods,svc -n backend; kubectl get pods,svc -n database'
    Write-Host '  kubectl describe pods -n backend; kubectl logs deployment/backend -n backend'
    Write-Host '  kubectl logs deployment/postgres -n database; kubectl describe secretproviderclass db-password -n backend'
    Write-Host '  az aks check-acr --resource-group <resource-group> --name <cluster> --acr <registry>.azurecr.io'
    throw
} finally {
    if (Test-Path -LiteralPath $tempManifestRoot) { Remove-Item -LiteralPath $tempManifestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $terraformPlanPath) { Remove-Item -LiteralPath $terraformPlanPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $terraformJsonPath) { Remove-Item -LiteralPath $terraformJsonPath -Force -ErrorAction SilentlyContinue }
}
