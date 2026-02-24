-- Upgrade script from pg_semantic_cache 0.1.0-beta3 to 0.1.0-beta4
--
-- Changes in this version:
-- 1. Fix cache_hit_rate() stub (was returning 0.0, now returns real hit rate)
-- 2. Fix auto_evict() stub (was returning 0, now delegates to correct eviction function)

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
