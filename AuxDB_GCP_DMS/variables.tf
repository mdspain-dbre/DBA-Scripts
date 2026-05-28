# =============================================================================
# VARIABLES — auxdb-qa Cloud SQL for MySQL (Inscape-Dev)
# =============================================================================

variable "project_id" {
  description = "GCP project ID that will host the Cloud SQL instance."
  type        = string
  ##default     = "inscape-dev"
  default = "vz-inscape-portfolio-dev"
}

variable "region" {
  description = "Region for the Cloud SQL instance."
  type        = string
  default     = "us-west1"
}

# -----------------------------------------------------------------------------
# Per-instance Cloud SQL configuration
# -----------------------------------------------------------------------------
# Each map entry creates one Cloud SQL instance plus its own PSC endpoint
# (internal IP + forwarding rule + optional DNS A record).
#
# Map key (e.g. "qa", "dre_test3") is used internally by Terraform as the
# for_each key — keep it short, lowercase, and stable (renaming the key
# forces a destroy/create unless you `terraform state mv`).
# -----------------------------------------------------------------------------
variable "instances" {
  description = "Map of Cloud SQL for MySQL instances to create."
  type = map(object({
    instance_name       = string
    sub_service         = string # Vizio module sub_service label — drives derived names (svc accts, IAM, SQL users). DO NOT change for existing instances or they will be destroyed/recreated.
    environment         = string
    tier                = string
    database_version    = string
    availability_type   = string # ZONAL or REGIONAL
    deletion_protection = bool
  }))
  default = {
    qa = {
      instance_name       = "auxdb-qa-dre-test"
      sub_service         = "auxdb-qa" # MUST stay as-is — matches original hardcoded value in state.
      environment         = "qa"
      tier                = "db-custom-2-7680"
      database_version    = "MYSQL_8_0"
      availability_type   = "ZONAL"
      deletion_protection = true
    }
    dre_test3 = {
      instance_name       = "auxdb-dre-test3"
      sub_service         = "auxdb-dre-test3"
      environment         = "qa"
      tier                = "db-custom-2-7680"
      database_version    = "MYSQL_8_0"
      availability_type   = "ZONAL"
      deletion_protection = true
    }
  }
}

# -----------------------------------------------------------------------------
# Private Service Connect (PSC) consumer-side networking
# -----------------------------------------------------------------------------
variable "consumer_vpc_self_link" {
  description = <<-EOT
    Self link of the consumer VPC network where the PSC endpoint (forwarding
    rule) will be created. Example:
      projects/vz-inscape-portfolio-dev/global/networks/inscape-dev-vpc
  EOT
  type        = string
}

variable "consumer_subnet_self_link" {
  description = <<-EOT
    Self link of the subnet (in var.region) where the PSC endpoint's internal
    IP will be allocated. Must live in the same VPC as var.consumer_vpc_self_link.
    Example:
      projects/vz-inscape-portfolio-dev/regions/us-west1/subnetworks/inscape-dev-usw1
  EOT
  type        = string
}

variable "create_psc_dns" {
  description = "When true, create a private Cloud DNS zone for sql.goog. and an A record mapping the instance's PSC DNS name to the endpoint IP. Set to false if a sql.goog. zone already exists in the VPC (you can only have one)."
  type        = bool
  default     = true
}
