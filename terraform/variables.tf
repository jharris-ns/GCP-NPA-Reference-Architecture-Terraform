# ─── GCP Project ─────────────────────────────────────────────────────────────

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID where publishers will be deployed"
}

variable "gcp_region" {
  type        = string
  description = "GCP region for publisher deployment (e.g., us-central1)"
  default     = "us-central1"
}

variable "zones" {
  type        = list(string)
  description = "Specific GCP zones for publisher distribution within gcp_region. If empty, Terraform auto-selects the first two available zones."
  default     = []
}

# ─── Netskope ─────────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  type        = string
  description = "Netskope tenant API URL (e.g., https://mytenant.goskope.com/api/v2). Set via TF_VAR_netskope_server_url."
  sensitive   = true
}

variable "netskope_api_key" {
  type        = string
  description = "Netskope REST API v2 token with Infrastructure Management scope. Set via TF_VAR_netskope_api_key."
  sensitive   = true
}

# ─── Publisher ────────────────────────────────────────────────────────────────

variable "publisher_name" {
  type        = string
  description = "Base name for NPA publishers. Used as a prefix for all GCP resource names. Must be lowercase, start with a letter, contain only letters/numbers/hyphens, and be 3-26 characters (GCP naming constraints)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,25}$", var.publisher_name))
    error_message = "publisher_name must be lowercase, 3-26 characters, start with a letter, and contain only letters, numbers, and hyphens."
  }
}

variable "publisher_count" {
  type        = number
  description = "Number of NPA Publisher instances to deploy. Minimum 2 for HA — a single publisher is a single point of failure. Publishers are distributed across zones using modulo."
  default     = 2

  validation {
    condition     = var.publisher_count >= 2 && var.publisher_count <= 10
    error_message = "publisher_count must be between 2 and 10. A minimum of 2 publishers across separate zones is required for high availability."
  }
}

variable "publisher_machine_type" {
  type        = string
  description = "GCP machine type for publisher VM instances. See docs/ARCHITECTURE.md for capacity guidance."
  default     = "n2-standard-2"

  validation {
    condition = contains([
      "e2-medium",
      "e2-standard-2",
      "e2-standard-4",
      "n2-standard-2",
      "n2-standard-4",
      "n2-standard-8",
      "n2-highmem-2",
      "n2-highmem-4",
      "n2-highmem-8",
      "c2-standard-4",
      "c2-standard-8",
    ], var.publisher_machine_type)
    error_message = "publisher_machine_type must be one of the supported GCP machine types listed in variables.tf."
  }
}

variable "publisher_image_self_link" {
  type        = string
  description = "Full self-link of a custom GCP Compute Engine image to use for publisher VMs. If empty (default), the latest Ubuntu 22.04 LTS public image is used and the publisher software is installed via bootstrap at first boot."
  default     = ""
}

# ─── VPC ──────────────────────────────────────────────────────────────────────

variable "create_vpc" {
  type        = bool
  description = "If true, create a new VPC, subnet, Cloud Router, and Cloud NAT. If false, provide existing_network_self_link and existing_subnet_self_links."
  default     = true
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR range for the publisher subnet. Only used when create_vpc = true."
  default     = "10.0.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block (e.g., 10.0.0.0/24)."
  }
}

variable "existing_network_self_link" {
  type        = string
  description = "Self-link of an existing GCP VPC network. Required when create_vpc = false. Format: https://www.googleapis.com/compute/v1/projects/PROJECT/global/networks/NETWORK"
  default     = null
}

variable "existing_subnet_self_links" {
  type        = list(string)
  description = "Self-links of existing subnets. Must have Private Google Access enabled and be covered by a Cloud NAT. Required when create_vpc = false."
  default     = []
}

# ─── Monitoring ───────────────────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  description = "If true, install the Google Cloud Ops Agent on publisher instances to collect memory, disk, and application metrics in Cloud Monitoring."
  default     = false
}

# ─── Labels ───────────────────────────────────────────────────────────────────

variable "environment" {
  type        = string
  description = "Environment label applied to all resources"
  default     = "Production"

  validation {
    condition     = contains(["Production", "Staging", "Development", "Test"], var.environment)
    error_message = "environment must be one of: Production, Staging, Development, Test."
  }
}

variable "cost_center" {
  type        = string
  description = "Cost center label for billing allocation"
  default     = "IT-Operations"
}

variable "project_label" {
  type        = string
  description = "Project label applied to all resources"
  default     = "NPA-Publisher"
}

variable "additional_labels" {
  type        = map(string)
  description = "Additional labels to apply to all resources. Values must be lowercase. Must not conflict with managed_by, project, environment, or cost_center."
  default     = {}
}