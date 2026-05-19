################################################################################
# PSC consumer-side resources
#
# Cloud SQL provides the service attachment (output:
# psc_service_attachment_link). To reach the instance from a VPC we need:
#   1. A static internal IP in a subnet of the consumer VPC (one per instance)
#   2. A forwarding rule pointing that IP at the service attachment
#   3. A private DNS zone + A record so the instance's dns_name resolves
#      to the internal IP (Cloud SQL connector / drivers expect dns_name)
#
# Defaults wire everything into the "default" VPC + its us-east1 subnet so
# this works in a sandbox project with no other networking. Override via
# variables for production.
################################################################################

data "google_compute_network" "consumer" {
  project = var.project_id
  name    = var.psc_consumer_network
}

data "google_compute_subnetwork" "consumer" {
  project = var.project_id
  region  = var.region
  name    = var.psc_consumer_subnet
}

# ---------- Primary ----------------------------------------------------------

resource "google_compute_address" "psc_primary" {
  project      = var.project_id
  region       = var.region
  name         = "${var.instance_name}-psc-ip"
  subnetwork   = data.google_compute_subnetwork.consumer.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "psc_primary" {
  project               = var.project_id
  region                = var.region
  name                  = "${var.instance_name}-psc-fr"
  network               = data.google_compute_network.consumer.id
  subnetwork            = data.google_compute_subnetwork.consumer.id
  ip_address            = google_compute_address.psc_primary.id
  target                = google_sql_database_instance.primary.psc_service_attachment_link
  load_balancing_scheme = ""
}

# ---------- Replica ----------------------------------------------------------

resource "google_compute_address" "psc_replica" {
  project      = var.project_id
  region       = var.region
  name         = "${var.replica_name}-psc-ip"
  subnetwork   = data.google_compute_subnetwork.consumer.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "psc_replica" {
  project               = var.project_id
  region                = var.region
  name                  = "${var.replica_name}-psc-fr"
  network               = data.google_compute_network.consumer.id
  subnetwork            = data.google_compute_subnetwork.consumer.id
  ip_address            = google_compute_address.psc_replica.id
  target                = google_sql_database_instance.replica.psc_service_attachment_link
  load_balancing_scheme = ""
}

# ---------- Private DNS for *.sql.goog --------------------------------------
#
# Cloud SQL gives each instance a dns_name of the form
#   <uid>.<region>.sql.goog.
# We create one private zone for "sql.goog." visible to the consumer VPC,
# plus an A record per instance pointing at its PSC internal IP.

resource "google_dns_managed_zone" "sql_goog" {
  count       = var.psc_create_dns_zone ? 1 : 0
  project     = var.project_id
  name        = "cloud-sql-psc-sql-goog"
  dns_name    = "sql.goog."
  description = "Private zone for Cloud SQL PSC dns_name resolution"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = data.google_compute_network.consumer.id
    }
  }
}

resource "google_dns_record_set" "psc_primary" {
  count        = var.psc_create_dns_zone ? 1 : 0
  project      = var.project_id
  managed_zone = google_dns_managed_zone.sql_goog[0].name
  name         = google_sql_database_instance.primary.dns_name
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.psc_primary.address]
}

resource "google_dns_record_set" "psc_replica" {
  count        = var.psc_create_dns_zone ? 1 : 0
  project      = var.project_id
  managed_zone = google_dns_managed_zone.sql_goog[0].name
  name         = google_sql_database_instance.replica.dns_name
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.psc_replica.address]
}
