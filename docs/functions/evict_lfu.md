# evict_lfu

Evict least frequently used entries, keeping only the most accessed.

## Signature

```sql
semantic_cache.evict_lfu(keep_count integer) RETURNS bigint
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `keep_count` | integer | Number of most frequently used entries to keep |

## Returns

- **bigint**: Number of entries evicted

## Example

```sql
-- Keep only the 500 most frequently accessed entries
SELECT semantic_cache.evict_lfu(500);
```
