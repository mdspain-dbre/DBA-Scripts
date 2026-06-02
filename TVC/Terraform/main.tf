# #############################################################################
# FILE:        main.tf
# PURPOSE:     Provisions an AlloyDB cluster in GCP for TVC workloads.
# AUTHOR:      Michael D'Spain (CPIE-DRE)
# PROJECT:     vz-inscape-portfolio-dev
# REGION:      us-east1 — matches source Aurora cluster region (us-east-1)
#
# USAGE:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy
# #############################################################################

terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "alloydb" {
  source = "git::ssh://git@github.com/vizio-terraform-marketplace/gcp-alloydb.git?ref=v1.0.3"

  service     = var.service
  environment = var.environment

  project_id            = var.project_id
  region                = var.region
  cluster_name          = var.cluster_name
  primary_instance_name = var.instance_name
  machine_cpu_count     = var.machine_cpu_count
  support_tier          = var.support_tier

  psc_host_project         = var.psc_host_project
  psc_host_project_network = var.psc_host_project_network

  google_alloydb_module_config = {
    initial_user = {
      user     = var.db_user
      password = var.db_password
    }
  }
}
