variable "databricks_account_id" {
  type        = string
  description = "Databricks account ID (UUID). Not a secret; supplied via terraform.tfvars."
}

variable "databricks_account_profile" {
  type        = string
  description = "Name of the account-level profile in ~/.databrickscfg used for auth."
  default     = "DEFAULT"
}

variable "region" {
  type        = string
  description = "AWS region. Must match the metastore region (one metastore per region per account)."
  default     = "us-east-1"
}

variable "aws_profile" {
  type        = string
  description = "AWS named profile (~/.aws) used for auth. SSO profile for the sandbox account."
  default     = "databricks-sandbox"
}

variable "prefix" {
  type        = string
  description = "Short prefix for resource names. Also seeds globally-unique S3 bucket names."
  default     = "sandbox"
}

# No default: supplied per-environment via .env (TF_VAR_my_email) or terraform.tfvars,
# so no personal identifier lives in version control.
variable "my_email" {
  type        = string
  description = "The user to assign as workspace ADMIN, metastore owner, and catalog owner."
}

# No default: supplied via .env (TF_VAR_sandbox_user_email) or terraform.tfvars.
variable "sandbox_user_email" {
  type        = string
  description = "Email/userName of the sandbox service user created in identity.tf."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to AWS resources."
  default = {
    Project   = "databricks-sandbox"
    ManagedBy = "terraform"
  }
}
