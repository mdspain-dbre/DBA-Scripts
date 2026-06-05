variable "environment" {
  description = "Deployment environment for naming and policy context."
  type        = string
  default     = "dev"
}

variable "instance_name" {
  description = "Cloud SQL instance name."
  type        = string
  default     = "tvc-development"
}

variable "project_id" {
  description = "GCP project ID where Cloud SQL will be deployed."
  type        = string
  default     = "vz-inscape-portfolio-dev"
}

variable "psc_host_project" {
  description = "Project ID of the host network for Private Service Connect."
  type        = string
  default     = null
}

variable "psc_host_project_network" {
  description = "Name or full self-link of the VPC network where PSC endpoints will be created."
  type        = string
  default     = null
}

variable "region" {
  description = "GCP region for Cloud SQL resources."
  type        = string
  default     = "us-east4"
}

variable "root_user_password" {
  description = "Root/admin password for the Cloud SQL instance."
  type        = string
  sensitive   = true
}

variable "service" {
  description = "Service identifier used by the module for naming and labels."
  type        = string
  default     = "tvc"
}

variable "sub_service" {
  description = "Sub-service identifier used by the module for naming and labels."
  type        = string
  default     = "tvc-development"
}
