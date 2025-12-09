-- pg_semantic_cache Logging and Cost Tracking Examples
-- Demonstrates how to use the logging mechanism to track cache hits/misses and cost savings

-- ============================================================================
-- SETUP: Configure Cost Tracking
-- ============================================================================

-- Set the default cost per query (e.g., OpenAI API cost per query)
-- For example, if embedding + query costs $0.0001 per request:
SELECT semantic_cache.set_config('default_query_cost', '0.0001');

-- Enable access logging (enabled by default)
SELECT semantic_cache.set_config('enable_access_logging', 'true');

-- Set log retention period (days)
SELECT semantic_cache.set_config('log_retention_days', '30');

-- ============================================================================
-- EXAMPLE 1: Cache a Query with Automatic Logging
-- ============================================================================

-- Cache a query - logging happens automatically when get_cached_result is called
SELECT semantic_cache.cache_query(
    query_text := 'What are the top products by revenue this quarter?',
    query_embedding := (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
    result_data := '{"products": [{"name": "Widget A", "revenue": 50000}, {"name": "Widget B", "revenue": 35000}]}'::jsonb,
    ttl_seconds := 3600,
    tags := ARRAY['analytics', 'revenue']
);

-- Try to retrieve it - this will log a HIT
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
    similarity_threshold := 0.85,
    max_age_seconds := NULL
);

-- Try to retrieve with different embedding - this will log a MISS
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := (SELECT array_agg((random() * 2)::float4) FROM generate_series(1, 1536))::vector,
    similarity_threshold := 0.95,
    max_age_seconds := NULL
);

-- ============================================================================
-- EXAMPLE 2: Manual Logging with Custom Cost
-- ============================================================================

-- Log a cache access event manually with specific cost
SELECT semantic_cache.log_cache_access(
    cache_entry_id := 1,
    cache_hit := true,
    similarity_score := 0.98,
    query_text := 'What are sales trends?',
    query_cost := 0.00025,  -- Custom cost for this specific query
    user_context := 'user_id:12345, app:analytics_dashboard',
    tags := ARRAY['sales', 'trends']
);

-- Log a miss with context
SELECT semantic_cache.log_cache_access(
    cache_entry_id := NULL,
    cache_hit := false,
    similarity_score := NULL,
    query_text := 'Show me customer churn rate',
    query_cost := 0.00025,
    user_context := 'user_id:67890, app:crm',
    tags := ARRAY['customers', 'churn']
);

-- ============================================================================
-- EXAMPLE 3: View Access Logs
-- ============================================================================

-- View recent access log
SELECT * FROM semantic_cache.recent_access_log
LIMIT 20;

-- View all access events from the last hour
SELECT
    accessed_at,
    cache_hit,
    similarity_score,
    query_preview,
    cost_saved,
    result
FROM semantic_cache.recent_access_log
WHERE accessed_at > NOW() - INTERVAL '1 hour'
ORDER BY accessed_at DESC;

-- ============================================================================
-- EXAMPLE 4: Cost Savings Analysis
-- ============================================================================

-- Get cost savings for the last 24 hours
SELECT * FROM semantic_cache.get_cost_savings(24);

-- Get cost savings for the last 7 days (168 hours)
SELECT * FROM semantic_cache.get_cost_savings(168);

-- View daily cost savings summary
SELECT
    date,
    total_queries,
    hits,
    misses,
    hit_rate_pct,
    total_cost_saved,
    total_query_cost,
    savings_pct
FROM semantic_cache.cost_savings_daily
WHERE date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY date DESC;

-- View hourly cost savings for today
SELECT
    hour,
    hits,
    misses,
    hit_rate_pct,
    total_cost_saved,
    avg_cost_saved_per_hit
FROM semantic_cache.cost_savings_hourly
WHERE hour >= DATE_TRUNC('day', NOW())
ORDER BY hour DESC;

-- ============================================================================
-- EXAMPLE 5: Cost Savings by Tag
-- ============================================================================

-- See which tags have the best cost savings
SELECT
    tag,
    hits,
    misses,
    hit_rate_pct,
    total_cost_saved
FROM semantic_cache.cost_savings_by_tag
ORDER BY total_cost_saved DESC
LIMIT 10;

-- ============================================================================
-- EXAMPLE 6: Overall Cache Statistics with Cost
-- ============================================================================

-- View cache statistics including total cost saved
SELECT * FROM semantic_cache.cache_stats();

-- View total cost saved from metadata
SELECT
    total_hits,
    total_misses,
    total_cost_saved,
    ROUND((total_hits::NUMERIC / NULLIF(total_hits + total_misses, 0) * 100)::NUMERIC, 2) as hit_rate_pct
FROM semantic_cache.cache_metadata
WHERE id = 1;

-- ============================================================================
-- EXAMPLE 7: Cost Analysis Queries
-- ============================================================================

-- Calculate ROI: How much money saved vs potential cost
SELECT
    SUM(cost_saved) as total_saved,
    SUM(query_cost) as total_potential_cost,
    ROUND((SUM(cost_saved) / NULLIF(SUM(query_cost), 0) * 100)::NUMERIC, 2) as savings_percentage
FROM semantic_cache.cache_access_log
WHERE accessed_at >= NOW() - INTERVAL '30 days';

