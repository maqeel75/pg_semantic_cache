# evict_expired

Remove expired cache entries.

## Signature

```sql
semantic_cache.evict_expired() RETURNS bigint
```

## Parameters

None

## Returns

- **bigint**: Number of expired entries removed

## Description

Removes all cache entries where `expires_at` is in the past. Should be run regularly as part of maintenance.

## Example

```sql
-- Remove all expired entries
SELECT semantic_cache.evict_expired();
-- Returns: 23 (23 expired entries removed)
```

## Scheduling

```sql
-- Run every 15 minutes with pg_cron
SELECT cron.schedule(
    'cache-evict-expired',
    '*/15 * * * *',
    'SELECT semantic_cache.evict_expired()'
);
```

## See Also

- [evict_lru](evict_lru.md) - Evict by least recently used
- [evict_lfu](evict_lfu.md) - Evict by least frequently used
- [auto_evict](auto_evict.md) - Automatic eviction
