# rebuild_index

Rebuild cache table and index with current configuration.

## Signature

```sql
semantic_cache.rebuild_index() RETURNS void
```

## Description

Rebuilds the cache table and index using current configuration settings. **WARNING: This clears all cached data.**

## Example

```sql
-- After changing dimension or index type
SELECT semantic_cache.set_vector_dimension(3072);
SELECT semantic_cache.rebuild_index();  -- Applies changes, clears cache
```
