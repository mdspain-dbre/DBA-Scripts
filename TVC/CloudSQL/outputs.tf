output "instance_name" {
  description = "Cloud SQL instance name configured for deployment."
  value       = var.instance_name
}

output "project_id" {
  description = "Project receiving Cloud SQL deployment."
  value       = var.project_id
}

output "region" {
  description = "Region targeted by provider and module."
  value       = var.region
}
