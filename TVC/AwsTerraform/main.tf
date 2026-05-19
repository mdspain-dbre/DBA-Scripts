################################################################################
# Aurora PostgreSQL cluster: tvc-production
# Account: 788724168120 (Inscape Production US 1)
# Region:  us-east-1
#
# Reflects the live configuration captured via:
#   aws rds describe-db-clusters   --db-cluster-identifier tvc-production
#   aws rds describe-db-instances  --filters Name=db-cluster-id,Values=tvc-production
#
# NOTE: master_password is managed in AWS Secrets Manager via
# manage_master_user_password. Do NOT set master_password directly.
################################################################################

resource "aws_rds_cluster" "tvc_production" {
  cluster_identifier = var.cluster_identifier
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version

  database_name   = var.database_name
  master_username = var.master_username

  # Lets RDS create + rotate the master credential in Secrets Manager.
  # Remove these two lines and add `master_password` if importing the
  # existing password unchanged.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_id

  port = 5432

  db_subnet_group_name            = var.db_subnet_group_name
  vpc_security_group_ids          = var.vpc_security_group_ids
  db_cluster_parameter_group_name = "default.aurora-postgresql12"

  availability_zones = ["us-east-1b", "us-east-1c", "us-east-1d"]

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window

  storage_encrypted = true
  kms_key_id        = var.kms_key_id

  iam_database_authentication_enabled = false
  deletion_protection                 = var.deletion_protection
  copy_tags_to_snapshot               = false
  apply_immediately                   = false
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${var.cluster_identifier}-final"

  tags = merge(var.common_tags, {
    Name = var.cluster_identifier
    name = var.cluster_identifier
  })

  lifecycle {
    ignore_changes = [
      # availability_zones is set at create time; ignore drift.
      availability_zones,
      # Don't fight a manually rotated password if managed externally.
      master_password,
    ]
  }
}

################################################################################
# Cluster instances (writer + reader)
################################################################################

locals {
  cluster_instances = {
    "tvc-production" = {
      availability_zone = "us-east-1b"
    }
    "tvc-production-us-east-1c" = {
      availability_zone = "us-east-1c"
    }
  }
}

resource "aws_rds_cluster_instance" "tvc_production" {
  for_each = local.cluster_instances

  identifier         = each.key
  cluster_identifier = aws_rds_cluster.tvc_production.id

  engine         = aws_rds_cluster.tvc_production.engine
  engine_version = aws_rds_cluster.tvc_production.engine_version

  instance_class       = var.instance_class
  db_subnet_group_name = var.db_subnet_group_name
  availability_zone    = each.value.availability_zone

  db_parameter_group_name = "default.aurora-postgresql12"

  publicly_accessible        = false
  auto_minor_version_upgrade = true
  promotion_tier             = 1
  ca_cert_identifier         = "rds-ca-rsa2048-g1"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_id
  performance_insights_retention_period = 7

  monitoring_interval = 0
  monitoring_role_arn = var.monitoring_role_arn

  tags = merge(var.common_tags, {
    Name                             = each.key
    name                             = each.key
    "OPP-5465_db_cost_resource_name" = each.key
  })
}
