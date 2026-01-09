# cache_hit_rate

Get current cache hit rate percentage.

## Signature

```sql
semantic_cache.cache_hit_rate() RETURNS float4
```

## Returns

- **float4**: Hit rate as percentage (0-100)

## Example

```sql
SELECT semantic_cache.cache_hit_rate();
-- Returns: 80.93
```

## See Also

- [cache_stats](cache_stats.md) - Comprehensive statistics
