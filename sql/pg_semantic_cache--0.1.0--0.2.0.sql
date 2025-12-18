-- pg_semantic_cache--0.1.0--0.2.0.sql
-- Upgrade script from version 0.1.0 to 0.2.0
-- Adds logging and cost tracking features

-- Add total_cost_saved column to cache_metadata table
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'semantic_cache'
        AND table_name = 'cache_metadata'
        AND column_name = 'total_cost_saved'
    ) THEN
        ALTER TABLE semantic_cache.cache_metadata
        ADD COLUMN total_cost_saved NUMERIC(12,6) DEFAULT 0.0;
    END IF;
END $$;

-- Create cache_access_log table for logging
CREATE TABLE IF NOT EXISTS semantic_cache.cache_access_log (
    id BIGSERIAL PRIMARY KEY,
    access_time TIMESTAMPTZ DEFAULT NOW(),
    query_hash TEXT,
    cache_hit BOOLEAN NOT NULL,
    similarity_score REAL,
    query_cost NUMERIC(10,6),
    cost_saved NUMERIC(10,6)
);

-- Create indexes for cache_access_log
CREATE INDEX IF NOT EXISTS idx_access_log_time
    ON semantic_cache.cache_access_log(access_time);
CREATE INDEX IF NOT EXISTS idx_access_log_hash
    ON semantic_cache.cache_access_log(query_hash);

-- Add log_cache_access function
CREATE OR REPLACE FUNCTION log_cache_access(
    query_hash text DEFAULT NULL,
    cache_hit boolean DEFAULT false,
    similarity_score float4 DEFAULT NULL,
    query_cost numeric DEFAULT NULL
)
RETURNS void
AS 'MODULE_PATHNAME', 'log_cache_access'
LANGUAGE C;

-- Add get_cost_savings function
CREATE OR REPLACE FUNCTION get_cost_savings(
    days integer DEFAULT 30
)
RETURNS TABLE(
    total_queries bigint,
    cache_hits bigint,
    cache_misses bigint,
    hit_rate float4,
    total_cost_saved float8,
    avg_cost_per_hit float8,
    total_cost_if_no_cache float8
)
AS 'MODULE_PATHNAME', 'get_cost_savings'
LANGUAGE C;

-- Add evict_lfu function (was missing in 0.1.0)
CREATE OR REPLACE FUNCTION evict_lfu(keep_count integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'evict_lfu'
LANGUAGE C STRICT;

-- Create new analytics views
CREATE OR REPLACE VIEW cache_access_summary AS
SELECT
    DATE_TRUNC('hour', access_time) as hour,
    COUNT(*) as total_accesses,
    SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END) as hits,
    SUM(CASE WHEN NOT cache_hit THEN 1 ELSE 0 END) as misses,
    ROUND((SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END)::NUMERIC / COUNT(*)::NUMERIC * 100)::NUMERIC, 2) as hit_rate_pct,
    ROUND(SUM(cost_saved)::NUMERIC, 6) as cost_saved
FROM semantic_cache.cache_access_log
GROUP BY DATE_TRUNC('hour', access_time)
ORDER BY hour DESC;

CREATE OR REPLACE VIEW cost_savings_daily AS
SELECT
    DATE(access_time) as date,
    COUNT(*) as total_queries,
    SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END) as cache_hits,
    SUM(CASE WHEN NOT cache_hit THEN 1 ELSE 0 END) as cache_misses,
    ROUND((SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END)::NUMERIC / COUNT(*)::NUMERIC * 100)::NUMERIC, 2) as hit_rate_pct,
    ROUND(SUM(cost_saved)::NUMERIC, 6) as total_cost_saved,
    ROUND(AVG(CASE WHEN cache_hit THEN cost_saved END)::NUMERIC, 6) as avg_cost_per_hit
FROM semantic_cache.cache_access_log
GROUP BY DATE(access_time)
ORDER BY date DESC;

CREATE OR REPLACE VIEW top_cached_queries AS
SELECT
    query_hash,
    COUNT(*) as hit_count,
    AVG(similarity_score) as avg_similarity,
    ROUND(SUM(cost_saved)::NUMERIC, 6) as total_cost_saved,
    MAX(access_time) as last_access
FROM semantic_cache.cache_access_log
WHERE cache_hit = true
GROUP BY query_hash
ORDER BY total_cost_saved DESC
LIMIT 100;

-- Add comments for new functions and tables
COMMENT ON FUNCTION log_cache_access(text, boolean, float4, numeric) IS 'Log cache access event with cost information';
COMMENT ON FUNCTION get_cost_savings(integer) IS 'Get cost savings report for the specified number of days';
COMMENT ON FUNCTION evict_lfu(integer) IS 'Evict least frequently used entries';

COMMENT ON TABLE semantic_cache.cache_access_log IS 'Logs all cache access events with cost tracking';

COMMENT ON VIEW semantic_cache.cache_access_summary IS 'Hourly cache access statistics with cost savings';
COMMENT ON VIEW semantic_cache.cost_savings_daily IS 'Daily cost savings breakdown';
COMMENT ON VIEW semantic_cache.top_cached_queries IS 'Top queries by cost savings';
