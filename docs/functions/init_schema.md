# init_schema

Initialize cache schema and create required tables.

## Signature

```sql
semantic_cache.init_schema() RETURNS void
```

## Description

Creates all required tables, indexes, and views. Called automatically during `CREATE EXTENSION`.

## Example

```sql
-- Manually initialize (rarely needed)
SELECT semantic_cache.init_schema();
```
