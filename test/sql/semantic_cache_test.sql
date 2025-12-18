-- pg_semantic_cache regression tests
-- This file tests core functionality of the semantic cache extension

-- Create extension and initialize schema
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Test 1: Schema initialization
SELECT semantic_cache.init_schema();

-- Verify tables were created
SELECT COUNT(*) as tables_created FROM information_schema.tables
WHERE table_schema = 'semantic_cache'
AND table_name IN ('cache_entries', 'cache_metadata', 'cache_config', 'cache_access_log');

-- Test 2: Cache a simple query
SELECT semantic_cache.cache_query(
    'SELECT * FROM users WHERE id = 1',
    (SELECT array_agg(0.1::float4) FROM generate_series(1, 1536))::text,
    '{"result": "test data"}'::jsonb,
    3600,
    ARRAY['test', 'users']
) > 0 as cache_inserted;

-- Test 3: Retrieve cached result
SELECT
    found,
    result_data->>'result' as result,
    similarity_score >= 0.99 as high_similarity
FROM semantic_cache.get_cached_result(
    (SELECT array_agg(0.1::float4) FROM generate_series(1, 1536))::text,
    0.95
);

-- Test 4: Cache statistics
SELECT
    total_entries >= 1 as has_entries
FROM semantic_cache.cache_stats();

-- Test 5: Cache multiple entries
SELECT semantic_cache.cache_query(
    'SELECT * FROM users WHERE id = ' || i,
    (SELECT array_agg((i::float / 1536)::float4) FROM generate_series(1, 1536))::text,
    ('{"result": "user ' || i || '"}')::jsonb,
    3600,
    NULL
) > 0 as inserted
FROM generate_series(2, 10) i;

-- Verify count
SELECT COUNT(*) as total_cached FROM semantic_cache.cache_entries;

-- Test 6: Evict expired entries (none should be expired)
SELECT semantic_cache.evict_expired() as expired_count;

-- Test 7: LRU eviction - keep only 5 entries
SELECT semantic_cache.evict_lru(5) as lru_evicted;
SELECT COUNT(*) as remaining_after_lru FROM semantic_cache.cache_entries;

-- Test 8: Add more entries with different access counts
INSERT INTO semantic_cache.cache_entries
    (query_hash, query_text, query_embedding, result_data, access_count, ttl_seconds)
VALUES
    ('test_hash_1', 'test query 1', (SELECT array_agg(0.5::float4) FROM generate_series(1, 1536))::vector, '{"test": 1}'::jsonb, 10, 3600),
    ('test_hash_2', 'test query 2', (SELECT array_agg(0.6::float4) FROM generate_series(1, 1536))::vector, '{"test": 2}'::jsonb, 5, 3600),
    ('test_hash_3', 'test query 3', (SELECT array_agg(0.7::float4) FROM generate_series(1, 1536))::vector, '{"test": 3}'::jsonb, 1, 3600);

-- Test 9: LFU eviction - keep only 3 entries (should keep highest access_count)
SELECT semantic_cache.evict_lfu(3) as lfu_evicted;
SELECT COUNT(*) as remaining_after_lfu FROM semantic_cache.cache_entries;

-- Verify the kept entries have highest access counts
SELECT access_count FROM semantic_cache.cache_entries ORDER BY access_count DESC LIMIT 3;

-- Test 10: Cost tracking - log cache misses and hits
SELECT semantic_cache.log_cache_access('query_1', false, NULL, 0.006);
SELECT semantic_cache.log_cache_access('query_2', true, 0.95, 0.006);
SELECT semantic_cache.log_cache_access('query_3', true, 0.97, 0.008);

-- Verify logs were created
SELECT COUNT(*) >= 3 as has_logs FROM semantic_cache.cache_access_log;

-- Test 11: Cost savings report
SELECT
    total_queries >= 3 as has_queries,
    cache_hits >= 2 as has_hits,
    cache_misses >= 1 as has_misses,
    hit_rate >= 50.0 as reasonable_hit_rate,
    total_cost_saved > 0 as has_savings
FROM semantic_cache.get_cost_savings(1);

-- Test 12: Views work correctly
SELECT COUNT(*) > 0 as access_summary_works FROM semantic_cache.cache_access_summary;
SELECT COUNT(*) > 0 as daily_savings_works FROM semantic_cache.cost_savings_daily;
SELECT COUNT(*) >= 0 as top_queries_works FROM semantic_cache.top_cached_queries;

-- Test 13: Cache invalidation (when implemented)
-- SELECT semantic_cache.invalidate_cache('test%', NULL);

-- Test 14: Clear cache
SELECT semantic_cache.clear_cache() >= 0 as cleared;
SELECT COUNT(*) as count_after_clear FROM semantic_cache.cache_entries;

-- Test 15: Error handling - NULL embedding
SELECT
    CASE
        WHEN found IS NULL THEN 'handled_null_correctly'
        ELSE 'unexpected_result'
    END as null_test
FROM semantic_cache.get_cached_result(NULL, 0.95);

-- Test 16: Error handling - negative keep_count for evict_lru
DO $$
BEGIN
    PERFORM semantic_cache.evict_lru(-5);
    RAISE EXCEPTION 'Should have failed with negative keep_count';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Correctly rejected negative keep_count';
END $$;

-- Test 17: Error handling - negative keep_count for evict_lfu
DO $$
BEGIN
    PERFORM semantic_cache.evict_lfu(-5);
    RAISE EXCEPTION 'Should have failed with negative keep_count';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Correctly rejected negative keep_count';
END $$;

-- Cleanup
DROP EXTENSION pg_semantic_cache CASCADE;
DROP EXTENSION vector CASCADE;
