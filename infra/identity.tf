# ===========================================================================
# Account-level identity: users and groups
#
# These live at the ACCOUNT level (accounts.cloud.databricks.com), so they use
# the `databricks.mws` provider -- same as the metastore / workspace creation.
# They are independent of any workspace and survive a workspace teardown.
#
# admin_group / user_group are plain groups here: names only, no privileges yet.
# Wire privileges (account roles, workspace assignment, UC grants) separately.
# ===========================================================================

# New user. `data.databricks_user.me` (var.my_email) is defined in unity_catalog.tf.
resource "databricks_user" "sandbox" {
  provider  = databricks.mws
  user_name = var.sandbox_user_email
}

resource "databricks_group" "admin_group" {
  provider     = databricks.mws
  display_name = "admin_group"
}

resource "databricks_group" "user_group" {
  provider     = databricks.mws
  display_name = "user_group"
}

# me (var.my_email) -> admin_group
resource "databricks_group_member" "admin_me" {
  provider  = databricks.mws
  group_id  = databricks_group.admin_group.id
  member_id = data.databricks_user.me.id
}

# databricks_sandbox -> user_group
resource "databricks_group_member" "user_sandbox" {
  provider  = databricks.mws
  group_id  = databricks_group.user_group.id
  member_id = databricks_user.sandbox.id
}
