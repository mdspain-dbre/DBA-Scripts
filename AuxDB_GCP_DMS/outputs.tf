output "connection_names" {
  description = "Map of instance key => connection name used by the Cloud SQL Auth Proxy (project:region:instance)."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.connection_name }
}

output "instance_names" {
  description = "Map of instance key => Cloud SQL instance name."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.name }
}

output "psc_dns_names" {
  description = "Map of instance key => Cloud SQL-provided *.sql.goog DNS name that resolves to the PSC endpoint."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.dns_name }
}

output "psc_endpoint_ips" {
  description = "Map of instance key => internal IP of the PSC endpoint in the consumer VPC."
  value       = { for k, v in google_compute_address.psc_ip : k => v.address }
}

output "psc_service_attachment_links" {
  description = "Map of instance key => service attachment URI on the producer side (informational)."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.psc_service_attachment_link }
}

output "self_links" {
  description = "Map of instance key => self link of the Cloud SQL instance."
  value       = { for k, v in data.google_sql_database_instance.auxdb : k => v.self_link }
}
