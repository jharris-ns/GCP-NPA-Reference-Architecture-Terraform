# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git

- Commit messages must NOT contain the word "claude" in any form (including in Co-Authored-By lines).

## Common Commands

```bash
# All Terraform commands run from terraform/ directory
cd terraform

# Format, validate, plan
terraform fmt -recursive
terraform validate
terraform plan
terraform apply

# Generate documentation (writes to terraform/README.md)
terraform-docs markdown .

# Pre-commit hooks (must pass before committing)
pre-commit run --all-files
pre-commit run terraform_fmt --all-files    # Run single hook

# Lint
tflint --init
tflint
```

## Architecture

This is a Terraform module that deploys Netskope NPA (Network Private Access) Publishers to AWS with multi-AZ redundancy. It uses **two providers** (AWS + Netskope) that coordinate in sequence:

1. **Netskope provider** creates publisher records and generates registration tokens (`netskope.tf`)
2. **AWS provider** creates infrastructure, launches EC2 instances, and registers publishers via SSM Run Command (`ec2_publisher.tf` + `ssm.tf`)

### Directory Layout

- `terraform/` — All Terraform code (single flat root configuration)
- `docs/` — Project documentation (8 files covering architecture, deployment, operations, troubleshooting)

### Key Cross-File Patterns

**Conditional VPC** (`locals.tf` → all resource files): The module supports creating a new VPC or using an existing one. `locals.tf` resolves `local.vpc_id` and `local.private_subnet_ids` from either created or existing resources, so downstream files never check `var.create_vpc` directly.

**Publisher map** (`locals.tf` → `netskope.tf` → `ec2_publisher.tf`): `local.publishers` generates a name-keyed map from `var.publisher_count`. All publisher resources use `for_each = local.publishers` so state addresses are human-readable (`aws_instance.publisher["my-pub-2"]`) and removing a publisher doesn't cascade.

**AZ distribution**: Publishers spread across AZs via modulo: `subnet_id = local.private_subnet_ids[each.value.index % length(local.private_subnet_ids)]`

**Token flow**: `netskope_npa_publisher_token.this[each.key].token` → `aws_ssm_parameter.publisher_token` (SecureString) → `null_resource.publisher_registration` fetches token locally via AWS CLI → SSM Run Command executes `/home/ubuntu/npa_publisher_wizard -token <TOKEN>` on the instance. User data is minimal (CloudWatch agent only if enabled).

## Terraform Conventions

### File Structure (AWS I&A Standards)

- All Terraform code lives in the `terraform/` directory
- Core files: `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf`
- Optional files: `data.tf`, `locals.tf`, `backend.tf`
- Split service-specific resources into their own files (e.g. `iam.tf`, `vpc.tf`, `ec2.tf`, `security.tf`) when they exceed ~150 lines
- Optional directories: `terraform/templates/` (for templatefile templates)

### Naming

- snake_case for all resource names, variables, and outputs
- Resource meta-names should be contextual and descriptive (e.g. `data "aws_region" "current"`, not `"self"`)

### Variables & Outputs

- All variables must have an explicit `type` and `description`
- Add `validation` blocks to catch user errors early
- Use `default = null` for optional disruptive attributes
- Mark sensitive values with `sensitive = true`

### Resource Patterns

- Prefer `for_each` over `count` for multi-instance resources (prevents cascading state changes)
- Use `count` only for simple on/off toggles (0 or 1)
- Use attachment resources over inline blocks (e.g. `aws_iam_role_policy_attachment` instead of inline `policy`)
- Use `default_tags` on the AWS provider for consistent tagging across all resources

### Code Quality

- Run `terraform fmt -recursive` on all code
- Auto-generate docs with `terraform-docs` (configured in `.terraform-docs.yaml`)
- Security scanning with `checkov` and `gitleaks`
- Lint with `tflint` (configured in `.tflint.hcl`)
- Pre-commit hooks are configured in `.pre-commit-config.yaml` and must pass before committing

## Guardrails

### Never Commit

- `.env` (contains API keys)
- `*.tfvars` (may contain environment-specific config)
- `*.tfstate` / `*.tfstate.backup`
- `.terraform/` directory
- SSH private keys

### Always Before Committing

- Run `pre-commit run --all-files`

## Workflow Awareness

### CI Checks

- **`lint.yml`** — runs `terraform fmt -check`, `terraform validate`, `tflint` on push and PR
- **`security.yml`** — runs `gitleaks` and `checkov` on push, PR, and weekly schedule
- Checks are advisory (not blocking) — will be enforced later

### Branch Protection

- PRs required to merge to `main` (no direct push)
- CI status checks shown on PRs (advisory)
