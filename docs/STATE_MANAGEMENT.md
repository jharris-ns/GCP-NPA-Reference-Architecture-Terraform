# Terraform State Management

Guide to managing Terraform state for the NPA Publisher deployment on GCP.

## Table of Contents

- [What is Terraform State?](#what-is-terraform-state)
- [Local State](#local-state)
- [Remote State with GCS](#remote-state-with-gcs)
- [Creating the State Bucket](#creating-the-state-bucket)
- [Configuring the GCS Backend](#configuring-the-gcs-backend)
- [Migration: Local to Remote](#migration-local-to-remote)
- [State Security](#state-security)
- [State Operations](#state-operations)
- [Team Workflow](#team-workflow)
- [Disaster Recovery](#disaster-recovery)
- [Cost](#cost)

## What is Terraform State?

Terraform state is a JSON file that maps your configuration to real-world infrastructure. Every time you run `terraform apply`, Terraform records what it created so it can manage those resources on future runs.

### What State Tracks

- **Resource IDs**: Compute Engine instance IDs, service account emails, VPC names
- **Attribute values**: Private IPs, self-links, names, configuration details
- **Dependencies**: Which resources depend on which others
- **Metadata**: Provider configuration, Terraform version, serial number

### Sensitive Data in State

**This is the most important thing to understand about state.**

Terraform state stores resource attributes in plain text. For this project, state contains:

- **Netskope API key** (from the provider configuration)
- **Netskope publisher registration tokens** (from `netskope_npa_publisher_token` and `google_secret_manager_secret_version.publisher_token`)
- **Compute Engine instance metadata** (private IPs, instance IDs)
- **Service account emails and IAM bindings**

> **Warning**: Anyone who can read your state file can see your Netskope API key and registration tokens. Treat state files with the same care as credentials. Registration tokens are also stored in Secret Manager (encrypted at rest by Google).

## Local State

### Default Behavior

By default, Terraform stores state in a file called `terraform.tfstate` in the working directory. A backup of the previous state is kept in `terraform.tfstate.backup`.

```
terraform/
├── main.tf
├── variables.tf
├── terraform.tfstate        ← Current state (contains secrets)
└── terraform.tfstate.backup ← Previous state
```

### When Local State is Appropriate

- **Learning and experimentation**: Testing Terraform concepts
- **Solo developer projects**: No team collaboration needed
- **Ephemeral environments**: Destroyed after each use (CI/CD test runs)
- **Quick prototyping**: Before committing to remote state infrastructure

### Security Precautions for Local State

**1. Never commit state to Git:**

The `.gitignore` file in this project already excludes state files:
```gitignore
*.tfstate
*.tfstate.*
```

Verify this is working:
```bash
git status | grep tfstate
# Should return nothing
```

**2. Restrict file permissions:**
```bash
chmod 600 terraform.tfstate
chmod 600 terraform.tfstate.backup
```

**3. Encrypt at rest:**

On macOS, enable FileVault. On Linux, use LUKS or similar disk encryption.

### Limitations of Local State

| Limitation | Impact |
|---|---|
| No encryption at rest | Secrets visible in plain text on disk |
| No locking | Concurrent runs can corrupt state |
| No versioning | Cannot recover from mistakes |
| No sharing | Team members cannot collaborate |
| No audit trail | No record of who changed what |

## Remote State with GCS

### Why GCS Remote State?

The Terraform GCS backend provides native state locking via object conditional updates — no separate locking resource is required. A single GCS bucket is all that is needed.

### Benefits Over Local State

- **Encryption at rest**: GCS encrypts all objects by default with Google-managed keys
- **Encryption in transit**: HTTPS enforced
- **Locking**: GCS backend uses object conditional updates (optimistic locking) — prevents concurrent modifications
- **Versioning**: GCS versioning allows recovery of any previous state
- **Access control**: IAM controls who can read/write state
- **Audit trail**: Cloud Audit Logs record all GCS access
- **Durability**: GCS provides 99.999999999% (11 nines) durability

### How Locking Works

GCS state locking uses a separate `.tflock` object. When `terraform apply` runs:

```
terraform apply
    │
    ├─ 1. Acquire lock (write .tflock object)
    │     └─ Fails if lock object already exists (another run is active)
    │
    ├─ 2. Read state (read default.tfstate object)
    │
    ├─ 3. Plan and apply changes
    │     └─ Create/update/destroy GCP and Netskope resources
    │
    ├─ 4. Write state (upload new default.tfstate)
    │     └─ Previous version preserved (GCS versioning)
    │
    └─ 5. Release lock (delete .tflock object)
```

## Creating the State Bucket

Before configuring the backend, create the GCS bucket.

### Via gcloud CLI

```bash
PROJECT_ID="my-gcp-project-id"
BUCKET="npa-publisher-terraform-state-${PROJECT_ID}"
REGION="us-central1"

# Create bucket with uniform bucket-level access
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access

# Enable object versioning (allows state recovery)
gcloud storage buckets update "gs://${BUCKET}" --versioning

# Verify settings
gcloud storage buckets describe "gs://${BUCKET}" \
  --format="value(versioning.enabled,iamConfiguration.uniformBucketLevelAccess.enabled)"
# Should show: True  True

echo ""
echo "Add to terraform/backend.tf:"
echo "  bucket = \"${BUCKET}\""
echo "  prefix = \"npa-publishers\""
```

### CMEK Encryption (Optional)

For customer-managed encryption keys (CMEK):

```bash
# Create a key ring and crypto key
gcloud kms keyrings create npa-publisher-terraform \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

gcloud kms keys create terraform-state \
  --location="${REGION}" \
  --keyring=npa-publisher-terraform \
  --purpose=encryption \
  --rotation-period=90d \
  --project="${PROJECT_ID}"

KEY_URI="projects/${PROJECT_ID}/locations/${REGION}/keyRings/npa-publisher-terraform/cryptoKeys/terraform-state"

# Grant GCS service account access to the key
GCS_SA=$(gcloud storage service-agent --project="${PROJECT_ID}" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['email_address'])")
gcloud kms keys add-iam-policy-binding terraform-state \
  --location="${REGION}" \
  --keyring=npa-publisher-terraform \
  --member="serviceAccount:${GCS_SA}" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project="${PROJECT_ID}"

# Apply CMEK to the bucket
gcloud storage buckets update "gs://${BUCKET}" \
  --default-encryption-key="${KEY_URI}"

echo "CMEK key URI: ${KEY_URI}"
echo "Add to backend.tf: encryption_key = \"${KEY_URI}\""
```

### Restrict State Bucket Access

Grant the Terraform service account access to the bucket only (not all GCS):

```bash
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:npa-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

## Configuring the GCS Backend

After creating the state bucket, configure the main project to use it.

### Uncomment backend.tf

Open `terraform/backend.tf` and uncomment the backend block:

```hcl
terraform {
  backend "gcs" {
    bucket = "npa-publisher-terraform-state-my-gcp-project-id"
    prefix = "npa-publishers"

    # Optional: CMEK encryption key URI (from key creation above)
    # encryption_key = "projects/PROJECT_ID/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY"
  }
}
```

### Backend Parameters

| Parameter | Required | Description |
|---|---|---|
| `bucket` | Yes | GCS bucket name for state storage |
| `prefix` | Yes | Path prefix within the bucket for state objects |
| `encryption_key` | Optional | CMEK key URI for customer-managed encryption |

### Environment-Specific Prefixes

Use different `prefix` values to maintain separate state for different environments:

```hcl
# Production
prefix = "npa-publishers/production"

# Staging
prefix = "npa-publishers/staging"

# Development
prefix = "npa-publishers/development"
```

All environments can share the same GCS bucket. The `prefix` provides isolation.

## Migration: Local to Remote

If you already have local state and want to move to GCS, Terraform handles the migration automatically.

### Step-by-Step Migration

**1. Verify current local state:**
```bash
terraform state list
```

**2. Initialize with the new backend:**
```bash
terraform init -migrate-state
```

Terraform will detect the backend change and prompt:
```
Initializing the backend...
Backend configuration changed!

Do you want to copy existing state to the new backend?
  Enter a value: yes
```

**3. Type `yes` to confirm the migration.**

Terraform will:
1. Read the local state file
2. Upload it to GCS
3. Acquire a lock during the operation
4. Verify the upload

**4. Verify the migration:**
```bash
# List resources from remote state (should match previous output)
terraform state list
```

**5. Verify in GCS:**
```bash
gcloud storage objects list "gs://YOUR_BUCKET/npa-publishers/"
```

**6. Clean up local state (optional but recommended):**
```bash
# After confirming remote state works
rm terraform.tfstate
rm terraform.tfstate.backup
```

> **Warning**: Only delete local state files after verifying remote state contains all your resources. Run `terraform plan` first to confirm "No changes".

### Rollback

If you need to revert to local state:

```bash
# Comment out the backend block in backend.tf
terraform init -migrate-state
# Terraform will copy state back to a local file
```

## State Security

### Registration Tokens in State

The Netskope publisher registration tokens are stored in both Terraform state and Secret Manager:

```
netskope_npa_publisher_token.this["my-publisher"]
  ├── publisher_id = "13450"
  └── token        = "eyJhbGci..." (sensitive, stored in plain text in state)

google_secret_manager_secret_version.publisher_token["my-publisher"]
  ├── secret   = "projects/.../secrets/my-npa-publisher-registration-token"
  └── secret_data = "eyJhbGci..." (encrypted at rest in Secret Manager; also in state)
```

**Mitigations:**

1. **Tokens are single-use**: Once a publisher registers with Netskope, the token cannot be reused. An attacker who obtains a used token cannot register additional publishers.

2. **Remote state encryption**: With the GCS backend, state is encrypted at rest by Google (or CMEK if configured) and in transit with HTTPS.

3. **Token not in instance metadata**: The registration token is stored in Secret Manager and fetched at runtime by the startup script. The token is not embedded in the startup script template (which is in state) — only the Secret Manager secret name is there.

4. **Secret Manager encryption**: Tokens stored in Secret Manager are encrypted at rest by Google-managed keys by default.

5. **Audit trail**: Cloud Audit Logs record every access to Secret Manager versions.

## State Operations

### Listing Resources

```bash
# List all managed resources
terraform state list

# Example output:
# google_compute_instance.publisher["my-publisher"]
# google_compute_instance.publisher["my-publisher-2"]
# google_compute_network.vpc[0]
# google_compute_subnetwork.publisher[0]
# google_service_account.publisher
# netskope_npa_publisher.this["my-publisher"]
# netskope_npa_publisher.this["my-publisher-2"]
# google_secret_manager_secret.publisher_token["my-publisher"]
# google_secret_manager_secret_version.publisher_token["my-publisher"]
```

### Showing Resource Details

```bash
# Show a specific resource's attributes
terraform state show 'google_compute_instance.publisher["my-publisher"]'

# Show Netskope publisher details
terraform state show 'netskope_npa_publisher.this["my-publisher"]'
```

### Removing Resources from State

Stop Terraform from managing a resource without destroying it:

```bash
# Remove a specific resource from state
terraform state rm 'google_compute_instance.publisher["my-publisher"]'

# Remove a Netskope publisher (useful when destroy fails for a connected publisher)
terraform state rm 'netskope_npa_publisher.this["my-publisher"]'
terraform state rm 'netskope_npa_publisher_token.this["my-publisher"]'
```

> **Warning**: After removing from state, Terraform no longer tracks the resource. Manage it manually or re-import it.

### Moving Resources in State

Rename a resource without destroying and recreating it:

```bash
terraform state mv \
  'google_compute_instance.publisher["old-name"]' \
  'google_compute_instance.publisher["new-name"]'
```

### Replacing Resources

Force replacement of a specific resource:

```bash
# Replace a specific publisher instance (with new token)
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
```

### Unlocking State

If a Terraform process crashes or is interrupted, the GCS lock object may remain:

```bash
# Get the lock ID from the error message
terraform force-unlock LOCK_ID
```

> **Warning**: Only force-unlock when you are certain no other Terraform process is running.

## Team Workflow

### Concurrent Access

When two operators run Terraform simultaneously:

- `terraform plan` — does not acquire the write lock (safe to run concurrently)
- `terraform apply` — acquires the lock; a second apply will fail with a lock error

**Example lock contention:**
```
Error: Error locking state: writing "lock" file:
  googleapi: Error 412: At least one of the pre-conditions you specified did not hold., conditionNotMet
```

Wait for the first apply to complete, then retry.

### CI/CD Best Practices

1. **Use the same backend**: CI/CD pipelines should use the same GCS backend as developers
2. **Plan on PR, apply on merge**: Run `terraform plan` on pull requests, `terraform apply` on merge to main
3. **Store plan files**: Save `terraform plan -out=tfplan` and apply the exact plan file:
   ```bash
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
4. **Use Workload Identity Federation**: No service account key files in CI/CD — see [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md)

### Workspaces

Terraform workspaces provide an alternative to separate `prefix` values for environment isolation:

```bash
terraform workspace new staging
terraform workspace select production
terraform workspace list
```

Each workspace maintains its own state file. For this project, separate `prefix` values are recommended over workspaces because they are more explicit.

## Disaster Recovery

### Recovering Previous State with GCS Versioning

If state is corrupted or a bad apply occurs:

**1. List state versions:**
```bash
gcloud storage objects list \
  "gs://YOUR_BUCKET/npa-publishers/" \
  --versions \
  --format="table(name,generation,timeCreated,size)"
```

**2. Download a previous version:**
```bash
gcloud storage cp \
  "gs://YOUR_BUCKET/npa-publishers/default.tfstate#GENERATION_NUMBER" \
  recovered-state.json
```

**3. Inspect the recovered state:**
```bash
python3 -c "
import json
with open('recovered-state.json') as f:
    state = json.load(f)
for r in state.get('resources', []):
    for i in r.get('instances', []):
        print(f\"{r['type']}.{r['name']}[{i.get('index_key', 0)}]\")
"
```

**4. Push the recovered state:**
```bash
# CAUTION: This overwrites current state
terraform state push recovered-state.json
```

### Manual Backup

```bash
# Pull current state to a local file
terraform state pull > state-backup-$(date +%Y%m%d-%H%M%S).json
```

### Rebuilding State After Total Loss

If state is completely lost but infrastructure still exists in GCP:

```bash
terraform init

# Import GCP resources
terraform import 'google_compute_network.vpc[0]' \
  projects/PROJECT/global/networks/my-vpc

terraform import 'google_compute_subnetwork.publisher[0]' \
  projects/PROJECT/regions/REGION/subnetworks/my-subnet

terraform import 'google_service_account.publisher' \
  projects/PROJECT/serviceAccounts/my-publisher-sa@PROJECT.iam.gserviceaccount.com

terraform import 'google_compute_instance.publisher["my-publisher"]' \
  projects/PROJECT/zones/ZONE/instances/my-publisher

terraform import 'google_secret_manager_secret.publisher_token["my-publisher"]' \
  projects/PROJECT/secrets/my-npa-publisher-registration-token

# ... import remaining resources

terraform plan
# Fix any differences between configuration and imported state
```

> **Note**: Netskope resources (`netskope_npa_publisher`, `netskope_npa_publisher_token`) may not support import depending on provider version. If they cannot be imported, remove any dangling Netskope publisher records via the API, then run `terraform apply` to create new ones.

### Complete Recovery from Scratch

If both state and infrastructure are lost:

1. Ensure the GCS state bucket exists
2. Configure `terraform/backend.tf`
3. Initialize: `terraform init`
4. Set variables in `terraform.tfvars` or environment
5. Apply: `terraform apply`

This creates everything from scratch. Netskope publishers will be new registrations.

## Cost

The GCS state backend costs essentially nothing for this use case:

| Service | Cost | Details |
|---|---|---|
| **GCS Storage** | ~$0.02/GB/month | State files are typically <100 KB; negligible |
| **GCS Versioning** | ~$0.01/month | Small incremental cost per version |
| **GCS Operations** | ~$0.00/month | Very infrequent read/write operations |
| **CMEK Key** (optional) | ~$0.06/month per key version | Only if using Cloud KMS for CMEK |

**Total: ~$0.00-0.06/month** (CMEK adds ~$0.06/month per key version if required)

## Additional Resources

- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture overview including state backend
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Deployment paths including remote state setup
- [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md) — IAM permissions for state access
- [Terraform GCS Backend Documentation](https://developer.hashicorp.com/terraform/language/settings/backends/gcs)
- [GCS Object Versioning](https://cloud.google.com/storage/docs/object-versioning)
- [GCP Cloud KMS Documentation](https://cloud.google.com/kms/docs)
