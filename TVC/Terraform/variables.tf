variable "service" {
  description = "Service name used as part of the resource identifier (Vizio convention)."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, stage, prod)."
  type        = string
}

variable "project_id" {
  description = "GCP project ID."
  type        = string
  default     = null
}

variable "region" {
  description = "GCP region for the AlloyDB cluster."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "AlloyDB cluster name."
  type        = string
  default     = null
}

variable "instance_name" {
  description = "AlloyDB primary instance name."
  type        = string
  default     = null
}

variable "machine_cpu_count" {
  description = "Number of vCPUs for the AlloyDB instance (must be 2, 4, 8, 16, 32, 64, or 96)."
  type        = number
  default     = 2
}

variable "support_tier" {
  description = "Vizio BCDR support tier: V0, V1, or V2."
  type        = string
  default     = "V2"
}

variable "psc_host_project" {
  description = "Project ID of the host network for Private Service Connect. Required for PSC connectivity."
  type        = string
  default     = null
}

variable "psc_host_project_network" {
  description = "Name or full self-link of the VPC network where PSC endpoints will be created."
  type        = string
  default     = null
}

variable "db_user" {
  description = "Initial database user."
  type        = string
  default     = "root"
}

variable "db_password" {
  description = "Password for the initial database user."
  type        = string
  sensitive   = true
}
