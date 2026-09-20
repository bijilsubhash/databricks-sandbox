# ---------------------------------------------------------------------------
# Providers
#
# No credentials are ever written into these blocks. Auth is ambient:
#   - AWS         -> ~/.aws (AWS_PROFILE / default profile / SSO)
#   - Databricks  -> ~/.databrickscfg account-level profile (var.databricks_account_profile)
#                    or DATABRICKS_CLIENT_ID / DATABRICKS_CLIENT_SECRET env vars.
#
# Two Databricks providers are required:
#   - databricks.mws        : account level  -> metastore + mws_* (workspace creation)
#   - databricks.workspace  : workspace level -> catalog, storage credential, grants
#                             (its host only exists AFTER the workspace is created)
# ---------------------------------------------------------------------------

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# Account-level provider (accounts console).
provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_account_profile
}

# Workspace-level provider. host is wired from the workspace we create, so this
# provider is only usable after `databricks_mws_workspaces.this` exists.
# It reuses the same account credentials (the account SP/user is workspace admin).
provider "databricks" {
  alias   = "workspace"
  host    = databricks_mws_workspaces.this.workspace_url
  profile = var.databricks_account_profile
}
