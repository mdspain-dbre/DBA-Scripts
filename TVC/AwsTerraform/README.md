# tvc-production Aurora PostgreSQL — Terraform

Mirrors the live Aurora cluster `tvc-production` in AWS account
`788724168120` (Inscape Production US 1), region `us-east-1`.

## Files
- `versions.tf` — Terraform & provider version pins
- `providers.tf` — AWS provider with profile + default tags
- `variables.tf` — All inputs (defaults match production)
- `main.tf` — `aws_rds_cluster` + two `aws_rds_cluster_instance` (writer + reader)
- `outputs.tf` — endpoints, ARN, resource ID, secret ARN

## Usage

```bash
aws sso login --profile inscape-production-us-1-inscape-aws-ops
terraform init
terraform plan
```

## Importing the existing cluster (recommended before `apply`)

```bash
terraform import aws_rds_cluster.tvc_production tvc-production
terraform import 'aws_rds_cluster_instance.tvc_production["tvc-production"]' tvc-production
terraform import 'aws_rds_cluster_instance.tvc_production["tvc-production-us-east-1c"]' tvc-production-us-east-1c
```

Then run `terraform plan` and reconcile any drift before `apply`.

## Notes
- **Master password**: `manage_master_user_password = true` lets RDS store
  & rotate the credential in Secrets Manager. If the existing cluster uses
  a manually-set password, remove that block, add `master_password = ...`
  (via a `*.tfvars` file kept out of git), and re-import.
- **Parameter groups**: cluster and instances use the AWS-managed
  `default.aurora-postgresql12` group. Switch to a custom group if you
  need parameter overrides.
- **Subnet group / security groups / KMS key / monitoring role**: assumed
  to already exist (referenced by ID/ARN, not managed here).
- **Engine 12.22**: Aurora PostgreSQL 12 reaches end of standard support
  Feb 2026. Plan an upgrade path.
