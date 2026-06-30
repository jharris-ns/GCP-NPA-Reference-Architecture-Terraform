# Terraform Technical Notes

Technical deep-dive into the Terraform patterns, Netskope provider integration, GCP-specific design decisions, and development tooling used in this project.

## Table of Contents

- [Netskope Terraform Provider](#netskope-terraform-provider)
- [Publisher Registration Flow](#publisher-registration-flow)
- [for_each Pattern](#for_each-pattern)
- [Conditional Resource Creation](#conditional-resource-creation)
- [Startup Script Template](#startup-script-template)
- [IAM Configuration](#iam-configuration)
- [GCP vs AWS Design Decisions](#gcp-vs-aws-design-decisions)
- [Deployment Flow](#deployment-flow)
- [Resource Dependencies](#resource-dependencies)
- [Pre-commit Hooks and Code Quality](#pre-commit-hooks-and-code-quality)
- [Lifecycle Rules](#lifecycle-rules)
- [Provider Version Constraints](#provider-version-constraints)

## Netskope Terraform Provider

### Provider Configuration

The Netskope provider is configured in `terraform/providers.tf`:

```hcl
provider "netskope" {
  server_url = var.netskope_server_url
  api_key    = var.netskope_api_key
}
```

This is identical to the AWS implementation. The Netskope provider is cloud-agnostic.

### Authentication

The provider authenticates using a REST API v2 token. The recommended approach is environment variables:

```bash
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"
```

The API key requires the **Infrastructure Management** scope in Netskope:
1. Netskope UI → **Settings → Tools → REST API v2**
2. Create or select a token
3. Enable **Infrastructure Management** (read/write)

### Resources Used

| Resource | File | Purpose |
|---|---|---|
| `netskope_npa_publisher` | `terraform/netskope.tf` | Creates publisher records in Netskope tenant |
| `netskope_npa_publisher_token` | `terraform/netskope.tf` | Generates one-time registration tokens |

### Provider Schema Notes

The Netskope provider uses `publisher_name` (not `name`) on the publisher resource:

```hcl
resource "netskope_npa_publisher" "this" {
  for_each     = local.publishers
  publisher_name = each.key   # ← "publisher_name", not "name"
}

resource "netskope_npa_publisher_token" "this" {
  for_each     = local.publishers
  publisher_id = netskope_npa_publisher.this[each.key].publisher_id
}
```

The `publisher_id` attribute (not `id`) is used to reference the publisher from the token resource.

### Connected Publisher Deletion Issue

**Symptom**: `terraform destroy` fails with an error when a publisher is Connected.

**Cause**: Netskope rejects API deletion of a publisher with active connections.

**Workaround**:
```bash
# Remove from Terraform state
terraform state rm 'netskope_npa_publisher.this["my-publisher"]'
terraform state rm 'netskope_npa_publisher_token.this["my-publisher"]'

# Delete via Netskope API (disconnects and removes)
curl -X DELETE \
  -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers/PUBLISHER_ID"

# Then destroy remaining GCP resources
terraform destroy
```

## Publisher Registration Flow

The end-to-end flow from Terraform to a connected publisher:

```
1. Terraform creates netskope_npa_publisher.this[each.key]
   └─ Netskope API: POST /api/v2/infrastructure/publishers
      → publisher record created, publisher_id returned

2. Terraform creates netskope_npa_publisher_token.this[each.key]
   └─ Netskope API: POST /api/v2/infrastructure/publishers/{id}/token
      → one-time registration token generated

3. Terraform creates google_secret_manager_secret + secret_version
   └─ Token stored in Secret Manager (encrypted at rest by Google)
   └─ IAM binding: publisher service account → secretAccessor on this secret only

4. Terraform creates google_compute_instance.publisher[each.key]
   └─ VM launches with startup script in instance metadata
   └─ No external IP — egress via Cloud NAT
   └─ Service account attached (provides identity for GCP API calls)
   └─ terraform apply completes at this point

5. VM boots and runs startup script (asynchronous, post-apply):
   ├─ Wait for GCP metadata server (up to 60s)
   ├─ Set /tmp permissions to 777 (Netskope publisher requirement)
   ├─ Pre-seed .nonat flag (GCP MTU 1460 workaround)
   ├─ Install Ops Agent (if enable_monitoring = true, BEFORE bootstrap)
   ├─ Download and run Netskope bootstrap.sh:
   │    - Installs Docker
   │    - Pulls NPA Publisher container
   │    - Extracts npa_publisher_wizard
   │    - Removes curl and wget (security hardening)
   │    - Configures .nonat mode for GCP
   └─ Fetch token from Secret Manager using Python3 urllib:
        - Get service account access token from GCP metadata server
        - Call Secret Manager REST API with the access token
        - Retry loop: 30 attempts × 5s = 150s max
   └─ Run npa_publisher_wizard -token "$TOKEN"
        └─ Token consumed (single-use)
        └─ Outbound TLS connection to Netskope NewEdge established

6. Publisher appears as "Connected" in Netskope UI (12-18 min after apply)
```

### Why Python3 urllib Instead of curl/wget

The Netskope `bootstrap.sh` removes `curl` and `wget` as a security hardening step. The startup script fetches the Secret Manager token AFTER bootstrap completes. Since `curl` and `wget` are unavailable at that point, the token fetch uses Python 3's built-in `urllib` library, which is always present in the Ubuntu 22.04 base image.

```python
# Token fetch uses urllib — no external dependencies
import urllib.request, json, base64, sys, time

def get_access_token():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())["access_token"]
```

### The .nonat Pre-seed

GCP uses MTU 1460 (not 1500). The Netskope publisher container needs to be started in "No NAT mode" on GCP to handle this correctly. The startup script pre-seeds the `.nonat` flag file before bootstrap runs. `bootstrap.sh` also calls `configure_nonat_mode_for_gcp` which creates the same file — the pre-seed is belt-and-suspenders.

```bash
mkdir -p /home/ubuntu/resources
touch /home/ubuntu/resources/.nonat
chown -R ubuntu:ubuntu /home/ubuntu/resources
```

### Ops Agent Must Install Before Bootstrap

The Google Cloud Ops Agent installer requires `curl`. Since `bootstrap.sh` removes `curl`, the Ops Agent must be installed BEFORE the bootstrap runs. The startup script enforces this order explicitly.

### Token Security Properties

- The token is stored in Secret Manager — never in instance metadata or startup script template
- The startup script template (stored in Terraform state) contains only the secret name, not the token value
- The token is fetched at runtime by the instance using its service account identity via the GCP metadata server
- The token is held only in shell memory (`TOKEN=$(...)`); it is not written to disk
- After registration, the token is `unset TOKEN` from the shell environment
- The token is never transmitted through the Terraform operator workstation

## for_each Pattern

### The publishers Local

The `local.publishers` map is the core of the multi-instance pattern:

```hcl
# terraform/locals.tf
locals {
  publishers = {
    for i in range(var.publisher_count) :
    (i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}") => {
      index = i
      name  = i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}"
    }
  }
}
```

With `publisher_name = "my-pub"` and `publisher_count = 3`, this generates:

```hcl
{
  "my-pub"   = { index = 0, name = "my-pub" }
  "my-pub-2" = { index = 1, name = "my-pub-2" }
  "my-pub-3" = { index = 2, name = "my-pub-3" }
}
```

### State Addressing

Resources using `for_each` are addressed by their map key:

```
netskope_npa_publisher.this["my-pub"]
netskope_npa_publisher.this["my-pub-2"]
google_compute_instance.publisher["my-pub"]
google_compute_instance.publisher["my-pub-2"]
google_secret_manager_secret.publisher_token["my-pub"]
google_secret_manager_secret_version.publisher_token["my-pub"]
```

### Why for_each Over count

With `count`, removing the middle instance would shift index assignments and destroy the wrong resources. With `for_each` keyed by name, only the specifically named publisher is affected.

### Zone Distribution

Instances are distributed across zones using modulo arithmetic:

```hcl
zone = local.zones[each.value.index % length(local.zones)]
```

With 2 zones and 4 publishers:
| Publisher | Index | Index % 2 | Zone |
|---|---|---|---|
| my-pub | 0 | 0 | us-central1-b |
| my-pub-2 | 1 | 1 | us-central1-c |
| my-pub-3 | 2 | 0 | us-central1-b |
| my-pub-4 | 3 | 1 | us-central1-c |

### Zone Auto-Selection

`local.zones` defaults to the first N available zones in `gcp_region`, where N = `publisher_count`:

```hcl
zones = (
  length(var.zones) > 0
  ? var.zones
  : slice(data.google_compute_zones.available.names, 0, min(var.publisher_count, length(data.google_compute_zones.available.names)))
)
```

This ensures 2 publishers get 2 distinct zones, 3 publishers get 3 distinct zones, etc.

## Conditional Resource Creation

### count for On/Off Toggles

VPC resources use `count` with 0 or 1:

```hcl
resource "google_compute_network" "vpc" {
  count = var.create_vpc ? 1 : 0
  # Created if create_vpc = true, skipped if false
}
```

Monitoring uses `count` for the optional resource metadata writer:

```hcl
resource "google_project_iam_member" "publisher_resource_metadata_writer" {
  count   = var.enable_monitoring ? 1 : 0
  role    = "roles/stackdriver.resourceMetadata.writer"
  ...
}
```

### locals.tf Conditional Resolution

`locals.tf` resolves network references once so downstream files never check `var.create_vpc` directly:

```hcl
network_self_link = (
  var.create_vpc
  ? google_compute_network.vpc[0].self_link
  : var.existing_network_self_link
)

subnet_self_links = (
  var.create_vpc
  ? [google_compute_subnetwork.publisher[0].self_link]
  : var.existing_subnet_self_links
)
```

## Startup Script Template

### Template File

The startup script is in `terraform/templates/startup.sh.tftpl`. It uses Terraform's `templatefile()` function with these variables:

| Variable | Type | Purpose |
|---|---|---|
| `enable_monitoring` | bool | Whether to install the Ops Agent |
| `secret_name` | string | Secret Manager secret ID for the token |
| `project_id` | string | GCP project ID (for Secret Manager API URL) |
| `publisher_name` | string | Publisher name (log messages only) |

### Template Rendering

The template is rendered in `compute_publisher.tf`:

```hcl
metadata = {
  enable-oslogin = "TRUE"
  startup-script = templatefile("${path.module}/templates/startup.sh.tftpl", {
    enable_monitoring = var.enable_monitoring
    secret_name       = google_secret_manager_secret.publisher_token[each.key].secret_id
    project_id        = var.gcp_project_id
    publisher_name    = each.key
  })
}
```

### Template Syntax

| Syntax | Purpose | Example |
|---|---|---|
| `${var}` | Variable interpolation | `${project_id}` |
| `%{ if cond ~}` | Conditional block start | `%{ if enable_monitoring ~}` |
| `%{ endif ~}` | Conditional block end | `%{ endif ~}` |
| `~` | Strip surrounding whitespace | Prevents blank lines |
| `$${VAR}` | Literal `${VAR}` in shell (escape for templatefile) | `$${SUDO_USER:-$(logname)}` |

Note: Shell variable references within the template use `$${...}` (double `$`) to prevent Terraform from interpreting them as template interpolations.

## IAM Configuration

### Service Account Pattern (No Instance Profile Wrapper)

GCP collapses the AWS three-resource pattern (Role + Instance Profile + Attachments) into a simpler structure:

**AWS pattern:**
```
aws_iam_role.publisher
  └─► aws_iam_instance_profile.publisher  ← required wrapper
        └─► aws_instance.publisher (iam_instance_profile)
```

**GCP pattern:**
```
google_service_account.publisher
  └─► google_compute_instance.publisher (service_account.email)
```

No "instance profile" wrapper resource exists in GCP. The service account is attached directly.

### IAM Binding Granularity

For Secret Manager, IAM bindings are applied at the **secret resource level** (not project level):

```hcl
# Correct: scoped to specific secret
resource "google_secret_manager_secret_iam_member" "publisher_token_access" {
  for_each  = local.publishers
  secret_id = google_secret_manager_secret.publisher_token[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.publisher.email}"
}
```

This ensures publisher VM can read only its own registration token, not other publishers' tokens.

### No SSM Automation Role Equivalent

The AWS architecture required a separate "SSM Automation role" to resolve registration tokens server-side without transiting the operator workstation. In GCP, this role is eliminated:

- The VM's startup script runs as the VM's service account
- The service account fetches the token from Secret Manager using its GCP metadata server identity
- The token never transits the operator workstation — it goes directly from Secret Manager to instance memory within GCP

This is equivalent security with a simpler IAM structure.

## GCP vs AWS Design Decisions

### No Public Subnets

AWS requires public subnets + Internet Gateway + route tables for NAT Gateway public IPs. GCP collapses this: Cloud NAT is a regional service that handles all egress for instances without external IPs. There are no public subnets in this architecture.

### Firewall Rules Are VPC-Level, Not Per-Instance

AWS security groups are attached to instances at creation. GCP firewall rules are applied to the VPC and target instances via network tags (`["npa-publisher"]` on the VM, `target_tags = ["npa-publisher"]` on the rule). The instance does not reference the firewall rule directly.

### Private Google Access Replaces VPC Endpoints

The AWS architecture requires three VPC Interface Endpoints (ssm, ssmmessages, ec2messages) for instances to reach AWS APIs without internet access. GCP replaces this with `private_ip_google_access = true` on the subnet — a single subnet attribute enables access to all Google APIs without internet or VPC endpoints.

### IAP TCP Tunnel Replaces SSM Session Manager

| Feature | AWS | GCP |
|---|---|---|
| Shell access without public IP | SSM Session Manager (IAM-controlled) | IAP TCP tunnel (IAM + firewall rule) |
| Access method | `aws ssm start-session --target INSTANCE_ID` | `gcloud compute ssh --tunnel-through-iap INSTANCE_NAME --zone ZONE` |
| GCP firewall rule needed | No (SSM is IAM-only) | Yes (`35.235.240.0/20` → port 22) |
| Access control | IAM policy on the instance | `roles/iap.tunnelResourceAccessor` + firewall rule |

### GCS Backend Has No DynamoDB Equivalent

Terraform's GCS backend implements state locking natively via GCS object conditional updates. The AWS architecture requires a separate DynamoDB table for locking. The GCS backend eliminates this resource.

### Default Disk Encryption

GCP encrypts all persistent disk data at rest by default (Google-managed keys). This is equivalent to the AWS `root_block_device { encrypted = true }` setting — it's the default and doesn't need to be configured. CMEK via `disk_encryption_key` block can be added for customer-managed keys if required.

## Deployment Flow

### Terraform Apply Sequence

```
1. Provider Initialization
   ├─ Google provider (project, region)
   └─ Netskope provider (server_url, api_key)

2. Data Source Queries
   ├─ data.google_compute_zones.available (query available zones)
   └─ data.google_compute_image.ubuntu[0] (find Ubuntu 22.04 LTS image)

3. VPC Resources (if create_vpc = true)
   ├─ google_compute_network.vpc[0]
   ├─ google_compute_subnetwork.publisher[0]
   ├─ google_compute_router.publisher[0]
   └─ google_compute_router_nat.publisher[0]

4. Firewall Rules
   ├─ google_compute_firewall.publisher_egress
   └─ google_compute_firewall.publisher_iap

5. IAM Resources
   ├─ google_service_account.publisher
   ├─ google_project_iam_member.publisher_log_writer
   ├─ google_project_iam_member.publisher_metric_writer
   └─ google_project_iam_member.publisher_resource_metadata_writer (if monitoring)

6. Netskope Resources
   ├─ netskope_npa_publisher.this (for_each: create publishers)
   └─ netskope_npa_publisher_token.this (for_each: generate tokens)

7. Secret Manager Resources
   ├─ google_secret_manager_secret.publisher_token (for_each)
   ├─ google_secret_manager_secret_version.publisher_token (for_each)
   └─ google_secret_manager_secret_iam_member.publisher_token_access (for_each)

8. Compute Engine Instances
   └─ google_compute_instance.publisher (for_each: launch instances)

terraform apply completes here (~2-3 minutes from start)

9. VM Startup Scripts run asynchronously (12-18 minutes total):
   └─ Wait for metadata server
   └─ Set /tmp permissions, pre-seed .nonat
   └─ Install Ops Agent (if monitoring enabled)
   └─ Run bootstrap.sh (~5-10 minutes)
   └─ Fetch token from Secret Manager (Python3 urllib)
   └─ Run npa_publisher_wizard -token "$TOKEN"
   └─ Publisher appears Connected in Netskope UI
```

### Terraform Destroy Sequence

```
1. Compute Engine instances terminated
2. Secret Manager IAM bindings removed
3. Secret Manager versions and secrets deleted
4. Netskope publishers and tokens deleted (via provider)
5. IAM resources deleted (service account, project bindings)
6. Firewall rules deleted
7. VPC resources deleted (if created):
   ├─ Cloud NAT removed
   ├─ Cloud Router removed
   ├─ Subnet deleted
   └─ VPC network deleted

Total Destruction Time: ~2-4 minutes
```

## Resource Dependencies

### Implicit Dependency Graph

Terraform automatically determines resource creation order based on references:

```
data.google_compute_zones.available
  └─► local.zones

data.google_compute_image.ubuntu[0]
  └─► local.publisher_image

google_compute_network.vpc[0]
  └─► google_compute_subnetwork.publisher[0]
  │     └─► local.subnet_self_links
  └─► google_compute_firewall.publisher_egress
  └─► google_compute_firewall.publisher_iap

google_compute_router.publisher[0]
  └─► google_compute_router_nat.publisher[0]

google_service_account.publisher
  └─► google_project_iam_member.publisher_*
  └─► google_secret_manager_secret_iam_member.publisher_token_access

netskope_npa_publisher.this
  └─► netskope_npa_publisher_token.this
        └─► google_secret_manager_secret_version.publisher_token
              └─► google_secret_manager_secret_iam_member.publisher_token_access

google_compute_instance.publisher
  depends_on (implicitly via references):
    ├─ local.zones (from data source)
    ├─ local.publisher_image
    ├─ local.subnet_self_links
    ├─ google_service_account.publisher
    ├─ google_secret_manager_secret.publisher_token (for startup-script secret_name)
    └─ google_compute_firewall (via network tag — no explicit dependency)
```

## Pre-commit Hooks and Code Quality

### Hook Configuration

The `.pre-commit-config.yaml` defines three categories of hooks:

#### Terraform Hooks (pre-commit-terraform)

| Hook | Command | Purpose |
|---|---|---|
| `terraform_fmt` | `terraform fmt` | Consistent code formatting |
| `terraform_validate` | `terraform validate` | Syntax and configuration validation |
| `terraform_docs` | `terraform-docs` | Auto-generate README from variables/outputs |
| `terraform_tflint` | `tflint` | Linting and best practice enforcement |
| `terraform_checkov` | `checkov` | Compliance and misconfiguration detection |

#### General Hooks (pre-commit-hooks)

| Hook | Purpose |
|---|---|
| `check-added-large-files` | Prevent files > 1000 KB |
| `check-merge-conflict` | Detect unresolved merge markers |
| `end-of-file-fixer` | Ensure files end with newline |
| `trailing-whitespace` | Remove trailing whitespace |
| `check-yaml` | Validate YAML syntax |
| `check-json` | Validate JSON syntax |
| `detect-private-key` | Prevent committing private keys |

#### Secrets Detection (gitleaks)

Scans all staged files for patterns matching known secret formats (API keys, tokens, passwords).

### Installation and Usage

```bash
# Install pre-commit
pip install pre-commit

# Install hooks in the repository
pre-commit install

# Run manually on all files
pre-commit run --all-files

# Run a specific hook
pre-commit run terraform_fmt --all-files
pre-commit run terraform_checkov --all-files
```

### TFLint Configuration

The `.tflint.hcl` configures linting with the Google plugin:

```hcl
plugin "google" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
```

### terraform-docs Configuration

The `.terraform-docs.yaml` auto-generates documentation from variables and outputs into `terraform/README.md`.

## Lifecycle Rules

### ignore_changes on Startup Script

Compute Engine instances use `ignore_changes` to prevent unintended replacements:

```hcl
lifecycle {
  ignore_changes = [
    metadata["startup-script"],
    boot_disk,
  ]
}
```

**Why ignore `metadata["startup-script"]`?**
- The startup script only runs on first boot — changing the template after deployment has no effect on running instances anyway
- Without `ignore_changes`, modifying the template would trigger instance replacement (destroy + recreate), disrupting running publishers

**Why ignore `boot_disk`?**
- The Ubuntu image reference (`data.google_compute_image.ubuntu[0].self_link`) updates whenever Google publishes a new image
- Without `ignore_changes`, a newer Ubuntu image would cause Terraform to want to replace all running publishers on every `terraform plan`
- Publishers should be updated via Netskope auto-update, not OS image replacement

For intentional replacement, use `-replace` flags explicitly.

### Intentional Replacement

When you do want to replace an instance (e.g., to pick up a new Ubuntu image or change machine type), you must also replace the Netskope publisher record, token, and Secret Manager version because registration tokens are single-use:

```bash
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
```

### When to Use -replace

| Scenario | Command |
|---|---|
| Instance is unhealthy | `-replace` all four resources (publisher, token, secret_version, instance) |
| Need new Ubuntu image | Same as above |
| Change machine type | Same as above (machine type changes require replacement) |
| Re-run registration (token not consumed) | `gcloud compute instances reset INSTANCE_NAME --zone ZONE` |
| Replace everything | `terraform destroy && terraform apply` |

## Provider Version Constraints

From `terraform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    netskope = {
      source  = "netskopeoss/netskope"
      version = ">= 0.3.3"
    }
  }
}
```

Note: The `null` provider is not used in this GCP implementation. Publisher registration is handled by the VM's startup script (no `null_resource` polling loop needed, unlike the AWS implementation).

### Lock File

The `.terraform.lock.hcl` file pins exact provider versions and checksums:

```bash
# Update lock file after changing version constraints
terraform init -upgrade
```

## Additional Resources

- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture overview
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — State management guide
- [OPERATIONS.md](OPERATIONS.md) — Day-2 operations
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskope/netskope/latest/docs)
- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [Terraform for_each Documentation](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
- [Google Cloud Ops Agent](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent)
- [GCP IAP TCP Forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform)
