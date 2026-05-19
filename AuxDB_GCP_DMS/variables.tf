# =============================================================================
# VARIABLES — auxdb-qa Cloud SQL for MySQL (Inscape-Dev)
# =============================================================================

variable "project_id" {
  description = "GCP project ID that will host the Cloud SQL instance."
  type        = string
  default     = "inscape-dev"
}

variable "region" {
  description = "Region for the Cloud SQL instance."
  type        = string
  default     = "us-west1"
}

variable "zone" {
  description = "Preferred zone for ZONAL instances. Ignored for REGIONAL availability."
  type        = string
  default     = "us-west1-a"
}

variable "instance_name" {
  description = "Cloud SQL instance name. Cannot be reused for ~7 days after deletion."
  type        = string
  default     = "auxdb-qa-dre-test"
}

variable "database_version" {
  description = "MySQL engine version (e.g. MYSQL_8_0, MYSQL_8_0_36)."
  type        = string
  default     = "MYSQL_8_0"
}

variable "tier" {
  description = "Machine tier (e.g. db-custom-2-7680, db-n1-standard-2)."
  type        = string
  default     = "db-custom-2-7680" # 2 vCPU / 7.5 GB RAM — sensible QA default
}

variable "availability_type" {
  description = "ZONAL (single zone) or REGIONAL (HA with standby)."
  type        = string
  default     = "ZONAL"
}

variable "disk_size_gb" {
  description = "Initial PD-SSD size in GB."
  type        = number
  default     = 100
}

variable "disk_autoresize_limit_gb" {
  description = "Hard cap (GB) on disk autoresize to prevent runaway growth. 0 = no limit."
  type        = number
  default     = 500
}

variable "mysql_root_password" {
  description = "Root password for the MySQL instance. Provide via tfvars or -var."
  type        = string
  sensitive   = true
}

variable "deletion_protection" {
  description = "When true, both API and Terraform deletion protection are enabled."
  type        = bool
  default     = true
}
