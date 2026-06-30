locals {
  # ─── Publisher map ──────────────────────────────────────────────────────────
  # Name-keyed map used by all for_each resources.
  # With publisher_name = "my-pub" and publisher_count = 3:
  #   { "my-pub" = {index=0, name="my-pub"}, "my-pub-2" = {index=1, ...}, "my-pub-3" = {index=2, ...} }
  #
  # Using for_each (not count) so that removing a publisher only affects that
  # specific resource — not all higher-indexed ones.
  publishers = {
    for i in range(var.publisher_count) :
    (i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}") => {
      index = i
      name  = i == 0 ? var.publisher_name : "${var.publisher_name}-${i + 1}"
    }
  }

  # ─── Network references ─────────────────────────────────────────────────────
  # Resolved from either created or existing resources so downstream files
  # never check var.create_vpc directly.
  network_self_link = (
    var.create_vpc
    ? google_compute_network.vpc[0].self_link
    : var.existing_network_self_link
  )

  subnet_self_links = (
    var.create_vpc
    ? [google_compute_subnetwork.publisher[0].self_link]
    : var.existing_subnet_self_links
  )

  # ─── Zone distribution ──────────────────────────────────────────────────────
  # Defaults to the first N available zones in gcp_region, where N = publisher_count
  # (capped at the number of available zones). This ensures each publisher lands in
  # a distinct zone for HA — e.g., 2 publishers → 2 zones, 3 publishers → 3 zones.
  # AZ distribution for publishers: zone = zones[index % len(zones)]
  zones = (
    length(var.zones) > 0
    ? var.zones
    : slice(data.google_compute_zones.available.names, 0, min(var.publisher_count, length(data.google_compute_zones.available.names)))
  )

  # ─── Publisher image ────────────────────────────────────────────────────────
  # Defaults to Ubuntu 22.04 LTS. Publisher software is installed at first boot
  # via bootstrap.sh (see templates/startup.sh.tftpl).
  publisher_image = (
    var.publisher_image_self_link != ""
    ? var.publisher_image_self_link
    : data.google_compute_image.ubuntu[0].self_link
  )

  # ─── Common labels ──────────────────────────────────────────────────────────
  # GCP does not support provider-level default_labels (unlike AWS default_tags).
  # This map is merged into every resource's labels block.
  common_labels = merge(
    {
      project     = lower(replace(var.project_label, " ", "-"))
      environment = lower(var.environment)
      cost_center = lower(replace(var.cost_center, " ", "-"))
      managed_by  = "terraform"
    },
    var.additional_labels
  )
}