# ===========================================================================
# 4. Unity Catalog metastore  (ROOTLESS -- see docs/adr/0001)
#
#    A metastore is one-per-region-per-account. Databricks may auto-create one.
#    BEFORE first apply, verify us-east-1 is empty:
#      databricks metastore list --profile <account-profile>
#    If one already exists, do NOT create -- import it instead:
#      terraform import databricks_metastore.this <existing-metastore-id>
# ===========================================================================
resource "databricks_metastore" "this" {
  provider = databricks.mws
  name     = "${var.prefix}-metastore"
  region   = var.region
  owner    = var.my_email
  # No storage_root -> managed storage is attached at the catalog level.

  force_destroy = true
}

# Attach the metastore to the workspace.
resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  metastore_id = databricks_metastore.this.id
  workspace_id = databricks_mws_workspaces.this.workspace_id
}

# ---------------------------------------------------------------------------
# 5. Assign myself to the workspace as ADMIN.
# ---------------------------------------------------------------------------
data "databricks_user" "me" {
  provider  = databricks.mws
  user_name = var.my_email
}

resource "databricks_mws_permission_assignment" "me_admin" {
  provider     = databricks.mws
  workspace_id = databricks_mws_workspaces.this.workspace_id
  principal_id = data.databricks_user.me.id
  permissions  = ["ADMIN"]
}

# Assign user_group (which contains the sandbox user) to the workspace as USER.
resource "databricks_mws_permission_assignment" "user_group" {
  provider     = databricks.mws
  workspace_id = databricks_mws_workspaces.this.workspace_id
  principal_id = databricks_group.user_group.id
  permissions  = ["USER"]
}

# USER assignment alone doesn't grant entitlements. Give user_group the workspace
# and SQL access entitlements so members can actually open the workspace/SQL UIs.
# (Uses the workspace-level provider; entitlements resources require it.)
resource "databricks_entitlements" "user_group" {
  provider              = databricks.workspace
  group_id              = databricks_group.user_group.id
  workspace_access      = true
  databricks_sql_access = true

  depends_on = [databricks_mws_permission_assignment.user_group]
}

# ===========================================================================
# 6. Catalog data bucket + storage credential + external location
#    (catalog-level managed storage -- the recommended pattern)
# ===========================================================================
resource "aws_s3_bucket" "data" {
  bucket        = local.data_bucket_name
  force_destroy = true
  tags          = merge(var.tags, { Name = local.data_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The storage credential is created first; it generates the external_id that the
# IAM role's trust policy must reference (breaks the circular dependency).
resource "databricks_storage_credential" "data" {
  provider = databricks.workspace
  name     = "${local.prefix}-data-cred"
  owner    = var.my_email
  aws_iam_role {
    role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.uc_iam_role}"
  }
  depends_on = [databricks_metastore_assignment.this]
}

data "databricks_aws_unity_catalog_assume_role_policy" "data" {
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.uc_iam_role
  external_id    = databricks_storage_credential.data.aws_iam_role[0].external_id
}

data "databricks_aws_unity_catalog_policy" "data" {
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = aws_s3_bucket.data.id
  role_name      = local.uc_iam_role
}

resource "aws_iam_policy" "uc_data" {
  name   = "${local.uc_iam_role}-policy"
  policy = data.databricks_aws_unity_catalog_policy.data.json
}

resource "aws_iam_role" "uc_data" {
  name               = local.uc_iam_role
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.data.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "uc_data" {
  role       = aws_iam_role.uc_data.name
  policy_arn = aws_iam_policy.uc_data.arn
}

# Give IAM a moment to propagate before UC validates the external location.
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_role_policy_attachment.uc_data]
  create_duration = "30s"
}

resource "databricks_external_location" "data" {
  provider        = databricks.workspace
  name            = "${local.prefix}-data-loc"
  url             = "s3://${aws_s3_bucket.data.id}/"
  credential_name = databricks_storage_credential.data.id
  owner           = var.my_email
  depends_on      = [time_sleep.iam_propagation]
}

# ===========================================================================
# 7. My catalog -- managed storage at the catalog level, owned by me.
# ===========================================================================
resource "databricks_catalog" "sandbox" {
  provider     = databricks.workspace
  name         = "sandbox"
  owner        = var.my_email
  storage_root = "s3://${aws_s3_bucket.data.id}/"
  comment      = "Sandbox catalog with catalog-level managed storage."
  depends_on   = [databricks_external_location.data]
}

resource "databricks_grants" "sandbox" {
  provider = databricks.workspace
  catalog  = databricks_catalog.sandbox.name
  grant {
    principal  = var.my_email
    privileges = ["ALL_PRIVILEGES"]
  }
  # Read access for the sandbox user_group: browse the catalog/schemas and read
  # tables (the "unprivileged reader" used to test ABAC masking/row filters).
  grant {
    principal  = databricks_group.user_group.display_name
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]
  }
}
