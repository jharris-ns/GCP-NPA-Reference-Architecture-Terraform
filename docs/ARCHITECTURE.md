# Architecture Overview

GCP reference architecture for deploying Netskope Private Access (NPA) Publishers using Terraform. This document explains each design decision through the lens of [GCP architecture best practices](https://cloud.google.com/architecture/framework) and the [Google Cloud Well-Architected Framework](https://cloud.google.com/architecture/framework).

## Table of Contents

- [Architecture Diagram](#architecture-diagram)
- [Component Overview](#component-overview)
- [Network Architecture](#network-architecture)
- [Security Architecture](#security-architecture)
- [High Availability Design](#high-availability-design)
- [Additional Resources](#additional-resources)

## Architecture Diagram

```
                                                       ┌──────────────────────────┐
                                                       │  Terraform Operator      │
                                                       │  (Workstation / CI/CD)   │
                                                       └────────────┬─────────────┘
                                                                    │
                                                                    │ Terraform API Calls
                                                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GCP Project                                    │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    GCP Services                                       │  │
│  │                                                                       │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │  │
│  │  │    IAM       │  │    Secret    │  │    Cloud     │               │  │
│  │  │  (Service    │  │   Manager   │  │  Monitoring  │               │  │
│  │  │  Accounts)   │  │  (Tokens)   │  │  + Logging   │               │  │
│  │  └──────────────┘  └──────────────┘  └──────────────┘               │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │               Terraform State Backend (Optional)                      │  │
│  │                                                                       │  │
│  │  ┌──────────────┐  ┌──────────────┐                                  │  │
│  │  │  GCS Bucket  │  │   KMS Key    │  No DynamoDB needed —            │  │
│  │  │ (State File) │  │ (Encryption) │  GCS backend locks natively      │  │
│  │  └──────────────┘  └──────────────┘                                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                  VPC (global) / Region (e.g., us-east1)               │  │
│  │                                                                       │  │
│  │  ┌──────────────────────┐         ┌──────────────────────┐           │  │
│  │  │       Zone B         │         │       Zone C         │           │  │
│  │  │                      │         │                      │           │  │
│  │  │  ┌────────────────┐  │         │  ┌────────────────┐  │           │  │
│  │  │  │ Regional Subnet│  │         │  │ Regional Subnet│  │           │  │
│  │  │  │ (shared)       │  │         │  │ (shared)       │  │           │  │
│  │  │  │                │  │         │  │                │  │           │  │
│  │  │  │ ┌────────────┐ │  │         │  │ ┌────────────┐ │  │           │  │
│  │  │  │ │    NPA     │ │  │         │  │ │    NPA     │ │  │           │  │
│  │  │  │ │ Publisher  │ │  │         │  │ │ Publisher  │ │  │           │  │
│  │  │  │ │ Instance 1 │ │  │         │  │ │ Instance 2 │ │  │           │  │
│  │  │  │ └────────────┘ │  │         │  │ └────────────┘ │  │           │  │
│  │  │  └────────┬───────┘  │         │  └────────┬───────┘  │           │  │
│  │  └───────────┼──────────┘         └───────────┼──────────┘           │  │
│  │              └─────────────┬───────────────────┘                     │  │
│  │                            │                                         │  │
│  │                  Cloud NAT (regional — covers all zones)             │  │
│  │                  Cloud Router                                        │  │
│  └────────────────────────────┼──────────────────────────────────────────┘  │
│                               │                                             │
│                               │ Internet (HTTPS 443)                        │
│                               ▼                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                 ┌───────────────────────────────┐
                 │  Netskope NewEdge Network     │
                 │  (Publisher Management)       │
                 └───────────────────────────────┘
```

**Key simplification vs. AWS:** There are no public subnets, no per-zone NAT gateways, and no internet gateway resource. Cloud NAT is a single regional resource covering all zones.

## Component Overview

### VPC and Subnet Design

**GCP best practice**: GCP VPCs are global resources; subnets are regional. There is no concept of a "public subnet" in GCP — privacy is determined by whether a VM has an external IP assigned, not which subnet it is in.

- **VPC** (`google_compute_network`): Global network resource. Only created when `create_vpc = true`; an existing VPC can be supplied instead via `existing_network_self_link`.
- **Subnet** (`google_compute_subnetwork`): Regional subnet with `private_ip_google_access = true`, enabling VMs without external IPs to reach GCP APIs (Secret Manager, Cloud Logging, Cloud Monitoring) without Cloud NAT or VPC Endpoints.
- **CIDR**: Configurable via `subnet_cidr` (default: `10.0.0.0/24`).

### Cloud Router and Cloud NAT

**GCP best practice**: Cloud NAT is a regional service — a single NAT resource provides outbound internet for all zones in a region, unlike AWS where one NAT Gateway per AZ is required for zone isolation.

- **Cloud Router** (`google_compute_router`): Regional BGP router required by Cloud NAT.
- **Cloud NAT** (`google_compute_router_nat`): Regional NAT with auto-allocated IPs. Provides outbound internet for all publisher VMs across zones. SLA: 99.99%.
- **No Elastic IPs or public subnets**: GCP manages NAT IPs automatically (`AUTO_ONLY`).

### Compute Engine Instances (NPA Publishers)

**GCP best practice**: Use service accounts (not SSH keys) for VM identity. Enable Shielded VM features for boot integrity. Use OS Login for human access control via IAM.

- **Machine type**: `n2-standard-2` (default, configurable). See [OPERATIONS.md](OPERATIONS.md) for sizing guidance.
- **Image**: Ubuntu 22.04 LTS (public image). The Netskope NPA Publisher software is installed at first boot via `bootstrap.sh` (downloaded from Netskope S3). There is no GCP Marketplace image required.
- **Deployment**: Distributed across zones using `for_each` with modulo: `zone = local.zones[index % len(zones)]`
- **Networking**: No external IP assigned. Outbound via Cloud NAT. Inbound only via IAP TCP tunnel.
- **Service Account**: One shared publisher service account with least-privilege IAM bindings.
- **Boot disk**: 30 GB pd-ssd, encrypted at rest by default (Google-managed key).
- **HA Scheduling**: `automatic_restart = true`, `on_host_maintenance = "MIGRATE"` (live migration during host maintenance — near-zero downtime). `preemptible = false`.

### Firewall Rules

**GCP best practice**: Firewall rules are applied to the VPC and scoped to VMs via network tags, not attached to instances directly.

- **Egress rule**: All outbound traffic allowed from VMs tagged `npa-publisher`. Publishers must reach Netskope NewEdge, DNS, and package repositories.
- **IAP SSH rule**: Ingress from `35.235.240.0/20` on port 22, targeted to `npa-publisher` tag. Required for `gcloud compute ssh --tunnel-through-iap` access. No equivalent is needed in AWS because SSM Session Manager is purely IAM-controlled.
- **No ingress rule**: Publishers only initiate outbound connections — zero inbound attack surface.

### IAM and Service Account

**GCP best practice**: Attach a dedicated service account to VMs rather than using the default compute service account. Scope IAM bindings to specific resources, not the project.

- **`google_service_account.publisher`**: Attached to all publisher VMs. Has three IAM bindings:
  - `roles/logging.logWriter` (project-level): Write logs to Cloud Logging.
  - `roles/monitoring.metricWriter` (project-level): Write metrics to Cloud Monitoring (when Ops Agent enabled).
  - `roles/secretmanager.secretAccessor` (per-secret): Read this publisher's registration token. Scoped to the specific `google_secret_manager_secret` resource — not the whole project.
- No separate "instance profile" resource: GCP service accounts are attached directly in the `service_account {}` block.
- No separate "automation role": Registration is handled in the startup script running as the VM's service account — the token never transits the operator workstation.

### Secret Manager (Registration Tokens)

Replaces AWS SSM Parameter Store. The Netskope registration token is stored as a Secret Manager secret version per publisher.

- **`google_secret_manager_secret`**: One secret per publisher (named `<publisher-name>-registration-token`).
- **`google_secret_manager_secret_version`**: Stores the token value (from `netskope_npa_publisher_token.this[key].token`).
- **Encrypted at rest**: Google-managed encryption by default. CMEK optional.
- **Access control**: IAM binding scoped to the specific secret for each publisher's service account.
- **Audit trail**: Cloud Audit Logs record every `secretmanager.versions.access` call.

### Netskope Provider

The Netskope Terraform provider creates publisher records and generates one-time registration tokens. It does not manage any GCP infrastructure. Identical to the AWS implementation.

- `netskope_npa_publisher`: Creates publisher records in the Netskope tenant.
- `netskope_npa_publisher_token`: Generates one-time registration tokens.
- Authentication: REST API v2 key (set via `TF_VAR_netskope_api_key`).

### Terraform State Backend (Optional)

**GCP advantage over AWS**: The GCS backend has native state locking — no DynamoDB equivalent is needed.

- **GCS Bucket**: Encrypted state file storage with versioning. Locking via GCS object conditional updates.
- **KMS Key** (optional): Customer-managed encryption key for the state bucket.
- See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for details.

### Cloud Monitoring / Ops Agent (Optional)

When `enable_monitoring = true`, the startup script installs the [Google Cloud Ops Agent](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent) before running bootstrap (bootstrap removes curl/wget).

- **Metrics**: CPU, memory, disk → Cloud Monitoring.
- **Logs**: System logs → Cloud Logging.

## Network Architecture

### Traffic Flows

#### 1. Publisher to Netskope NewEdge
```
NPA Publisher (no external IP) → Firewall egress rule →
Cloud NAT → Internet → Netskope NewEdge Data Centers
```
- **Port**: HTTPS (443)
- **Purpose**: Publisher registration, management plane, tunnel establishment

#### 2. Publisher to Internal Applications
```
NPA Publisher → Firewall egress rule →
VPC Internal / VPC Peering / Cloud VPN / Cloud Interconnect
```
- **Ports**: Application-specific
- **Destination**: RFC1918 private IP ranges
- **Purpose**: Proxying user traffic to internal applications via Netskope tunnels

#### 3. Publisher to GCP APIs (Secret Manager, Cloud Logging, Cloud Monitoring)
```
NPA Publisher → Private Google Access (subnet attribute) →
GCP APIs (private.googleapis.com)
```
- **Port**: HTTPS (443)
- **Purpose**: Registration token retrieval, log/metric delivery
- Private Google Access replaces the three AWS VPC Endpoints (`ssm`, `ssmmessages`, `ec2messages`). No VPC endpoint resources needed.

#### 4. Operator Shell Access (Diagnostics)
```
Operator → IAP TCP tunnel (35.235.240.0/20) → VM port 22
gcloud compute ssh INSTANCE_NAME --tunnel-through-iap --zone ZONE
```
- **Requires**: `roles/iap.tunnelResourceAccessor` for the operator + firewall IAP rule + OS Login enabled.
- No bastion hosts, no SSH keys stored in metadata.

#### 5. Terraform Operator to GCP / Netskope APIs
```
Terraform Operator → GCP APIs (create/manage resources)
                   → Netskope APIs (create publishers, generate tokens)
```
- **Port**: HTTPS (443)
- **Source**: Operator workstation or CI/CD pipeline

### Network Segmentation

| Plane | Traffic | GCP Mechanism |
|---|---|---|
| **Data Plane** | Publisher ↔ Netskope NewEdge, internal apps | No external IP → Cloud NAT → Internet / VPC peering |
| **Management Plane** | Operator → Publisher (shell access, diagnostics) | IAP TCP tunnel — IAM-controlled, no open network path |
| **GCP API Plane** | Publisher → Secret Manager, Logging, Monitoring | Private Google Access — stays on Google's network |
| **Control Plane** | Terraform ↔ GCP APIs, Netskope APIs | External (operator workstation / CI/CD) over HTTPS |

## Security Architecture

This architecture implements defense in depth aligned to the [Google Cloud Well-Architected Framework Security Pillar](https://cloud.google.com/architecture/framework/security).

### Layer 1: Network Security

**VPC-Level Controls:**
- No external IPs on publisher VMs
- Cloud NAT for outbound internet (no inbound surface)
- Firewall rules scoped to `npa-publisher` network tag

**Firewall Configuration:**
```
Ingress Rules:
  IAP SSH (35.235.240.0/20 → port 22) — for diagnostic access

Egress Rules:
  All traffic → 0.0.0.0/0 (publishers need Netskope NewEdge + DNS + bootstrap)
```

**Private Google Access:**
- VMs reach GCP APIs without external IPs or Cloud NAT
- Replaces AWS VPC Endpoints — no interface endpoint resources needed

### Layer 2: Identity and Access Management

**Single service account** with three scoped bindings — no broad permissions:

| Binding | Scope | Purpose |
|---|---|---|
| `roles/logging.logWriter` | Project | Write logs to Cloud Logging |
| `roles/monitoring.metricWriter` | Project | Write metrics to Cloud Monitoring |
| `roles/secretmanager.secretAccessor` | Specific secret | Read this publisher's registration token only |

**Design rationale:**
- The service account has no access to other publishers' tokens (secret-scoped binding, not project-scoped).
- OS Login (`enable-oslogin = TRUE`) replaces static SSH keys — human access is controlled via IAM.
- Registration tokens never transit the operator workstation: the VM fetches its own token from Secret Manager using its service account identity.

### Layer 3: Data Protection at Rest

**Terraform State Security:**
- **At rest**: GCS default encryption (Google-managed) or CMEK.
- **Access control**: IAM policies on the GCS bucket.
- **Versioning**: GCS versioning for state recovery.
- **Locking**: Built into GCS backend — no DynamoDB needed.

**Secret Manager:**
- All secret versions encrypted at rest by Google by default.
- CMEK available via `customer_managed_encryption` block.

**Boot Disks:**
- GCP encrypts all persistent disks at rest automatically (Google-managed key). CMEK via `kms_key_self_link` if needed.

### Layer 4: Data Protection in Transit

- All GCP API calls: TLS 1.2+ (GCP enforced)
- Netskope communication: TLS 1.3 (Netskope enforced)
- IAP TCP tunnels: Encrypted via Google's infrastructure
- Secret Manager token retrieval: HTTPS with bearer token (service account identity from metadata server)

### Layer 5: Shielded VM (Boot Integrity)

GCP Shielded VM replaces AWS IMDSv2 + Nitro Enclaves as the platform security baseline.

```hcl
shielded_instance_config {
  enable_secure_boot          = true   # UEFI firmware validation
  enable_vtpm                 = true   # Virtual TPM for measured boot
  enable_integrity_monitoring = true   # Boot measurement comparison
}
```

- **Secure Boot**: Prevents loading unsigned/malicious boot components.
- **vTPM**: Cryptographic attestation of boot sequence integrity.
- **Integrity Monitoring**: Alerts in Cloud Monitoring if boot measurements change.

### Layer 6: Code Quality and Pre-commit

**Automated Security Scanning:**
- **Checkov**: GCP misconfiguration and compliance scanning
- **gitleaks**: Scans for hardcoded secrets and credentials
- **detect-private-key**: Prevents committing private keys

**Code Quality:**
- **terraform fmt**: Consistent formatting
- **terraform validate**: Syntax validation
- **TFLint** (with `tflint-ruleset-google`): GCP-specific linting
- **terraform-docs**: Auto-generated documentation

See [DEVOPS-NOTES.md](DEVOPS-NOTES.md) for pre-commit hook details.

## High Availability Design

### Multi-Zone Architecture

#### Zone Distribution

**Active-Active Design:**
- Publishers distributed across zones using `for_each` with modulo:
  ```hcl
  zone = local.zones[each.value.index % length(local.zones)]
  ```
- Each instance handles traffic independently.
- With `publisher_count = 2`, Terraform auto-selects 2 distinct zones (one per publisher).
- With `publisher_count = 3`, Terraform selects 3 distinct zones.

**Zone Distribution Example (us-east1, 2 publishers):**
| Publisher | Zone |
|---|---|
| `my-pub` | us-east1-b |
| `my-pub-2` | us-east1-c |

**HA Scheduling Policy (GCP best practice for persistent workloads):**
```hcl
scheduling {
  automatic_restart   = true       # Restart automatically on unexpected stop
  on_host_maintenance = "MIGRATE"  # Live migration during host maintenance
  preemptible         = false      # Not eligible for GCP preemption
}
```
`on_host_maintenance = "MIGRATE"` means GCP live-migrates the VM during planned maintenance — near-zero downtime, no instance stop needed.

#### Cloud NAT: Regional vs. Per-Zone

Unlike AWS (one NAT Gateway per AZ for zone isolation), Cloud NAT is regional — a single `google_compute_router_nat` serves all zones. Zone-level failure isolation is handled internally by GCP. SLA: 99.99%.

#### Failure Scenarios and Recovery

**Scenario 1: Single Instance Failure**
- **Impact**: Reduced capacity (remaining instances continue serving)
- **Recovery**: `terraform apply -replace='google_compute_instance.publisher["name"]' -replace='netskope_npa_publisher.this["name"]' -replace='netskope_npa_publisher_token.this["name"]' -replace='google_secret_manager_secret_version.publisher_token["name"]'`
- **Automatic**: No intervention needed for remaining instances

**Scenario 2: Zone Failure**
- **Impact**: Instance in affected zone unavailable
- **Recovery**: Instance in healthy zone continues serving all traffic automatically
- **Manual**: None required (wait for zone recovery)

**Scenario 3: Cloud NAT Failure**
- **Impact**: All zones lose outbound internet (regional resource)
- **Recovery**: GCP restores Cloud NAT (99.99% SLA)
- **Note**: This is the trade-off vs. AWS per-AZ NAT Gateways — regional scope means zone failures don't isolate egress, but rare regional NAT failures affect all zones

**Scenario 4: Region-Wide Failure**
- **Impact**: Entire deployment unavailable
- **Recovery**: Deploy in different region using same Terraform configuration

### Capacity and Scalability

**Scaling Publishers:**
```hcl
# Change publisher_count in terraform.tfvars
publisher_count = 4  # Scale from 2 to 4

# Apply the change — only new publishers are created
terraform apply
```

**Vertical Scaling:**
```hcl
# Change machine type
publisher_machine_type = "n2-standard-4"
```

| Machine Type | vCPU | Memory | Approximate Capacity |
|---|---|---|---|
| `e2-medium` | 2 | 4 GB | Light workloads |
| `n2-standard-2` | 2 | 8 GB | ~2,000 concurrent users (default) |
| `n2-standard-4` | 4 | 16 GB | ~4,000 concurrent users |
| `n2-standard-8` | 8 | 32 GB | ~8,000 concurrent users |
| `n2-highmem-2` | 2 | 16 GB | Memory-intensive workloads |
| `n2-highmem-4` | 4 | 32 GB | Memory-intensive, heavy |

### RPO and RTO

**Recovery Point Objective (RPO):**
- **Data Loss**: None (stateless publishers)
- **Configuration**: Stored in Git (version-controlled `.tf` files)
- **Netskope State**: Maintained by Netskope cloud
- **Terraform State**: GCS versioning provides point-in-time recovery

**Recovery Time Objective (RTO):**
- **Single Instance**: Minutes (`terraform apply -replace`)
- **Zone Failure**: 0 seconds (automatic — other zone continues)
- **Entire Stack**: ~5-8 minutes (`terraform apply` from scratch)

## Additional Resources

- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — Terraform state guide (GCS backend)
- [QUICKSTART.md](QUICKSTART.md) — Quick deployment guide
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Detailed deployment instructions
- [DEVOPS-NOTES.md](DEVOPS-NOTES.md) — Technical deep-dive
- [OPERATIONS.md](OPERATIONS.md) — Day-2 operational procedures
- [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md) — GCP IAM requirements
