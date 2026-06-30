# IAM resources: publisher VM service account and its bindings.
#
# GCP merges the AWS IAM Role + Instance Profile into a single google_service_account.
# The service account is attached directly to VMs in the service_account {} block —
# no separate "instance profile" wrapper resource is needed.
#
# Role separation:
#   Publisher VM SA  — attached to each VM; used by the Ops Agent, startup script,
#                      and NPA publisher process. Scoped to minimum required permissions.
#   Terraform operator — external; manages all GCP and Netskope resources.
#                        (no Terraform-managed resource — configured outside this module)

# ─── Publisher VM Service Account ─────────────────────────────────────────────

resource "google_service_account" "publisher" {
  # account_id must be 6-30 chars: publisher_name (3-26) + "-sa" (3) = 6-29 chars
  account_id   = "${var.publisher_name}-sa"
  display_name = "NPA Publisher VM Service Account"
  description  = "Service account for NPA Publisher VM instances. Managed by Terraform."
  project      = var.gcp_project_id
}

# ─── Cloud Logging ────────────────────────────────────────────────────────────
# Allows the Ops Agent and startup script output to write to Cloud Logging.

resource "google_project_iam_member" "publisher_log_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

# ─── Cloud Monitoring ─────────────────────────────────────────────────────────
# Allows the Ops Agent to write metrics to Cloud Monitoring.

resource "google_project_iam_member" "publisher_metric_writer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

# ─── Resource Metadata (Ops Agent) ────────────────────────────────────────────
# Required for the Ops Agent to report VM metadata (instance name, zone, etc.)
# alongside metrics and logs. Only needed when monitoring is enabled.

resource "google_project_iam_member" "publisher_resource_metadata_writer" {
  count   = var.enable_monitoring ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.publisher.email}"
}

# ─── Secret Manager access (scoped per-publisher secret) ──────────────────────
# Grants the publisher VM service account read access to its own registration
# token secret only. Not project-wide — each binding is scoped to one secret.
#
# This mirrors the AWS SSM Automation role's resource-scoped ssm:GetParameter
# permission on /npa/publishers/*/registration-token.
#
# The VM's startup script uses this binding to fetch its token from Secret Manager
# via the GCP metadata server identity — the token never transits the operator.

resource "google_secret_manager_secret_iam_member" "publisher_token_access" {
  for_each  = local.publishers
  project   = var.gcp_project_id
  secret_id = google_secret_manager_secret.publisher_token[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.publisher.email}"
}