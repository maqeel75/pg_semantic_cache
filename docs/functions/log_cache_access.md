# log_cache_access

Log cache access event with cost information.

## Signature

```sql
semantic_cache.log_cache_access(
    query_hash text DEFAULT NULL,
    cache_hit boolean DEFAULT false,
    similarity_score float4 DEFAULT NULL,
    query_cost numeric DEFAULT NULL
) RETURNS void
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query_hash` | text | Query identifier |
| `cache_hit` | boolean | Whether this was a cache hit |
| `similarity_score` | float4 | Similarity score if hit |
| `query_cost` | numeric | Cost saved (e.g., API cost in USD) |

## Example

```sql
-- Log a cache hit that saved $0.02
SELECT semantic_cache.log_cache_access(
    'query_abc123',
    true,
    0.96,
    0.02
);
```
