-- pg_semantic_cache--0.1.0.sql
-- Extension installation script

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
AS 'MODULE_PATHNAME', 'get_cached_result'
LANGUAGE C;

CREATE FUNCTION invalidate_cache(
    pattern text DEFAULT NULL,
    tag text DEFAULT NULL
)
RETURNS bigint
AS 'MODULE_PATHNAME', 'invalidate_cache'
LANGUAGE C;

CREATE FUNCTION cache_stats()
RETURNS TABLE(
    total_entries bigint,
    total_hits bigint,
    total_misses bigint,
    hit_rate_percent float4
)
AS 'MODULE_PATHNAME', 'cache_stats'
LANGUAGE C STRICT;

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

CREATE FUNCTION clear_cache()
RETURNS bigint
AS 'MODULE_PATHNAME', 'clear_cache'
LANGUAGE C STRICT;

CREATE FUNCTION auto_evict()
RETURNS bigint
AS 'MODULE_PATHNAME', 'auto_evict'
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
    (SELECT COUNT(*) FROM cache_entries) as total_entries,
    (SELECT COUNT(*) FROM cache_entries WHERE expires_at <= NOW()) as expired_entries,
    (SELECT pg_size_pretty(SUM(result_size_bytes)::BIGINT) FROM cache_entries) as total_size,
    (SELECT AVG(access_count) FROM cache_entries) as avg_access_count,
    m.total_hits,
    m.total_misses,
    ROUND((m.total_hits::NUMERIC / NULLIF(m.total_hits + m.total_misses, 0) * 100)::NUMERIC, 2) as hit_rate_pct
FROM cache_metadata m
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
FROM cache_entries
ORDER BY last_accessed_at DESC
LIMIT 50;

CREATE VIEW cache_by_tag AS
SELECT 
    UNNEST(tags) as tag,
    COUNT(*) as entry_count,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size,
    AVG(access_count) as avg_access_count
FROM cache_entries
WHERE tags IS NOT NULL
GROUP BY tag
ORDER BY entry_count DESC;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON FUNCTION init_schema() IS 'Initialize cache schema and create required tables';
COMMENT ON FUNCTION cache_query(text, text, jsonb, integer, text[]) IS 'Cache a query result with its vector embedding';
COMMENT ON FUNCTION get_cached_result(text, float4, integer) IS 'Retrieve cached result by semantic similarity';
COMMENT ON FUNCTION invalidate_cache(text, text) IS 'Invalidate cache entries by pattern or tag';
COMMENT ON FUNCTION cache_stats() IS 'Get cache statistics including hits, misses, and hit rate';
COMMENT ON FUNCTION evict_expired() IS 'Remove expired cache entries';
COMMENT ON FUNCTION evict_lru(integer) IS 'Evict least recently used entries';
COMMENT ON FUNCTION clear_cache() IS 'Clear all cache entries';
COMMENT ON FUNCTION auto_evict() IS 'Automatically evict entries based on cache configuration';

COMMENT ON TABLE cache_entries IS 'Stores cached query results with vector embeddings';
COMMENT ON TABLE cache_metadata IS 'Cache statistics and metadata';
COMMENT ON TABLE cache_config IS 'Cache configuration settings';

COMMENT ON VIEW cache_health IS 'Real-time cache health metrics';
COMMENT ON VIEW recent_cache_activity IS 'Most recently accessed cache entries';
COMMENT ON VIEW cache_by_tag IS 'Cache entries grouped by tag';
