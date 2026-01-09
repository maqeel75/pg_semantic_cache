# Monitoring

Comprehensive guide to monitoring and optimizing pg_semantic_cache performance.

## Quick Health Check

```sql
-- View overall cache health
SELECT * FROM semantic_cache.cache_health;
```

**Sample Output:**
```
 total_entries | expired_entries | total_size | avg_access_count | total_hits | total_misses | hit_rate_pct
---------------+-----------------+------------+------------------+------------+--------------+--------------
          1543 |              23 | 145 MB     |            5.78  |       8921 |         2103 |        80.93
```

## Key Metrics

### 1. Cache Hit Rate

The most important metric for cache effectiveness.

```sql
-- Get current hit rate
SELECT
    total_hits,
    total_misses,
    (total_hits + total_misses) as total_queries,
    hit_rate_percent,
    CASE
        WHEN hit_rate_percent >= 80 THEN '🟢 Excellent'
        WHEN hit_rate_percent >= 60 THEN '🟡 Good'
        WHEN hit_rate_percent >= 40 THEN '🟠 Fair'
        ELSE '🔴 Poor'
    END as rating
FROM semantic_cache.cache_stats();
```

**Target Hit Rates:**
- LLM/AI: 70-85%
- Analytics: 60-75%
- API Caching: 75-90%
- Real-time Data: 40-60%

### 2. Cache Size and Growth

Monitor storage usage and growth trends.

```sql
-- Current size and entry count
SELECT
    COUNT(*) as total_entries,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size,
    pg_size_pretty(AVG(result_size_bytes)::BIGINT) as avg_entry_size,
    pg_size_pretty(MAX(result_size_bytes)::BIGINT) as largest_entry,
    pg_size_pretty(MIN(result_size_bytes)::BIGINT) as smallest_entry
FROM semantic_cache.cache_entries;
```

**Track Growth:**
```sql
-- Create size tracking table
CREATE TABLE IF NOT EXISTS monitoring.cache_size_history (
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    entry_count BIGINT,
    total_bytes BIGINT
);

-- Log current size
INSERT INTO monitoring.cache_size_history (entry_count, total_bytes)
SELECT COUNT(*), SUM(result_size_bytes)
FROM semantic_cache.cache_entries;

-- View growth trend
SELECT
    timestamp,
    entry_count,
    pg_size_pretty(total_bytes) as size,
    entry_count - LAG(entry_count) OVER (ORDER BY timestamp) as entry_delta,
    pg_size_pretty((total_bytes - LAG(total_bytes) OVER (ORDER BY timestamp))::BIGINT) as size_delta
FROM monitoring.cache_size_history
ORDER BY timestamp DESC
LIMIT 20;
```

### 3. Access Patterns

Understand which entries are most valuable.

```sql
-- Most accessed entries
SELECT
    id,
    LEFT(query_text, 60) as query_preview,
    access_count,
    pg_size_pretty(result_size_bytes::BIGINT) as size,
    created_at,
    last_accessed_at,
    EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600 as age_hours
FROM semantic_cache.cache_entries
ORDER BY access_count DESC
LIMIT 20;
```

**Access Distribution:**
```sql
-- Group entries by access frequency
SELECT
    CASE
        WHEN access_count = 0 THEN '0 (Never)'
        WHEN access_count BETWEEN 1 AND 5 THEN '1-5 (Low)'
        WHEN access_count BETWEEN 6 AND 20 THEN '6-20 (Medium)'
        WHEN access_count BETWEEN 21 AND 100 THEN '21-100 (High)'
        ELSE '100+ (Very High)'
    END as access_range,
    COUNT(*) as entry_count,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size,
    ROUND(AVG(access_count), 2) as avg_accesses
FROM semantic_cache.cache_entries
GROUP BY 1
ORDER BY 1;
```

### 4. Entry Age and Freshness

Monitor how old cached entries are.

