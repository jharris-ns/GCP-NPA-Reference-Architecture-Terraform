# GCP NPA Publisher Reference Architecture
#
# Deploys Netskope Private Access (NPA) Publishers on GCP Compute Engine with
# multi-zone redundancy. Uses two Terraform providers that coordinate in sequence:
#
#   1. Netskope provider  — creates publisher records and generates registration tokens
#   2. Google provider    — creates VPC, IAM, Secret Manager, and Compute Engine resources
#
# Registration flow (no SSM required):
#   Netskope token → Secret Manager → VM startup script (via metadata server identity)
#   → npa_publisher_wizard → Netskope NewEdge
#
# File layout:
#   vpc.tf              — VPC, subnet, Cloud Router, Cloud NAT, firewall rules
#   iam.tf              — Service accounts, IAM bindings
#   secrets.tf          — Secret Manager secrets (registration tokens)
#   netskope.tf         — Netskope publisher records and tokens
#   compute_publisher.tf — Compute Engine VM instances
#   monitoring.tf       — Cloud Monitoring / Ops Agent (placeholder)
#
# See docs/GCP_MIGRATION_PLAN.md and docs/ARCHITECTURE.md for design rationale.