locals {
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
  sub_service = "prod-gcp-auxdb-qa-84-20260226"
  environment = "dev"
  user_labels = local.labels

  project_id = "vz-inscape-portfolio-dev"
  region     = "us-west1"

  instance_name             = "prod-gcp-auxdb-qa-84-20260226"
  cloudsql_database_version = "MYSQL_8_4"
  dbms_engine               = "mysql"

  machine_tier     = "db-custom-4-26624"
  cloudsql_edition = "ENTERPRISE"

  enable_ha                      = false
  point_in_time_recovery_enabled = true

  gcp_deletion_protection_enabled       = true
  terraform_deletion_protection_enabled = true

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
}
 