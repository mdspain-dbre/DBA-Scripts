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
#   - Uses the Vizio Terraform marketplace gcp-cloudsql module wrapping the
#     terraform-google-modules/sql-db/google//modules/mysql module.
#   - Deletion protection is ON by default. Set deletion_protection = false
#     in variables (or override at apply) before running terraform destroy.
#   - Networking: Private Service Connect (PSC) is ENABLED, public IP is OFF.
#     A PSC endpoint (internal forwarding rule) is created in the consumer
#     VPC/subnet specified by var.consumer_vpc_self_link /
#     var.consumer_subnet_self_link. Connect via the Cloud SQL Auth Proxy
#     (`cloud-sql-proxy --psc <conn-name>`) or directly to the endpoint IP
#     / DNS name from inside the consumer VPC.
# #############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.29"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.29"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Standard labels applied to every resource for cost reporting / inventory.
# Per-instance `environment` is merged in below via each.value.environment.
# -----------------------------------------------------------------------------
locals {
  base_labels = {
    application = "auxdb"
    cost-center = "2650"
    created-by  = "michael-dspain"
    owner       = "cpie-dre"
    service     = "auxdb"
  }
}

# =============================================================================
# CLOUD SQL FOR MYSQL — one instance per entry in var.instances
# =============================================================================
# Wrapped by the Vizio gcp-cloudsql module (opinionated wrapper around
# GoogleCloudPlatform/cloud-foundation-fabric//modules/cloudsql-instance).
# Variable names below match the Vizio module's interface, NOT the upstream
# terraform-google-modules/sql-db module.
# =============================================================================
module "auxdb" {
  for_each = var.instances
  source   = "git::https://github.com/vizio-terraform-marketplace/gcp-cloudsql.git?ref=main"

  # ---- Vizio metadata (required) -------------------------------------------
  service     = "auxdb"
  sub_service = each.value.sub_service
  environment = each.value.environment
  user_labels = merge(local.base_labels, { environment = each.value.environment })

  # ---- GCP placement -------------------------------------------------------
  project_id = var.project_id
  region     = var.region

  # ---- Instance identity / engine ------------------------------------------
  instance_name             = each.value.instance_name
  cloudsql_database_version = each.value.database_version
  dbms_engine               = "mysql"

  # ---- Sizing / edition ----------------------------------------------------
  machine_tier     = each.value.tier
  cloudsql_edition = "ENTERPRISE"

  # ---- HA / DR -------------------------------------------------------------
  support_tier                   = "V2"
  enable_ha                      = each.value.availability_type == "REGIONAL"
  point_in_time_recovery_enabled = true

  # ---- Safety --------------------------------------------------------------
  gcp_deletion_protection_enabled       = each.value.deletion_protection
  terraform_deletion_protection_enabled = each.value.deletion_protection

  # ---- Maintenance ---------------------------------------------------------
  maintenance_update_track = "stable"

  # ---- MySQL flags (sp_configure equivalent) -------------------------------
  flags = {
    character_set_server = "utf8mb4"
    default_time_zone    = "+00:00"
  }

  # ---- Networking — Private Service Connect (PSC) only ---------------------
  # Setting psc_allowed_consumer_projects enables PSC on the producer side.
  # Public IP is forced off via google_cloudsql_module_config below.
  psc_allowed_consumer_projects = [var.project_id]

  google_cloudsql_module_config = {
    network_config = {
      connectivity = {
        public_ipv4                   = false
        psc_allowed_consumer_projects = [var.project_id]
      }
    }
  }
}

# =============================================================================
# PRIVATE SERVICE CONNECT (PSC) — CONSUMER ENDPOINTS (one per instance)
# =============================================================================
# These resources live in the *consumer* VPC and present each Cloud SQL
# instance as a single internal IP. The producer side (the service
# attachment) is auto-created by Cloud SQL when psc_enabled = true above.
# =============================================================================

# Look up each instance after the module creates it so we can grab the
# psc_service_attachment_link without depending on a specific module output
# name (which can vary between module versions / forks).
data "google_sql_database_instance" "auxdb" {
  for_each   = var.instances
  project    = var.project_id
  name       = each.value.instance_name
  depends_on = [module.auxdb]
}

# Static internal IP in the consumer subnet — this is the address apps
# connect to.
resource "google_compute_address" "psc_ip" {
  for_each     = var.instances
  name         = "${each.value.instance_name}-psc-ip"
  project      = var.project_id
  region       = var.region
  subnetwork   = var.consumer_subnet_self_link
  address_type = "INTERNAL"
  labels       = merge(local.base_labels, { environment = each.value.environment })
}

# Forwarding rule = the PSC endpoint. `target` points at the service
# attachment Cloud SQL exposes on the producer side.
resource "google_compute_forwarding_rule" "psc" {
  for_each              = var.instances
  name                  = "${each.value.instance_name}-psc-fr"
  project               = var.project_id
  region                = var.region
  network               = var.consumer_vpc_self_link
  ip_address            = google_compute_address.psc_ip[each.key].id
  load_balancing_scheme = "" # MUST be empty string for PSC consumer endpoints
  target                = data.google_sql_database_instance.auxdb[each.key].psc_service_attachment_link
  labels                = merge(local.base_labels, { environment = each.value.environment })
}

# Optional: private DNS so apps can connect by the Cloud SQL-provided
# *.sql.goog name instead of a hardcoded IP. Toggle with var.create_psc_dns.
# Only one sql.goog. zone may exist per VPC — keep this as a single resource.
resource "google_dns_managed_zone" "sql_goog" {
  count       = var.create_psc_dns ? 1 : 0
  name        = "sql-goog-private"
  project     = var.project_id
  dns_name    = "sql.goog."
  description = "Private zone resolving Cloud SQL PSC DNS names to consumer endpoints"
  visibility  = "private"
  labels      = local.base_labels

  private_visibility_config {
    networks {
      network_url = var.consumer_vpc_self_link
    }
  }
}

resource "google_dns_record_set" "psc" {
  for_each     = var.create_psc_dns ? var.instances : {}
  project      = var.project_id
  managed_zone = google_dns_managed_zone.sql_goog[0].name
  name         = "${data.google_sql_database_instance.auxdb[each.key].dns_name}."
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.psc_ip[each.key].address]
}

# =============================================================================
# OUTPUTS — keyed by instance key (e.g. "qa", "dre_test3")
# =============================================================================
# NOTE: We read most attributes from the data lookup rather than module
# outputs because the Vizio module's output names differ from the upstream
# terraform-google-modules/sql-db conventions.
# =============================================================================
output "instance_names" {
  description = "Map of instance key => Cloud SQL instance name."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.name }
}

output "connection_names" {
  description = "Map of instance key => connection name used by the Cloud SQL Auth Proxy (project:region:instance)."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.connection_name }
}

output "self_links" {
  description = "Map of instance key => self link of the Cloud SQL instance."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.self_link }
}

output "psc_endpoint_ips" {
  description = "Map of instance key => internal IP of the PSC endpoint in the consumer VPC."
  value       = { for k, v in google_compute_address.psc_ip : k => v.address }
}

output "psc_dns_names" {
  description = "Map of instance key => Cloud SQL-provided *.sql.goog DNS name that resolves to the PSC endpoint."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.dns_name }
}

output "psc_service_attachment_links" {
  description = "Map of instance key => service attachment URI on the producer side (informational)."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.psc_service_attachment_link }
}
