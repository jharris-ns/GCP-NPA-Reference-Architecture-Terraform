provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "netskope" {
  server_url = var.netskope_server_url
  api_key    = var.netskope_api_key
}