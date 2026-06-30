# VPC, subnet, Cloud Router, Cloud NAT, and firewall rules.
# All resources are conditional on var.create_vpc.
#
# GCP networking differs from AWS in three key ways:
#   1. VPCs are global; subnets are regional (one subnet covers all zones in a region).
#   2. Cloud NAT is a regional service — no per-zone NAT gateways or Elastic IPs needed.
#   3. Firewall rules target instances via network tags, not per-instance security groups.

# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  count                   = var.create_vpc ? 1 : 0
  name                    = "${var.publisher_name}-vpc"
  project                 = var.gcp_project_id
  auto_create_subnetworks = false
  description             = "VPC for NPA Publisher deployment managed by Terraform"
}

# ─── Subnet ───────────────────────────────────────────────────────────────────
# A single regional subnet. GCP subnets cover all zones in the region, so a
# single subnet is sufficient for multi-zone publisher distribution.
#
# private_ip_google_access = true allows VMs without external IPs to reach GCP
# APIs (Secret Manager, Cloud Logging, Cloud Monitoring) — replacing the three
# AWS VPC Endpoints (ssm, ssmmessages, ec2messages).

resource "google_compute_subnetwork" "publisher" {
  count                    = var.create_vpc ? 1 : 0
  name                     = "${var.publisher_name}-subnet"
  project                  = var.gcp_project_id
  region                   = var.gcp_region
  network                  = google_compute_network.vpc[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─── Cloud Router ─────────────────────────────────────────────────────────────
# Required by Cloud NAT. Manages BGP sessions and route advertisements.

resource "google_compute_router" "publisher" {
  count   = var.create_vpc ? 1 : 0
  name    = "${var.publisher_name}-router"
  project = var.gcp_project_id
  region  = var.gcp_region
  network = google_compute_network.vpc[0].id
}

# ─── Cloud NAT ────────────────────────────────────────────────────────────────
# Provides outbound internet access for VMs that have no external IP.
# A single regional Cloud NAT covers all zones — no per-zone gateways needed.
# GCP SLA: 99.99% availability.
#
# Replaces: aws_nat_gateway + aws_eip (one per AZ in the AWS architecture).

resource "google_compute_router_nat" "publisher" {
  count                              = var.create_vpc ? 1 : 0
  name                               = "${var.publisher_name}-nat"
  project                            = var.gcp_project_id
  router                             = google_compute_router.publisher[0].name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─── Firewall: Allow IAP SSH ingress ──────────────────────────────────────────
# Permits Identity-Aware Proxy TCP tunneling from the operator for shell access.
# This is the GCP equivalent of AWS SSM Session Manager — IAM-controlled, no
# bastion host or open SSH port required from the public internet.
#
# All IAP TCP tunnel traffic originates from 35.235.240.0/20 (Google-managed).
# The target_tags filter ensures this rule only applies to publisher instances.
#
# Ingress: Only IAP CIDR on port 22. GCP's implicit deny-all-ingress covers
# all other sources — publishers accept no other inbound connections.

resource "google_compute_firewall" "publisher_allow_iap_ssh" {
  name        = "${var.publisher_name}-allow-iap-ssh"
  project     = var.gcp_project_id
  network     = local.network_self_link
  description = "Allow IAP TCP tunneling for operator shell access (gcloud compute ssh --tunnel-through-iap)"

  direction = "INGRESS"
  priority  = 1000

  target_tags   = ["npa-publisher"]
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ─── Firewall: Allow all egress ───────────────────────────────────────────────
# Publishers must reach Netskope NewEdge, DNS, package repositories, and
# internal applications — destinations that vary per deployment.
# GCP already allows all egress by default; this explicit rule documents intent.

resource "google_compute_firewall" "publisher_allow_egress" {
  name        = "${var.publisher_name}-allow-egress"
  project     = var.gcp_project_id
  network     = local.network_self_link
  description = "Allow all egress from NPA Publisher VMs to reach Netskope NewEdge and internal applications"

  direction = "EGRESS"
  priority  = 1000

  target_tags        = ["npa-publisher"]
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }
}