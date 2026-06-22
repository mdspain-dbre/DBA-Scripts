module "cloudsql" {
  source = "git::https://github.com/vizio-terraform-marketplace/gcp-cloudsql.git?ref=main"

  service                  = var.service
  sub_service              = var.sub_service
  environment              = var.environment
  project_id               = var.project_id
  region                   = var.region
  instance_name            = var.instance_name
  dbms_engine              = local.dbms_engine
  machine_tier             = "db-f1-micro" # pin to live; do not let the module default change this
  psc_host_project         = var.psc_host_project
  psc_host_project_network = var.psc_host_project_network

  user_labels = local.labels

  google_cloudsql_module_config = {
    root_password = {
      password = var.root_user_password
    }
  }
}
