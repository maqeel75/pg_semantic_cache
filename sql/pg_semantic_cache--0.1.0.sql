-- pg_semantic_cache--0.1.0.sql
-- Extension installation script

-- Require pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Create schema and tables
SELECT semantic_cache.init_schema();

-- Create helpful views

-- View for cache health monitoring
CREATE OR REPLACE VIEW semantic_cache.cache_health AS
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

-- View for recently accessed entries
CREATE OR REPLACE VIEW semantic_cache.recent_cache_activity AS
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

-- View for cache entries by tag
CREATE OR REPLACE VIEW semantic_cache.cache_by_tag AS
SELECT 
    UNNEST(tags) as tag,
    COUNT(*) as entry_count,
    pg_size_pretty(SUM(result_size_bytes)::BIGINT) as total_size,
    AVG(access_count) as avg_access_count
FROM semantic_cache.cache_entries
WHERE tags IS NOT NULL
GROUP BY tag
ORDER BY entry_count DESC;

-- Grant permissions (adjust as needed for your security model)
-- GRANT USAGE ON SCHEMA semantic_cache TO PUBLIC;
-- GRANT SELECT ON ALL TABLES IN SCHEMA semantic_cache TO PUBLIC;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA semantic_cache TO PUBLIC;

-- Set up automatic eviction (optional background worker)
-- This can be configured via pg_cron or similar scheduler
-- Example: SELECT cron.schedule('cache-eviction', '*/5 * * * *', 'SELECT semantic_cache.auto_evict()');

COMMENT ON SCHEMA semantic_cache IS 'PostgreSQL semantic query result caching using vector embeddings';
COMMENT ON TABLE semantic_cache.cache_entries IS 'Stores cached query results with vector embeddings';
COMMENT ON TABLE semantic_cache.cache_metadata IS 'Cache statistics and metadata';
COMMENT ON TABLE semantic_cache.cache_config IS 'Cache configuration settings';