```sql
-- Age distribution
SELECT
    CASE
        WHEN age_minutes < 5 THEN '< 5 min'
        WHEN age_minutes < 30 THEN '5-30 min'
        WHEN age_minutes < 60 THEN '30-60 min'
        WHEN age_minutes < 360 THEN '1-6 hours'
        WHEN age_minutes < 1440 THEN '6-24 hours'
        ELSE '> 24 hours'
    END as age_range,
    COUNT(*) as entry_count,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size
FROM (
    SELECT
        EXTRACT(EPOCH FROM (NOW() - created_at)) / 60 as age_minutes,
        result_size_bytes
    FROM semantic_cache.cache_entries
) ages
GROUP BY 1
ORDER BY 1;
```

## Built-in Monitoring Views

### cache_health

Real-time cache health metrics.

```sql
SELECT * FROM semantic_cache.cache_health;
```

Includes:
- Total entries and expired entries
- Total cache size
- Average access count
- Hit/miss statistics
- Hit rate percentage

### recent_cache_activity

Most recently accessed entries.

```sql
SELECT * FROM semantic_cache.recent_cache_activity LIMIT 10;
```

Shows:
- Query preview (first 80 chars)
- Access count
- Timestamps (created, last accessed, expires)
- Result size

### cache_by_tag

Entries grouped by tag.

```sql
SELECT * FROM semantic_cache.cache_by_tag;
```

Useful for:
- Understanding cache composition
- Identifying which features use cache most
- Targeted invalidation planning

### cache_access_summary

Hourly access statistics with cost savings.

```sql
SELECT * FROM semantic_cache.cache_access_summary
ORDER BY hour DESC
LIMIT 24;
```

### cost_savings_daily

Daily cost savings breakdown.

```sql
SELECT * FROM semantic_cache.cost_savings_daily
ORDER BY date DESC
LIMIT 30;
```

### top_cached_queries

Top queries by cost savings.

```sql
SELECT * FROM semantic_cache.top_cached_queries
LIMIT 10;
```

## Performance Monitoring

### Query Performance

Track how fast cache lookups are.

```sql
-- Enable timing
\timing on

-- Test lookup speed
SELECT * FROM semantic_cache.get_cached_result(
    (SELECT array_agg(random()::float4)::text FROM generate_series(1, 1536)),
    0.95
);

-- Expected: < 5ms
```

**Benchmarking:**
```sql
-- Benchmark cache lookups
DO $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    test_embedding TEXT;
    i INTEGER;
BEGIN
    -- Generate test embedding
    SELECT array_agg(random()::float4)::text INTO test_embedding
    FROM generate_series(1, 1536);

    -- Run 100 lookups
    start_time := clock_timestamp();

    FOR i IN 1..100 LOOP
        PERFORM * FROM semantic_cache.get_cached_result(test_embedding, 0.95);
    END LOOP;

    end_time := clock_timestamp();

    RAISE NOTICE 'Average lookup time: % ms',
        ROUND((EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 100)::NUMERIC, 2);
END $$;
```

### Index Performance

Monitor vector index effectiveness.

```sql
-- Check index usage
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as times_used,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'semantic_cache'
ORDER BY idx_scan DESC;
```

**Index Statistics:**
```sql
-- Detailed index info
SELECT
    i.indexrelname as index_name,
    t.tablename as table_name,
    pg_size_pretty(pg_relation_size(i.indexrelid)) as index_size,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    ROUND(idx_tup_read::NUMERIC / NULLIF(idx_scan, 0), 2) as tuples_per_scan
FROM pg_stat_user_indexes i
JOIN pg_stat_user_tables t ON i.relid = t.relid
WHERE i.schemaname = 'semantic_cache';
```

### PostgreSQL Statistics

```sql
-- Table statistics
SELECT
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples
FROM pg_stat_user_tables
WHERE schemaname = 'semantic_cache';
```

## Alerting

### Set Up Alerts

