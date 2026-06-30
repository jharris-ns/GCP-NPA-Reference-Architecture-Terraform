output "publisher_instance_ids" {
  description = "Map of publisher name to Compute Engine instance ID"
  value       = { for k, v in google_compute_instance.publisher : k => v.instance_id }
}

output "publisher_self_links" {
  description = "Map of publisher name to instance self-link (used for IAM bindings and gcloud commands)"
  value       = { for k, v in google_compute_instance.publisher : k => v.self_link }
}

output "publisher_private_ips" {
  description = "Map of publisher name to private IP address"
  value       = { for k, v in google_compute_instance.publisher : k => v.network_interface[0].network_ip }
}

output "publisher_zones" {
  description = "Map of publisher name to GCP zone"
  value       = { for k, v in google_compute_instance.publisher : k => v.zone }
}

output "publisher_names" {
  description = "List of publisher names registered with Netskope"
  value       = keys(local.publishers)
}

output "publisher_service_account_email" {
  description = "Email of the publisher VM service account"
  value       = google_service_account.publisher.email
}

output "netskope_publisher_ids" {
  description = "Map of publisher name to Netskope publisher ID"
  value       = { for k, v in netskope_npa_publisher.this : k => v.publisher_id }
}

output "network_self_link" {
  description = "Self-link of the VPC network (created or existing)"
  value       = local.network_self_link
}

output "subnet_self_links" {
  description = "Self-links of the publisher subnets (created or existing)"
  value       = local.subnet_self_links
}

output "vpc_name" {
  description = "Name of the created VPC network. Empty when using an existing VPC."
  value       = var.create_vpc ? google_compute_network.vpc[0].name : ""
}

# ─── SSH / IAP Access Commands ────────────────────────────────────────────────
output "iap_ssh_commands" {
  description = "gcloud commands to SSH into each publisher via IAP TCP tunneling (replaces SSM Session Manager)"
  value = {
    for k, v in google_compute_instance.publisher :
    k => "gcloud compute ssh ${v.name} --tunnel-through-iap --zone ${v.zone} --project ${var.gcp_project_id}"
  }
}

output "log_query" {
  description = "Cloud Logging query to view publisher startup script output"
  value       = "gcloud logging read 'resource.type=\"gce_instance\" AND logName:\"google-startup-scripts\"' --project=${var.gcp_project_id} --limit=50"
}
