data "aws_caller_identity" "current" {}

locals {
  prefix = var.prefix

  # Globally-unique-ish bucket names. Account id suffix avoids collisions.
  root_bucket_name = "${var.prefix}-root-${data.aws_caller_identity.current.account_id}"
  data_bucket_name = "${var.prefix}-data-${data.aws_caller_identity.current.account_id}"

  uc_iam_role = "${var.prefix}-uc-storage"
}

# ===========================================================================
# 1. Workspace root storage bucket  (workspace system storage / DBFS root)
#    NOT where governed tables live -- that is the catalog data bucket below.
# ===========================================================================
resource "aws_s3_bucket" "root" {
  bucket        = local.root_bucket_name
  force_destroy = true
  tags          = merge(var.tags, { Name = local.root_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "root" {
  bucket                  = aws_s3_bucket.root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "root" {
  bucket = aws_s3_bucket.root.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bucket policy authorizing the Databricks control plane to use the root bucket.
# Without this the workspace fails storage-configuration validation (Access Denied).
data "databricks_aws_bucket_policy" "root" {
  provider                 = databricks.mws
  bucket                   = aws_s3_bucket.root.bucket
  databricks_e2_account_id = var.databricks_account_id
}

resource "aws_s3_bucket_policy" "root" {
  bucket = aws_s3_bucket.root.id
  policy = data.databricks_aws_bucket_policy.root.json
}

# ===========================================================================
# 2. Cross-account IAM role  (Databricks control plane assumes this)
# ===========================================================================
data "databricks_aws_assume_role_policy" "this" {
  provider    = databricks.mws
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account" {
  name               = "${local.prefix}-crossaccount"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = var.tags
}

data "databricks_aws_crossaccount_policy" "this" {
  provider    = databricks.mws
  policy_type = "managed" # Databricks-managed VPC -> full policy incl. VPC/IGW/NAT creation
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${local.prefix}-crossaccount-policy"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

# ===========================================================================
# 3. Register credentials + storage config, then create the workspace
#    (Databricks-managed VPC -> no network_id)
# ===========================================================================
resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  credentials_name = "${local.prefix}-creds"
  role_arn         = aws_iam_role.cross_account.arn
  depends_on       = [aws_iam_role_policy.cross_account]
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id # required by this resource (per provider docs)
  storage_configuration_name = "${local.prefix}-storage"
  bucket_name                = aws_s3_bucket.root.bucket
  depends_on                 = [aws_s3_bucket_policy.root]
}

resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id # required by this resource (per provider docs)
  workspace_name = local.prefix
  aws_region     = var.region

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  # No network_id => Databricks-managed VPC.
}
