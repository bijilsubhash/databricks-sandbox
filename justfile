# justfile -- session bootstrap for the databricks-sandbox repo
#
# Auth is ambient (nothing secret lives here):
#   AWS        -> SSO session `databricks` in ~/.aws/config (profile databricks-sandbox)
#   Databricks -> account-level OAuth profile `sandbox-account` in ~/.databrickscfg
#
# Both use short-lived tokens that expire between sessions. Run `just up` at the
# start of a session to refresh whatever has lapsed and confirm you're good to
# run terraform / the databricks CLI.
#
# Quick start:  just up

# Real values come from .env (gitignored). Copy .env.example -> .env first.
set dotenv-load := true

aws_profile        := env_var_or_default("AWS_PROFILE", "")
db_account_profile := env_var_or_default("DATABRICKS_CONFIG_PROFILE", "")
db_account_host    := env_var_or_default("DATABRICKS_ACCOUNT_HOST", "https://accounts.cloud.databricks.com")
db_account_id      := env_var_or_default("DATABRICKS_ACCOUNT_ID", "")

# List available recipes.
default:
    @just --list

# One-shot session bootstrap: refresh AWS + Databricks auth only if needed, then report.
up: _check-env aws-login db-login status

# Fail early with a helpful message if .env hasn't been set up.
_check-env:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ -z "{{aws_profile}}" ] || [ -z "{{db_account_profile}}" ]; then
        echo "✗ Missing config. Run: cp .env.example .env  (then edit it)"
        exit 1
    fi

# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

# Refresh the AWS SSO token only if the current one is invalid/expired.
aws-login:
    #!/usr/bin/env bash
    set -uo pipefail
    if aws sts get-caller-identity --profile {{aws_profile}} >/dev/null 2>&1; then
        echo "✓ AWS: session already valid ({{aws_profile}})"
    else
        echo "→ AWS: token expired, logging in via SSO..."
        aws sso login --profile {{aws_profile}}
    fi

# Force an AWS SSO re-login regardless of current token state.
aws-relogin:
    aws sso login --profile {{aws_profile}}

# One-time interactive SSO setup (only needed on a fresh machine / new profile).
aws-configure:
    aws configure sso --profile {{aws_profile}}

# ---------------------------------------------------------------------------
# Databricks
# ---------------------------------------------------------------------------

# Refresh the Databricks account OAuth token only if the current one is invalid/expired.
db-login:
    #!/usr/bin/env bash
    set -uo pipefail
    if databricks account users list --profile {{db_account_profile}} >/dev/null 2>&1; then
        echo "✓ Databricks: session already valid ({{db_account_profile}})"
    else
        echo "→ Databricks: token expired, logging in (a browser will open)..."
        just db-relogin
    fi

# Force a Databricks account re-login regardless of current token state.
db-relogin:
    #!/usr/bin/env bash
    set -uo pipefail
    # Reuse host + account_id already stored in ~/.databrickscfg when .env omits them.
    if [ -n "{{db_account_id}}" ]; then
        databricks auth login --host {{db_account_host}} --account-id {{db_account_id}} --profile {{db_account_profile}}
    else
        databricks auth login --profile {{db_account_profile}}
    fi

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

# Show who you are on both AWS and Databricks (fails loudly if either is unauthenticated).
status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "── AWS ──────────────────────────────────────────"
    aws sts get-caller-identity --profile {{aws_profile}} \
        --query '{Account:Account,Arn:Arn}' --output table \
        || echo "✗ AWS not authenticated — run: just aws-login"
    echo "── Databricks (account: {{db_account_profile}}) ─"
    databricks account users list --profile {{db_account_profile}} -o json 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"✓ {len(d)} user(s) visible; auth OK")' \
        || echo "✗ Databricks not authenticated — run: just db-login"
