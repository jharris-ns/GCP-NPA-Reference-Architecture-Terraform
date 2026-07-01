# Deployment Guide

Detailed deployment instructions for the NPA Publisher Terraform configuration on GCP, covering multiple deployment paths.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Deployment Paths Overview](#deployment-paths-overview)
- [Path A: Local State + New VPC](#path-a-local-state--new-vpc)
- [Path B: Remote State + New VPC](#path-b-remote-state--new-vpc)
- [Path C: Existing VPC](#path-c-existing-vpc)
- [Configuring Variables](#configuring-variables)
- [Reviewing the Plan](#reviewing-the-plan)
- [Applying the Configuration](#applying-the-configuration)
- [Post-Deployment Verification](#post-deployment-verification)
- [Clean Up](#clean-up)

## Prerequisites

### Tool Versions

| Tool | Minimum Version | Check Command |
|---|---|---|
| Terraform | >= 1.0 | `terraform version` |
| gcloud CLI | any current | `gcloud version` |
| pre-commit (optional) | any | `pre-commit --version` |

### GCP Requirements

- **Project**: Active GCP project with billing enabled
- **Credentials**: Application Default Credentials configured (`gcloud auth application-default login`) or a service account key with deployment permissions (see [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md))
- **APIs enabled** in the target project:
  ```bash
  gcloud services enable \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    iap.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --project=YOUR_PROJECT_ID
  ```

> **No Marketplace subscription required.** Publishers install on Ubuntu 22.04 LTS via Netskope's bootstrap script. No GCP Marketplace image subscription or acceptance of additional terms is needed.

### Netskope Requirements

- **Tenant**: Active Netskope tenant with NPA license
- **API Token**: REST API v2 token with **Infrastructure Management** scope
- **Tenant URL**: Your Netskope API endpoint (e.g., `https://mytenant.goskope.com/api/v2`)

## Deployment Paths Overview

| Path | State | VPC | Best For |
|---|---|---|---|
| **A** | Local | New | Quick start, solo developer, learning |
| **B** | Remote (GCS) | New | Teams, production, CI/CD |
| **C** | Either | Existing | Integration with existing GCP infrastructure |

## Path A: Local State + New VPC

The fastest path for getting started. State is stored locally.

### Step 1: Clone and Initialize

```bash
git clone <repository-url>
cd GCP-NPA-Reference-Architecture-Terraform/terraform

terraform init
```

### Step 2: Configure Variables

```bash
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
gcp_project_id = "my-gcp-project-id"
gcp_region     = "us-central1"

publisher_name         = "my-npa-publisher"
publisher_count        = 2
publisher_machine_type = "n2-standard-2"

create_vpc  = true
subnet_cidr = "10.0.0.0/24"

environment   = "Production"
cost_center   = "IT-Operations"
project_label = "NPA-Publisher"
```

Set sensitive values via environment variables:
```bash
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"
```

### Step 3: Plan and Apply

```bash
terraform plan
terraform apply
```

### Step 4: Verify

```bash
terraform output
terraform output iap_ssh_commands
```

> **Limitation**: Local state cannot be shared with team members and has no locking. See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for migration to remote state.

## Path B: Remote State + New VPC

The recommended path for teams and production deployments. GCS provides native state locking.

### Step 1: Create the GCS State Bucket

Before configuring the backend, create the GCS bucket:

```bash
PROJECT_ID="my-gcp-project-id"
BUCKET="npa-publisher-terraform-state-${PROJECT_ID}"
REGION="us-central1"

# Create bucket with uniform access and versioning
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access

# Enable versioning (allows state recovery)
gcloud storage buckets update "gs://${BUCKET}" --versioning

echo "bucket = \"${BUCKET}\""
echo "prefix = \"npa-publishers\""
```

See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for detailed bucket configuration including CMEK encryption and IAM.

### Step 2: Configure the Backend

Edit `terraform/backend.tf` — uncomment the backend block and fill in the bucket name:

```hcl
terraform {
  backend "gcs" {
    bucket = "npa-publisher-terraform-state-my-gcp-project-id"
    prefix = "npa-publishers"

    # Optional: CMEK encryption
    # encryption_key = "projects/PROJECT_ID/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY"
  }
}
```

### Step 3: Initialize with Remote Backend

```bash
terraform init
```

If you have existing local state, use:
```bash
terraform init -migrate-state
```

### Step 4: Configure Variables and Deploy

```bash
cp example.tfvars terraform.tfvars
# Edit terraform.tfvars with your values

export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"

terraform plan
terraform apply
```

State is now stored in GCS with native locking. Team members can use the same backend.

## Path C: Existing VPC

Deploy publishers into an existing GCP VPC. Works with either local or remote state.

### Requirements

Your existing VPC must have:
- **A subnet** with **Private Google Access enabled** (required for Secret Manager, Cloud Logging, Cloud Monitoring access without external IPs)
- **Cloud Router and Cloud NAT** configured for the region (publishers need outbound internet access to reach Netskope)
- **Firewall rules** allowing:
  - Egress: all outbound (publishers initiate connections to Netskope)
  - Ingress from `35.235.240.0/20` on port 22 (required for IAP SSH access)

### Step 1: Gather VPC Information

```bash
PROJECT_ID="my-gcp-project-id"

# List VPC networks
gcloud compute networks list --project="${PROJECT_ID}"

# Get subnet self-link (needed for existing_subnet_self_links)
gcloud compute networks subnets describe my-subnet \
  --region=us-central1 \
  --project="${PROJECT_ID}" \
  --format="value(selfLink)"

# Get network self-link (needed for existing_network_self_link)
gcloud compute networks describe my-vpc \
  --project="${PROJECT_ID}" \
  --format="value(selfLink)"
```

### Step 2: Configure Variables

```hcl
# terraform.tfvars

# Disable VPC creation
create_vpc = false

# Provide existing VPC details (use self-links, not names)
existing_network_self_link = "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/global/networks/my-vpc"
existing_subnet_self_links = [
  "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/regions/us-central1/subnetworks/my-subnet",
]

# Publisher configuration
gcp_project_id         = "my-gcp-project-id"
gcp_region             = "us-central1"
publisher_name         = "my-npa-publisher"
publisher_count        = 2
publisher_machine_type = "n2-standard-2"
```

### Step 3: Deploy

```bash
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"

terraform init
terraform plan
terraform apply
```

> **Note**: When using an existing VPC, Terraform only creates the firewall rules, service account, IAM bindings, Secret Manager secrets, Netskope publishers, and Compute Engine instances. VPC resources are not managed.

## Configuring Variables

### Three Methods

**1. terraform.tfvars file (recommended for most values):**
```hcl
# terraform.tfvars
gcp_project_id         = "my-gcp-project-id"
publisher_name         = "my-npa-publisher"
publisher_count        = 2
publisher_machine_type = "n2-standard-2"
```

**2. Environment variables (required for secrets):**
```bash
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"
```

**3. Command-line flags:**
```bash
terraform apply \
  -var="publisher_name=my-npa-publisher" \
  -var="publisher_count=3"
```

### Security Recommendation

Never put `netskope_api_key` or `netskope_server_url` in `terraform.tfvars`. Use environment variables instead:

```bash
# Good — secret not written to disk
export TF_VAR_netskope_api_key="your-api-key"

# Bad — secret stored in a file that may be committed or logged
# netskope_api_key = "your-api-key"  # Don't do this
```

The `.gitignore` file excludes `terraform.tfvars` from Git, but environment variables are safer.

## Reviewing the Plan

Always review the plan before applying:

```bash
terraform plan
```

### Understanding Plan Output

```
Terraform will perform the following actions:

  # google_compute_instance.publisher["my-npa-publisher"] will be created
  + resource "google_compute_instance" "publisher" {
      + machine_type = "n2-standard-2"
      + zone         = "us-central1-b"
      ...
    }

Plan: 21 to add, 0 to change, 0 to destroy.
```

Key symbols:
- `+` — Resource will be created
- `~` — Resource will be updated in-place
- `-` — Resource will be destroyed
- `-/+` — Resource will be destroyed and recreated

### Saving Plans

For CI/CD or audit purposes, save the plan to a file:

```bash
# Save plan
terraform plan -out=tfplan

# Apply the exact saved plan (no re-evaluation)
terraform apply tfplan
```

## Applying the Configuration

```bash
terraform apply
```

Terraform will:
1. Show the execution plan
2. Prompt for confirmation (`yes` / `no`)
3. Create resources in dependency order
4. Display outputs on completion

### Monitoring Progress

Terraform displays each resource as it's created:

```
google_compute_network.vpc[0]: Creating...
google_compute_network.vpc[0]: Creation complete after 8s
google_compute_subnetwork.publisher[0]: Creating...
google_compute_subnetwork.publisher[0]: Creation complete after 10s
...
netskope_npa_publisher.this["my-npa-publisher"]: Creating...
netskope_npa_publisher.this["my-npa-publisher"]: Creation complete after 2s
...
google_compute_instance.publisher["my-npa-publisher"]: Creating...
google_compute_instance.publisher["my-npa-publisher"]: Creation complete after 30s

Apply complete! Resources: 21 added, 0 changed, 0 destroyed.
```

> **Important**: `terraform apply` completes when GCP resources are created — not when publishers are registered. Publisher registration runs asynchronously in the startup script (12-18 min total). Check Cloud Logging or the Netskope UI for registration status.

### Handling Failures

If `terraform apply` fails partway through:

1. Read the error message — it identifies the specific resource and reason
2. Fix the issue (e.g., missing permission, API not enabled, quota exceeded)
3. Run `terraform apply` again — Terraform picks up where it left off

Terraform is idempotent. Already-created resources are not recreated.

## Post-Deployment Verification

### 1. Terraform Outputs

```bash
terraform output
```

### 2. GCP Resources

```bash
PROJECT_ID=$(terraform output -raw -no-color 2>/dev/null | grep gcp_project_id || echo "YOUR_PROJECT_ID")

# Check Compute Engine instances
gcloud compute instances list \
  --filter="labels.managed_by=terraform AND labels.project=npa-publisher" \
  --project=YOUR_PROJECT_ID \
  --format="table(name,zone,status,networkInterfaces[0].networkIP)"

# Check startup script logs
terraform output -raw log_query | bash
```

### 3. Netskope UI

1. Log in to Netskope tenant
2. Navigate to **Settings → Security Cloud Platform → Publishers**
3. Verify publisher status is **Connected**

### 4. IAP SSH Access

```bash
# Get the pre-built SSH command from outputs
terraform output iap_ssh_commands

# Run the command for one publisher, e.g.:
gcloud compute ssh my-npa-publisher \
  --tunnel-through-iap \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID

# Once connected, check publisher container:
sudo docker ps
sudo docker logs $(sudo docker ps -q) 2>&1 | tail -20
```

### 5. Drift Detection

Run `terraform plan` periodically to check for configuration drift:

```bash
terraform plan
# "No changes" means infrastructure matches configuration
```

## Clean Up

### Destroy NPA Infrastructure

```bash
terraform destroy
```

This removes all resources managed by Terraform:
- Compute Engine instances
- Netskope publishers and tokens
- Secret Manager secrets and versions
- Service account and IAM bindings
- Firewall rules
- VPC resources (if created by this deployment)

> **Note**: If a publisher is **Connected** in Netskope, the Netskope provider's delete call may fail. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the recovery procedure using `terraform state rm`.

### Verify Cleanup

```bash
# No resources should remain in state
terraform state list

# Check GCP for any remaining resources
gcloud compute instances list \
  --filter="labels.managed_by=terraform AND labels.project=npa-publisher" \
  --project=YOUR_PROJECT_ID
```

## Additional Resources

- [QUICKSTART.md](QUICKSTART.md) — Fast deployment (4 steps)
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — Remote state setup
- [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md) — Required permissions
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Common issues
- [OPERATIONS.md](OPERATIONS.md) — Day-2 operations
