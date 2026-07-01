# Quick Start Guide

Get your Netskope Private Access Publishers deployed on GCP with multi-zone redundancy.

## Table of Contents

- [Prerequisites Checklist](#prerequisites-checklist)
- [Quick Deploy](#quick-deploy)
- [Variable Reference](#variable-reference)
- [Deployment Timeline](#deployment-timeline)
- [Verify Deployment](#verify-deployment)
- [Clean Up](#clean-up)
- [Next Steps](#next-steps)

## Prerequisites Checklist

Before you begin, ensure you have:

- [ ] **Terraform** >= 1.0 installed ([install guide](https://developer.hashicorp.com/terraform/install))
- [ ] **gcloud CLI** installed and authenticated ([install guide](https://cloud.google.com/sdk/docs/install))
- [ ] **GCP project** with billing enabled
- [ ] **GCP credentials** — application default credentials configured (`gcloud auth application-default login`)
- [ ] **Required APIs enabled** in your GCP project (see below)
- [ ] **Netskope API v2 Token** with Infrastructure Management scope ([Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html))
- [ ] **Netskope tenant URL** (e.g., `https://mytenant.goskope.com/api/v2`)
- [ ] **For existing VPC**: VPC self-link and subnet self-links with Private Google Access enabled

### Verify Prerequisites

```bash
# Check Terraform version
terraform version
# Should show >= 1.0

# Check gcloud and active account
gcloud auth list
gcloud config get-value project

# Enable required GCP APIs (one-time per project)
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project=YOUR_PROJECT_ID
```

> **No Marketplace subscription required.** This deployment uses Ubuntu 22.04 LTS as the base image. The Netskope NPA Publisher software is installed at first boot via Netskope's bootstrap script.

## Quick Deploy

### Step 1: Clone and Configure

```bash
# Clone the repository
git clone <repository-url>
cd GCP-NPA-Reference-Architecture-Terraform/terraform

# Create your variables file from the example
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
# Required
gcp_project_id = "my-gcp-project-id"
gcp_region     = "us-central1"

# Publisher
publisher_name         = "my-npa-publisher"
publisher_count        = 2          # Minimum 2 for HA — enforced by validation
publisher_machine_type = "n2-standard-2"

# VPC (defaults to creating a new one)
create_vpc  = true
subnet_cidr = "10.0.0.0/24"

# Labels
environment   = "Production"
cost_center   = "IT-Operations"
project_label = "NPA-Publisher"
```

### Step 2: Set Sensitive Values via Environment Variables

```bash
# Set Netskope credentials (never put these in terraform.tfvars)
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-netskope-api-key"

# Confirm GCP credentials are active
gcloud auth application-default print-access-token > /dev/null && echo "Credentials OK"
```

### Step 3: Initialize and Plan

```bash
# Initialize Terraform (downloads providers)
terraform init

# Review what will be created
terraform plan
```

Review the plan output carefully. You should see resources being created for:
- VPC network, subnet, Cloud Router, Cloud NAT (if `create_vpc = true`)
- Firewall rules (egress, IAP ingress for SSH)
- Service account + IAM bindings
- Secret Manager secrets (registration tokens)
- Netskope publishers and tokens
- Compute Engine instances (Shielded VM, OS Login enabled)

### Step 4: Apply

```bash
# Deploy the infrastructure
terraform apply
```

Type `yes` when prompted. Terraform creates all resources. Publishers register automatically via the startup script — no separate step needed.

## Variable Reference

### Required Variables

| Variable | Description | Example |
|---|---|---|
| `gcp_project_id` | GCP project ID | `my-gcp-project-id` |
| `netskope_server_url` | Netskope API URL | `https://mytenant.goskope.com/api/v2` |
| `netskope_api_key` | Netskope API key (sensitive) | Set via `TF_VAR_netskope_api_key` |
| `publisher_name` | Base name for publishers (3-26 chars, lowercase) | `my-npa-publisher` |

### Publisher Variables

| Variable | Default | Description |
|---|---|---|
| `publisher_count` | `2` | Number of publisher instances (minimum 2 for HA) |
| `publisher_machine_type` | `n2-standard-2` | GCP machine type |
| `publisher_image_self_link` | `""` | Custom image (default: Ubuntu 22.04 LTS) |
| `gcp_region` | `us-central1` | GCP region for deployment |
| `zones` | `[]` | Specific zones (default: auto-select first N available) |

### VPC Variables

| Variable | Default | Description |
|---|---|---|
| `create_vpc` | `true` | Create new VPC or use existing |
| `subnet_cidr` | `10.0.0.0/24` | CIDR for the publisher subnet |
| `existing_network_self_link` | `null` | VPC self-link when `create_vpc = false` |
| `existing_subnet_self_links` | `[]` | Subnet self-links when `create_vpc = false` |

### Monitoring and Label Variables

| Variable | Default | Description |
|---|---|---|
| `enable_monitoring` | `false` | Install Google Cloud Ops Agent |
| `environment` | `Production` | Environment label (Production/Staging/Development/Test) |
| `cost_center` | `IT-Operations` | Cost center label |
| `project_label` | `NPA-Publisher` | Project label |
| `additional_labels` | `{}` | Extra labels for all resources |

## Deployment Timeline

Typical deployment time: **10-18 minutes**

```
t=0m    terraform apply starts
        ├─ Netskope publishers created via API
        ├─ Registration tokens generated, stored in Secret Manager
        └─ VPC resources creation begins (if new VPC)

t=1-2m  GCP resources created
        ├─ VPC network, subnet, Cloud Router, Cloud NAT
        ├─ Firewall rules, service account, IAM bindings
        └─ Secret Manager secrets (tokens stored)

t=2-3m  Compute Engine instances launch
        ├─ Shielded VM boot, OS Login enabled
        └─ Startup script begins executing

t=3-5m  Startup script: Ops Agent install (if enabled)

t=5-12m Startup script: Netskope bootstrap (~5-10 min)
        ├─ Docker installed, publisher container pulled
        └─ npa_publisher_wizard extracted

t=12-15m Startup script: token fetch + registration
        ├─ Python3 urllib fetches token from Secret Manager
        └─ npa_publisher_wizard -token "$TOKEN" runs

t=10-18m terraform apply completes
        └─ Outputs displayed
```

> **Note**: Terraform completes after resource creation. Publisher registration continues in the startup script after `terraform apply` returns — check Cloud Logging or the Netskope UI to confirm **Connected** status.

## Verify Deployment

### 1. Check Terraform Outputs

```bash
# Display all outputs
terraform output

# Get IAP SSH commands (ready to copy and run)
terraform output iap_ssh_commands

# Get Cloud Logging query
terraform output log_query
```

**Expected output:**
```
iap_ssh_commands = {
  "my-npa-publisher"   = "gcloud compute ssh my-npa-publisher --tunnel-through-iap --zone us-central1-b --project my-project"
  "my-npa-publisher-2" = "gcloud compute ssh my-npa-publisher-2 --tunnel-through-iap --zone us-central1-c --project my-project"
}
publisher_private_ips = {
  "my-npa-publisher"   = "10.0.0.2"
  "my-npa-publisher-2" = "10.0.0.3"
}
publisher_zones = {
  "my-npa-publisher"   = "us-central1-b"
  "my-npa-publisher-2" = "us-central1-c"
}
```

### 2. Verify in Netskope UI

1. Log in to your Netskope tenant
2. Go to **Settings → Security Cloud Platform → Publishers**
3. Look for publishers named `my-npa-publisher` and `my-npa-publisher-2`
4. Status should be **Connected** (may take 12-18 minutes after `terraform apply` completes)

### 3. Check Startup Script Logs

```bash
# View startup script output via Cloud Logging (no SSH required)
gcloud logging read \
  'resource.type="gce_instance" AND logName:"google-startup-scripts"' \
  --project=YOUR_PROJECT_ID \
  --limit=50 \
  --format="table(timestamp,jsonPayload.message)"
```

Look for `NPA Publisher wizard completed successfully` and `startup complete` in the output.

### 4. Connect via IAP SSH (Optional)

```bash
# Copy the command from terraform output iap_ssh_commands, or:
gcloud compute ssh my-npa-publisher \
  --tunnel-through-iap \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID

# Once connected, check publisher container status:
sudo docker ps
sudo docker logs $(sudo docker ps -q) 2>&1 | tail -20
```

## Clean Up

```bash
# Destroy all resources created by Terraform
terraform destroy
```

Type `yes` when prompted. This will:
- Terminate Compute Engine instances
- Delete Netskope publishers and tokens (via Netskope provider)
- Delete Secret Manager secrets
- Delete IAM resources (service account, bindings)
- Delete VPC resources (if created by this deployment)

> **Note**: If a publisher is currently **Connected** in Netskope, the Netskope provider's delete call may fail. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the recovery procedure.

**Verify cleanup:**
```bash
# Confirm no resources remain in state
terraform state list
# Should return empty

# Check GCP for remaining instances
gcloud compute instances list \
  --filter="labels.managed_by=terraform AND labels.project=npa-publisher" \
  --project=YOUR_PROJECT_ID
```

## Next Steps

1. **Set up remote state** — For team use, create a GCS bucket and enable the backend for state storage and locking. See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md).

2. **Review security** — Understand the IAM model and GCP security layers. See [ARCHITECTURE.md](ARCHITECTURE.md) and [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md).

3. **Enable monitoring** — Install the Ops Agent by setting `enable_monitoring = true`. See [OPERATIONS.md](OPERATIONS.md).

4. **Set up pre-commit hooks** — Install quality gates for your team:
   ```bash
   pip install pre-commit
   pre-commit install
   ```

5. **Plan for operations** — Review day-2 procedures for scaling, upgrades, and troubleshooting. See [OPERATIONS.md](OPERATIONS.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Additional Resources

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Detailed deployment with multiple paths
- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture deep-dive
- [DEVOPS-NOTES.md](DEVOPS-NOTES.md) — Technical patterns and provider details
- [Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html)
- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskope/netskope/latest/docs)
