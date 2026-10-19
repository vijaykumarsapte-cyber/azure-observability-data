# Deployment guide

This project deploys a Node.js frontend, Go API, and PostgreSQL database to an existing AKS cluster. The frontend is the only public Kubernetes Service. Backend and database use `ClusterIP`; network policies allow backend traffic only from frontend pods and database traffic only from backend pods.

## Requirements

- Windows PowerShell 7 (`pwsh`)
- Azure CLI, Docker Desktop using Linux containers, and `kubectl`
- An active Azure subscription with an existing, running AKS cluster and ACR
- The AKS node identity must have `AcrPull` on the selected ACR. The deployment identity needs permission to push images to ACR, read the AKS cluster and retrieve its user credentials, and read the `DB-PASSWORD` secret metadata from Key Vault.
- The AKS Key Vault Secrets Store CSI add-on and `SecretProviderClass` CRD must be enabled. The user-assigned identity configured in the manifests must be attached to the AKS nodes and allowed to read Key Vault secret `DB-PASSWORD`.

No credentials or database password are placed in this repository. The password is read by AKS from Key Vault and is never printed by the deployment script.

## Sign in and select a subscription

Open PowerShell 7 and run:

```powershell
az login
az account set --subscription '<subscription-id>'
az account show --output table
```

If the account has more than one AKS cluster, use the resource group and cluster name in the deployment command below. The ACR is derived from the existing frontend manifest by default; override it with `-AcrName` if needed. Key Vault defaults come from the existing backend SecretProviderClass and can be overridden with `-KeyVaultName`, `-TenantId`, and `-KeyVaultIdentityClientId`.

## Deploy

```powershell
Set-Location 'E:\Azure 3-Tier-Application\3-Tier-Application'
./deploy.ps1 -ResourceGroup '<existing-resource-group>' -AksCluster '<existing-aks-name>'
```

If exactly one AKS cluster exists in the active subscription, the shorter command works:

```powershell
./deploy.ps1
```

The script verifies Azure access and existing resources, confirms ACR pull access and Key Vault CSI prerequisites, builds and pushes tagged frontend and backend images, applies the manifests, waits for all rollouts, checks that backend/database Services remain private, and tests the public frontend API endpoint. When PostgreSQL already exists, its image and pod template are preserved so an app rollout does not restart the database. If the database Deployment is missing, it is created from the existing database manifest. The script never creates the AKS cluster, ACR, or Key Vault during a normal deployment.

Use `-ImageTag '<tag>'` to provide a release tag. Otherwise, a timestamp and (when available) Git commit are used. Keep the tag for rollback and diagnostics.

## Terraform

Terraform configuration lives one directory above this application. It can create or change the resource group, virtual network, AKS, ACR, and Key Vault, so the deployment script does not run Terraform by default. Only when an infrastructure change is required, run:

```powershell
./deploy.ps1 -ResourceGroup '<existing-resource-group>' -AksCluster '<existing-aks-name>' -RunTerraform
```

The script validates and displays the Terraform plan first. It refuses any plan containing a delete or replacement. To approve the displayed non-destructive plan, type `APPLY` at the prompt; any other input skips Terraform and continues with the existing resources. Review the plan carefully because resource creation or resizing can incur charges. The Terraform source and state files are not changed by preparing this deployment.

## Key Vault and ACR access

The deployment account must be allowed to retrieve AKS credentials and push to ACR. A cluster operator can grant the deployment principal `AcrPush` and `Azure Kubernetes Service Cluster User Role` at the appropriate resource scopes. The AKS kubelet identity needs `AcrPull` at the registry scope. Do not enable the ACR admin account or place registry passwords in manifests.

The Key Vault identity used by the CSI provider needs secret `Get` access to `DB-PASSWORD`. The identity GUID, Key Vault name, and tenant ID in the checked-in manifests are configuration identifiers, not credentials. Verify they match the existing cluster and vault before running the script. The script checks that the vault and secret exist but does not grant roles or alter cluster identity settings.

## Database storage note

The existing PostgreSQL Deployment has no persistent volume. Data can be lost if its pod is replaced or rescheduled. The script preserves this existing behavior and warns after a successful deployment; it does not provision a managed disk or storage class. For production data, approve and configure persistent storage before using this database for durable data.

## Troubleshooting

```powershell
kubectl get pods,svc -n frontend
kubectl get pods,svc -n backend
kubectl get pods,svc -n database
kubectl describe pods -n backend
kubectl logs deployment/backend -n backend
kubectl logs deployment/postgres -n database
kubectl describe secretproviderclass db-password -n backend
az aks check-acr --resource-group '<resource-group>' --name '<aks-name>' --acr '<registry>.azurecr.io'
```

- `ImagePullBackOff`: verify `AcrPush` for the deployment identity and `AcrPull` for the AKS kubelet identity.
- Secret mount or missing `db-secret`: verify CSI add-on status, identity attachment, Key Vault permissions, and the exact secret name `DB-PASSWORD`.
- Backend readiness failures: check PostgreSQL pod status and backend logs, then verify the configured password is the same Key Vault secret used by both namespaces.
- No frontend external IP: inspect `kubectl describe service frontend -n frontend` and the AKS subnet, quota, and network restrictions. The script does not create a load balancer directly; AKS provisions it for the frontend Service.

The script cleans its temporary manifest copies on exit. Checked-in Kubernetes files and Terraform state are not edited by a deployment run.
