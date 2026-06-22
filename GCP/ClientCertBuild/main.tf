locals {
  instance_name = "client-cert-auxdb"

  client_cert_roles = ["core-services"]

  client_certificates = [
    for role in local.client_cert_roles : "${local.instance_name}-${role}-cert"
  ]

  labels = {
    application = "auxdb"
    cost-center = "2650"
    created-by  = "michael-dspain"
    environment = "dev"
    owner       = "cpie-dre"
    service     = "auxdb"
  }
}

module "auxdb" {
  source = "git::https://github.com/vizio-terraform-marketplace/gcp-cloudsql.git?ref=main"

  service     = "auxdb"
  sub_service = "client-cert-auxdb"
  environment = "dev"
  user_labels = local.labels

  project_id = "vz-inscape-portfolio-dev"
  region     = "us-west1"

  instance_name             = local.instance_name
  cloudsql_database_version = "MYSQL_8_4"
  dbms_engine               = "mysql"

  machine_tier     = "db-custom-4-26624"
  cloudsql_edition = "ENTERPRISE"

  enable_ha                      = false
  point_in_time_recovery_enabled = false

  gcp_deletion_protection_enabled       = false
  terraform_deletion_protection_enabled = false

  maintenance_update_track = "stable"

  flags = {
    character_set_server = "utf8mb4"
    default_time_zone    = "+00:00"
    slow_query_log       = "on"
    long_query_time      = "4"
  }

  psc_allowed_consumer_projects = ["vz-inscape-portfolio-dev"]
  psc_host_project              = "vz-inscape-dev"
  psc_host_project_network      = "vz-inscape-dev-vpc-01"

  google_cloudsql_module_config = {
    # Match source instance security posture: client cert required, no public IP, PSC only.
    ssl = {
      mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
      client_certificates = local.client_certificates
    }

    backup_configuration = {
      enabled                        = false
      point_in_time_recovery_enabled = false
      location                       = "us-west1"
      start_time                     = "02:00"
    }
  }
}
