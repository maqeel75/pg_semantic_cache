-- pg_semantic_cache--0.2.0.sql
-- This is a direct installation of version 0.2.0
-- (includes all features from 0.1.0 plus logging and cost tracking)

-- This file is identical to 0.1.0.sql since init_schema() creates all tables
-- The difference is that 0.2.0 includes the new logging functions

\echo Use "CREATE EXTENSION pg_semantic_cache" to load this file. \quit

-- Require pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================================
-- FUNCTION DECLARATIONS
-- Note: Schema prefix not needed - functions auto-placed in semantic_cache
-- ============================================================================

CREATE FUNCTION init_schema()
RETURNS void
AS 'MODULE_PATHNAME', 'init_schema'
LANGUAGE C STRICT;

CREATE FUNCTION cache_query(
    query_text text,
    query_embedding text,
    result_data jsonb,
    ttl_seconds integer DEFAULT 3600,
    tags text[] DEFAULT NULL
)
RETURNS bigint
AS 'MODULE_PATHNAME', 'cache_query'
LANGUAGE C;

-- Note: Implemented in SQL for better memory management and performance with automatic stats tracking
CREATE FUNCTION get_cached_result(
    query_embedding text,
    similarity_threshold float4 DEFAULT 0.95,
    max_age_seconds integer DEFAULT NULL
)
RETURNS TABLE(
    found boolean,
    result_data jsonb,
    similarity_score float4,
    age_seconds integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    result_record RECORD;
    query_vec vector := query_embedding::vector;
BEGIN
    -- Try to find a cached result
    SELECT
        true::boolean as found,
        ce.result_data,
        (1 - (ce.query_embedding <=> query_vec))::float4 as similarity_score,
        EXTRACT(EPOCH FROM (NOW() - ce.created_at))::integer as age_seconds
    INTO result_record
    FROM semantic_cache.cache_entries ce
    WHERE (ce.expires_at IS NULL OR ce.expires_at > NOW())
      AND (1 - (ce.query_embedding <=> query_vec)) >= similarity_threshold
      AND (max_age_seconds IS NULL OR EXTRACT(EPOCH FROM (NOW() - ce.created_at)) <= max_age_seconds)
    ORDER BY ce.query_embedding <=> query_vec
    LIMIT 1;

    -- Check if we found a result
    IF result_record.found IS NOT NULL THEN
        -- Update cache stats for HIT
        UPDATE semantic_cache.cache_metadata
        SET total_hits = total_hits + 1
        WHERE id = 1;

        -- Return the cached result
        RETURN QUERY SELECT result_record.found, result_record.result_data,
                           result_record.similarity_score, result_record.age_seconds;
    ELSE
        -- Update cache stats for MISS
        UPDATE semantic_cache.cache_metadata
        SET total_misses = total_misses + 1
        WHERE id = 1;

        -- No result found - return nothing
        RETURN;
    END IF;
END;
$$;

CREATE FUNCTION invalidate_cache(
    pattern text DEFAULT NULL,
    tag text DEFAULT NULL
)
RETURNS bigint
AS 'MODULE_PATHNAME', 'invalidate_cache'
LANGUAGE C;

-- Note: Implemented in SQL to properly read from cache_metadata table
CREATE FUNCTION cache_stats()
RETURNS TABLE(
    total_entries bigint,
    total_hits bigint,
    total_misses bigint,
    hit_rate_percent float4
)
LANGUAGE sql STABLE
AS $$
    SELECT
        (SELECT COUNT(*)::bigint FROM semantic_cache.cache_entries) as total_entries,
        m.total_hits,
        m.total_misses,
        CASE
            WHEN (m.total_hits + m.total_misses) > 0
            THEN (m.total_hits::numeric / (m.total_hits + m.total_misses)::numeric * 100)::float4
            ELSE 0::float4
        END as hit_rate_percent
    FROM semantic_cache.cache_metadata m
    WHERE m.id = 1;
$$;

CREATE FUNCTION cache_hit_rate()
RETURNS float4
AS 'MODULE_PATHNAME', 'cache_hit_rate'
LANGUAGE C STRICT;

CREATE FUNCTION evict_expired()
RETURNS bigint
AS 'MODULE_PATHNAME', 'evict_expired'
LANGUAGE C STRICT;

CREATE FUNCTION evict_lru(keep_count integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'evict_lru'
LANGUAGE C STRICT;

CREATE FUNCTION evict_lfu(keep_count integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'evict_lfu'
LANGUAGE C STRICT;

CREATE FUNCTION clear_cache()
RETURNS bigint
AS 'MODULE_PATHNAME', 'clear_cache'
LANGUAGE C STRICT;

CREATE FUNCTION auto_evict()
RETURNS bigint
AS 'MODULE_PATHNAME', 'auto_evict'
LANGUAGE C STRICT;

CREATE FUNCTION log_cache_access(
    query_hash text DEFAULT NULL,
    cache_hit boolean DEFAULT false,
    similarity_score float4 DEFAULT NULL,
    query_cost numeric DEFAULT NULL
)
RETURNS void
AS 'MODULE_PATHNAME', 'log_cache_access'
LANGUAGE C;

CREATE FUNCTION get_cost_savings(
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

-- ============================================================================
-- CONFIGURATION FUNCTIONS
-- ============================================================================

CREATE FUNCTION set_vector_dimension(dimension integer)
RETURNS void
AS 'MODULE_PATHNAME', 'set_vector_dimension'
LANGUAGE C STRICT;

CREATE FUNCTION get_vector_dimension()
RETURNS integer
AS 'MODULE_PATHNAME', 'get_vector_dimension'
LANGUAGE C STRICT;

CREATE FUNCTION set_index_type(index_type text)
RETURNS void
AS 'MODULE_PATHNAME', 'set_index_type'
LANGUAGE C STRICT;

CREATE FUNCTION get_index_type()
RETURNS text
AS 'MODULE_PATHNAME', 'get_index_type'
LANGUAGE C STRICT;

CREATE FUNCTION rebuild_index()
RETURNS void
AS 'MODULE_PATHNAME', 'rebuild_index'
LANGUAGE C STRICT;

-- ============================================================================
-- INITIALIZE SCHEMA
-- ============================================================================

SELECT init_schema();

-- ============================================================================
-- HELPER VIEWS
-- ============================================================================

CREATE VIEW cache_health AS
SELECT
    (SELECT COUNT(*) FROM semantic_cache.cache_entries) as total_entries,
    (SELECT COUNT(*) FROM semantic_cache.cache_entries WHERE expires_at <= NOW()) as expired_entries,
    (SELECT pg_size_pretty(SUM(result_size_bytes)::BIGINT) FROM semantic_cache.cache_entries) as total_size,
    (SELECT AVG(access_count) FROM semantic_cache.cache_entries) as avg_access_count,
    m.total_hits,
    m.total_misses,
    ROUND((m.total_hits::NUMERIC / NULLIF(m.total_hits + m.total_misses, 0) * 100)::NUMERIC, 2) as hit_rate_pct
FROM semantic_cache.cache_metadata m
WHERE m.id = 1;

CREATE VIEW recent_cache_activity AS
SELECT
    id,
    LEFT(query_text, 80) as query_preview,
    access_count,
    created_at,
    last_accessed_at,
    expires_at,
    pg_size_pretty(result_size_bytes::BIGINT) as result_size
FROM semantic_cache.cache_entries
ORDER BY last_accessed_at DESC
LIMIT 50;

CREATE VIEW cache_by_tag AS
SELECT
    UNNEST(tags) as tag,
    COUNT(*) as entry_count,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size,
    AVG(access_count) as avg_access_count
FROM semantic_cache.cache_entries
WHERE tags IS NOT NULL
GROUP BY tag
ORDER BY entry_count DESC;

-- Logging and cost analysis views
CREATE VIEW cache_access_summary AS
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

CREATE VIEW cost_savings_daily AS
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

CREATE VIEW top_cached_queries AS
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

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON FUNCTION init_schema() IS 'Initialize cache schema and create required tables';
COMMENT ON FUNCTION cache_query(text, text, jsonb, integer, text[]) IS 'Cache a query result with its vector embedding';
COMMENT ON FUNCTION get_cached_result(text, float4, integer) IS 'Retrieve cached result by semantic similarity (automatically optimizes IVFFlat probes)';
COMMENT ON FUNCTION invalidate_cache(text, text) IS 'Invalidate cache entries by pattern or tag';
COMMENT ON FUNCTION cache_stats() IS 'Get cache statistics including hits, misses, and hit rate';
COMMENT ON FUNCTION evict_expired() IS 'Remove expired cache entries';
COMMENT ON FUNCTION evict_lru(integer) IS 'Evict least recently used entries';
COMMENT ON FUNCTION evict_lfu(integer) IS 'Evict least frequently used entries';
COMMENT ON FUNCTION clear_cache() IS 'Clear all cache entries';
COMMENT ON FUNCTION auto_evict() IS 'Automatically evict entries based on cache configuration';
COMMENT ON FUNCTION log_cache_access(text, boolean, float4, numeric) IS 'Log cache access event with cost information';
COMMENT ON FUNCTION get_cost_savings(integer) IS 'Get cost savings report for the specified number of days';
COMMENT ON FUNCTION set_vector_dimension(integer) IS 'Configure vector embedding dimension (768, 1536, etc.) - call rebuild_index() to apply';
COMMENT ON FUNCTION get_vector_dimension() IS 'Get configured vector embedding dimension';
COMMENT ON FUNCTION set_index_type(text) IS 'Set vector index type: ivfflat (default, fast) or hnsw (accurate, requires pgvector 0.5.0+) - call rebuild_index() to apply';
COMMENT ON FUNCTION get_index_type() IS 'Get configured vector index type';
COMMENT ON FUNCTION rebuild_index() IS 'Rebuild cache table and index with current configuration (WARNING: clears all cached data)';

COMMENT ON TABLE semantic_cache.cache_entries IS 'Stores cached query results with vector embeddings';
COMMENT ON TABLE semantic_cache.cache_metadata IS 'Cache statistics and metadata';
COMMENT ON TABLE semantic_cache.cache_config IS 'Cache configuration settings';
COMMENT ON TABLE semantic_cache.cache_access_log IS 'Logs all cache access events with cost tracking';

COMMENT ON VIEW semantic_cache.cache_health IS 'Real-time cache health metrics';
COMMENT ON VIEW semantic_cache.recent_cache_activity IS 'Most recently accessed cache entries';
COMMENT ON VIEW semantic_cache.cache_by_tag IS 'Cache entries grouped by tag';
COMMENT ON VIEW semantic_cache.cache_access_summary IS 'Hourly cache access statistics with cost savings';
COMMENT ON VIEW semantic_cache.cost_savings_daily IS 'Daily cost savings breakdown';
COMMENT ON VIEW semantic_cache.top_cached_queries IS 'Top queries by cost savings';
