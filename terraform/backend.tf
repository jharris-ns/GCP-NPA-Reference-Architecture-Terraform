
# Remote state backend using GCS.
#
# GCS provides native state locking via object versioning — no DynamoDB equivalent
# is required. Uncomment and configure before running terraform init for team use.
#
# Prerequisites: create the GCS bucket before enabling (see docs/STATE_MANAGEMENT.md).
#
# terraform {
#   backend "gcs" {
#     bucket = "npa-publisher-terraform-state-PROJECT_ID"
#     prefix = "npa-publishers"
#
#     # Optional: CMEK encryption key for the state object.
#     # encryption_key = "projects/PROJECT_ID/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY"
#   }
# }