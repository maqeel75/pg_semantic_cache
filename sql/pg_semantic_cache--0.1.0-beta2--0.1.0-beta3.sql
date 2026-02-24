-- Upgrade script from pg_semantic_cache 0.1.0-beta2 to 0.1.0-beta3
--
-- Major improvements in this version:
-- 1. Dynamic IVFFlat probes optimization (fixes cache retrieval bugs)
-- 2. Configurable vector dimensions (768, 1536, 3072, etc.)
-- 3. Configurable index type (IVFFlat vs HNSW)
-- 4. Automatic index optimization based on cache size
-- 5. Fix cache_hit_rate() stub (now returns real hit rate)
-- 6. Fix auto_evict() stub (now delegates to correct eviction function)

-- ============================================================================
-- NEW CONFIGURATION FUNCTIONS
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
-- UPDATE COMMENTS FOR IMPROVED FUNCTIONS
-- ============================================================================

COMMENT ON FUNCTION get_cached_result(text, float4, integer) IS
  'Retrieve cached result by semantic similarity (automatically optimizes IVFFlat probes for reliable results)';

-- ============================================================================
-- ADD COMMENTS FOR NEW FUNCTIONS
-- ============================================================================

COMMENT ON FUNCTION set_vector_dimension(integer) IS
  'Configure vector embedding dimension (768, 1536, 3072, etc.) - call rebuild_index() to apply changes';

COMMENT ON FUNCTION get_vector_dimension() IS
  'Get configured vector embedding dimension';

COMMENT ON FUNCTION set_index_type(text) IS
  'Set vector index type: "ivfflat" (default, fast, approximate) or "hnsw" (accurate, requires pgvector 0.5.0+) - call rebuild_index() to apply';

COMMENT ON FUNCTION get_index_type() IS
  'Get configured vector index type (ivfflat or hnsw)';

COMMENT ON FUNCTION rebuild_index() IS
  'Rebuild cache table and index with current configuration (WARNING: clears all cached data)';

-- ============================================================================
-- FIX STUB FUNCTIONS
-- ============================================================================

-- Replace cache_hit_rate() C stub (was returning 0.0) with real SQL implementation
CREATE OR REPLACE FUNCTION cache_hit_rate()
RETURNS float4
LANGUAGE sql STABLE
AS $$
    SELECT hit_rate_percent FROM semantic_cache.cache_stats();
$$;

-- Replace auto_evict() C stub (was returning 0) with real PL/pgSQL implementation
-- Reads eviction_policy from cache_config and delegates to the appropriate eviction function
CREATE OR REPLACE FUNCTION auto_evict()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    policy      TEXT;
    total_count BIGINT;
    keep_count  INTEGER;
    evicted     BIGINT := 0;
BEGIN
    -- Always evict TTL-expired entries first
    evicted := evicted + semantic_cache.evict_expired();

    -- Read eviction policy from config (default: 'ttl')
    SELECT value INTO policy
    FROM semantic_cache.cache_config
    WHERE key = 'eviction_policy';

    IF policy IS NULL THEN
        policy := 'ttl';
    END IF;

    -- For LRU or LFU policies, also evict by usage pattern (keep 80% of remaining)
    IF policy IN ('lru', 'lfu') THEN
        SELECT COUNT(*)::BIGINT INTO total_count
        FROM semantic_cache.cache_entries;

        keep_count := GREATEST((total_count * 0.8)::INTEGER, 0);

        IF policy = 'lru' THEN
            evicted := evicted + semantic_cache.evict_lru(keep_count);
        ELSE
            evicted := evicted + semantic_cache.evict_lfu(keep_count);
        END IF;
    END IF;

    RETURN evicted;
END;
$$;

COMMENT ON FUNCTION cache_hit_rate() IS 'Get current cache hit rate percentage';
COMMENT ON FUNCTION auto_evict() IS 'Automatically evict entries based on configured eviction_policy (ttl, lru, or lfu)';