```sql
-- Create alert function
CREATE OR REPLACE FUNCTION monitoring.check_cache_alerts()
RETURNS TABLE(
    alert_level TEXT,
    alert_type TEXT,
    message TEXT,
    metric_value NUMERIC
) AS $$
BEGIN
    -- Alert: Low hit rate
    RETURN QUERY
    SELECT
        'WARNING'::TEXT,
        'low_hit_rate'::TEXT,
        'Cache hit rate below 60%'::TEXT,
        hit_rate_percent::NUMERIC
    FROM semantic_cache.cache_stats()
    WHERE hit_rate_percent < 60;

    -- Alert: Cache too large
    RETURN QUERY
    SELECT
        'WARNING'::TEXT,
        'cache_size'::TEXT,
        'Cache size exceeding 80% of limit'::TEXT,
        (SUM(result_size_bytes) / 1024 / 1024)::NUMERIC
    FROM semantic_cache.cache_entries
    HAVING SUM(result_size_bytes) / 1024 / 1024 > 800;  -- If max is 1000MB

    -- Alert: Too many expired entries
    RETURN QUERY
    SELECT
        'INFO'::TEXT,
        'expired_entries'::TEXT,
        'More than 10% entries expired'::TEXT,
        COUNT(*)::NUMERIC
    FROM semantic_cache.cache_entries
    WHERE expires_at <= NOW()
    HAVING COUNT(*) > (SELECT COUNT(*) * 0.1 FROM semantic_cache.cache_entries);

    -- Alert: No activity
    RETURN QUERY
    SELECT
        'CRITICAL'::TEXT,
        'no_activity'::TEXT,
        'No cache activity in last hour'::TEXT,
        0::NUMERIC
    FROM semantic_cache.cache_entries
    WHERE last_accessed_at < NOW() - INTERVAL '1 hour'
    HAVING COUNT(*) = (SELECT COUNT(*) FROM semantic_cache.cache_entries);
END;
$$ LANGUAGE plpgsql;

-- Check for alerts
SELECT * FROM monitoring.check_cache_alerts();
```

### Schedule Alert Checks

```sql
-- With pg_cron (if available)
SELECT cron.schedule(
    'cache-alerts',
    '*/15 * * * *',  -- Every 15 minutes
    $$
    DO $$
    DECLARE
        alert RECORD;
    BEGIN
        FOR alert IN SELECT * FROM monitoring.check_cache_alerts() LOOP
            RAISE WARNING '[%] %: % (value: %)',
                alert.alert_level,
                alert.alert_type,
                alert.message,
                alert.metric_value;
            -- Add your notification logic here (email, Slack, etc.)
        END LOOP;
    END $$;
    $$
);
```

## Integration with Monitoring Tools

### Prometheus/Grafana

Export metrics in Prometheus format.

```sql
-- Create metrics export function
CREATE OR REPLACE FUNCTION monitoring.prometheus_metrics()
RETURNS TEXT AS $$
DECLARE
    stats RECORD;
    result TEXT := '';
BEGIN
    SELECT * INTO stats FROM semantic_cache.cache_stats();

    result := result || '# HELP cache_entries_total Total number of cached entries' || E'\n';
    result := result || '# TYPE cache_entries_total gauge' || E'\n';
    result := result || 'cache_entries_total ' || stats.total_entries || E'\n';

    result := result || '# HELP cache_hits_total Total cache hits' || E'\n';
    result := result || '# TYPE cache_hits_total counter' || E'\n';
    result := result || 'cache_hits_total ' || stats.total_hits || E'\n';

    result := result || '# HELP cache_misses_total Total cache misses' || E'\n';
    result := result || '# TYPE cache_misses_total counter' || E'\n';
    result := result || 'cache_misses_total ' || stats.total_misses || E'\n';

    result := result || '# HELP cache_hit_rate Cache hit rate percentage' || E'\n';
    result := result || '# TYPE cache_hit_rate gauge' || E'\n';
    result := result || 'cache_hit_rate ' || stats.hit_rate_percent || E'\n';

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Export metrics
SELECT monitoring.prometheus_metrics();
```

### Application Logging

