# databricks-sandbox

Personal Databricks-on-AWS sandbox: Terraform infra (`infra/`) plus account-level
identity (users/groups) managed as code.

## Getting started

```bash
cp .env.example .env      # fill in real values (gitignored)
direnv allow              # optional: auto-loads .env into your shell
just up                   # refresh AWS + Databricks auth, then print status
```

`just up` refreshes whichever session token has expired (AWS SSO and/or the
Databricks account OAuth) and confirms you're authenticated. Run `just` to list
all recipes.

## Layout

| Path | What |
|---|---|
| `justfile` | Session bootstrap / auth helpers (`just up`, `just status`, …). |
| `.env.example` | Template for local, gitignored config (`.env`). |
| `infra/` | Terraform: workspace, Unity Catalog, and `identity.tf` (users/groups). |
| `docs/adr/` | Architecture decision records. |

## Secrets & PII

Nothing personal or account-specific is committed. Real values (emails, account
IDs, profile names) live only in gitignored files: `.env`, `infra/terraform.tfvars`,
and Terraform state (`*.tfstate*`). Auth tokens live in `~/.aws` and `~/.databrickscfg`.
