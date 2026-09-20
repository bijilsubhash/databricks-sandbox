# Databricks notebook source
# MAGIC %md
# MAGIC # ABAC Playground (Bakehouse)
# MAGIC
# MAGIC Test Unity Catalog **ABAC** — governed tags, row filters, column masks.
# MAGIC Run **Setup**, work through sections 1–5, run **Teardown** when done.
# MAGIC Groups (`admin_group`, `user_group`) come from `infra/identity.tf`.
# MAGIC Docs: https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/

# COMMAND ----------

# MAGIC %md
# MAGIC ## Setup — copy bakehouse tables into a schema we own

# COMMAND ----------

dbutils.widgets.text("catalog", "sandbox", "Catalog")
dbutils.widgets.text("schema", "abac_demo", "Schema")

catalog = dbutils.widgets.get("catalog")
schema = dbutils.widgets.get("schema")
fq = f"`{catalog}`.`{schema}`"

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {fq}")

tables = {
    "customers": "samples.bakehouse.sales_customers",
    "transactions": "samples.bakehouse.sales_transactions",
    "franchises": "samples.bakehouse.sales_franchises",
}
for name, source in tables.items():
    spark.sql(f"CREATE OR REPLACE TABLE {fq}.`{name}` AS SELECT * FROM {source}")