-- Find most expensive queries that were cached
SELECT
    query_preview,
    cache_hit,
    query_cost,
    cost_saved,
    accessed_at
FROM semantic_cache.recent_access_log
WHERE cache_hit = true
ORDER BY cost_saved DESC
LIMIT 10;

-- Analyze cache performance by hour of day
SELECT
    EXTRACT(HOUR FROM accessed_at) as hour_of_day,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE cache_hit = true) as hits,
    ROUND((COUNT(*) FILTER (WHERE cache_hit = true)::NUMERIC / COUNT(*) * 100)::NUMERIC, 2) as hit_rate_pct,
    SUM(cost_saved) as total_saved
FROM semantic_cache.cache_access_log
WHERE accessed_at >= NOW() - INTERVAL '7 days'
GROUP BY EXTRACT(HOUR FROM accessed_at)
ORDER BY hour_of_day;

-- ============================================================================
-- EXAMPLE 8: Clean Up Old Logs
-- ============================================================================

-- Clean up access logs older than retention period
SELECT semantic_cache.cleanup_access_logs();

-- Manually delete logs older than 60 days (override retention policy)
DELETE FROM semantic_cache.cache_access_log
WHERE accessed_at < NOW() - INTERVAL '60 days';

-- ============================================================================
-- EXAMPLE 9: Monitoring Dashboard Query
-- ============================================================================

-- Create a comprehensive monitoring view
SELECT
    -- Current stats
    (SELECT COUNT(*) FROM semantic_cache.cache_entries) as total_cache_entries,

    -- Last 24 hours performance
    (SELECT COUNT(*) FILTER (WHERE cache_hit = true)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as hits_24h,

    (SELECT COUNT(*) FILTER (WHERE cache_hit = false)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as misses_24h,

    (SELECT ROUND((COUNT(*) FILTER (WHERE cache_hit = true)::NUMERIC /
                   NULLIF(COUNT(*), 0) * 100)::NUMERIC, 2)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as hit_rate_24h,

    (SELECT COALESCE(SUM(cost_saved), 0)
     FROM semantic_cache.cache_access_log
     WHERE accessed_at >= NOW() - INTERVAL '24 hours') as cost_saved_24h,

    -- All time stats
    (SELECT total_cost_saved FROM semantic_cache.cache_metadata WHERE id = 1) as total_cost_saved_all_time,

    (SELECT total_hits FROM semantic_cache.cache_metadata WHERE id = 1) as total_hits_all_time,

    (SELECT total_misses FROM semantic_cache.cache_metadata WHERE id = 1) as total_misses_all_time;

-- ============================================================================
-- EXAMPLE 10: Setting Up Automated Log Cleanup (with pg_cron)
-- ============================================================================

-- Requires pg_cron extension
-- CREATE EXTENSION pg_cron;

-- Schedule automatic log cleanup daily at 2 AM
-- SELECT cron.schedule(
--     'semantic-cache-log-cleanup',
--     '0 2 * * *',
--     $$SELECT semantic_cache.cleanup_access_logs()$$
-- );

-- View scheduled jobs
-- SELECT * FROM cron.job WHERE jobname LIKE 'semantic-cache%';

-- ============================================================================
-- EXAMPLE 11: Export Cost Savings Report
-- ============================================================================

-- Generate a CSV-ready report for the last 30 days
COPY (
    SELECT
        date,
        total_queries,
        hits,
        misses,
        hit_rate_pct,
        total_cost_saved,
        total_query_cost,
        savings_pct
    FROM semantic_cache.cost_savings_daily
    WHERE date >= CURRENT_DATE - INTERVAL '30 days'
    ORDER BY date DESC
) TO '/tmp/cache_cost_savings_report.csv' WITH CSV HEADER;

-- ============================================================================
-- EXAMPLE 12: Real-Time Cost Tracking
-- ============================================================================

-- Create a function to track cost in real-time for your application
CREATE OR REPLACE FUNCTION track_query_cost(
    p_query_text TEXT,
    p_embedding vector(1536),
    p_actual_cost NUMERIC DEFAULT NULL
)
RETURNS TABLE(
    was_cache_hit BOOLEAN,
    result_data JSONB,
    cost_saved NUMERIC,
    response_time_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMP;
    v_end_time TIMESTAMP;
    v_cache_result RECORD;
    v_cost NUMERIC;
BEGIN
    v_start_time := clock_timestamp();

    -- Get default cost if not provided
    IF p_actual_cost IS NULL THEN
        SELECT value::NUMERIC INTO v_cost
        FROM semantic_cache.cache_config
        WHERE key = 'default_query_cost';
    ELSE
        v_cost := p_actual_cost;
    END IF;

    -- Try to get from cache
    SELECT * INTO v_cache_result
    FROM semantic_cache.get_cached_result(p_embedding::text, 0.95, NULL);

    v_end_time := clock_timestamp();

    -- Return results
    was_cache_hit := v_cache_result.hit;
    result_data := v_cache_result.result_data;
    cost_saved := CASE WHEN v_cache_result.hit THEN v_cost ELSE 0 END;
    response_time_ms := EXTRACT(MILLISECONDS FROM (v_end_time - v_start_time))::INTEGER;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Use the tracking function
SELECT * FROM track_query_cost(
    'What is the revenue forecast?',
    (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
    0.0002
);
