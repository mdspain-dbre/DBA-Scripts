output "cluster_endpoint" {
  description = "Writer endpoint."
  value       = aws_rds_cluster.tvc_production.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint."
  value       = aws_rds_cluster.tvc_production.reader_endpoint
}

output "cluster_arn" {
  description = "Cluster ARN."
  value       = aws_rds_cluster.tvc_production.arn
}

output "cluster_resource_id" {
  description = "Cluster resource ID (used for IAM auth & Performance Insights)."
  value       = aws_rds_cluster.tvc_production.cluster_resource_id
}

output "instance_endpoints" {
  description = "Per-instance endpoints."
  value       = { for k, i in aws_rds_cluster_instance.tvc_production : k => i.endpoint }
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the master password (when managed)."
  value       = try(aws_rds_cluster.tvc_production.master_user_secret[0].secret_arn, null)
}
