# GCP NPA Publisher — example variable values.
# Copy to terraform.tfvars and edit before running terraform apply.
# terraform.tfvars is excluded from git (.gitignore).

# ─── Required ─────────────────────────────────────────────────────────────────

gcp_project_id = "my-gcp-project-id"
gcp_region     = "us-central1"

# Netskope credentials — set via environment variables instead of this file:
#   export TF_VAR_netskope_server_url="https://mytenant.goskope.com/api/v2"
#   export TF_VAR_netskope_api_key="your-api-key"

# ─── Publisher ────────────────────────────────────────────────────────────────

publisher_name         = "my-npa-publisher"
publisher_machine_type = "n2-standard-2"

# HA requires a minimum of 2 publishers in separate zones.
# A single publisher is a single point of failure — 2 is the recommended minimum.
# Terraform auto-distributes across N distinct zones (one per publisher).
publisher_count = 2

# Leave empty (default) to use Ubuntu 22.04 LTS. Publisher software is installed
# at first boot via the Netskope bootstrap script. Override only if you have a
# pre-baked custom image.
# publisher_image_self_link = ""

# ─── VPC ──────────────────────────────────────────────────────────────────────

# New VPC (default)
create_vpc  = true
subnet_cidr = "10.0.0.0/24"

# Specific zones (default: first two available zones in gcp_region)
# zones = ["us-central1-a", "us-central1-b"]

# Existing VPC (set create_vpc = false to use these)
# create_vpc                 = false
# existing_network_self_link = "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/global/networks/my-vpc"
# existing_subnet_self_links = [
#   "https://www.googleapis.com/compute/v1/projects/MY_PROJECT/regions/us-central1/subnetworks/my-subnet",
# ]

# ─── Monitoring ───────────────────────────────────────────────────────────────

enable_monitoring = false

# ─── Labels ───────────────────────────────────────────────────────────────────

environment   = "Production"
cost_center   = "IT-Operations"
project_label = "NPA-Publisher"

# additional_labels = {
#   team  = "platform"
#   owner = "alice"
# }