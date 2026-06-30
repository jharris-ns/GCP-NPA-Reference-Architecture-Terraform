# NPA Publisher - Multi-Zone Deployment on GCP (Terraform)

Automated deployment of Netskope Private Access (NPA) Publishers to Google Cloud Platform using Terraform with multi-zone redundancy and the Netskope Terraform provider for publisher lifecycle management.

## Overview

This solution provides a highly available deployment of NPA Publishers with automatic registration to your Netskope tenant. It uses the [Netskope Terraform provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest) to create publishers, generate registration tokens, and launch Compute Engine instances that self-register on first boot via a startup script. Multi-zone deployment distributes publishers across GCP zones for production redundancy.

## Documentation

This project includes comprehensive documentation for deployment, operations, and troubleshooting:

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Detailed architecture overview covering network design, security layers, high availability, and GCP Well-Architected alignment
- **[QUICKSTART.md](docs/QUICKSTART.md)** — Get started with a guided quick deployment
- **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)** — Complete deployment instructions with all configuration options and multiple deployment paths
- **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)** — Terraform state management: local vs. remote, GCS backend setup, migration, security, and disaster recovery
- **[IAM_PERMISSIONS.md](docs/IAM_PERMISSIONS.md)** — Required GCP IAM permissions for the Terraform operator, with custom role YAML and CI/CD examples
- **[DEVOPS-NOTES.md](docs/DEVOPS-NOTES.md)** — Technical deep-dive into Terraform patterns, provider internals, `for_each`, startup script, and pre-commit hooks
- **[OPERATIONS.md](docs/OPERATIONS.md)** — Day-2 operational procedures: upgrades, scaling, rotation, replacement, and monitoring
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — Common issues and solutions with diagnostic commands

**Quick links:**
- New to the project? Start with **[QUICKSTART.md](docs/QUICKSTART.md)**
- Need to deploy? See **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)**
- Setting up remote state? See **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)**
- Already deployed? Check **[OPERATIONS.md](docs/OPERATIONS.md)**
- Having issues? See **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**

## IAM Permissions Required

To deploy this Terraform configuration, the operator needs permissions to create and manage multiple GCP resources. A complete custom role definition is provided in **[IAM_PERMISSIONS.md](docs/IAM_PERMISSIONS.md)**.

### Permission Summary

| Service | Key Permissions | Purpose |
|---------|----------------|---------|
| **Compute Engine** | VPC, subnets, Cloud Router, Cloud NAT, firewall rules, instances | Network infrastructure and compute |
| **IAM** | Create/manage service accounts, project IAM bindings | VM identity for Secret Manager access |
| **Secret Manager** | Create/manage secrets, versions, IAM policies | Registration token storage and access |
| **Cloud Storage** | Read/write objects in state bucket | Terraform state (remote backend) |

### Least Privilege Considerations

- Secret Manager IAM is scoped per-publisher secret — a compromised VM cannot read other publishers' tokens
- No project-wide `secretmanager.secretAccessor` binding is used
- GCS access is scoped to the specific state bucket, not all buckets
- See **[IAM_PERMISSIONS.md](docs/IAM_PERMISSIONS.md)** for the full custom role YAML and setup instructions

## VPC Deployment Options

The configuration supports two deployment modes:

### Option 1: Create New VPC

- **Automatically creates**: VPC, subnet, Cloud Router, Cloud NAT
- **Routing**: Private Google Access enabled on the subnet for GCP API access without a public IP
- **High availability**: Publishers distributed across zones within the region

```hcl
create_vpc  = true
subnet_cidr = "10.0.0.0/24"
```

### Option 2: Use Existing VPC

- **Requires**: Existing VPC with a subnet that has Private Google Access enabled and is covered by a Cloud NAT

```hcl
create_vpc                 = false
existing_network_self_link = "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/global/networks/my-vpc"
existing_subnet_self_links = [
  "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/regions/us-central1/subnetworks/my-subnet",
]
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Terraform Operator                                                 │
│  terraform plan / apply / destroy                                   │
└────────┬───────────────────────────────────┬────────────────────────┘
         │                                   │
         ▼                                   ▼
┌─────────────────────┐           ┌─────────────────────────┐
│  Netskope API       │           │  GCP API                │
│  Create publishers  │           │  Create infrastructure  │
│  Generate tokens    │           │                         │
└─────────────────────┘           └────────┬────────────────┘
                                           │
                                           ▼
                              ┌────────────────────────────┐
                              │  VPC (regional)             │
                              │                            │
                              │  ┌──────────────────────┐  │
                              │  │  Subnet              │  │
                              │  │  Private Google      │  │
                              │  │  Access enabled      │  │
                              │  │                      │  │
                              │  │  ┌───────────────┐   │  │
                              │  │  │  Publisher 1  │───┼──┼──▶ Netskope NewEdge
                              │  │  │  (Zone A)     │   │  │
                              │  │  └───────────────┘   │  │
                              │  │  ┌───────────────┐   │  │
                              │  │  │  Publisher 2  │───┼──┼──▶ Netskope NewEdge
                              │  │  │  (Zone B)     │   │  │
                              │  │  └───────────────┘   │  │
                              │  └──────────┬───────────┘  │
                              │             │              │
                              │             ▼              │
                              │  ┌──────────────────────┐  │
                              │  │  Cloud NAT           │  │   ┌──────────────────┐
                              │  │  (regional, all zones│  │   │ Secret Manager   │
                              │  └──────────────────────┘  │◀──│ (Private Google  │
                              │             │              │   │  Access)         │
                              └─────────────┼──────────────┘   └──────────────────┘
                                            ▼
                                       Internet
```

## Firewall Rules

Publisher instances require specific outbound access. No inbound rules are needed — publishers only initiate outbound connections. SSH access uses IAP TCP tunneling, not a public IP.

### Egress Rules

| Rule | Port | Protocol | Destination | Purpose |
|------|------|----------|-------------|---------|
| All egress | All | All | `0.0.0.0/0` | Netskope NewEdge, bootstrap downloads, GCP APIs |
| RFC1918 | All | All | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | Private app discovery (included in egress rule above) |

### Ingress Rules

| Rule | Port | Protocol | Source | Purpose |
|------|------|----------|--------|---------|
| IAP SSH | 22 | TCP | `35.235.240.0/20` | IAP TCP tunneling for `gcloud compute ssh` |

> **No public IPs**: Publisher VMs have no external IP. GCP API access (Secret Manager, Cloud Logging) uses Private Google Access — traffic stays on Google's network. Outbound internet access (Netskope NewEdge, bootstrap downloads) uses Cloud NAT.

## How It Works

### On `terraform apply`

1. **Netskope provider creates publisher records** in your Netskope tenant via the REST API
2. **Netskope provider generates registration tokens** (one per publisher, single-use)
3. **Terraform stores each token** as a Secret Manager secret version
4. **Compute Engine instances boot** and execute the startup script
5. **Startup script fetches the token** from Secret Manager using the VM's service account identity via the metadata server — the token never transits the operator workstation
6. **`npa_publisher_wizard`** runs on each instance, consuming the token and establishing an outbound TLS connection to Netskope NewEdge
7. **Publishers appear as "Connected"** in the Netskope admin console

### On `terraform destroy`

`terraform destroy` requires two passes due to a race between VM termination and the Netskope API:

1. **Pass 1**: Compute Engine instances are terminated, Secret Manager versions are destroyed, and Netskope publisher records are deleted. The Netskope deletes fail with a 422 error if the VMs (which take 60–90 seconds to terminate) are still reporting a heartbeat. All GCP resources are removed; only the Netskope publisher records remain in state.
2. **Wait ~2 minutes** for the publishers to show **Disconnected** in Netskope.
3. **Pass 2**: `terraform destroy` removes the remaining publisher records. State is empty.

> **Before destroying**: remove all private app associations from each publisher (**Settings → Security Cloud Platform → Private Apps**) — a publisher with active app associations cannot be deleted by the API even when disconnected.

## Getting Started

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.0
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) configured with appropriate credentials
- Netskope API key with **Infrastructure Management** scope
- GCP project with billing enabled
- Required APIs enabled (Compute Engine, Secret Manager, IAP, Cloud Logging)

### Quick Deploy

```bash
# 1. Clone and configure
git clone <repository-url>
cd GCP-NPA-Reference-Architecture-Terraform/terraform
cp example.tfvars terraform.tfvars
# Edit terraform.tfvars with your GCP project ID, region, and publisher name

# 2. Set Netskope credentials (never put these in terraform.tfvars)
export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
export TF_VAR_netskope_api_key="your-api-key"

# 3. Authenticate with GCP
gcloud auth application-default login

# 4. Enable required APIs
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  --project=YOUR_PROJECT_ID

# 5. Deploy
terraform init
terraform plan
terraform apply

# 6. Verify
terraform output publisher_names
terraform output publisher_private_ips
terraform output iap_ssh_commands
# Check Netskope UI: Settings → Security Cloud Platform → Publishers → verify "Connected"
```

For detailed instructions, see **[QUICKSTART.md](docs/QUICKSTART.md)** or **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)**.

## Project Structure

```
GCP-NPA-Reference-Architecture-Terraform/
├── README.md                        # This file
├── CLAUDE.md                        # Project guidelines for AI-assisted development
│
├── docs/                            # Comprehensive documentation
│   ├── ARCHITECTURE.md
│   ├── QUICKSTART.md
│   ├── DEPLOYMENT_GUIDE.md
│   ├── STATE_MANAGEMENT.md
│   ├── IAM_PERMISSIONS.md
│   ├── DEVOPS-NOTES.md
│   ├── OPERATIONS.md
│   └── TROUBLESHOOTING.md
│
├── terraform/                       # All Terraform code
│   ├── main.tf                      # Google provider label configuration
│   ├── variables.tf                 # Input variables with validation
│   ├── outputs.tf                   # Output values (IDs, IPs, names, IAP commands)
│   ├── providers.tf                 # Google and Netskope provider configuration
│   ├── versions.tf                  # Terraform and provider version constraints
│   ├── backend.tf                   # GCS remote state backend (commented template)
│   ├── data.tf                      # Data sources (zones, project, Ubuntu image)
│   ├── locals.tf                    # Computed values (publisher map, zone distribution)
│   │
│   ├── netskope.tf                  # Netskope publisher and token resources
│   ├── compute_publisher.tf         # Compute Engine instances with for_each zone distribution
│   ├── vpc.tf                       # VPC, subnet, Cloud Router, Cloud NAT, firewall rules
│   ├── iam.tf                       # Service account, project IAM bindings, per-secret IAM
│   ├── secrets.tf                   # Secret Manager secrets and registration token versions
│   ├── monitoring.tf                # Ops Agent monitoring configuration (optional)
│   │
│   ├── example.tfvars               # Example variable values (copy to terraform.tfvars)
│   └── templates/
│       └── startup.sh.tftpl         # VM startup script (bootstrap, token fetch, registration)
│
├── .pre-commit-config.yaml          # Pre-commit hooks (fmt, validate, checkov, gitleaks)
├── .terraform-docs.yaml             # terraform-docs configuration
├── .tflint.hcl                      # TFLint configuration
└── .gitignore                       # Git ignore rules
```

## Cost Estimation

Approximate monthly costs for us-central1 region (2 publishers, new VPC):

| Resource | Monthly Cost |
|----------|-------------|
| Compute Engine n2-standard-2 ×2 (24/7) | ~$140 |
| Cloud NAT (1 regional gateway) | ~$3 + data transfer |
| Secret Manager (2 secrets + API calls) | < $1 |
| Cloud Logging / Cloud Monitoring | < $1 (within free tier for small deployments) |
| GCS state backend | < $1 |
| **Total (new VPC)** | **~$145/month** |
| **Total (existing VPC with NAT)** | **~$141/month** |

*Costs vary by region, machine type, and data transfer volume. Committed Use Discounts can reduce Compute Engine costs by up to 57%.*

> **Compared to the AWS equivalent**: GCP Cloud NAT costs ~$3/month vs. AWS NAT Gateways at ~$65/month for 2 AZs. GCP Private Google Access replaces 3 AWS VPC Endpoints (~$22/month). The GCS state backend has no equivalent DynamoDB locking cost.

## Security Considerations

- **No inbound rules** — Publishers only initiate outbound connections
- **No external IPs** — Instances deployed with internal IP only; accessed via IAP TCP tunneling
- **Shielded VM** — Secure Boot, vTPM, and Integrity Monitoring enabled
- **OS Login** — Identity-based SSH access; no SSH key distribution needed
- **Private Google Access** — GCP API traffic (Secret Manager, Logging) stays on Google's network
- **Per-publisher secret IAM** — Each VM can only read its own registration token
- **Token never exposed to operator** — Fetched directly from Secret Manager by the VM's service account at boot
- **GCS versioning** — Remote state has automatic version history for recovery
- **Pre-commit scanning** — checkov and gitleaks catch issues before commit

> **Trade-off**: Registration tokens are stored in Terraform state (as Secret Manager secret data). The state file should be treated as sensitive. See **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)** for encryption and access control guidance.

## Limitations

- No auto scaling — fixed capacity per deployment
- Instance failure requires manual replacement (`terraform apply -replace`)
- Registration tokens are single-use — replacing the Netskope publisher record generates a new token
- Publisher software self-updates via Netskope auto-update; OS image changes require instance replacement
- Replacing a publisher creates a new Netskope publisher ID — private app associations must be re-configured

## Use Cases

**Ideal for:**
- Production workloads with predictable traffic patterns
- Multi-zone redundancy requirements within a GCP region
- Teams using Terraform for infrastructure management
- Organizations already using GCP with existing VPCs and Cloud NAT

**Built-in redundancy:**
- Multi-zone deployment (configurable 2–10 publishers distributed across available zones)
- Single regional Cloud NAT covers all zones — no per-zone redundancy needed
- `for_each` instance management prevents cascading state changes when scaling

**Considerations for production:**
- Monitor publisher health in Netskope admin console
- Use remote GCS state with versioning enabled for team environments
- Enable `enable_monitoring = true` and configure Cloud Monitoring alerts for memory and disk
- Remove private app associations before replacing or deleting a publisher

## Additional Resources

### Project Documentation
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Architecture overview and GCP best practices
- **[QUICKSTART.md](docs/QUICKSTART.md)** — Quick deployment guide
- **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)** — Complete deployment instructions
- **[STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md)** — State management and recovery
- **[IAM_PERMISSIONS.md](docs/IAM_PERMISSIONS.md)** — Required IAM permissions
- **[DEVOPS-NOTES.md](docs/DEVOPS-NOTES.md)** — Technical deep-dive
- **[OPERATIONS.md](docs/OPERATIONS.md)** — Operational procedures
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — Common issues and solutions

### External Resources
- [Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html)
- [Netskope Terraform Provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest)
- [Terraform Documentation](https://developer.hashicorp.com/terraform/docs)
- [GCP IAP TCP Tunneling](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [GCP Private Google Access](https://cloud.google.com/vpc/docs/private-google-access)
- [GCP Cloud NAT](https://cloud.google.com/nat/docs/overview)
- [NewEdge IP Ranges](https://docs.netskope.com/en/newedge-ip-ranges-for-allowlisting)
