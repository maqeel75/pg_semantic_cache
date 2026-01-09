# clear_cache

Remove all cache entries.

## Signature

```sql
semantic_cache.clear_cache() RETURNS bigint
```

## Returns

- **bigint**: Number of entries removed

## Description

Removes all cached entries. Use with caution!

## Example

```sql
-- Clear entire cache
SELECT semantic_cache.clear_cache();
```
