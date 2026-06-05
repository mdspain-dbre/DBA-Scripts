# Cloud SQL for MySQL: one instance per entry in var.instances.
# Uses the Vizio gcp-cloudsql wrapper module.
module "auxdb" {
  for_each = var.instances
  source   = "git::https://github.com/vizio-terraform-marketplace/gcp-cloudsql.git?ref=main"

  # Vizio metadata (required)
  service     = "auxdb"
  sub_service = each.value.sub_service
  environment = each.value.environment
  user_labels = merge(local.base_labels, { environment = each.value.environment })

  # GCP placement
  project_id = var.project_id
  region     = var.region

  # Instance identity and engine
  instance_name             = each.value.instance_name
  cloudsql_database_version = each.value.database_version
  dbms_engine               = "mysql"

  # Sizing and edition
  machine_tier     = each.value.tier
  cloudsql_edition = "ENTERPRISE"

  # HA and DR
  support_tier                   = "V2"
  enable_ha                      = each.value.availability_type == "REGIONAL"
  point_in_time_recovery_enabled = true

  # Safety
  gcp_deletion_protection_enabled       = each.value.deletion_protection
  terraform_deletion_protection_enabled = each.value.deletion_protection

  # Maintenance
  maintenance_update_track = "stable"

  # MySQL flags
  flags = {
    character_set_server = "utf8mb4"
    default_time_zone    = "+00:00"
  }

  # Networking: Private Service Connect (PSC) only.
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

# PSC consumer endpoints: one per instance.
# These resources live in the consumer VPC and expose each Cloud SQL
# instance as a single internal IP.

# Look up instance details after module creation to read
# psc_service_attachment_link reliably.
data "google_sql_database_instance" "auxdb" {
  for_each   = var.instances
  project    = var.project_id
  name       = each.value.instance_name
  depends_on = [module.auxdb]
}

# Static internal IP in the consumer subnet used by clients.
resource "google_compute_address" "psc_ip" {
  for_each     = var.instances
  name         = "${each.value.instance_name}-psc-ip"
  project      = var.project_id
  region       = var.region
  subnetwork   = var.consumer_subnet_self_link
  address_type = "INTERNAL"
  labels       = merge(local.base_labels, { environment = each.value.environment })
}

# Forwarding rule for PSC endpoint; target is the producer service attachment.
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

# Optional private DNS for *.sql.goog. names.
# Toggle with var.create_psc_dns.
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
