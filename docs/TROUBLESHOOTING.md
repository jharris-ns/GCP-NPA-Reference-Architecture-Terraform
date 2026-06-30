# Troubleshooting Guide

Common issues and solutions for NPA Publisher Terraform deployments on GCP.

## Table of Contents

- [Terraform Deployment Issues](#terraform-deployment-issues)
- [Netskope Provider Issues](#netskope-provider-issues)
- [Publisher Registration Issues](#publisher-registration-issues)
- [Network Connectivity Issues](#network-connectivity-issues)
- [IAP SSH Access Issues](#iap-ssh-access-issues)
- [State Issues](#state-issues)
- [Diagnostic Commands](#diagnostic-commands)

## Terraform Deployment Issues

### Issue: terraform init Fails

**Symptom:** `Error: Failed to query available provider packages`

**Causes and solutions:**

1. **No internet access:**
   ```bash
   curl -I https://registry.terraform.io
   ```

2. **Provider not found:**
   Verify `terraform/versions.tf` has the correct provider source:
   ```hcl
   google = {
     source  = "hashicorp/google"
     version = ">= 5.0"
   }
   ```

3. **Lock file conflict:**
   ```bash
   terraform init -upgrade
   ```

### Issue: terraform plan Shows Errors

**Symptom:** `Error: Invalid value for variable`

**Solution:** Check variable values against validation rules in `terraform/variables.tf`:

```bash
# Common validation errors:
# publisher_name: must be lowercase, 3-26 chars, start with a letter, letters/numbers/hyphens only
# publisher_count: must be 2-10 (minimum 2 for HA)
# publisher_machine_type: must be in the allowed list
# environment: must be Production, Staging, Development, or Test
```

**Symptom:** `Error: Invalid credentials` or `Error: googleapi: Error 403`

**Solution:** Configure GCP credentials:
```bash
# Check active account
gcloud auth list

# Re-authenticate
gcloud auth application-default login

# Or set service account key
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
```

**Symptom:** `Error: googleapi: Error 403: Compute Engine API has not been enabled`

**Solution:** Enable required APIs:
```bash
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### Issue: terraform apply Fails Partway Through

**Symptom:** Some resources created, then error

**Solution:** Fix the error and re-run `terraform apply`. Terraform is idempotent — it will skip already-created resources and continue from where it stopped.

Common apply errors:

| Error | Cause | Solution |
|---|---|---|
| `403 Permission denied` | Missing IAM permissions | See [IAM_PERMISSIONS.md](IAM_PERMISSIONS.md) |
| `API not enabled` | Required API not enabled | Run `gcloud services enable ...` |
| `Quota exceeded` | GCP quota limit reached | Request quota increase in GCP Console |
| `CIDR conflict` | Subnet CIDR overlaps existing | Change `subnet_cidr` value |
| `publisher_count must be >= 2` | Tried to set count to 1 | Minimum is 2 for HA |

### Issue: terraform destroy Fails

**Symptom:** `Error: Error deleting publisher` — publisher is **Connected** in Netskope

**Cause:** Netskope rejects API deletion of a publisher that has active connections or that still has private apps associated with it.

> **Before deleting a publisher**: remove all private app associations in the Netskope UI (**Settings → Security Cloud Platform → Private Apps → edit each app → remove the publisher**). A publisher with associated private apps cannot be deleted even if it is disconnected.

**Solution:**
1. Remove any private app associations, then disconnect the publisher in Netskope UI (**Settings → Security Cloud Platform → Publishers → Disconnect**)
2. Or remove it from Terraform state and delete it manually:
   ```bash
   # Remove from Terraform state (resource still exists in GCP/Netskope)
   terraform state rm 'netskope_npa_publisher.this["my-publisher"]'
   terraform state rm 'netskope_npa_publisher_token.this["my-publisher"]'

   # Delete the Netskope publisher via API
   curl -X DELETE \
     -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
     "$TF_VAR_netskope_server_url/infrastructure/publishers/PUBLISHER_ID"

   # Run destroy again (only deletes remaining GCP resources)
   terraform destroy
   ```

## Netskope Provider Issues

### Issue: Authentication Failed

**Symptom:** `Error: Authentication failed` or `401 Unauthorized`

**Solutions:**

1. **Verify API key:**
   ```bash
   # Check the environment variable is set
   echo "${TF_VAR_netskope_api_key:0:10}..."
   # Should show first 10 characters

   # Test API directly
   curl -s -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
     "$TF_VAR_netskope_server_url/infrastructure/publishers" | head -c 200
   ```

2. **Check server URL format:**
   ```bash
   # Correct format (include /api/v2):
   export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"

   # Wrong formats:
   # https://mytenant.goskope.com        (missing /api/v2)
   # https://mytenant.goskope.com/api/v2/ (trailing slash may cause issues)
   ```

3. **Check token scopes** in Netskope UI:
   - Settings → Tools → REST API v2
   - Verify token has **Infrastructure Management** scope

### Issue: Publisher Creation Failed

**Symptom:** `Error: Failed to create publisher`

**Solutions:**

1. **Duplicate name:** Publisher names must be unique within a tenant
   ```bash
   curl -s -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
     "$TF_VAR_netskope_server_url/infrastructure/publishers" \
     | python3 -c "import json,sys; [print(p['publisher_name']) for p in json.load(sys.stdin)['data']['publishers']]"
   ```

2. **API rate limiting:** Wait and retry:
   ```bash
   terraform apply
   ```

3. **Tenant issues:** Check Netskope service status at your tenant's status page.

## Publisher Registration Issues

### Issue: Publisher Not Showing as Connected

**Symptom:** Terraform completes successfully but Netskope UI shows the publisher as **Disconnected** or it doesn't appear

**Cause:** `terraform apply` completes when GCP resources are created — publisher registration runs asynchronously in the startup script (12-18 minutes total). If registration fails, the instance will be running but the publisher won't connect.

**Diagnose:**

```bash
# Check startup script output via Cloud Logging (no SSH needed)
gcloud logging read \
  'resource.type="gce_instance" AND logName:"google-startup-scripts"' \
  --project=YOUR_PROJECT_ID \
  --limit=50 \
  --format="table(timestamp,jsonPayload.message)"

# Check serial port output for early boot issues
gcloud compute instances get-serial-port-output my-publisher \
  --zone us-central1-b \
  --project YOUR_PROJECT_ID | tail -100
```

**Common failure messages and solutions:**

| Log Message | Cause | Solution |
|---|---|---|
| `Failed to fetch token after 30 attempts` | Secret Manager unreachable | Check Private Google Access on subnet; check IAM binding |
| `npa_publisher_wizard exited with code ...` | Registration wizard error | Check Netskope publisher ID still exists in tenant |
| `Bootstrap script failed` | bootstrap.sh download failed | Check Cloud NAT is healthy; check outbound internet |
| `Metadata server not reachable` | Python3 not found, or link-local unreachable | Check instance health; if the VM is up, reset it — the startup script uses Python3 for this check, which is always present |

### Issue: Secret Manager Token Fetch Fails

**Symptom:** Log shows `Failed to fetch token after 30 attempts (150 s)`

**Diagnose:**

1. **Private Google Access not enabled on subnet:**
   ```bash
   gcloud compute networks subnets describe YOUR_SUBNET \
     --region=YOUR_REGION \
     --project=YOUR_PROJECT_ID \
     --format="value(privateIpGoogleAccess)"
   # Should return: True
   ```

2. **IAM binding missing — service account not allowed to read secret:**
   ```bash
   # List IAM bindings on the secret
   gcloud secrets get-iam-policy my-npa-publisher-registration-token \
     --project=YOUR_PROJECT_ID
   # Should show: roles/secretmanager.secretAccessor for the publisher service account
   ```

3. **Secret doesn't exist:**
   ```bash
   gcloud secrets list --project=YOUR_PROJECT_ID | grep registration-token
   ```

**Recovery:** If these checks fail, re-run `terraform apply` to ensure IAM bindings and secrets are correct, then reset the VM:
```bash
terraform apply  # Fix any missing resources
gcloud compute instances reset my-publisher --zone ZONE --project PROJECT_ID
```

### Issue: Bootstrap Script Fails

**Symptom:** Log shows `Bootstrap script failed` or bootstrap-related errors

**Cause:** The Netskope bootstrap script requires outbound internet access (via Cloud NAT) to download Docker and the publisher container.

**Diagnose:**

```bash
# Check Cloud NAT status
gcloud compute routers describe YOUR_ROUTER_NAME \
  --region=YOUR_REGION \
  --project=YOUR_PROJECT_ID

# Check Cloud NAT is attached to the router
gcloud compute routers nats list \
  --router=YOUR_ROUTER_NAME \
  --region=YOUR_REGION \
  --project=YOUR_PROJECT_ID
```

**Recovery:** If Cloud NAT is missing or misconfigured, run `terraform apply` to recreate it, then reset the VM.

### Issue: Publisher Registration Token Already Consumed

**Symptom:** VM was reset or replaced but registration still fails with a token error

**Cause:** Registration tokens are single-use. If the wizard ran (even unsuccessfully), the token is consumed.

**Solution:** Replace the publisher with a new token:

```bash
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
```

### Issue: Partial Replace Failure — Publisher Shows Connected During Replace

**Symptom:** `terraform apply -replace=...` fails partway through with:

```
Error: failure to invoke API
API error: Error returned by backend API, status code:422, reason: Not allow to delete the connected publisher
```

**Cause:** The Netskope publisher was still marked **connected** when Terraform tried to delete it. This can happen if the old VM takes longer than expected to terminate, and Terraform's deletion of the Netskope record races with the VM shutdown.

**What is left in state after this failure:**
- The old Netskope publisher record still exists (destroy failed)
- The registration token and secret version have been destroyed (earlier in the sequence)
- A new VM may have already been created but has no token in Secret Manager

**Recovery procedure:**

**Step 1 — Wait for the publisher to disconnect.** Once the old VM is terminated, Netskope will mark it disconnected within a few minutes. Check:

```bash
curl -s \
  -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers" \
  | python3 -c "
import json, sys
for p in json.load(sys.stdin)['data']['publishers']:
    if 'my-publisher' in p['publisher_name']:
        print(p['publisher_name'], p['publisher_id'], p.get('status','?'))
"
# Wait until status shows: disconnected
```

**Step 2 — Re-run the same replace command:**

```bash
terraform apply \
  -replace='netskope_npa_publisher.this["my-publisher"]' \
  -replace='netskope_npa_publisher_token.this["my-publisher"]' \
  -replace='google_secret_manager_secret_version.publisher_token["my-publisher"]' \
  -replace='google_compute_instance.publisher["my-publisher"]'
```

If the new VM was already created in the failed run, Terraform will detect that the token and secret version are missing from state and recreate them, then replace the compute instance again.

**Alternative — if only the token/secret are missing from state** (new VM already created):

```bash
# Step 1: Recreate just the missing token and secret version
terraform apply

# Step 2: Reset the new VM to re-run the startup script with the fresh token
gcloud compute instances reset my-publisher --zone ZONE --project PROJECT_ID
```

The startup script detects that Docker and the wizard are already installed, skips bootstrap, and runs the wizard directly with the new token. Re-registration completes in seconds rather than minutes.

## Network Connectivity Issues

### Issue: Publisher Not Connecting to Netskope NewEdge

**Diagnose from the instance via IAP SSH:**
```bash
gcloud compute ssh my-publisher \
  --tunnel-through-iap --zone ZONE --project PROJECT_ID

# Test outbound connectivity
python3 -c "import urllib.request; print(urllib.request.urlopen('https://www.google.com', timeout=5).status)"

# Test Netskope specifically
python3 -c "import urllib.request; print(urllib.request.urlopen('https://mytenant.goskope.com', timeout=5).status)"

# Test DNS
python3 -c "import socket; print(socket.gethostbyname('mytenant.goskope.com'))"
```

**Check Cloud NAT:**
```bash
gcloud compute routers nats list \
  --router=YOUR_ROUTER \
  --region=YOUR_REGION \
  --project=YOUR_PROJECT_ID
```

All egress traffic uses Cloud NAT. If Cloud NAT is missing, instances cannot reach the internet.

### Issue: Private Google Access Not Working

**Symptom:** VM cannot reach `secretmanager.googleapis.com` or `logging.googleapis.com`

**Check:**
```bash
gcloud compute networks subnets describe YOUR_SUBNET \
  --region=YOUR_REGION --project=YOUR_PROJECT_ID \
  --format="value(privateIpGoogleAccess)"
# Must be True
```

**Fix:**
```bash
gcloud compute networks subnets update YOUR_SUBNET \
  --region=YOUR_REGION \
  --enable-private-ip-google-access \
  --project=YOUR_PROJECT_ID
```

Or run `terraform apply` — the subnet resource has `private_ip_google_access = true` set.

## IAP SSH Access Issues

### Issue: gcloud compute ssh Fails

**Symptom:** `Error: (gcloud.compute.ssh) Could not fetch resource`

**Causes:**

1. **Missing IAP role:**
   ```bash
   # Grant IAP Tunnel User role
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="user:you@example.com" \
     --role="roles/iap.tunnelResourceAccessor"
   ```

2. **Missing firewall rule for IAP:**
   The firewall rule allowing ingress from `35.235.240.0/20` on port 22 should exist:
   ```bash
   gcloud compute firewall-rules list \
     --filter="name~iap" \
     --project=YOUR_PROJECT_ID
   ```
   If missing, run `terraform apply`.

3. **OS Login not enabled:**
   ```bash
   gcloud compute instances describe my-publisher \
     --zone=ZONE --project=PROJECT_ID \
     --format="value(metadata.items[key='enable-oslogin'].value)"
   # Should return: TRUE
   ```

4. **IAP TCP forwarding API not enabled:**
   ```bash
   gcloud services enable iap.googleapis.com --project=YOUR_PROJECT_ID
   ```

## State Issues

### Issue: State Lock Stuck

**Symptom:** `Error: Error acquiring the state lock`

**Diagnose:**
```bash
# Check which process holds the lock
gcloud storage objects describe \
  "gs://YOUR_STATE_BUCKET/npa-publishers/default.tflock" \
  --project=YOUR_PROJECT_ID 2>/dev/null || echo "No lock file found"
```

**Solution:**

First, verify no other Terraform process is running. Then:
```bash
# Get the lock ID from the error message
terraform force-unlock LOCK_ID
```

> **Warning**: Only force-unlock when you are certain no other process is running.

### Issue: State Out of Sync

**Symptom:** `terraform plan` shows changes for resources that haven't actually changed

**Solution:**
```bash
# Refresh state from actual infrastructure
terraform apply -refresh-only
```

This updates state to match the current state of resources in GCP/Netskope without making any changes to infrastructure.

### Issue: Lost State

**Symptom:** State file missing or empty, but infrastructure exists

**Solution:** Rebuild state by importing each resource:

```bash
terraform import 'google_compute_network.vpc[0]' projects/PROJECT/global/networks/my-vpc
terraform import 'google_compute_subnetwork.publisher[0]' projects/PROJECT/regions/REGION/subnetworks/my-subnet
terraform import 'google_service_account.publisher' projects/PROJECT/serviceAccounts/my-publisher-sa@PROJECT.iam.gserviceaccount.com
terraform import 'google_compute_instance.publisher["my-publisher"]' projects/PROJECT/zones/ZONE/instances/my-publisher
# ... import remaining resources

terraform plan
# Fix any configuration differences
```

## Diagnostic Commands

### Terraform Diagnostics

```bash
# Check Terraform version and providers
terraform version

# List managed resources
terraform state list

# Show specific resource details
terraform state show 'google_compute_instance.publisher["my-publisher"]'

# Validate configuration
terraform validate

# Plan with detailed exit code
terraform plan -detailed-exitcode
# 0=no changes, 1=error, 2=changes detected

# Enable debug logging
TF_LOG=DEBUG terraform plan 2>terraform-debug.log
```

### GCP CLI Diagnostics

```bash
# Current identity
gcloud auth list
gcloud config get-value project

# Instance details
gcloud compute instances describe my-publisher \
  --zone=ZONE --project=PROJECT_ID --format=json

# Instance list with status
gcloud compute instances list \
  --filter="labels.managed_by=terraform AND labels.project=npa-publisher" \
  --project=PROJECT_ID \
  --format="table(name,zone,status,networkInterfaces[0].networkIP)"

# Serial port output (boot log)
gcloud compute instances get-serial-port-output my-publisher \
  --zone=ZONE --project=PROJECT_ID | tail -100

# Startup script logs (Cloud Logging)
gcloud logging read \
  'resource.type="gce_instance" AND logName:"google-startup-scripts"' \
  --project=PROJECT_ID --limit=50 \
  --format="table(timestamp,jsonPayload.message)"

# Cloud NAT status
gcloud compute routers nats list \
  --router=YOUR_ROUTER --region=YOUR_REGION --project=PROJECT_ID

# Firewall rules
gcloud compute firewall-rules list \
  --filter="network~npa-publisher" \
  --project=PROJECT_ID

# Service account bindings
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --format="table(bindings.role)" \
  --filter="bindings.members:my-publisher-sa@PROJECT_ID.iam.gserviceaccount.com"
```

### Secret Manager Diagnostics

```bash
# List secrets
gcloud secrets list --project=PROJECT_ID | grep registration-token

# Check secret IAM
gcloud secrets get-iam-policy my-npa-publisher-registration-token \
  --project=PROJECT_ID

# Verify secret has a version (token was stored)
gcloud secrets versions list my-npa-publisher-registration-token \
  --project=PROJECT_ID
```

### Netskope API Diagnostics

```bash
# Test API connectivity
curl -v -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers"

# List all publishers with status
curl -s -H "Netskope-Api-Token: $TF_VAR_netskope_api_key" \
  "$TF_VAR_netskope_server_url/infrastructure/publishers" \
  | python3 -c "
import json, sys
for p in json.load(sys.stdin)['data']['publishers']:
    print(p['publisher_name'], p['publisher_id'], p.get('status', 'unknown'))
"
```

## Getting Help

If you're still experiencing issues:

1. **Collect diagnostics** using the commands above
2. **Check GCP Service Health** at `status.cloud.google.com`
3. **Check Netskope System Status** at your tenant's status page
4. **Review Terraform debug logs** (`TF_LOG=DEBUG terraform plan`)
5. **File an issue** on the GitHub repository with:
   - Terraform version (`terraform version`)
   - Error messages (full output)
   - Deployment mode (new VPC / existing VPC, local / remote state)
   - Relevant diagnostic command outputs

## Additional Resources

- [OPERATIONS.md](OPERATIONS.md) — Operational procedures
- [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) — State management and recovery
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Deployment instructions
- [Netskope REST API v2](https://docs.netskope.com/en/rest-api-v2-overview-312207.html)
- [Terraform Debugging](https://developer.hashicorp.com/terraform/internals/debugging)
- [GCP IAP Troubleshooting](https://cloud.google.com/iap/docs/troubleshooting)