```python
import psycopg2
import logging

logger = logging.getLogger(__name__)

def log_cache_metrics():
    """Log cache metrics to application logs"""
    conn = psycopg2.connect("dbname=mydb")
    cur = conn.cursor()

    cur.execute("SELECT * FROM semantic_cache.cache_stats()")
    stats = cur.fetchone()

    logger.info(
        "Cache Stats - Entries: %d, Hits: %d, Misses: %d, Hit Rate: %.2f%%",
        stats[0], stats[1], stats[2], stats[3]
    )

    # Also log to metrics service (DataDog, New Relic, etc.)
    # metrics.gauge('cache.entries', stats[0])
    # metrics.counter('cache.hits', stats[1])
    # metrics.counter('cache.misses', stats[2])
    # metrics.gauge('cache.hit_rate', stats[3])
```

## Optimization Guidelines

### When Hit Rate is Low (< 60%)

1. **Lower similarity threshold**
   ```sql
   -- Try 0.90 instead of 0.95
   SELECT * FROM semantic_cache.get_cached_result('[...]'::text, 0.90);
   ```

2. **Check TTL settings**
   ```sql
   -- Entries expiring too quickly?
   SELECT COUNT(*), AVG(EXTRACT(EPOCH FROM (expires_at - created_at)))
   FROM semantic_cache.cache_entries
   WHERE expires_at IS NOT NULL;
   ```

3. **Verify embedding quality**
   ```sql
   -- Look at similarity scores
   SELECT
       query_text,
       (1 - (query_embedding <=> (SELECT query_embedding FROM semantic_cache.cache_entries LIMIT 1))) as similarity
   FROM semantic_cache.cache_entries
   ORDER BY similarity DESC
   LIMIT 10;
   ```

### When Cache Size is Growing Too Fast

1. **Reduce TTL**
   ```sql
   -- Cache for shorter periods
   UPDATE semantic_cache.cache_config
   SET value = '1800'  -- 30 minutes instead of 1 hour
   WHERE key = 'default_ttl_seconds';
   ```

2. **Enable aggressive eviction**
   ```sql
   -- Lower max size
   UPDATE semantic_cache.cache_config
   SET value = '500'
   WHERE key = 'max_cache_size_mb';

   -- Run auto-eviction
   SELECT semantic_cache.auto_evict();
   ```

3. **Remove low-value entries**
   ```sql
   -- Delete entries with 0 accesses older than 1 hour
   DELETE FROM semantic_cache.cache_entries
   WHERE access_count = 0
     AND created_at < NOW() - INTERVAL '1 hour';
   ```

### When Lookups are Slow (> 10ms)

1. **Rebuild index with more lists** (for IVFFlat)
   ```sql
   DROP INDEX semantic_cache.idx_cache_entries_embedding;
   CREATE INDEX idx_cache_entries_embedding
   ON semantic_cache.cache_entries
   USING ivfflat (query_embedding vector_cosine_ops)
   WITH (lists = 1000);
   ```

2. **Consider HNSW index**
   ```sql
   SELECT semantic_cache.set_index_type('hnsw');
   SELECT semantic_cache.rebuild_index();
   ```

3. **Increase work_mem**
   ```sql
   -- In postgresql.conf or session
   SET work_mem = '512MB';
   ```

## Regular Maintenance Checklist

Daily:
- [ ] Check hit rate: `SELECT * FROM semantic_cache.cache_stats()`
- [ ] Review cache size: `SELECT * FROM semantic_cache.cache_health`
- [ ] Clear expired: `SELECT semantic_cache.evict_expired()`

Weekly:
- [ ] Review top queries: `SELECT * FROM semantic_cache.recent_cache_activity`
- [ ] Check for alerts: `SELECT * FROM monitoring.check_cache_alerts()`
- [ ] Analyze tables: `ANALYZE semantic_cache.cache_entries`

Monthly:
- [ ] Review configuration settings
- [ ] Optimize index if needed
- [ ] Archive old access logs
- [ ] Review cost savings: `SELECT * FROM semantic_cache.get_cost_savings(30)`

## See Also

- [Functions Reference](functions/index.md) - All monitoring functions
- [Configuration](configuration.md) - Tuning parameters
- [Use Cases](use_cases.md) - Monitoring patterns in practice
