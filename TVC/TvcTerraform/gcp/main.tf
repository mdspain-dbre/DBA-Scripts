################################################################################
# Cloud SQL for PostgreSQL — port of AWS Aurora cluster `tvc-production`
# Project: dre-sandbox-471618
#
# Topology mapping:
#   AWS Aurora writer + reader (2 nodes)  -->  Cloud SQL HA primary (REGIONAL,
#   active + standby across zones) plus 1 cross-zone read replica.
#
# Notes:
# - Cloud SQL HA gives automatic failover; the standby is NOT readable.
# - The read replica provides the equivalent of an Aurora reader endpoint.
# - Storage is always encrypted; provide var.kms_key_name to use CMEK instead
#   of Google-managed keys.
################################################################################

# Random password for the master user. Cloud SQL has no built-in
# Secrets-Manager-managed-credential equivalent, so we generate one and
# expose it via output (mark output sensitive). For production, store this
# in Secret Manager separately.
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_database_instance" "primary" {
  name                = var.instance_name
  project             = var.project_id
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  encryption_key_name = var.kms_key_name != "" ? var.kms_key_name : null

  settings {
    tier                  = var.tier
    availability_type     = "REGIONAL" # active/standby HA across zones in the region
    edition               = "ENTERPRISE_PLUS"
    disk_type             = var.disk_type
    disk_size             = var.disk_size_gb
    disk_autoresize       = var.disk_autoresize
    disk_autoresize_limit = var.disk_autoresize_limit

    user_labels = merge(var.common_labels, {
      name = var.instance_name
    })

    location_preference {
      zone = var.primary_zone
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = var.backup_start_time
      location                       = var.region
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = var.backup_retention_count
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = var.maintenance_day
      hour         = var.maintenance_hour
      update_track = "stable"
    }

    ip_configuration {
      ipv4_enabled    = var.ipv4_enabled
      private_network = var.private_network != "" ? var.private_network : null
      ssl_mode        = "ENCRYPTED_ONLY"

      dynamic "psc_config" {
        for_each = var.psc_enabled ? [1] : []
        content {
          psc_enabled               = true
          allowed_consumer_projects = var.psc_allowed_consumer_projects
        }
      }

      dynamic "authorized_networks" {
        for_each = var.authorized_networks
        content {
          name  = authorized_networks.value.name
          value = authorized_networks.value.value
        }
      }
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }
  }

  lifecycle {
    ignore_changes = [
      # Disk grows automatically; don't fight it.
      settings[0].disk_size,
    ]
  }
}

################################################################################
# Initial database + master user
################################################################################

resource "google_sql_database" "tvlocation" {
  name     = var.database_name
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
}

resource "google_sql_user" "master" {
  name     = var.master_username
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
  password = random_password.master.result
}

################################################################################
# Read replica (mirrors the Aurora reader instance)
################################################################################

resource "google_sql_database_instance" "replica" {
  name                 = var.replica_name
  project              = var.project_id
  region               = var.region
  database_version     = var.database_version
  master_instance_name = google_sql_database_instance.primary.name
  deletion_protection  = var.deletion_protection

  encryption_key_name = var.kms_key_name != "" ? var.kms_key_name : null

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = var.tier
    availability_type = "ZONAL" # replicas are always zonal
    edition           = "ENTERPRISE_PLUS"
    disk_type         = var.disk_type
    disk_autoresize   = var.disk_autoresize

    user_labels = merge(var.common_labels, {
      name = var.replica_name
      role = "replica"
    })

    location_preference {
      zone = var.replica_zone
    }

    ip_configuration {
      ipv4_enabled    = var.ipv4_enabled
      private_network = var.private_network != "" ? var.private_network : null
      ssl_mode        = "ENCRYPTED_ONLY"

      dynamic "psc_config" {
        for_each = var.psc_enabled ? [1] : []
        content {
          psc_enabled               = true
          allowed_consumer_projects = var.psc_allowed_consumer_projects
        }
      }
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size,
    ]
  }
}
