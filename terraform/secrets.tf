# Secret Manager resources for NPA Publisher registration tokens.
#
# Replaces aws_ssm_parameter (SecureString) from the AWS architecture.
# One secret per publisher; each holds a single-use registration token.
#
# Security properties:
#   - Encrypted at rest by GCP (Google-managed key by default; CMEK configurable)
#   - Access is scoped per-secret via IAM (see iam.tf)
#   - Tokens are single-use: once a publisher registers, the token cannot be reused
#   - Cloud Audit Logs records every secretmanager.versions.access call

resource "google_secret_manager_secret" "publisher_token" {
  for_each  = local.publishers
  secret_id = "${each.key}-registration-token"
  project   = var.gcp_project_id
  labels    = local.common_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "publisher_token" {
  for_each = local.publishers

  secret      = google_secret_manager_secret.publisher_token[each.key].id
  secret_data = netskope_npa_publisher_token.this[each.key].token
}