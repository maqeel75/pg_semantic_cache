# cache_stats

Get comprehensive cache statistics including hits, misses, and hit rate.

## Signature

```sql
semantic_cache.cache_stats()
RETURNS TABLE(
    total_entries bigint,
    total_hits bigint,
    total_misses bigint,
    hit_rate_percent float4
)
```

## Parameters

None

## Returns

Returns a table with a single row containing:

| Column | Type | Description |
|--------|------|-------------|
| `total_entries` | bigint | Current number of cached entries |
| `total_hits` | bigint | Cumulative cache hits since initialization |
| `total_misses` | bigint | Cumulative cache misses since initialization |
| `hit_rate_percent` | float4 | Hit rate as percentage (0-100) |

## Description

This function provides a comprehensive view of cache performance by querying both the `cache_entries` and `cache_metadata` tables. Statistics are automatically updated with every `get_cached_result()` call.

### Calculation

```
hit_rate_percent = (total_hits / (total_hits + total_misses)) * 100
```

If no queries have been executed, `hit_rate_percent` returns `0.0`.

## Examples

### Basic Usage

```sql
SELECT * FROM semantic_cache.cache_stats();
```

**Sample Output:**
```
 total_entries | total_hits | total_misses | hit_rate_percent
---------------+------------+--------------+------------------
          1543 |       8921 |         2103 |            80.93
```

### Monitoring Over Time

```sql
-- Create a monitoring table
CREATE TABLE my_app.cache_monitoring (
    timestamp timestamptz DEFAULT NOW(),
    total_entries bigint,
    total_hits bigint,
    total_misses bigint,
    hit_rate_percent float4
);

-- Log current stats
INSERT INTO my_app.cache_monitoring (
    total_entries, total_hits, total_misses, hit_rate_percent
)
SELECT * FROM semantic_cache.cache_stats();

-- View trends
SELECT
    timestamp,
    hit_rate_percent,
    total_entries,
    (total_hits - LAG(total_hits) OVER (ORDER BY timestamp)) as hits_since_last,
    (total_misses - LAG(total_misses) OVER (ORDER BY timestamp)) as misses_since_last
FROM my_app.cache_monitoring
ORDER BY timestamp DESC
LIMIT 24;
```

### Formatted Display

```sql
-- Human-readable cache statistics
SELECT
    total_entries as "Cache Entries",
    TO_CHAR(total_hits, '999,999,999') as "Total Hits",
    TO_CHAR(total_misses, '999,999,999') as "Total Misses",
    ROUND(hit_rate_percent, 2) || '%' as "Hit Rate",
    CASE
        WHEN hit_rate_percent >= 80 THEN '✓ Excellent'
        WHEN hit_rate_percent >= 60 THEN '~ Good'
        WHEN hit_rate_percent >= 40 THEN '! Fair'
        ELSE '✗ Poor'
    END as "Performance"
FROM semantic_cache.cache_stats();
```

### Integration with Application Metrics

```sql
-- Export for Prometheus/Grafana
CREATE OR REPLACE FUNCTION my_app.cache_metrics()
RETURNS TABLE(
    metric_name text,
    metric_value numeric,
    metric_type text
) AS $$
    SELECT 'cache_entries_total', total_entries::numeric, 'gauge'
    FROM semantic_cache.cache_stats()
    UNION ALL
    SELECT 'cache_hits_total', total_hits::numeric, 'counter'
    FROM semantic_cache.cache_stats()
    UNION ALL
    SELECT 'cache_misses_total', total_misses::numeric, 'counter'
    FROM semantic_cache.cache_stats()
    UNION ALL
    SELECT 'cache_hit_rate', hit_rate_percent::numeric, 'gauge'
    FROM semantic_cache.cache_stats();
$$ LANGUAGE SQL;
```

## Performance Interpretation

### Target Hit Rates by Use Case

| Use Case | Target Hit Rate | Typical Rate |
|----------|----------------|--------------|
| LLM/AI Queries | 70-85% | 75% |
| Analytics | 60-75% | 65% |
| Real-time Data | 40-60% | 50% |
| API Results | 75-90% | 80% |

### What Different Hit Rates Mean

**80%+ Hit Rate** 🎯
- Excellent performance
- Cache is well-tuned
- Significant cost savings
- Continue monitoring

```sql
-- If hit rate > 80%, you're doing great
SELECT
    CASE
        WHEN hit_rate_percent >= 80 THEN 'Optimal - maintain current settings'
        ELSE 'Needs tuning'
    END as recommendation
FROM semantic_cache.cache_stats();
```

**60-80% Hit Rate** ✓
- Good performance
- Room for improvement
- Consider lowering similarity threshold
- Review TTL settings

