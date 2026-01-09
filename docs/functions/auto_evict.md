# auto_evict

Automatically evict entries based on configured policy.

## Signature

```sql
semantic_cache.auto_evict() RETURNS bigint
```

## Returns

- **bigint**: Number of entries evicted

## Description

Evicts entries based on the configured `eviction_policy` setting (LRU, LFU, or TTL).

## Example

```sql
-- Run automatic eviction
SELECT semantic_cache.auto_evict();
```
