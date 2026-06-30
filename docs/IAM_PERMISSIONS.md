# IAM Permissions Guide

GCP IAM permissions required to deploy and manage the NPA Publisher Terraform configuration.

## Table of Contents

- [Overview](#overview)
- [Publisher VM Service Account](#publisher-vm-service-account)
- [Terraform Operator Permissions](#terraform-operator-permissions)
- [Recommended: Custom Deployment Role](#recommended-custom-deployment-role)
- [CI/CD with Workload Identity Federation](#cicd-with-workload-identity-federation)
- [Security Best Practices](#security-best-practices)
- [Quick Reference](#quick-reference)

## Overview

This deployment uses two IAM identities:

1. **Publisher VM Service Account** — attached to each Compute Engine instance; used by the startup script and Ops Agent. Managed by Terraform.
2. **Terraform Operator** — the person or service account running `terraform apply`. Must have permissions to create and manage GCP and Netskope resources. Configured outside this module.

This is simpler than the AWS architecture, which required three IAM roles (instance role, SSM Automation role, Terraform operator). In GCP, the SSM Automation role is eliminated because registration is handled by the VM's own startup script using its service account identity.

## Publisher VM Service Account

Terraform creates and manages the publisher VM service account in `iam.tf`. The service account is named `<publisher_name>-sa@<project_id>.iam.gserviceaccount.com`.

### Roles Granted by Terraform

| Role | Scope | Purpose |
|---|---|---|
| `roles/logging.logWriter` | Project | Startup script and Ops Agent write logs to Cloud Logging |
| `roles/monitoring.metricWriter` | Project | Ops Agent writes metrics to Cloud Monitoring |
| `roles/stackdriver.resourceMetadata.writer` | Project | Ops Agent reports VM metadata (only when `enable_monitoring = true`) |
| `roles/secretmanager.secretAccessor` | Per-secret | Startup script reads its own registration token from Secret Manager |

### Why Secret Access Is Per-Secret, Not Project-Wide

The `secretmanager.secretAccessor` binding is applied to each publisher's registration token secret individually (not at the project level). This mirrors the AWS SSM Automation role's resource-scoped permission:

- AWS: `ssm:GetParameter` on `arn:aws:ssm:<region>:<account>:parameter/npa/publishers/*/registration-token`
- GCP: `roles/secretmanager.secretAccessor` on `projects/PROJECT/secrets/<name>-registration-token`

This ensures that a compromised publisher VM cannot read other publishers' registration tokens.

### What the VM Service Account Does NOT Have Access To

- Other publishers' registration token secrets
- Terraform state (GCS bucket)
- IAM management permissions
- Network modification permissions

## Terraform Operator Permissions

The operator running `terraform apply` needs permissions to create and manage NPA infrastructure. These can be granted as predefined roles (faster to set up) or a custom role (principle of least privilege).

### Required Permissions by Category

| Category | Permissions / Predefined Role | Purpose |
|---|---|---|
| **Compute Engine** | `roles/compute.instanceAdmin.v1` | Create/manage VMs, disks, firewall rules, VPC, subnets, Cloud Router, Cloud NAT |
| **Service Account Management** | `roles/iam.serviceAccountAdmin` | Create/delete publisher service account |
| **Service Account Assignment** | `roles/iam.serviceAccountUser` | Assign service account to VMs (`actAs`) |
| **IAM Binding Management** | `roles/resourcemanager.projectIamAdmin` (or `roles/iam.securityAdmin`) | Grant IAM bindings for publisher service account |
| **Secret Manager** | `roles/secretmanager.admin` | Create/delete secrets and versions, manage IAM on secrets |
| **GCS State Backend** | `roles/storage.objectAdmin` on bucket | Read/write Terraform state |
| **Netskope API** | N/A (Netskope API token, not GCP IAM) | Manage Netskope publishers |

### Predefined Role Shortcut (Opinion)

For small teams or development, combining predefined roles is the fastest path:

```bash
PROJECT_ID="my-gcp-project-id"
OPERATOR="user:you@example.com"   # or serviceAccount:terraform@PROJECT.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="$OPERATOR" --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="$OPERATOR" --role="roles/iam.serviceAccountAdmin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="$OPERATOR" --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="$OPERATOR" --role="roles/iam.securityAdmin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="$OPERATOR" --role="roles/secretmanager.admin"
```

> **Best practice note**: Predefined roles may grant more permissions than necessary. For production, use a custom role (see below).

## Recommended: Custom Deployment Role

A custom role scoped to exactly the permissions Terraform needs. This is the GCP equivalent of the `NPAPublisherTerraformPolicy` in the AWS architecture.

### Required Permissions List

```yaml
# Custom role permissions for the Terraform operator
includedPermissions:
  # Compute Engine — VPC and networking
  - compute.networks.create
  - compute.networks.delete
  - compute.networks.get
  - compute.networks.list
  - compute.networks.updatePolicy
  - compute.subnetworks.create
  - compute.subnetworks.delete
  - compute.subnetworks.get
  - compute.subnetworks.list
  - compute.subnetworks.use
  - compute.subnetworks.setPrivateIpGoogleAccess
  - compute.routers.create
  - compute.routers.delete
  - compute.routers.get
  - compute.routers.list
  - compute.routers.update
  - compute.firewalls.create
  - compute.firewalls.delete
  - compute.firewalls.get
  - compute.firewalls.list

  # Compute Engine — instances
  - compute.instances.create
  - compute.instances.delete
  - compute.instances.get
  - compute.instances.list
  - compute.instances.setServiceAccount
  - compute.instances.setMetadata
  - compute.instances.setTags
  - compute.instances.setLabels
  - compute.instances.start
  - compute.instances.stop
  - compute.instances.reset
  - compute.disks.create
  - compute.disks.delete
  - compute.disks.get
  - compute.images.useReadOnly
  - compute.zones.list
  - compute.regions.list
  - compute.machineTypes.list
  - compute.machineTypes.get
  - compute.addresses.list

  # IAM — service account management
  - iam.serviceAccounts.create
  - iam.serviceAccounts.delete
  - iam.serviceAccounts.get
  - iam.serviceAccounts.list
  - iam.serviceAccounts.actAs

  # IAM — project-level bindings
  - resourcemanager.projects.getIamPolicy
  - resourcemanager.projects.setIamPolicy

  # Secret Manager
  - secretmanager.secrets.create
  - secretmanager.secrets.delete
  - secretmanager.secrets.get
  - secretmanager.secrets.list
  - secretmanager.secrets.getIamPolicy
  - secretmanager.secrets.setIamPolicy
  - secretmanager.versions.add
  - secretmanager.versions.destroy
  - secretmanager.versions.get
  - secretmanager.versions.list

  # GCS (Terraform state backend)
  - storage.buckets.get
  - storage.objects.create
  - storage.objects.delete
  - storage.objects.get
  - storage.objects.list

  # General / data sources
  - compute.zones.get
  - compute.regions.get
```

### Create the Custom Role

```bash
PROJECT_ID="my-gcp-project-id"

# Save permissions to a YAML file
cat > /tmp/npa-deployer-role.yaml <<'EOF'
title: NPA Publisher Terraform Deployer
description: Permissions required to deploy NPA Publishers via Terraform
stage: GA
includedPermissions:
  - compute.networks.create
  - compute.networks.delete
  - compute.networks.get
  - compute.networks.list
  - compute.networks.updatePolicy
  - compute.subnetworks.create
  - compute.subnetworks.delete
  - compute.subnetworks.get
  - compute.subnetworks.list
  - compute.subnetworks.use
  - compute.subnetworks.setPrivateIpGoogleAccess
  - compute.routers.create
  - compute.routers.delete
  - compute.routers.get
  - compute.routers.list
  - compute.routers.update
  - compute.firewalls.create
  - compute.firewalls.delete
  - compute.firewalls.get
  - compute.firewalls.list
  - compute.instances.create
  - compute.instances.delete
  - compute.instances.get
  - compute.instances.list
  - compute.instances.setServiceAccount
  - compute.instances.setMetadata
  - compute.instances.setTags
  - compute.instances.setLabels
  - compute.instances.start
  - compute.instances.stop
  - compute.instances.reset
  - compute.disks.create
  - compute.disks.delete
  - compute.disks.get
  - compute.images.useReadOnly
  - compute.zones.list
  - compute.zones.get
  - compute.regions.list
  - compute.regions.get
  - compute.machineTypes.list
  - compute.machineTypes.get
  - compute.addresses.list
  - iam.serviceAccounts.create
  - iam.serviceAccounts.delete
  - iam.serviceAccounts.get
  - iam.serviceAccounts.list
  - iam.serviceAccounts.actAs
  - resourcemanager.projects.getIamPolicy
  - resourcemanager.projects.setIamPolicy
  - secretmanager.secrets.create
  - secretmanager.secrets.delete
  - secretmanager.secrets.get
  - secretmanager.secrets.list
  - secretmanager.secrets.getIamPolicy
  - secretmanager.secrets.setIamPolicy
  - secretmanager.versions.add
  - secretmanager.versions.destroy
  - secretmanager.versions.get
  - secretmanager.versions.list
  - storage.buckets.get
  - storage.objects.create
  - storage.objects.delete
  - storage.objects.get
  - storage.objects.list
EOF

# Create the custom role
gcloud iam roles create NPAPublisherTerraformDeployer \
  --project="${PROJECT_ID}" \
  --file=/tmp/npa-deployer-role.yaml

rm /tmp/npa-deployer-role.yaml
```

### Create a Terraform Service Account and Bind the Role

```bash
PROJECT_ID="my-gcp-project-id"

# Create dedicated service account for Terraform
gcloud iam service-accounts create npa-terraform \
  --display-name="NPA Publisher Terraform Service Account" \
  --project="${PROJECT_ID}"

# Bind the custom role
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:npa-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="projects/${PROJECT_ID}/roles/NPAPublisherTerraformDeployer"

# Create a key (for local use; Workload Identity Federation is preferred for CI/CD)
gcloud iam service-accounts keys create /tmp/npa-terraform-key.json \
  --iam-account="npa-terraform@${PROJECT_ID}.iam.gserviceaccount.com"

# Use the key
export GOOGLE_APPLICATION_CREDENTIALS="/tmp/npa-terraform-key.json"
terraform apply
```

## CI/CD with Workload Identity Federation

Workload Identity Federation is the recommended approach for CI/CD pipelines. It is the GCP equivalent of the AWS IAM OIDC trust policy — no service account key file is needed.

### GitHub Actions Example

**Step 1: Create the Workload Identity Pool**

```bash
PROJECT_ID="my-gcp-project-id"
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Create the pool
gcloud iam workload-identity-pools create github-actions \
  --location=global \
  --display-name="GitHub Actions Pool" \
  --project="${PROJECT_ID}"

# Create the provider (GitHub OIDC)
gcloud iam workload-identity-pools providers create-oidc github-oidc \
  --location=global \
  --workload-identity-pool=github-actions \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="attribute.repository == 'YOUR_ORG/YOUR_REPO'" \
  --project="${PROJECT_ID}"
```

**Step 2: Bind the Service Account**

```bash
gcloud iam service-accounts add-iam-policy-binding \
  "npa-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions/attribute.repository/YOUR_ORG/YOUR_REPO" \
  --project="${PROJECT_ID}"
```

**Step 3: GitHub Actions Workflow**

```yaml
# .github/workflows/terraform.yml
jobs:
  terraform:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # Required for Workload Identity Federation

    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/providers/github-oidc
          service_account: npa-terraform@PROJECT_ID.iam.gserviceaccount.com

      - uses: google-github-actions/setup-gcloud@v2

      - name: Terraform Init
        run: terraform init
        working-directory: terraform/

      - name: Terraform Plan
        run: terraform plan -out=tfplan
        working-directory: terraform/
        env:
          TF_VAR_netskope_server_url: ${{ secrets.NETSKOPE_SERVER_URL }}
          TF_VAR_netskope_api_key: ${{ secrets.NETSKOPE_API_KEY }}

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main'
        run: terraform apply tfplan
        working-directory: terraform/
```

## Security Best Practices

### 1. Principle of Least Privilege

Use the custom role rather than predefined roles like `roles/editor` or `roles/owner`. The custom role grants exactly what's needed and nothing more.

### 2. Use Workload Identity Federation for CI/CD

Never store service account key files in CI/CD pipelines. Workload Identity Federation eliminates the need for key rotation and reduces the risk of credential leakage.

### 3. Restrict Service Account Key Creation

For human operators, prefer `gcloud auth application-default login` over service account keys. If keys are required, set an expiry and rotate regularly.

### 4. Audit with Cloud Audit Logs

Enable Cloud Audit Logs (Data Access logs) for Secret Manager to track every access to registration tokens:

```bash
gcloud projects get-iam-policy YOUR_PROJECT_ID \
  --flatten="auditConfigs[].auditLogConfigs[]" \
  --format="table(auditConfigs.service,auditConfigs.auditLogConfigs.logType)"
```

### 5. Scope State Backend Access

Grant the Terraform service account access to the specific state bucket, not all GCS buckets:

```bash
gcloud storage buckets add-iam-policy-binding \
  "gs://npa-publisher-terraform-state-${PROJECT_ID}" \
  --member="serviceAccount:npa-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

### 6. Never Use Application Default Credentials in Production CI/CD

`gcloud auth application-default login` is appropriate for local development. CI/CD pipelines should use Workload Identity Federation or a service account.

## Quick Reference

```bash
# Check current identity
gcloud auth list
gcloud config get-value account

# List project IAM bindings for a member
gcloud projects get-iam-policy YOUR_PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:npa-terraform@" \
  --format="table(bindings.role)"

# Test permissions (validates without creating anything)
terraform plan

# Use a specific service account key
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"
terraform apply
```

## Additional Resources

- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — State access permissions
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Deployment instructions
- [GCP IAM Documentation](https://cloud.google.com/iam/docs)
- [GCP Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [GCP Custom Roles](https://cloud.google.com/iam/docs/creating-custom-roles)
