# evict_lru

Evict least recently used entries, keeping only the most recent.

## Signature

```sql
semantic_cache.evict_lru(keep_count integer) RETURNS bigint
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `keep_count` | integer | Number of most recently used entries to keep |

## Returns

- **bigint**: Number of entries evicted

## Example

```sql
-- Keep only the 1000 most recently used entries
SELECT semantic_cache.evict_lru(1000);
```
