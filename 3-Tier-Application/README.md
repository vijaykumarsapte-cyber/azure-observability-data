Three-Tier Goal Tracker
A small goal-tracking application with a Node.js frontend, Go API, and PostgreSQL database, deployed to AKS using the Kubernetes manifests in this folder.

Architecture

Deploy to AKS After Infrastructure Provisioning
This workflow assumes Terraform has already provisioned AKS, ACR, and Key Vault, and the database password has already been pushed to Key Vault as DB-PASSWORD in kvlearningvijaydev.

1. Check Prerequisites
You need Azure CLI, kubectl, and Podman installed. The signed-in Azure identity must be able to access the cluster, Key Vault, and ACR.

Before deploying, confirm:

AKS has the Azure Key Vault Secrets Store CSI provider enabled.
The user-assigned identity in both SecretProviderClasses is attached to the AKS node VM scale set and can read Key Vault secrets.
The AKS kubelet identity can pull images from observabilityacr.
The Key Vault contains the secret DB-PASSWORD.
To check the secret name without printing its value:
