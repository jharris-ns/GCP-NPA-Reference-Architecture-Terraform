# NPA Publisher Operational Procedures

Day-2 operational procedures for managing NPA Publisher deployments on GCP with Terraform.

## Table of Contents

- [Publisher Upgrades](#publisher-upgrades)
- [Scaling Publishers](#scaling-publishers)
- [Rotate Netskope API Token](#rotate-netskope-api-token)
- [Replace a Failed Publisher](#replace-a-failed-publisher)
- [Re-run Publisher Registration](#re-run-publisher-registration)
- [Connecting to Publisher Instances](#connecting-to-publisher-instances)
- [Import Existing Resources](#import-existing-resources)
- [Backup and Restore](#backup-and-restore)
- [Monitoring and Alerts](#monitoring-and-alerts)
- [Decommissioning](#decommissioning)

## Publisher Upgrades

### Auto-Updates (Recommended)

Netskope publishers support automatic upgrades managed through the Netskope console. This is the recommended method — no Terraform changes required.

**Configure auto-updates in Netskope UI:**

1. Log in to your Netskope tenant
2. Go to **Settings → Security Cloud Platform → Publishers**
3. Select your publisher group
4. Enable **Auto-Update** and configure the maintenance window
5. Choose update schedule (weekly, monthly)

**Benefits:**
- No manual intervention required
- Minimal downtime during updates
- Automatic rollback on failure
- No infrastructure replacement needed
- Controlled maintenance windows

**Documentation:** [Configure Publisher Auto-Updates](https://docs.netskope.com/en/configure-publisher-auto-updates)

### Instance Replacement

If you need to replace the underlying Compute Engine instance (e.g., to change machine type or pick up a new OS image):

A new instance requires a new registration token (tokens are single-use). You must replace the Netskope publisher record, the Secret Manager token version, and the Compute Engine instance together.

> **Private app associations**: Replacing the Netskope publisher record creates a new publisher with a new ID. Any private apps associated with the old publisher must be re-associated in the Netskope UI after replacement (**Settings → Security Cloud Platform → Private Apps → edit each app → update the publisher**). The old publisher record must also have no associations before it can be deleted — remove them first, or the replace will fail with a 422 error.

```bash
# Replace one publisher at a time for zero-downtime
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'

# Wait for the new instance to register with Netskope, then replace the next
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher-2"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher-2"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher-2"]' \
  -replace='google_compute_instance.publisher["my-publisher-2"]'
```

> **Note**: Because `ignore_changes = [metadata["startup-script"], boot_disk]` is set on instances, changing the startup script template or the Ubuntu base image will not trigger replacement. Use `-replace` explicitly for intentional replacement. Registration tokens are single-use, so the token and Netskope publisher record must also be replaced.

**Step 4: Verify in Netskope UI:**
- Check **Settings → Security Cloud Platform → Publishers**
- Verify both publishers show **Connected** status

## Scaling Publishers

### Horizontal Scaling (Add/Remove Instances)

**Scale up — add publishers:**
```hcl
# terraform.tfvars
publisher_count = 4  # Was 2
```

```bash
terraform plan
# Should show 2 new resources to add

terraform apply
```

New publishers are automatically:
- Distributed across zones (modulo distribution)
- Registered with Netskope via startup script
- Named sequentially (e.g., `my-publisher-3`, `my-publisher-4`)

**Scale down — reduce publishers:**
```hcl
# terraform.tfvars
publisher_count = 2  # Was 4 (minimum is 2)
```

```bash
terraform plan
# Should show resources to destroy for "my-publisher-3" and "my-publisher-4"

terraform apply
```

Terraform removes publishers from Netskope and terminates the Compute Engine instances. The `for_each` pattern ensures only the named publishers are removed — existing ones are untouched.

> **Minimum**: `publisher_count` must be at least 2. Deploying a single publisher is a single point of failure and is blocked by variable validation.

### Vertical Scaling (Change Machine Type)

**Step 1: Update machine type:**
```hcl
# terraform.tfvars
publisher_machine_type = "n2-standard-4"  # Was n2-standard-2
```

**Step 2: Replace instances (machine type changes require replacement):**
```bash
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
# Repeat for each publisher
```

**Supported machine types:**

| Type | vCPU | Memory | Use Case |
|---|---|---|---|
| `e2-medium` | 2 | 4 GB | Light / cost-optimized workloads |
| `e2-standard-2` | 2 | 8 GB | Light workloads |
| `e2-standard-4` | 4 | 16 GB | Moderate workloads |
| `n2-standard-2` | 2 | 8 GB | Standard workloads (default) |
| `n2-standard-4` | 4 | 16 GB | Heavy workloads |
| `n2-standard-8` | 8 | 32 GB | Very heavy workloads |
| `n2-highmem-2` | 2 | 16 GB | Memory-intensive |
| `n2-highmem-4` | 4 | 32 GB | Memory-intensive, heavy |
| `n2-highmem-8` | 8 | 64 GB | Memory-intensive, very heavy |
| `c2-standard-4` | 4 | 16 GB | Compute-optimized |
| `c2-standard-8` | 8 | 32 GB | Compute-optimized, heavy |

## Rotate Netskope API Token

The Netskope API token authenticates Terraform with the Netskope API. Rotation is straightforward because existing publishers are not affected by token changes.

### Step 1: Generate New Token

1. Log in to Netskope tenant
2. Go to **Settings → Tools → REST API v2**
3. Click **New Token**
4. Name: `NPA-Publisher-Rotated-<Date>`
5. Enable scope: **Infrastructure Management**
6. Copy the new token

### Step 2: Update Environment Variable

```bash
export TF_VAR_netskope_api_key="new-api-key-here"
```

Or update your secrets management system (Secret Manager, Vault, etc.).

### Step 3: Verify

```bash
# Terraform should be able to read existing publishers
terraform plan
# Should show "No changes"
```

### Step 4: Revoke Old Token (Optional)

1. Go to **Settings → Tools → REST API v2** in Netskope UI
2. Find the old token
3. Click **Revoke**

> **Note**: Existing publishers continue operating normally regardless of API token changes. The API token is only used by Terraform, not by the running publishers. Publisher-to-Netskope connectivity is established during registration and does not depend on the API token.

## Replace a Failed Publisher

> **Prerequisite**: Remove all private app associations from the publisher before replacing it. Netskope will reject deletion of a publisher that has private apps assigned, even if the publisher is disconnected. Go to **Settings → Security Cloud Platform → Private Apps**, edit each app that uses this publisher, and remove the association.

Since registration tokens are single-use, replacing an instance requires replacing the Netskope publisher record, token, Secret Manager version, and Compute Engine instance together:

```bash
# Replace the specific failed publisher (all four resources)
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
```

This will:
1. Create a new Netskope publisher record and generate a new registration token
2. Store the new token in Secret Manager
3. Terminate the old Compute Engine instance
4. Launch a new instance with the startup script
5. The startup script fetches the new token and registers automatically

**Verify:**
- Check Cloud Logging for registration completion
- Check **Settings → Security Cloud Platform → Publishers** in Netskope UI

## Re-run Publisher Registration

If the startup script registration failed (e.g., transient Secret Manager error) but the token has not been consumed, you can re-run registration by resetting the VM.

The startup script is **idempotent on reset**: it detects that Docker and the wizard are already installed, skips the bootstrap step (~2 min), and runs the wizard directly — re-registration completes in seconds.

```bash
# Reset the VM — re-runs the startup script
# Only works if the registration token was not consumed by a previous attempt
gcloud compute instances reset my-publisher \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID
```

If the token was already consumed (wizard ran, even if unsuccessfully), you need to replace the token before resetting:

```bash
# Replace just the token and secret version — no VM replacement needed
terraform apply \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]'

# Then reset the VM to re-run the startup script with the new token
gcloud compute instances reset my-publisher \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID
```

If the token was consumed but registration did not succeed (e.g., the wizard returned an error and you don't want to reuse the same publisher record), use a full replacement as described in [Replace a Failed Publisher](#replace-a-failed-publisher).

### Check Whether the Token Was Consumed

The startup script removes the token from memory after registration. Check the Netskope UI:
- If the publisher shows **Connected** or **Registered**: token was consumed successfully
- If the publisher shows **Disconnected** or has never appeared: token may not have been consumed

You can also check Cloud Logging for the registration outcome:

```bash
gcloud logging read \
  'resource.type="gce_instance" AND logName:"google-startup-scripts" AND jsonPayload.message:"wizard"' \
  --project=YOUR_PROJECT_ID \
  --limit=20 \
  --format="table(timestamp,jsonPayload.message)"
```

## Connecting to Publisher Instances

Publishers have no external IP. Access is via IAP TCP tunneling.

### Get the SSH Command

```bash
# Pre-built commands for all publishers
terraform output iap_ssh_commands
```

### Connect via IAP SSH

```bash
# Requires roles/iap.tunnelResourceAccessor on the project or instance
gcloud compute ssh my-publisher \
  --tunnel-through-iap \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID

# Once connected:
sudo docker ps                                    # Check publisher container
sudo docker logs $(sudo docker ps -q) 2>&1 | tail -20  # Container logs
sudo journalctl -u google-startup-scripts --no-pager   # Startup script log
```

### View Logs Without SSH

```bash
# Startup script output (registration events)
gcloud logging read \
  'resource.type="gce_instance" AND logName:"google-startup-scripts"' \
  --project=YOUR_PROJECT_ID \
  --limit=50

# Publisher application logs (if Ops Agent is enabled)
gcloud logging read \
  'resource.type="gce_instance" AND textPayload:"npa_publisher"' \
  --project=YOUR_PROJECT_ID \
  --limit=50
```

### Serial Port Output (Boot Diagnostics)

```bash
gcloud compute instances get-serial-port-output my-publisher \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID
```

## Import Existing Resources

If you have existing GCP resources that you want Terraform to manage:

```bash
# Import a Compute Engine instance
terraform import 'google_compute_instance.publisher["my-publisher"]' \
  projects/MY_PROJECT/zones/us-central1-b/instances/my-publisher

# Import a VPC network
terraform import 'google_compute_network.vpc[0]' \
  projects/MY_PROJECT/global/networks/my-vpc

# Import a subnet
terraform import 'google_compute_subnetwork.publisher[0]' \
  projects/MY_PROJECT/regions/us-central1/subnetworks/my-subnet

# Import a service account
terraform import 'google_service_account.publisher' \
  projects/MY_PROJECT/serviceAccounts/my-publisher-sa@MY_PROJECT.iam.gserviceaccount.com
```

**Post-import steps:**
1. Run `terraform plan` to see differences between configuration and imported state
2. Update `.tf` files to match actual resource configuration
3. Run `terraform plan` again to confirm "No changes"

> **Note**: Import only adds resources to state — it does not modify the actual resources or generate configuration.

## Backup and Restore

### Configuration Backup

Your Terraform configuration files (`.tf`) should be in Git:

```bash
git add terraform/*.tf terraform/example.tfvars
git commit -m "Configuration backup"
git push
```

> **Never commit**: `terraform.tfvars`, `*.tfstate` files, or sensitive environment variables.

### State Backup

**With remote state (GCS):**

GCS versioning is enabled when configured correctly. Every `terraform apply` creates a new version. To manually backup:

```bash
# Pull state to local file
terraform state pull > state-backup-$(date +%Y%m%d).json
```

**Recover previous state:**
```bash
# List versions
gcloud storage objects list \
  "gs://YOUR_STATE_BUCKET/npa-publishers/" \
  --versions \
  --format="table(name,generation,timeCreated)"

# Download a specific version
gcloud storage cp \
  "gs://YOUR_STATE_BUCKET/npa-publishers/default.tfstate#GENERATION_NUMBER" \
  recovered-state.json

# Push recovered state
terraform state push recovered-state.json
```

See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for complete disaster recovery procedures.

## Monitoring and Alerts

### Enable Cloud Ops Agent

Install the Google Cloud Ops Agent to collect memory, disk, and application metrics:

```hcl
# terraform.tfvars
enable_monitoring = true
```

```bash
terraform apply
```

> **Note**: Enabling monitoring on existing instances requires replacing them, because the startup script only installs the Ops Agent during first boot. Use `-replace` flags as described in [Instance Replacement](#instance-replacement).

The Ops Agent collects:
- CPU, memory, disk, and network metrics → Cloud Monitoring
- System logs (syslog, /var/log) → Cloud Logging

### Cloud Monitoring Alerts

Create alert policies for publisher health via the GCP Console or `google_monitoring_alert_policy` Terraform resources:

```bash
# Example: Create a high-CPU alert via gcloud
gcloud monitoring policies create \
  --display-name="NPA Publisher High CPU" \
  --project=YOUR_PROJECT_ID \
  ...
```

For Terraform-managed alerts, add `google_monitoring_alert_policy` resources to `monitoring.tf`.

### Key Metrics to Monitor

| Metric | Source | Threshold | Action |
|---|---|---|---|
| CPU Utilization | Cloud Monitoring (`compute.googleapis.com/instance/cpu/utilization`) | > 80% sustained | Scale up machine type |
| Memory Utilization | Ops Agent (`agent.googleapis.com/memory/percent_used`) | > 85% | Scale up machine type |
| Disk Utilization | Ops Agent (`agent.googleapis.com/disk/percent_used`) | > 80% | Investigate |
| Instance Status | `gcloud compute instances describe` | RUNNING | Replace instance if TERMINATED |
| Publisher Status | Netskope UI | Connected | Troubleshoot |
| `terraform plan` | Terraform | No changes | Investigate drift if changes detected |

### Netskope UI Monitoring

Check publisher health in the Netskope console:
1. **Settings → Security Cloud Platform → Publishers**
2. Verify status: **Connected** (green)
3. Check last seen timestamp

### Drift Detection with Terraform

Run `terraform plan` periodically to detect configuration drift:

```bash
terraform plan
```

For CI/CD pipelines:
```bash
terraform plan -detailed-exitcode
# Exit code 0: No changes
# Exit code 1: Error
# Exit code 2: Changes detected
```

## Decommissioning

`terraform destroy` consistently requires two passes due to a race between VM termination and the Netskope publisher delete API call.

### Why Two Passes Are Needed

Terraform destroys GCP resources and Netskope records in dependency order: VMs are terminated before the Netskope publisher records are deleted. However, GCE instance deletion takes 60–90 seconds, and the Netskope API rejects deletion of a publisher that is still marked **connected**. By the time Terraform reaches the publisher delete, the VM may still be reporting a heartbeat. The first `terraform destroy` exits with code 1 after successfully removing all GCP resources.

Within a few minutes of VM termination, Netskope marks the publishers as **disconnected**. Re-running `terraform destroy` then removes the remaining publisher records cleanly.

### Procedure

```bash
# Pass 1 — removes all GCP resources; exits with error on Netskope publisher delete
terraform destroy

# Wait ~2 minutes for publishers to show "disconnected" in Netskope UI, then:

# Pass 2 — removes the remaining Netskope publisher records
terraform destroy
```

After pass 2, `terraform state list` returns nothing.

> **Before destroying**: remove all private app associations from each publisher in the Netskope UI (**Settings → Security Cloud Platform → Private Apps**). A publisher with active app associations cannot be deleted by the API even when disconnected.

## Additional Resources

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Issue diagnosis and resolution
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — State operations and recovery
- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture reference
- [Netskope Publisher Admin Guide](https://docs.netskope.com/en/netskope-help/admin/private-access/publishers)
- [Google Cloud Ops Agent](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent)
