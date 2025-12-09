# Logging & Cost Tracking - Quick Reference

## Setup (One-Time)

```sql
-- Set your query cost (e.g., OpenAI API cost)
SELECT semantic_cache.set_config('default_query_cost', '0.0001');

-- Enable logging (default: enabled)
SELECT semantic_cache.set_config('enable_access_logging', 'true');

-- Set retention period (default: 30 days)
SELECT semantic_cache.set_config('log_retention_days', '30');
```

## Key Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `get_cost_savings(hours)` | Cost report for time period | `SELECT * FROM get_cost_savings(24)` |
| `log_cache_access(...)` | Manual logging | Usually automatic, see docs |
| `cleanup_access_logs()` | Delete old logs | `SELECT cleanup_access_logs()` |

## Essential Views

| View | Shows | Use Case |
|------|-------|----------|
| `cost_savings_daily` | Daily summary | Track trends over time |
| `cost_savings_hourly` | Hourly breakdown | Identify peak usage |
| `cost_savings_by_tag` | Savings by tag | Find most valuable caches |
| `recent_access_log` | Last 100 accesses | Debugging & monitoring |

## Quick Queries

### See Today's Savings
```sql
SELECT
    hits,
    misses,
    hit_rate_pct,
    total_cost_saved
FROM semantic_cache.cost_savings_daily
WHERE date = CURRENT_DATE;
```

### Last 24 Hours Report
```sql
SELECT * FROM semantic_cache.get_cost_savings(24);
```

### Check If Cache Is Working
```sql
SELECT
    cache_hit as status,
    COUNT(*) as count,
    ROUND(SUM(cost_saved)::numeric, 4) as saved
FROM semantic_cache.cache_access_log
WHERE accessed_at >= NOW() - INTERVAL '1 hour'
GROUP BY cache_hit;
```

### Top Cost-Saving Tags
```sql
SELECT tag, total_cost_saved
FROM semantic_cache.cost_savings_by_tag
ORDER BY total_cost_saved DESC
LIMIT 5;
```

### Overall Statistics
```sql
SELECT
    total_hits,
    total_misses,
    ROUND(total_cost_saved::numeric, 2) as total_saved,
    ROUND((total_hits::numeric / NULLIF(total_hits + total_misses, 0) * 100), 2) as hit_rate
FROM semantic_cache.cache_metadata
WHERE id = 1;
```

## Monitoring Dashboard Query

```sql
SELECT
    -- Last 24 hours
    (SELECT COUNT(*) FILTER (WHERE cache_hit = true)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as hits_24h,

    (SELECT ROUND(SUM(cost_saved)::numeric, 4)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as saved_24h,

    -- All time
    (SELECT total_cost_saved FROM semantic_cache.cache_metadata WHERE id = 1) as saved_all_time,

    -- Current cache size
    (SELECT COUNT(*) FROM semantic_cache.cache_entries) as cache_entries;
```

## Automated Cleanup (pg_cron)

```sql
-- Install pg_cron
CREATE EXTENSION pg_cron;

-- Schedule daily cleanup at 2 AM
SELECT cron.schedule(
    'semantic-cache-log-cleanup',
    '0 2 * * *',
    $$SELECT semantic_cache.cleanup_access_logs()$$
);
```

## Export Report

```sql
-- Export last 30 days to CSV
COPY (
    SELECT * FROM semantic_cache.cost_savings_daily
    WHERE date >= CURRENT_DATE - 30
    ORDER BY date
) TO '/tmp/cache_report.csv' WITH CSV HEADER;
```

## Disable/Enable Logging

```sql
-- Disable (stops creating log entries)
SELECT semantic_cache.set_config('enable_access_logging', 'false');

-- Re-enable
SELECT semantic_cache.set_config('enable_access_logging', 'true');
```

## Manual Cleanup

```sql
-- Clean up using retention policy
SELECT semantic_cache.cleanup_access_logs();

-- Or manually delete old entries
DELETE FROM semantic_cache.cache_access_log
WHERE accessed_at < NOW() - INTERVAL '7 days';
```

## Troubleshooting

### No logs appearing?
```sql
-- Check if logging is enabled
SELECT value FROM semantic_cache.cache_config
WHERE key = 'enable_access_logging';
```

### Wrong cost calculations?
```sql
-- Check your cost setting
SELECT value FROM semantic_cache.cache_config
WHERE key = 'default_query_cost';
```

### Too much storage used?
```sql
-- See log table size
SELECT pg_size_pretty(pg_total_relation_size('semantic_cache.cache_access_log'));

-- Clean up
SELECT semantic_cache.cleanup_access_logs();
```

## Access Log Table Structure

```sql
cache_access_log:
  ├─ id               (bigserial, primary key)
  ├─ cache_entry_id   (bigint, NULL for misses)
  ├─ accessed_at      (timestamptz, when accessed)
  ├─ cache_hit        (boolean, hit or miss)
  ├─ similarity_score (real, for hits only)
  ├─ query_text       (text, optional)
  ├─ query_cost       (numeric, cost of query)
  ├─ cost_saved       (numeric, = query_cost for hits)
  ├─ response_time_ms (integer, optional)
  ├─ user_context     (text, optional)
  └─ tags             (text[], optional)
```

## For More Details

- **Complete Guide**: See `LOGGING_GUIDE.md`
- **Examples**: See `examples/logging_examples.sql`
- **Tests**: See `test/test_logging.sql`
- **Changelog**: See `CHANGELOG_LOGGING.md`
