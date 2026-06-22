# Add a public DNS A record for the CloudSQL PSC endpoint without using the
# wrapper module's `dns_a_records` feature. Going through the module would
# force a re-plan of the underlying google_sql_database_instance, which
# currently fails (PSC config drift). Reading the live instance via a data
# source lets us publish DNS while leaving the instance untouched.

data "google_sql_database_instance" "this" {
  project = var.project_id
  name    = var.instance_name
}

locals {
  # The active PSC consumer IP for the instance (e.g. 10.234.255.246).
  cloudsql_psc_ip = one([
    for ip in flatten([
      for s in data.google_sql_database_instance.this.settings : [
        for ipc in s.ip_configuration : [
          for psc in ipc.psc_config : [
            for ac in psc.psc_auto_connections : ac.ip_address
          ]
        ]
      ]
    ]) : ip if ip != null && ip != "NONE"
  ])
}

resource "google_dns_record_set" "tvcdb_development" {
  project      = var.project_id
  managed_zone = "public-zone-dev-gcp-cognet"
  name         = "tvcdb-development.dev.gcp.cognet.tv."
  type         = "A"
  ttl          = 300
  rrdatas      = [local.cloudsql_psc_ip]
}