print(f"Ready: {fq}")
display(spark.sql(f"SHOW TABLES IN {fq}"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Build `fact_transactions`
# MAGIC
# MAGIC One row per transaction + customer geography, two PII columns, and franchise attributes.

# COMMAND ----------

spark.sql(f"""
CREATE OR REPLACE TABLE {fq}.`fact_transactions` AS
SELECT
    t.transactionID, t.dateTime, t.product, t.quantity,
    t.unitPrice, t.totalPrice, t.paymentMethod, t.cardNumber,
    c.customerID,
    c.country     AS customer_country,
    c.continent   AS customer_continent,
    c.email_address,
    c.address,
    f.franchiseID,
    f.name        AS franchise_name,
    f.city        AS franchise_city,
    f.country     AS franchise_country,
    f.size        AS franchise_size
FROM {fq}.`transactions` t
LEFT JOIN {fq}.`customers`  c ON t.customerID  = c.customerID
LEFT JOIN {fq}.`franchises` f ON t.franchiseID = f.franchiseID
""")
display(spark.sql(f"SELECT * FROM {fq}.`fact_transactions` LIMIT 20"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Governed tag `region` + apply to `customer_continent`
# MAGIC
# MAGIC Governed tags are **account-level** (no `IF [NOT] EXISTS`), so create/drop are wrapped.

# COMMAND ----------

# Key-only tag (create is wrapped: no IF NOT EXISTS for governed tags).
try:
    spark.sql("CREATE GOVERNED TAG region DESCRIPTION 'Marks the region column'")
    print("Created tag: region")
except Exception as e:
    print(f"region: {e.__class__.__name__} (may already exist)")

# COMMAND ----------

# Apply it to the continent column.
spark.sql(f"ALTER TABLE {fq}.`fact_transactions` ALTER COLUMN customer_continent SET TAGS ('region')")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Row filter — `admin_group` sees all, others see only North America
# MAGIC
# MAGIC Scoped `TO account users`, so the function runs for everyone; admins pass via the bypass.

# COMMAND ----------

# Filter function: admins pass, everyone else limited to North America.
spark.sql(f"""
CREATE OR REPLACE FUNCTION {fq}.`region_row_filter`(region STRING)
RETURNS BOOLEAN
RETURN is_account_group_member('admin_group') OR region = 'North America'
""")

# COMMAND ----------

# Bind the filter to the region-tagged column.
spark.sql(f"""
CREATE OR REPLACE POLICY fact_transactions_region_filter
ON TABLE {fq}.`fact_transactions`
ROW FILTER {fq}.`region_row_filter`
TO `account users`
FOR TABLES
MATCH COLUMNS has_tag('region') AS region
USING COLUMNS (region)
""")

# COMMAND ----------

# Check: admin sees all continents, non-admin only North America.
display(spark.sql(f"""
SELECT customer_continent, count(*) AS n
FROM {fq}.`fact_transactions` GROUP BY customer_continent ORDER BY n DESC
"""))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Column masks — value-based `pii` tag
# MAGIC
# MAGIC | Column | Tag | admin_group | others |
# MAGIC |---|---|---|---|
# MAGIC | `email_address` | `pii='email'`   | domain only | `NULL` |
# MAGIC | `address`       | `pii='address'` | full        | `NULL` |
# MAGIC
# MAGIC One mask per column, so both coexist. Masked column = the function's first arg.

# COMMAND ----------

# Value-constrained tag for PII columns.
try:
    spark.sql("CREATE GOVERNED TAG pii DESCRIPTION 'PII columns' VALUES ('email', 'address')")
    print("Created tag: pii")
except Exception as e:
    print(f"pii: {e.__class__.__name__} (may already exist)")

# COMMAND ----------

# Tag each column with its allowed value.
spark.sql(f"ALTER TABLE {fq}.`fact_transactions` ALTER COLUMN email_address SET TAGS ('pii' = 'email')")
spark.sql(f"ALTER TABLE {fq}.`fact_transactions` ALTER COLUMN address SET TAGS ('pii' = 'address')")

# COMMAND ----------

# Mask functions: admins get domain / full value, everyone else NULL.
spark.sql(f"""
CREATE OR REPLACE FUNCTION {fq}.`pii_email_mask`(email STRING) RETURNS STRING
RETURN CASE WHEN is_account_group_member('admin_group')
            THEN concat('****@', split_part(email, '@', 2)) ELSE NULL END
""")
spark.sql(f"""
CREATE OR REPLACE FUNCTION {fq}.`pii_address_mask`(addr STRING) RETURNS STRING
RETURN CASE WHEN is_account_group_member('admin_group') THEN addr ELSE NULL END
""")

# COMMAND ----------

# Mask the email column (pii = 'email').
spark.sql(f"""
CREATE OR REPLACE POLICY fact_transactions_email_mask
ON TABLE {fq}.`fact_transactions`
COLUMN MASK {fq}.`pii_email_mask`
TO `account users`
FOR TABLES
MATCH COLUMNS has_tag_value('pii', 'email') AS email_col
ON COLUMN email_col
""")

# COMMAND ----------

# Mask the address column (pii = 'address').
spark.sql(f"""
CREATE OR REPLACE POLICY fact_transactions_address_mask
ON TABLE {fq}.`fact_transactions`
COLUMN MASK {fq}.`pii_address_mask`
TO `account users`
FOR TABLES
MATCH COLUMNS has_tag_value('pii', 'address') AS addr_col
ON COLUMN addr_col
""")

# COMMAND ----------

# Check: admin sees domain / full address, non-admin sees NULL.
display(spark.sql(f"""
SELECT customerID, email_address, address, customer_continent
FROM {fq}.`fact_transactions` LIMIT 20
"""))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Inspect policies

# COMMAND ----------

display(spark.sql(f"SHOW POLICIES ON TABLE {fq}.`fact_transactions`"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. Metastore-level ABAC (Beta) — one policy, every table
# MAGIC
# MAGIC A policy `ON METASTORE` applies to **every** table in the metastore carrying the tag, not
# MAGIC just our schema. Here it spans the raw `customers` + `franchises` (both have a real
# MAGIC `country`). Needs **metastore admin** + **DBR 19+**; distinct tags avoid conflict with the
# MAGIC table-level policies above. Docs: .../abac/metastore-policies
# MAGIC
# MAGIC - Row filter on `country` → non-admins see only `US` (customers + franchises).
# MAGIC - Column mask on `email_pii` → non-admins get `NULL` email (customers).

# COMMAND ----------

# Metastore-wide tags (distinct from the table-level ones above).
for stmt in [
    "CREATE GOVERNED TAG country DESCRIPTION 'Country column (metastore-wide)'",
    "CREATE GOVERNED TAG email_pii DESCRIPTION 'Email column (metastore-wide)'",
]:
    try:
        spark.sql(stmt); print("Created tag:", stmt.split()[3])
    except Exception as e:
        print(f"{stmt.split()[3]}: {e.__class__.__name__} (may already exist)")

# COMMAND ----------

# Tag country on two tables + email on customers.
spark.sql(f"ALTER TABLE {fq}.`customers`  ALTER COLUMN country       SET TAGS ('country')")
spark.sql(f"ALTER TABLE {fq}.`franchises` ALTER COLUMN country       SET TAGS ('country')")
spark.sql(f"ALTER TABLE {fq}.`customers`  ALTER COLUMN email_address SET TAGS ('email_pii')")

# COMMAND ----------

# Filter + mask functions (admin bypass).
spark.sql(f"""
CREATE OR REPLACE FUNCTION {fq}.`mstr_country_filter`(country STRING) RETURNS BOOLEAN
RETURN is_account_group_member('admin_group') OR country in ('US', 'USA')
""")
spark.sql(f"""
CREATE OR REPLACE FUNCTION {fq}.`mstr_email_mask`(email STRING) RETURNS STRING
RETURN CASE WHEN is_account_group_member('admin_group') THEN email ELSE NULL END
""")

# COMMAND ----------

# Metastore-wide row filter on any `country`-tagged column.
spark.sql(f"""
CREATE OR REPLACE POLICY mstr_country_filter
ON METASTORE
ROW FILTER {fq}.`mstr_country_filter`
TO `account users`
FOR TABLES
MATCH COLUMNS has_tag('country') AS country
USING COLUMNS (country)
""")

# COMMAND ----------

# Metastore-wide column mask on any `email_pii`-tagged column.
spark.sql(f"""
CREATE OR REPLACE POLICY mstr_email_mask
ON METASTORE
COLUMN MASK {fq}.`mstr_email_mask`
TO `account users`
FOR TABLES
MATCH COLUMNS has_tag('email_pii') AS c
ON COLUMN c
""")

# COMMAND ----------

# Check: non-admin sees US rows only + email NULL; admin sees everything.
display(spark.sql(f"SELECT customerID, email_address, country FROM {fq}.`customers` LIMIT 20"))
display(spark.sql(f"SELECT franchiseID, name, country FROM {fq}.`franchises` LIMIT 20"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Teardown
# MAGIC
# MAGIC Set `confirm_teardown` to `yes`. Metastore policies live above the schema, so they're
# MAGIC dropped explicitly first; `CASCADE` drops the schema; account-level tags drop last.

# COMMAND ----------

dbutils.widgets.dropdown("confirm_teardown", "no", ["no", "yes"], "Confirm teardown")

if dbutils.widgets.get("confirm_teardown") == "yes":
    for pol in ("mstr_country_filter", "mstr_email_mask"):
        try:
            spark.sql(f"DROP POLICY {pol} ON METASTORE")
            print(f"Dropped metastore policy: {pol}")
        except Exception as e:
            print(f"{pol}: {e.__class__.__name__} (may not exist)")
    spark.sql(f"DROP SCHEMA IF EXISTS {fq} CASCADE")
    print(f"Dropped {fq}")
    for tag in ("region", "pii", "country", "email_pii"):
        try:
            spark.sql(f"DROP GOVERNED TAG {tag}")
            print(f"Dropped tag: {tag}")
        except Exception as e:
            print(f"{tag}: {e.__class__.__name__} (may not exist)")
else:
    print("Skipped. Set 'confirm_teardown' to 'yes' to drop the schema.")
