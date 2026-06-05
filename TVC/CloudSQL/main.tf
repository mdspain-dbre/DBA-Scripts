module "cloudsql" {
  source = "git::https://github.com/vizio-terraform-marketplace/gcp-cloudsql.git?ref=main"

  service                  = var.service
  sub_service              = var.sub_service
  environment              = var.environment
  project_id               = var.project_id
  region                   = var.region
  instance_name            = var.instance_name
  dbms_engine              = local.dbms_engine
  psc_host_project         = var.psc_host_project
  psc_host_project_network = var.psc_host_project_network

  # pgAudit cannot be installed via google_sql_provision_script because the ADC
  # caller identity is not cloudsqlsuperuser. Install it manually via gcloud sql
  # import sql (Admin API) after first apply, then this suppresses the re-run.
  pg_extensions = []

  google_cloudsql_module_config = {
    root_password = {
      password = var.root_user_password
    }
  }
}
