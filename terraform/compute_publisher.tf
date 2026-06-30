# Compute Engine VM instances for NPA Publishers.
#
# Key design decisions:
#   - No external IP (network_interface has no access_config block)
#   - Outbound internet via Cloud NAT (vpc.tf)
#   - GCP API access via Private Google Access on subnet (no VPC endpoints needed)
#   - Service account identity used by startup script to read registration token
#   - Shielded VM for boot integrity and vTPM (GCP security equivalent of IMDSv2)
#   - OS Login replaces EC2 key pairs
#   - ignore_changes on startup-script and image to prevent unintended replacement
#     (use explicit -replace for intentional replacement — same pattern as AWS)

resource "google_compute_instance" "publisher" {
  for_each = local.publishers

  name         = each.key
  machine_type = var.publisher_machine_type
  zone         = local.zones[each.value.index % length(local.zones)]
  project      = var.gcp_project_id

  # Network tag used by firewall rules in vpc.tf to target publisher VMs
  tags   = ["npa-publisher"]
  labels = local.common_labels

  boot_disk {
    initialize_params {
      image = local.publisher_image
      size  = 30
      type  = "pd-ssd"
    }
    # GCP encrypts all persistent disks at rest by default (Google-managed key).
    # To use a CMEK, add: kms_key_self_link = google_kms_crypto_key.publisher.id
  }

  network_interface {
    # Distribute instances across subnets using the same modulo pattern as zones.
    # With a single created subnet this is always index 0; with multiple existing
    # subnets it distributes across them.
    subnetwork = local.subnet_self_links[each.value.index % length(local.subnet_self_links)]
    # No access_config block = no external IP assigned to this instance.
    # Outbound internet access is provided by Cloud NAT.
  }

  service_account {
    email  = google_service_account.publisher.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # OS Login replaces EC2 key pairs. Access is controlled via IAM, not SSH keys.
    enable-oslogin = "TRUE"

    # The startup script fetches the registration token from Secret Manager using
    # the VM service account identity and runs the NPA Publisher wizard.
    startup-script = templatefile("${path.module}/templates/startup.sh.tftpl", {
      enable_monitoring = var.enable_monitoring
      secret_name       = google_secret_manager_secret.publisher_token[each.key].secret_id
      project_id        = var.gcp_project_id
      publisher_name    = each.key
    })
  }

  # HA scheduling policy — GCP best practice for persistent workloads.
  # MIGRATE: GCP live-migrates the VM instead of stopping it during host maintenance,
  # providing near-zero downtime for planned maintenance events.
  # automatic_restart: GCP restarts the VM automatically if it stops unexpectedly.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  # Shielded VM — GCP's security equivalent of AWS IMDSv2 + Nitro Enclaves.
  # Protects against boot-level tampering and UEFI-level attacks.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [
      # Do not replace running publishers when the startup script template changes.
      # Running publishers update themselves via Netskope auto-update.
      metadata["startup-script"],
      # Do not replace when the Ubuntu base image reference changes.
      # Use explicit -replace for intentional image replacement:
      #   terraform apply \
      #     -replace='netskope_npa_publisher.this["name"]' \
      #     -replace='netskope_npa_publisher_token.this["name"]' \
      #     -replace='google_secret_manager_secret_version.publisher_token["name"]' \
      #     -replace='google_compute_instance.publisher["name"]'
      boot_disk,
    ]
  }

  # Ensure IAM bindings exist before the VM boots and runs the startup script.
  # Without this, the startup script may fail to access Secret Manager if the
  # IAM propagation hasn't completed.
  depends_on = [
    google_secret_manager_secret_iam_member.publisher_token_access,
    google_compute_router_nat.publisher,
  ]
}