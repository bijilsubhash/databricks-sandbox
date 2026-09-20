# Databricks-on-AWS sandbox infra

Terraform for a personal Databricks-on-AWS sandbox: S3 buckets, cross-account IAM,
a Databricks workspace (Databricks-managed VPC), a rootless Unity Catalog metastore,
and the user in `var.my_email` wired in as workspace admin + metastore/catalog owner.
Account-level users and groups live in `identity.tf`.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.root` | Workspace root / system storage (DBFS root). **Not** table storage. |
| `aws_iam_role.cross_account` | Role the Databricks control plane assumes into your account. |
| `databricks_mws_workspaces` | The workspace, Databricks-managed VPC (no customer VPC). |
| `databricks_metastore` | Unity Catalog metastore, **rootless** (see `../docs/adr/0001`). |
| `databricks_metastore_assignment` | Attaches the metastore to the workspace. |
| `databricks_mws_permission_assignment` | You as workspace **ADMIN**. |
| `aws_s3_bucket.data` + storage credential + external location | Catalog-level managed storage. |
| `databricks_catalog.sandbox` | Your catalog, owned by you, storage at catalog level. |

## Prerequisites

- **Serverless-first**: no EC2/VPC is provisioned; the cross-account role stays dormant.
- Auth is **ambient** — no credentials live in any `.tf` file:
  - **AWS**: `~/.aws` (e.g. `export AWS_PROFILE=...`), region `us-east-1`.
  - **Databricks**: an **account-level** profile in `~/.databrickscfg` (has `account_id`
    + OAuth), named in `databricks_account_profile`. Alternatively export
    `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET`.

## Before first apply — check the metastore

A metastore is **one per region per account** and Databricks sometimes auto-creates one.
Verify `us-east-1` is empty first:

```bash
databricks metastore list --profile <account-profile>
```

- Empty → apply as-is (it will create the metastore).
- One already exists → **do not create**; import it and drop/adjust the resource:
  ```bash
  terraform import databricks_metastore.this <existing-metastore-id>
  ```

## Run

```bash
# Option A: terraform.tfvars (gitignored)
cp terraform.tfvars.example terraform.tfvars   # fill in real values

# Option B: use the repo .env instead (TF_VAR_* exported by direnv/just)
cp ../.env.example ../.env                      # fill in, then `direnv allow`

terraform init
terraform plan
terraform apply
```

### Two-apply caveat (IAM propagation)

The UC storage credential and its IAM role are mutually referential (the role's trust
policy needs the credential's generated `external_id`). A `time_sleep` covers most IAM
propagation, but if the **first** apply fails validating the external location or
storage credential, simply re-run `terraform apply` — the second pass succeeds once IAM
has propagated.

## State & secrets

- State is **local and gitignored** (`*.tfstate*`) — treat it as a plaintext secret on
  disk. Migrate to an encrypted S3 backend (in `versions.tf`) if this grows.
- The `.tf` code **is** committed; only state, `*.tfvars`, and `.terraform/` are ignored.
