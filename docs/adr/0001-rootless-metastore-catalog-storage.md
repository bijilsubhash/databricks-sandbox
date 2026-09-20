---
status: accepted
---

# Rootless Unity Catalog metastore with storage at the catalog level

We create the Unity Catalog metastore **without** a metastore-level `storage_root`, and instead attach managed storage at the **catalog** level (via a storage credential + external location on a dedicated S3 data bucket). Databricks [recommends catalog-level managed storage for logical data isolation](https://docs.databricks.com/aws/en/connect/unity-catalog/managed-storage) ("Databricks recommends that you assign managed storage at the catalog level for logical data isolation, with metastore-level and schema-level as options"); a metastore-level root becomes a shared default that every catalog silently inherits, which is exactly the isolation we want to avoid in a sandbox.

This is recorded because it is **hard to reverse** — a metastore's `storage_root` is immutable, so adding one later requires recreating the metastore — and **surprising** to a future reader who might otherwise assume the metastore "should" have a root bucket. The workspace root S3 bucket (DBFS/system storage) is a separate, mandatory thing and is unaffected by this decision.
