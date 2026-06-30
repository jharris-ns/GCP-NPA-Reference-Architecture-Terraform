# GCP Migration Plan: NPA Publisher Reference Architecture

> **Historical Document — Migration Complete**
>
> This document was written as a pre-implementation plan for migrating the NPA Publisher reference architecture from AWS to GCP. The migration has been completed. This file is preserved for historical reference only.
>
> For current documentation, see:
> - [ARCHITECTURE.md](ARCHITECTURE.md) — Current GCP architecture
> - [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — How to deploy
> - [DEVOPS-NOTES.md](DEVOPS-NOTES.md) — Technical implementation details
>
> **Implementation outcome vs. plan:** The implemented architecture follows this plan closely, with one key deviation: the plan proposed using `gcloud secrets versions access` to fetch the token, but bootstrap.sh removes `curl` and `wget` as a security hardening step. The startup script instead uses Python 3's built-in `urllib` library for Secret Manager access (the `gcloud` CLI also depends on Python but the `gcloud secrets` subcommand was not available in the execution environment post-bootstrap). All security properties from the plan are preserved.

---

This document plans the creation of a GCP equivalent of the existing AWS NPA Publisher Terraform reference architecture. It maps every AWS service and design decision to its GCP counterpart and calls out the places where the platforms diverge meaningfully.

## Table of Contents

- [Overview](#overview)
- [AWS to GCP Service Mapping](#aws-to-gcp-service-mapping)
- [Key Design Differences](#key-design-differences)
- [Architecture Overview](#architecture-overview)
- [Terraform File Structure](#terraform-file-structure)
- [Detailed Resource Plan](#detailed-resource-plan)
- [Publisher Registration Flow](#publisher-registration-flow)
- [IAM and Identity Design](#iam-and-identity-design)
- [State Backend Design](#state-backend-design)
- [Networking Design](#networking-design)
- [High Availability Design](#high-availability-design)
- [Monitoring](#monitoring)
- [CI/CD and Workload Identity](#cicd-and-workload-identity)
- [Code Quality and Pre-commit](#code-quality-and-pre-commit)
- [Variables Reference](#variables-reference)
- [Operations Equivalents](#operations-equivalents)
- [Open Decisions](#open-decisions)

---

## Overview

The AWS implementation deploys Netskope NPA Publishers using two Terraform providers (AWS + Netskope) that coordinate in sequence. The same two-provider pattern applies in GCP. The primary differences are in networking topology, IAM model, instance management, and the registration mechanism.

**Goals for the GCP implementation:**

- Maintain the same security properties: no public IPs on publishers, no SSH keys required, registration tokens delivered without transiting the operator workstation
- Replace each AWS service with an idiomatic GCP equivalent (not just the closest analogue)
- Preserve the `for_each` + name-keyed publisher map pattern for safe scaling
- Keep the same Terraform file conventions and code quality tooling
- Produce a parallel set of documentation

---

## AWS to GCP Service Mapping

### Core Infrastructure

| AWS Resource | GCP Resource | Notes |
|---|---|---|
| VPC | `google_compute_network` | GCP VPCs are global, not regional |
| Private Subnet | `google_compute_subnetwork` | Subnets are regional; no "public subnet" needed |
| Public Subnet + NAT Gateway + EIP | `google_compute_router` + `google_compute_router_nat` | Cloud NAT is regional, not per-AZ |
| Internet Gateway | (implicit) | Cloud NAT handles egress; no separate IGW resource |
| Route Table + Routes | (automatic) | GCP routes are managed automatically for subnets |
| Security Group | `google_compute_firewall` | Applied via network tags or service accounts, not per-instance |
| VPC Endpoint (Interface) for SSM | Private Google Access on subnet | Enables GCP API access without external IP |
| EC2 Instance | `google_compute_instance` | |
| AMI | Ubuntu 22.04 LTS (public GCP image) | No GCP Marketplace image exists; software installed via bootstrap.sh |
| EC2 Key Pair | GCP OS Login | Recommended; eliminates static SSH key management |
| IAM Role | `google_service_account` | |
| IAM Instance Profile | `google_service_account` (attached to VM) | No separate "instance profile" resource in GCP |
| IAM Policy / Attachment | `google_project_iam_member` or `google_secret_manager_secret_iam_member` | |
| SSM Parameter Store (SecureString) | `google_secret_manager_secret` + `google_secret_manager_secret_version` | |
| SSM Session Manager | GCP IAP (Identity-Aware Proxy) TCP tunnel | IAP tunnel provides SSH without public IPs |
| SSM Run Command | Startup script reading from Secret Manager | See [Publisher Registration Flow](#publisher-registration-flow) |
| SSM Automation Document + Role | Startup script + VM service account | No separate automation role needed |
| CloudWatch Logs | Cloud Logging (via Ops Agent) | |
| CloudWatch Metrics | Cloud Monitoring (via Ops Agent) | |
| CloudWatch Alarms | Cloud Monitoring Alerting Policies | |

### State Backend

| AWS Resource | GCP Resource | Notes |
|---|---|---|
| S3 Bucket (state storage) | `google_storage_bucket` (GCS) | |
| DynamoDB Table (state locking) | **None required** | Terraform GCS backend has native locking |
| KMS Key (state encryption) | GCS bucket CMEK via `google_kms_crypto_key` (optional) | Google-managed encryption by default |

### CI/CD Authentication

| AWS Mechanism | GCP Mechanism |
|---|---|
| OIDC provider + IAM role trust | Workload Identity Federation pool + provider |
| `sts:AssumeRoleWithWebIdentity` | `iam.googleapis.com/serviceAccounts.actAs` via WIF |

---

## Key Design Differences

### 1. GCP VPCs Are Global; Subnets Are Regional

In AWS, a VPC is scoped to a region and subnets to AZs. In GCP, a VPC is a global resource and subnets are regional. A single VPC can span all regions, but the NPA Publisher deployment is scoped to one region and one or more zones within it.

**Impact:** The `google_compute_network` resource has no region attribute. Subnets (`google_compute_subnetwork`) declare the region.

### 2. No Public Subnet or Internet Gateway Resource

AWS requires explicit Internet Gateway + public subnet + NAT Gateway + route tables to give private instances outbound internet access. GCP collapses this: Cloud NAT is a regional service associated with a Cloud Router. Instances in any subnet covered by Cloud NAT get outbound internet access without a public IP or route table manipulation.

**Impact:** The `vpc.tf` file is significantly simpler. No public subnets, EIPs, or route table resources.

### 3. Firewall Rules Are VPC-Level, Targeted by Network Tag

AWS security groups are attached to instances at creation. GCP firewall rules are attached to the VPC and target instances via network tags.

**Impact:** The firewall rule uses `target_tags = ["npa-publisher"]`. The VM sets `tags = ["npa-publisher"]`.

### 4. IAM Identity Model: Service Accounts, Not Instance Profiles

GCP merges the AWS IAM role + instance profile into a single `google_service_account`. There is no separate "instance profile" resource.

**Impact:** The three-role separation in AWS (EC2 instance role, SSM Automation role, Terraform operator) maps to two in GCP (publisher VM service account, Terraform operator service account). The SSM Automation role has no equivalent because registration is done by the VM's startup script.

### 5. Registration Mechanism: Startup Script

The VM startup script runs on the instance and fetches the registration token from Secret Manager using the VM's service account identity. The token never transits the operator workstation.

**Implementation note:** The plan originally proposed using `gcloud secrets versions access`. In the actual implementation, Python3 `urllib` is used because `bootstrap.sh` removes `curl` and `wget`.

### 6. State Locking: GCS Backend Has It Built In

No DynamoDB equivalent is needed. The Terraform GCS backend implements locking natively.

### 7. Labels vs. Tags

GCP does not support provider-level `default_labels` (unlike AWS `default_tags`). A `local.common_labels` map is defined in `locals.tf` and passed to every resource.

---

## Architecture Overview

```
                                                  ┌──────────────────────────┐
                                                  │  Terraform Operator      │
                                                  │  (Workstation / CI/CD)   │
                                                  └────────────┬─────────────┘
                                                               │
                                                               │ Terraform API Calls
                                                               ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                            GCP Project                                     │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    GCP Services                                      │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │  │
│  │  │    IAM       │  │    Secret    │  │    Cloud     │              │  │
│  │  │  (Service    │  │   Manager   │  │  Monitoring  │              │  │
│  │  │  Accounts)   │  │  (Tokens)   │  │  + Logging   │              │  │
│  │  └──────────────┘  └──────────────┘  └──────────────┘              │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │               GCS Terraform State Backend (Optional)                 │  │
│  │  ┌──────────────┐  (no DynamoDB needed —                            │  │
│  │  │  GCS Bucket  │   GCS backend locks natively)                     │  │
│  │  │ (State File) │                                                   │  │
│  │  └──────────────┘                                                   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    VPC (global)                                      │  │
│  │  ┌──────────────────────────────────────────────────────────────┐   │  │
│  │  │              Region (e.g., us-east1)                         │   │  │
│  │  │                                                              │   │  │
│  │  │  ┌───────────────────┐         ┌───────────────────┐        │   │  │
│  │  │  │    Zone B         │         │    Zone C         │        │   │  │
│  │  │  │  ┌─────────────┐  │         │  ┌─────────────┐  │        │   │  │
│  │  │  │  │   Subnet    │  │         │  │   Subnet    │  │        │   │  │
│  │  │  │  │  (regional) │  │         │  │  (regional) │  │        │   │  │
│  │  │  │  │ ┌─────────┐ │  │         │  │ ┌─────────┐ │  │        │   │  │
│  │  │  │  │ │   NPA   │ │  │         │  │ │   NPA   │ │  │        │   │  │
│  │  │  │  │ │Publisher│ │  │         │  │ │Publisher│ │  │        │   │  │
│  │  │  │  │ │  VM 1   │ │  │         │  │ │  VM 2   │ │  │        │   │  │
│  │  │  │  │ └─────────┘ │  │         │  │ └─────────┘ │  │        │   │  │
│  │  │  │  └─────────────┘  │         │  └─────────────┘  │        │   │  │
│  │  │  └───────────────────┘         └───────────────────┘        │   │  │
│  │  │           │                              │                   │   │  │
│  │  │           └──────────┬───────────────────┘                   │   │  │
│  │  │                      │                                       │   │  │
│  │  │              Cloud NAT (regional)                            │   │  │
│  │  │              Cloud Router (regional)                         │   │  │
│  │  └──────────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                               │                                            │
└───────────────────────────────┼────────────────────────────────────────────┘
                                │ HTTPS 443
                                ▼
               ┌───────────────────────────────┐
               │  Netskope NewEdge Network     │
               │  (Publisher Management)       │
               └───────────────────────────────┘
```

---

## Terraform File Structure

```
terraform/
├── main.tf                    # Minimal — zone data source
├── variables.tf               # All input variables
├── outputs.tf                 # All outputs (includes iap_ssh_commands, log_query)
├── providers.tf               # google + netskope provider config
├── versions.tf                # required_version + required_providers
├── data.tf                    # Data source queries (zones, Ubuntu image)
├── locals.tf                  # publishers map, common_labels, resolved vpc/subnet refs
├── backend.tf                 # GCS backend block (commented out by default)
├── vpc.tf                     # VPC, subnet, Cloud Router, Cloud NAT, firewall rules
├── iam.tf                     # Service accounts, IAM bindings
├── secrets.tf                 # Secret Manager secrets for registration tokens
├── netskope.tf                # Netskope provider resources (cloud-agnostic)
├── compute_publisher.tf       # VM instances (Shielded VM, OS Login, startup script)
├── monitoring.tf              # Monitoring IAM (conditional on enable_monitoring)
└── templates/
    └── startup.sh.tftpl       # VM startup script (bootstrap + token fetch + register)
```

---

## Publisher Registration Flow

```
1. Terraform creates netskope_npa_publisher → publisher record in Netskope tenant
2. Terraform creates netskope_npa_publisher_token → one-time registration token
3. Terraform stores token in Secret Manager (encrypted at rest)
4. Terraform creates google_compute_instance → VM launches with startup script
   terraform apply completes here

5. VM startup script runs asynchronously:
   ├─ Wait for GCP metadata server
   ├─ Set /tmp permissions, pre-seed .nonat flag
   ├─ Install Ops Agent (if monitoring, BEFORE bootstrap — curl required)
   ├─ Run Netskope bootstrap.sh (~5-10 min):
   │    installs Docker, pulls container, extracts wizard, removes curl/wget
   └─ Python3 urllib fetches token from Secret Manager (curl unavailable post-bootstrap)
   └─ Run npa_publisher_wizard -token "$TOKEN"

6. Publisher appears Connected in Netskope UI
```

---

## Open Decisions

> **Status as of implementation**: All open decisions below were resolved during implementation.

1. **NPA Publisher GCP Marketplace image**: Resolved — no GCP Marketplace image exists. Ubuntu 22.04 LTS is used as the base image; publisher software is installed via bootstrap.sh.

2. **`default_labels` support**: Resolved — Google provider v5.x supports `default_labels` at the provider level, but `local.common_labels` is used instead for explicit control.

3. **Registration mechanism**: Resolved — startup script (Option A) was implemented. Python3 urllib is used for Secret Manager access (not `gcloud secrets`) because bootstrap.sh removes curl.

4. **Subnet topology**: Resolved — single regional subnet. Publisher VMs in different zones share one subnet CIDR. Zone distribution is handled by the VM's `zone` attribute.

5. **CMEK for Secret Manager**: Resolved — Google-managed encryption is used by default. CMEK is documented as optional in STATE_MANAGEMENT.md.

6. **OS Login vs. metadata SSH keys**: Resolved — OS Login is enabled (`enable-oslogin = "TRUE"` in VM metadata).

7. **Existing VPC support**: Resolved — implemented via `create_vpc = false` + `existing_network_self_link` + `existing_subnet_self_links`.

---

## Additional Resources

- [GCP Compute Engine Documentation](https://cloud.google.com/compute/docs)
- [GCP Secret Manager Documentation](https://cloud.google.com/secret-manager/docs)
- [GCP Cloud NAT Documentation](https://cloud.google.com/nat/docs)
- [GCP IAP TCP Forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [GCP Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [GCS Terraform Backend](https://developer.hashicorp.com/terraform/language/settings/backends/gcs)
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskope/netskope/latest/docs)
