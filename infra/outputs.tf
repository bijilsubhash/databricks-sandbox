output "workspace_url" {
  description = "Databricks workspace URL."
  value       = databricks_mws_workspaces.this.workspace_url
}

output "workspace_id" {
  description = "Databricks workspace ID."
  value       = databricks_mws_workspaces.this.workspace_id
}

output "metastore_id" {
  description = "Unity Catalog metastore ID."
  value       = databricks_metastore.this.id
}

output "catalog_name" {
  description = "Sandbox catalog name."
  value       = databricks_catalog.sandbox.name
}

output "root_bucket" {
  description = "Workspace root (system) S3 bucket."
  value       = aws_s3_bucket.root.bucket
}

output "data_bucket" {
  description = "Catalog managed-storage S3 bucket."
  value       = aws_s3_bucket.data.bucket
}
