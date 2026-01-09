# Function Reference

Complete reference for all pg_semantic_cache functions.

## Function Categories

### Caching Functions

| Function | Description |
|----------|-------------|
| [cache_query](cache_query.md) | Store a query result with its vector embedding |
| [get_cached_result](get_cached_result.md) | Retrieve cached result by semantic similarity |
| [invalidate_cache](invalidate_cache.md) | Invalidate cache entries by pattern or tag |

### Eviction Functions

| Function | Description |
|----------|-------------|
| [evict_expired](evict_expired.md) | Remove expired cache entries |
| [evict_lru](evict_lru.md) | Evict least recently used entries |
| [evict_lfu](evict_lfu.md) | Evict least frequently used entries |
| [auto_evict](auto_evict.md) | Automatically evict based on configured policy |
| [clear_cache](clear_cache.md) | Remove all cache entries |

### Monitoring Functions

| Function | Description |
|----------|-------------|
| [cache_stats](cache_stats.md) | Get comprehensive cache statistics |
| [cache_hit_rate](cache_hit_rate.md) | Get current cache hit rate percentage |

### Configuration Functions

| Function | Description |
|----------|-------------|
| [set_vector_dimension](set_vector_dimension.md) | Configure vector embedding dimension |
| [get_vector_dimension](get_vector_dimension.md) | Get configured vector dimension |
| [set_index_type](set_index_type.md) | Set vector index type (ivfflat/hnsw) |
| [get_index_type](get_index_type.md) | Get configured index type |
| [rebuild_index](rebuild_index.md) | Rebuild cache table and index |

### Cost Tracking Functions

| Function | Description |
|----------|-------------|
| [log_cache_access](log_cache_access.md) | Log cache access event with cost information |
| [get_cost_savings](get_cost_savings.md) | Get cost savings report for specified period |

### Utility Functions

| Function | Description |
|----------|-------------|
| [init_schema](init_schema.md) | Initialize cache schema and tables |

## Helper Views

Pre-built views for monitoring and analysis:

| View | Description |
|------|-------------|
| `semantic_cache.cache_health` | Real-time cache health metrics |
| `semantic_cache.recent_cache_activity` | Most recently accessed cache entries |
| `semantic_cache.cache_by_tag` | Cache entries grouped by tag |
| `semantic_cache.cache_access_summary` | Hourly cache access statistics with cost savings |
| `semantic_cache.cost_savings_daily` | Daily cost savings breakdown |
| `semantic_cache.top_cached_queries` | Top queries by cost savings |

## Quick Reference

### Most Common Functions

```sql
-- Cache a query
SELECT semantic_cache.cache_query(
    'SELECT * FROM orders',
    '[0.1, 0.2, ...]'::text,
    '{"results": [...]}'::jsonb,
    3600,
    ARRAY['orders']
);

-- Get cached result
SELECT * FROM semantic_cache.get_cached_result(
    '[0.1, 0.2, ...]'::text,
    0.95
);

-- View statistics
SELECT * FROM semantic_cache.cache_stats();

-- Clear expired entries
SELECT semantic_cache.evict_expired();
```

## Function Naming Convention

All functions are in the `semantic_cache` schema:
- **Action functions**: Return affected row counts (bigint)
- **Getter functions**: Return specific data types
- **Table functions**: Return table results using `RETURNS TABLE`

## Return Value Patterns

### Row Count Returns
Functions that modify data return the number of affected rows:
```sql
-- Returns: bigint (number of entries evicted)
SELECT semantic_cache.evict_expired();
```

### Boolean Returns
Functions checking conditions return boolean:
```sql
-- Returns: boolean in the result set
SELECT found FROM semantic_cache.get_cached_result(...);
```

### Table Returns
Functions returning multiple values use `RETURNS TABLE`:
```sql
-- Returns multiple columns
SELECT * FROM semantic_cache.cache_stats();
```

## Error Handling

Functions follow PostgreSQL error conventions:

- **NULL inputs**: Most functions handle NULL gracefully
- **Invalid parameters**: Raise descriptive errors
- **Missing dependencies**: Check for pgvector extension
- **Dimension mismatches**: Error if vector dimensions don't match configuration

## Next Steps

- Browse individual function documentation for detailed signatures and examples
- See [Use Cases](../use_cases.md) for practical integration patterns
- Check [Monitoring](../monitoring.md) for using statistics functions effectively
