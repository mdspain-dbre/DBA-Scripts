output "primary_instance_name" {
  value = google_sql_database_instance.primary.name
}

output "primary_connection_name" {
  description = "project:region:instance — used by Cloud SQL Auth Proxy."
  value       = google_sql_database_instance.primary.connection_name
}

output "primary_private_ip" {
  value = google_sql_database_instance.primary.private_ip_address
}

output "primary_public_ip" {
  value = google_sql_database_instance.primary.public_ip_address
}

output "replica_connection_name" {
  value = google_sql_database_instance.replica.connection_name
}

output "replica_private_ip" {
  value = google_sql_database_instance.replica.private_ip_address
}

output "database_name" {
  value = google_sql_database.tvlocation.name
}

output "master_username" {
  value = google_sql_user.master.name
}

output "master_password" {
  description = "Generated master password. Store this in Secret Manager."
  value       = random_password.master.result
  sensitive   = true
}

output "primary_psc_endpoint_ip" {
  description = "Internal IP of the PSC forwarding rule for the primary instance."
  value       = google_compute_address.psc_primary.address
}

output "replica_psc_endpoint_ip" {
  description = "Internal IP of the PSC forwarding rule for the replica instance."
  value       = google_compute_address.psc_replica.address
}

output "primary_dns_name" {
  description = "DNS name (sql.goog) for the primary; resolves to primary_psc_endpoint_ip from within the consumer VPC."
  value       = google_sql_database_instance.primary.dns_name
}

output "replica_dns_name" {
  description = "DNS name (sql.goog) for the replica."
  value       = google_sql_database_instance.replica.dns_name
}
