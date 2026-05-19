variable "region" {
  description = "AWS region for the Aurora cluster."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile used by the provider."
  type        = string
  default     = "inscape-production-us-1-inscape-aws-ops"
}

variable "cluster_identifier" {
  description = "Aurora DB cluster identifier."
  type        = string
  default     = "tvc-production"
}

variable "database_name" {
  description = "Initial database created in the cluster."
  type        = string
  default     = "tvlocation"
}

variable "master_username" {
  description = "Master DB user name."
  type        = string
  default     = "root"
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "12.22"
}

variable "instance_class" {
  description = "DB instance class for cluster members."
  type        = string
  default     = "db.r6i.2xlarge"
}

variable "db_subnet_group_name" {
  description = "Existing DB subnet group name."
  type        = string
  default     = "prod-rds-subnet"
}

variable "vpc_security_group_ids" {
  description = "VPC security group IDs attached to the cluster."
  type        = list(string)
  default     = ["sg-32cd177b", "sg-4cfd2705"]
}

variable "kms_key_id" {
  description = "KMS key ARN for storage and Performance Insights encryption."
  type        = string
  default     = "arn:aws:kms:us-east-1:788724168120:key/de2276b9-c4c8-4168-90c1-d2fc99e242fb"
}

variable "monitoring_role_arn" {
  description = "IAM role ARN used for enhanced monitoring (currently disabled — interval=0)."
  type        = string
  default     = "arn:aws:iam::788724168120:role/rds-monitoring-role"
}

variable "backup_retention_period" {
  description = "Days to retain automated backups."
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily backup window (UTC)."
  type        = string
  default     = "08:33-09:03"
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window."
  type        = string
  default     = "fri:07:12-fri:07:42"
}

variable "deletion_protection" {
  description = "Enable cluster deletion protection."
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Tags applied to every resource (matches existing tag set on tvc-production)."
  type        = map(string)
  default = {
    role                             = "tvcontrol"
    resource                         = "rds"
    repo                             = "tvcontrol"
    description                      = "unknown"
    team                             = "DE"
    env                              = "prod"
    monitoring                       = "production"
    lifecycle                        = "in-use"
    "customer-billable"              = "unknown"
    "OPP-5465_db_cost_resource_name" = "tvc-production"
    createdby                        = "ops"
    service                          = "tvcontrol"
    function                         = "tv-command"
    zoo                              = "production"
    launchstate                      = "done"
    customer                         = "unknown"
  }
}
