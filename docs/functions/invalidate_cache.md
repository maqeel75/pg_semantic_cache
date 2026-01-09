# invalidate_cache

Invalidate cache entries by pattern or tag.

## Signature

```sql
semantic_cache.invalidate_cache(
    pattern text DEFAULT NULL,
    tag text DEFAULT NULL
) RETURNS bigint
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pattern` | text | NULL | SQL pattern to match against query_text (using LIKE) |
| `tag` | text | NULL | Tag to match for bulk invalidation |

!!! note
    At least one parameter must be provided. If both are provided, entries matching EITHER condition are invalidated.

## Returns

- **bigint**: Number of cache entries invalidated

## Description

This function removes cached entries based on pattern matching or tags, useful for invalidating stale data when source data changes.

## Examples

### Invalidate by Pattern

```sql
-- Invalidate all queries containing "revenue"
SELECT semantic_cache.invalidate_cache(
    pattern := '%revenue%',
    tag := NULL
);
-- Returns: 15 (15 entries invalidated)

-- Invalidate all order queries
SELECT semantic_cache.invalidate_cache(
    pattern := '%orders%',
    tag := NULL
);
```

### Invalidate by Tag

```sql
-- Invalidate all dashboard queries
SELECT semantic_cache.invalidate_cache(
    pattern := NULL,
    tag := 'dashboard'
);

-- Invalidate all user-specific cache
SELECT semantic_cache.invalidate_cache(
    pattern := NULL,
    tag := 'user_12345'
);
```

### Invalidate by Pattern OR Tag

```sql
-- Invalidate entries matching either condition
SELECT semantic_cache.invalidate_cache(
    pattern := '%customer%',
    tag := 'stale'
);
```

## Common Use Cases

### Invalidate After Data Update

```sql
-- After updating orders table
UPDATE orders SET status = 'completed' WHERE id = 123;

-- Invalidate related cache entries
SELECT semantic_cache.invalidate_cache(pattern := '%orders%');
```

### User Logout

```sql
-- Clear user-specific cached data
SELECT semantic_cache.invalidate_cache(tag := 'user_' || user_id);
```

### Scheduled Invalidation

```sql
-- Invalidate analytical queries nightly
SELECT cron.schedule(
    'invalidate-analytics',
    '0 0 * * *',
    $$SELECT semantic_cache.invalidate_cache(tag := 'analytics')$$
);
```

## See Also

- [cache_query](cache_query.md) - Store results with tags
- [clear_cache](clear_cache.md) - Remove all entries
- [evict_expired](evict_expired.md) - Remove expired entries
