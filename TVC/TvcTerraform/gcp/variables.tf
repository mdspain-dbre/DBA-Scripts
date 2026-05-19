variable "project_id" {
  description = "GCP project ID where Cloud SQL will be created."
  type        = string
  default     = "dre-sandbox-471618"
}

variable "region" {
  description = "GCP region for the Cloud SQL primary instance."
  type        = string
  default     = "us-east1"
}

variable "primary_zone" {
  description = "Preferred zone for the primary (HA standby auto-placed in another zone in the region)."
  type        = string
  default     = "us-east1-b"
}

variable "replica_zone" {
  description = "Zone for the read replica."
  type        = string
  default     = "us-east1-c"
}

variable "instance_name" {
  description = "Cloud SQL primary instance name (mirrors AWS cluster identifier)."
  type        = string
  default     = "tvc-dre-test"
}

variable "replica_name" {
  description = "Cloud SQL read replica instance name."
  type        = string
  default     = "tvc-dre-test-replica-1"
}

variable "database_name" {
  description = "Initial database to create."
  type        = string
  default     = "tvlocation_dretest"
}

variable "master_username" {
  description = "Master DB user name (matches AWS source: 'root'). Note: Cloud SQL also creates a built-in 'postgres' superuser."
  type        = string
  default     = "root"
}

variable "database_version" {
  description = "Cloud SQL Postgres engine version. POSTGRES_12 mirrors source (Aurora PG 12.22). Plan to upgrade — PG12 is end-of-life."
  type        = string
  default     = "POSTGRES_12"
}

variable "tier" {
  description = "Machine tier. db-perf-optimized-N-8 = 8 vCPU / 64 GB RAM (Enterprise Plus), matching db.r6i.2xlarge."
  type        = string
  default     = "db-perf-optimized-N-8"
}

variable "disk_size_gb" {
  description = "Initial disk size in GB. Aurora is storage-elastic; pick a reasonable starting point."
  type        = number
  default     = 100
}

variable "disk_type" {
  description = "PD_SSD or PD_HDD."
  type        = string
  default     = "PD_SSD"
}

variable "disk_autoresize" {
  description = "Allow Cloud SQL to grow the disk automatically."
  type        = bool
  default     = true
}

variable "disk_autoresize_limit" {
  description = "Upper bound for disk autoresize in GB (0 = unlimited)."
  type        = number
  default     = 0
}

variable "private_network" {
  description = "Self-link of the VPC network used for private IP (requires Private Services Access already configured)."
  type        = string
  default     = ""
}

variable "authorized_networks" {
  description = "Optional public CIDR allowlist (only used if a public IP is enabled)."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "ipv4_enabled" {
  description = "Enable a public IPv4 address. Set false if using only private IP or PSC."
  type        = bool
  default     = false
}

variable "psc_enabled" {
  description = "Enable Private Service Connect for the Cloud SQL instance(s)."
  type        = bool
  default     = true
}

variable "psc_allowed_consumer_projects" {
  description = "Consumer projects (project IDs or numbers) allowed to create PSC endpoints to the instance."
  type        = list(string)
  default     = ["dre-sandbox-471618"]
}

variable "psc_consumer_network" {
  description = "Name of the VPC in the consumer project that hosts the PSC endpoints (forwarding rules)."
  type        = string
  default     = "default"
}

variable "psc_consumer_subnet" {
  description = "Name of the subnet (in var.region) that holds the PSC endpoint internal IPs."
  type        = string
  default     = "default"
}

variable "psc_create_dns_zone" {
  description = "Create a private Cloud DNS zone for sql.goog so the instance dns_name resolves to the PSC endpoint IP."
  type        = bool
  default     = true
}

variable "backup_retention_count" {
  description = "Number of automated backups to retain (Cloud SQL counts backups, not days)."
  type        = number
  default     = 7
}

variable "backup_start_time" {
  description = "HH:MM (UTC) when the daily backup window begins. AWS source: 08:33-09:03."
  type        = string
  default     = "08:33"
}

variable "maintenance_day" {
  description = "Day of week for maintenance (1=Mon ... 7=Sun). AWS source: Fri = 5."
  type        = number
  default     = 5
}

variable "maintenance_hour" {
  description = "Hour of day (0-23, UTC) for maintenance. AWS source: 07:12."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block accidental deletion of the Cloud SQL instance."
  type        = bool
  default     = true
}

variable "kms_key_name" {
  description = "Optional CMEK key (projects/.../locations/.../keyRings/.../cryptoKeys/...). Empty = Google-managed."
  type        = string
  default     = ""
}

variable "common_labels" {
  description = "Labels applied to Cloud SQL resources (label keys/values must be lowercase, hyphens/underscores only)."
  type        = map(string)
  default = {
    role        = "tvcontrol"
    resource    = "cloudsql"
    repo        = "tvcontrol"
    team        = "de"
    env         = "sandbox"
    monitoring  = "production"
    lifecycle   = "in-use"
    createdby   = "ops"
    service     = "tvcontrol"
    function    = "tv-command"
    zoo         = "production"
    launchstate = "done"
  }
}
