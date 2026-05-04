# =============================================================================
# TERRAFORM CONFIGURATION
# =============================================================================
# This block tells Terraform which providers (plugins) are needed.
# Providers are how Terraform talks to cloud APIs — in this case, Google Cloud.
# "~> 6.0" means any version >= 6.0 and < 7.0 (pessimistic constraint).
# =============================================================================
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"    # Download from HashiCorp's registry
      version = "~> 6.0"              # Pin to major version 6.x
    }
  }
}

# =============================================================================
# GOOGLE CLOUD PROVIDER
# =============================================================================
# Configures how Terraform authenticates and interacts with GCP.
# - project: The GCP project ID where resources will be created.
# - region:  Default region for regional resources (can be overridden per-resource).
# - Authentication uses whatever method is available (gcloud auth application-default
#   login, GOOGLE_CREDENTIALS env var, or service account key file).
# =============================================================================
provider "google" {
  project = "dre-sandbox-471618"
  region  = "us-west1"
}

# =============================================================================
# VARIABLES
# =============================================================================
# Variables let you parameterize the config so values aren't hard-coded.
# Defaults are provided for most variables, but they can be overridden at
# runtime via:
#   - CLI flags:        terraform plan -var="sql_instance_name=my-sql"
#   - .tfvars file:     terraform plan -var-file="prod.tfvars"
#   - Environment vars: TF_VAR_sql_instance_name="my-sql"
# =============================================================================

# The name for the Cloud SQL instance. Must be unique within the project.
# Cloud SQL instance names cannot be reused for up to 7 days after deletion.
variable "sql_instance_name" {
  description = "Name for the Cloud SQL for SQL Server instance."
  default     = "cs-sql-01"
}

# The root password for the SQL Server instance. Marked "sensitive" so
# Terraform won't display it in plan output or logs. Since there's no default,
# you MUST supply it at runtime (e.g., -var="sql_root_password=YourP@ssw0rd!").
variable "sql_root_password" {
  description = "Root password for the SQL Server instance."
  sensitive   = true
}

# =============================================================================
# LOCAL VALUES (Computed/Reusable Values)
# =============================================================================
# Locals let you define values once and reuse them across multiple resources.
# GCP uses "labels" instead of Azure "tags" — same concept, different name.
# Label keys/values must be lowercase, max 63 chars, letters/numbers/hyphens only.
# =============================================================================
locals {
  labels = {
    application = "content-services"
    cost-center = "2650"
    created-by  = "michael-dspain"
    environment = "dev"
    owner       = "cpie-dre"
    service     = "content-services"
  }
}

# =============================================================================
# CLOUD SQL FOR SQL SERVER — ENTERPRISE PLUS (MEMORY-OPTIMIZED)
# =============================================================================
# Creates a Cloud SQL instance running SQL Server 2022 Enterprise.
#
# Edition: ENTERPRISE_PLUS
#   Enterprise Plus unlocks higher memory-per-vCPU limits (up to 32 GB/vCPU)
#   compared to standard Enterprise (6.5 GB/vCPU). This is required for
#   memory-heavy configurations like 24 vCPUs + 500 GB RAM (~20.8 GB/vCPU).
#   Enterprise Plus also provides:
#     - Data cache (local SSD for hot data)
#     - Advanced HA with near-zero downtime maintenance
#     - 99.99% SLA (regional)
#
# Machine tier: db-perf-optimized-N-24
#   - 24 vCPUs
#   - 500 GB RAM (512,000 MB)
#   Enterprise Plus uses "db-perf-optimized-N-<cpu>" tiers for
#   performance/memory-optimized configurations.
#
# Storage:
#   - 1 TB (1,000 GB) SSD persistent disk
#   - Auto-resize enabled (grows automatically if you approach the limit)
#   - Auto-resize limit set to 2 TB to prevent runaway growth
#
# Availability:
#   - ZONAL (single zone) — no automatic failover
#   - Change to REGIONAL for HA with automatic failover to a standby
#
# Backups:
#   - Automated daily backups enabled
#   - Point-in-time recovery (PITR) enabled via transaction log backups
#   - Retained for 7 days
#   - Backup window: 04:00-08:00 UTC (off-peak)
#
# Maintenance:
#   - Sunday, 05:00-06:00 UTC (off-peak window)
#
# Networking:
#   - Public IP enabled by default (restrict with authorized_networks)
#   - For private-only access, enable private_network and disable public IP
#
# Deletion protection is enabled to prevent accidental destruction.
# Set to false when you intentionally want to tear down the instance.
# =============================================================================
resource "google_sql_database_instance" "sql_server" {
  name                = var.sql_instance_name
  database_version    = "SQLSERVER_2022_ENTERPRISE"
  region              = "us-west1"
  root_password       = var.sql_root_password
  deletion_protection = true

  settings {
    tier              = "db-custom-24-159744"   # 24 vCPUs, 156 GB RAM (max at 6.5 GB/vCPU)
    edition           = "ENTERPRISE"             # Enterprise Plus is not available for SQL Server
    availability_type = "ZONAL"                  
    disk_type         = "PD_SSD"                 # PD_SSD is the correct disk for this tier
    disk_size         = 1000                     
    disk_autoresize   = true                     
    disk_autoresize_limit = 2000             # Auto-grow when space is low
  
    user_labels = local.labels

    # Automated backup configuration
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true       # PITR via transaction logs
      start_time                     = "04:00"    # Daily backup window (UTC)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7                      # Keep 7 daily backups
      }
    }

    # Maintenance window — Sunday 5 AM UTC
    maintenance_window {
      day          = 7    # Sunday (1=Mon, 7=Sun)
      hour         = 5    # 5 AM UTC
      update_track = "stable"
    }

    # IP configuration — public IP with no authorized networks by default.
    # Add authorized_networks blocks to restrict access by IP/CIDR,
    # or switch to private IP via private_network.
    ip_configuration {
      ipv4_enabled = true
    }

    # SQL Server-specific flags
    database_flags {
      name  = "remote access"
      value = "on"
    }
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================
# Outputs are printed after "terraform apply" completes and can be queried
# later with "terraform output". They're useful for:
#   - Displaying important info (IPs, connection strings) after deployment.
#   - Passing values to other Terraform modules or scripts.
# =============================================================================
output "sql_server_public_ip" {
  description = "Public IP address of the Cloud SQL instance"
  value       = google_sql_database_instance.sql_server.public_ip_address
}

output "sql_server_connection_name" {
  description = "Connection name for Cloud SQL Proxy (project:region:instance)"
  value       = google_sql_database_instance.sql_server.connection_name
}