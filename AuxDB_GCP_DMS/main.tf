# #############################################################################
# FILE:        main.tf
# PURPOSE:     Provisions a Cloud SQL for MySQL instance (auxdb-qa) in the
#              Inscape-Dev GCP project using the official Google Cloud SQL
#              Terraform module (terraform-google-modules/sql-db/google).
# AUTHOR:      Michael D'Spain (CPIE-DRE)
# PROJECT:     inscape-dev
# REGION:      us-west1 (Oregon)
#
# USAGE:
#   terraform init
#   terraform plan  -var="mysql_root_password=<strongpw>"
#   terraform apply -var="mysql_root_password=<strongpw>"
#
#   # Or place the password in secrets.auto.tfvars (gitignored) so you do not
#   # have to pass it on the CLI every run.
#
# NOTES:
#   - Uses the public terraform-google-modules/sql-db/google//modules/mysql
#     module instead of hand-rolled google_sql_database_instance resources.
#   - Deletion protection is ON by default. Set deletion_protection = false
#     in variables (or override at apply) before running terraform destroy.
#   - Public IP is enabled with NO authorized networks — connect via the
#     Cloud SQL Auth Proxy or add CIDR ranges in `authorized_networks`.
# #############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Standard labels applied to every resource for cost reporting / inventory.
# -----------------------------------------------------------------------------
locals {
  labels = {
    application = "auxdb"
    cost-center = "2650"
    created-by  = "michael-dspain"
    environment = "qa"
    owner       = "cpie-dre"
    service     = "auxdb"
  }
}

# =============================================================================
# CLOUD SQL FOR MYSQL — auxdb-qa
# =============================================================================
# Module docs:
#   https://registry.terraform.io/modules/terraform-google-modules/sql-db/google/latest/submodules/mysql
# =============================================================================
module "auxdb_qa" {
  source  = "terraform-google-modules/sql-db/google//modules/mysql"
  version = "~> 25.0"

  # ---- Instance identity ----------------------------------------------------
  project_id       = var.project_id
  name             = var.instance_name
  database_version = var.database_version
  region           = var.region
  zone             = var.zone

  # ---- Machine sizing / storage --------------------------------------------
  tier                = var.tier
  edition             = "ENTERPRISE"
  availability_type   = var.availability_type
  disk_type           = "PD_SSD"
  disk_size           = var.disk_size_gb
  disk_autoresize     = true
  disk_autoresize_limit = var.disk_autoresize_limit_gb

  # ---- Credentials ----------------------------------------------------------
  root_password = var.mysql_root_password

  # ---- Safety ---------------------------------------------------------------
  deletion_protection             = var.deletion_protection
  deletion_protection_enabled     = var.deletion_protection

  # ---- Labels ---------------------------------------------------------------
  user_labels = local.labels

  # ---- Maintenance window (Sunday 05:00 UTC) -------------------------------
  maintenance_window_day          = 7
  maintenance_window_hour         = 5
  maintenance_window_update_track = "stable"

  # ---- Backups + PITR -------------------------------------------------------
  backup_configuration = {
    enabled                        = true
    binary_log_enabled             = true
    start_time                     = "04:00"
    location                       = null
    transaction_log_retention_days = 7
    retained_backups               = 7
    retention_unit                 = "COUNT"
  }

  # ---- Networking -----------------------------------------------------------
  # Public IP enabled but no authorized networks — connect via Cloud SQL Auth
  # Proxy, or add CIDRs to `authorized_networks` below.
  ip_configuration = {
    ipv4_enabled                                  = true
    ssl_mode                                      = "ENCRYPTED_ONLY"
    require_ssl                                   = null
    private_network                               = null
    allocated_ip_range                            = null
    enable_private_path_for_google_cloud_services = false
    authorized_networks                           = []
    psc_enabled                                   = false
    psc_allowed_consumer_projects                 = []
  }

  # ---- MySQL flags (sp_configure equivalent) -------------------------------
  database_flags = [
    {
      name  = "character_set_server"
      value = "utf8mb4"
    },
    {
      name  = "default_time_zone"
      value = "+00:00"
    },
  ]
}

# =============================================================================
# OUTPUTS
# =============================================================================
output "instance_name" {
  description = "Cloud SQL instance name."
  value       = module.auxdb_qa.instance_name
}

output "connection_name" {
  description = "Connection name used by the Cloud SQL Auth Proxy (project:region:instance)."
  value       = module.auxdb_qa.instance_connection_name
}

output "public_ip_address" {
  description = "Public IPv4 address of the instance (null if disabled)."
  value       = module.auxdb_qa.instance_first_ip_address
}

output "self_link" {
  description = "Self link of the Cloud SQL instance."
  value       = module.auxdb_qa.instance_self_link
}