**40-60% Hit Rate** ⚠
- Marginal benefit
- Review cache strategy
- Check similarity threshold (might be too high)
- Verify embedding quality

**< 40% Hit Rate** ❌
- Poor performance
- Cache may not be beneficial
- Investigate root cause
- Consider different caching strategy

## Monitoring Patterns

### Daily Health Check

```sql
-- Daily cache health report
WITH current_stats AS (
    SELECT * FROM semantic_cache.cache_stats()
),
cache_size AS (
    SELECT pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size
    FROM semantic_cache.cache_entries
),
expired_count AS (
    SELECT COUNT(*) as expired
    FROM semantic_cache.cache_entries
    WHERE expires_at <= NOW()
)
SELECT
    cs.*,
    cz.total_size,
    ec.expired as expired_entries,
    CASE
        WHEN cs.hit_rate_percent >= 70 THEN 'Healthy'
        WHEN cs.hit_rate_percent >= 50 THEN 'Warning'
        ELSE 'Critical'
    END as health_status
FROM current_stats cs
CROSS JOIN cache_size cz
CROSS JOIN expired_count ec;
```

### Alert on Poor Performance

```sql
-- Alert if hit rate drops below threshold
DO $$
DECLARE
    stats RECORD;
BEGIN
    SELECT * INTO stats FROM semantic_cache.cache_stats();

    IF stats.hit_rate_percent < 50 THEN
        RAISE WARNING 'Cache hit rate below 50%%: %',
            stats.hit_rate_percent;
        -- Send alert (implement your alerting logic)
    END IF;
END $$;
```

### Periodic Cleanup Suggestion

```sql
-- Suggest cleanup if too many expired entries
WITH stats AS (
    SELECT * FROM semantic_cache.cache_stats()
),
expired AS (
    SELECT COUNT(*) as count
    FROM semantic_cache.cache_entries
    WHERE expires_at <= NOW()
)
SELECT
    s.total_entries,
    e.count as expired_entries,
    ROUND((e.count::numeric / NULLIF(s.total_entries, 0)) * 100, 2) as expired_percent,
    CASE
        WHEN (e.count::numeric / NULLIF(s.total_entries, 0)) > 0.10
        THEN 'Run: SELECT semantic_cache.evict_expired();'
        ELSE 'No action needed'
    END as recommendation
FROM stats s
CROSS JOIN expired e;
```

## Comparing with Application Metrics

### Cost Savings Calculation

```sql
-- Calculate cost savings from caching
WITH stats AS (
    SELECT * FROM semantic_cache.cache_stats()
)
SELECT
    total_hits,
    total_misses,
    (total_hits + total_misses) as total_queries,
    hit_rate_percent,
    -- Assuming $0.02 per query without cache
    ROUND((total_hits * 0.02)::numeric, 2) as "savings_usd",
    ROUND(((total_hits + total_misses) * 0.02)::numeric, 2) as "cost_without_cache_usd"
FROM stats;
```

### Cache Effectiveness Score

```sql
-- Custom effectiveness metric
WITH stats AS (
    SELECT * FROM semantic_cache.cache_stats()
),
cache_info AS (
    SELECT
        COUNT(*) as entries,
        AVG(access_count) as avg_accesses
    FROM semantic_cache.cache_entries
)
SELECT
    s.hit_rate_percent,
    c.avg_accesses,
    -- Effectiveness: hit rate * average accesses per entry
    ROUND((s.hit_rate_percent * c.avg_accesses / 100)::numeric, 2) as effectiveness_score
FROM stats s
CROSS JOIN cache_info c;
```

## Resetting Statistics

Statistics persist across restarts. To reset:

```sql
-- Reset hit/miss counters (use with caution!)
UPDATE semantic_cache.cache_metadata
SET total_hits = 0,
    total_misses = 0
WHERE id = 1;

-- Verify reset
SELECT * FROM semantic_cache.cache_stats();
```

!!! warning
    Resetting statistics loses historical data. Consider logging stats before reset.

## Related Functions

For more specific metrics:

```sql
-- Just the hit rate percentage
SELECT semantic_cache.cache_hit_rate();

-- Detailed cache health
SELECT * FROM semantic_cache.cache_health;

-- Recent activity
SELECT * FROM semantic_cache.recent_cache_activity;

-- Cost analysis (if using cost tracking)
SELECT * FROM semantic_cache.get_cost_savings(30);  -- Last 30 days
```

## See Also

- [cache_hit_rate](cache_hit_rate.md) - Get only the hit rate percentage
- [get_cost_savings](get_cost_savings.md) - Detailed cost analysis
- [Monitoring](../monitoring.md) - Complete monitoring guide
- Views: `cache_health`, `cache_access_summary`, `cost_savings_daily`
