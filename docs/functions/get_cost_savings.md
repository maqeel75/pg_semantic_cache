# get_cost_savings

Get cost savings report for specified period.

## Signature

```sql
semantic_cache.get_cost_savings(days integer DEFAULT 30)
RETURNS TABLE(
    total_queries bigint,
    cache_hits bigint,
    cache_misses bigint,
    hit_rate float4,
    total_cost_saved float8,
    avg_cost_per_hit float8,
    total_cost_if_no_cache float8
)
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `days` | integer | 30 | Number of days to analyze |

## Example

```sql
-- Get cost savings for last 30 days
SELECT * FROM semantic_cache.get_cost_savings(30);
```
