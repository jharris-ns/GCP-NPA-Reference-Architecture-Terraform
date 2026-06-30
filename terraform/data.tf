# Current project metadata
data "google_project" "current" {}

# Available zones in the target region
# Used by locals.tf to auto-select two zones when var.zones is empty.
data "google_compute_zones" "available" {
  region = var.gcp_region
  status = "UP"
}

# Ubuntu 22.04 LTS — base image for NPA Publisher VMs.
# The publisher software is installed at boot via bootstrap.sh (see startup.sh.tftpl).
# Only queried when publisher_image_self_link is not provided.
data "google_compute_image" "ubuntu" {
  count   = var.publisher_image_self_link == "" ? 1 : 0
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}