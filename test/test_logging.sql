-- Test script for logging and cost tracking functionality
-- Run this after installing the extension

\echo '=========================================='
\echo 'Testing pg_semantic_cache Logging'
\echo '=========================================='

-- Clean up any existing test data
TRUNCATE semantic_cache.cache_entries CASCADE;
TRUNCATE semantic_cache.cache_access_log CASCADE;
UPDATE semantic_cache.cache_metadata SET
    total_hits = 0,
    total_misses = 0,
    total_cost_saved = 0;

\echo ''
\echo 'Test 1: Configure cost tracking'
SELECT semantic_cache.set_config('default_query_cost', '0.0001');
SELECT semantic_cache.set_config('enable_access_logging', 'true');

SELECT key, value FROM semantic_cache.cache_config
WHERE key IN ('default_query_cost', 'enable_access_logging')
ORDER BY key;

\echo ''
\echo 'Test 2: Cache some queries'

-- Cache query 1
SELECT semantic_cache.cache_query(
    'SELECT * FROM orders WHERE status = ''pending''',
    (SELECT array_agg((i::float / 1536)::float4) FROM generate_series(1, 1536) i)::text,
    '{"total": 42, "amount": 12500}'::jsonb,
    3600,
    ARRAY['orders', 'pending']
) as cache_id_1;

-- Cache query 2
SELECT semantic_cache.cache_query(
    'SELECT * FROM products WHERE category = ''electronics''',
    (SELECT array_agg(((i + 100)::float / 1536)::float4) FROM generate_series(1, 1536) i)::text,
    '{"total": 25, "products": []}'::jsonb,
    3600,
    ARRAY['products', 'electronics']
) as cache_id_2;

\echo ''
\echo 'Test 3: Test cache HIT (similar embedding)'

SELECT
    hit,
    similarity_score,
    age_seconds,
    LEFT(result_data::text, 50) as result_preview
FROM semantic_cache.get_cached_result(
    (SELECT array_agg((i::float / 1536)::float4) FROM generate_series(1, 1536) i)::text,
    0.95,
    NULL
);

\echo ''
\echo 'Test 4: Test cache MISS (different embedding)'

SELECT
    hit,
    similarity_score,
    age_seconds,
    result_data
FROM semantic_cache.get_cached_result(
    (SELECT array_agg((random() * 10)::float4) FROM generate_series(1, 1536) i)::text,
    0.95,
    NULL
);

\echo ''
\echo 'Test 5: Check access log'

SELECT
    id,
    cache_hit,
    ROUND(similarity_score::numeric, 4) as similarity,
    ROUND(query_cost::numeric, 6) as cost,
    ROUND(cost_saved::numeric, 6) as saved
FROM semantic_cache.cache_access_log
ORDER BY id;

\echo ''
\echo 'Test 6: Manual logging test'

SELECT semantic_cache.log_cache_access(
    1::bigint,
    true::boolean,
    0.987::real,
    'Test query with high similarity'::text,
    0.00025::float8,
    'test_user:123'::text,
    ARRAY['test', 'manual']::text[]
);

\echo ''
\echo 'Test 7: View cost savings (last 24 hours)'

SELECT
    total_hits,
    total_misses,
    ROUND(total_cost_saved::numeric, 6) as cost_saved,
    ROUND(avg_cost_per_hit::numeric, 6) as avg_per_hit,
    hit_rate_pct
FROM semantic_cache.get_cost_savings(24);

\echo ''
\echo 'Test 8: View recent access log'

SELECT
    id,
    cache_hit,
    ROUND(similarity_score::numeric, 4) as similarity,
    LEFT(query_preview, 40) as query,
    ROUND(cost_saved::numeric, 6) as saved,
    result
FROM semantic_cache.recent_access_log;

\echo ''
\echo 'Test 9: Cost savings by tag'

SELECT
    tag,
    hits,
    misses,
    hit_rate_pct,
    ROUND(total_cost_saved::numeric, 6) as saved
FROM semantic_cache.cost_savings_by_tag
ORDER BY tag;

\echo ''
\echo 'Test 10: Daily cost savings'

SELECT
    date,
    total_queries,
    hits,
    misses,
    hit_rate_pct,
    ROUND(total_cost_saved::numeric, 6) as saved
FROM semantic_cache.cost_savings_daily
ORDER BY date DESC
LIMIT 5;

\echo ''
\echo 'Test 11: Check metadata table'

SELECT
    total_hits,
    total_misses,
    ROUND(total_cost_saved::numeric, 6) as total_saved,
    ROUND((total_hits::numeric / NULLIF(total_hits + total_misses, 0) * 100), 2) as hit_rate
FROM semantic_cache.cache_metadata
WHERE id = 1;

\echo ''
\echo 'Test 12: Test with logging disabled'

SELECT semantic_cache.set_config('enable_access_logging', 'false');

-- This should NOT create a log entry
SELECT * FROM semantic_cache.get_cached_result(
    (SELECT array_agg((i::float / 1536)::float4) FROM generate_series(1, 1536) i)::text,
    0.95,
    NULL
) LIMIT 1;

-- Count logs (should be same as before)
SELECT COUNT(*) as log_count_with_logging_disabled
FROM semantic_cache.cache_access_log;

-- Re-enable logging
SELECT semantic_cache.set_config('enable_access_logging', 'true');

\echo ''
\echo 'Test 13: Cleanup old logs'

-- Insert an old log entry
INSERT INTO semantic_cache.cache_access_log (
    cache_entry_id, cache_hit, accessed_at, query_cost, cost_saved
) VALUES (
    1, true, NOW() - INTERVAL '60 days', 0.0001, 0.0001
);

-- Set retention to 30 days
SELECT semantic_cache.set_config('log_retention_days', '30');

-- Clean up
SELECT semantic_cache.cleanup_access_logs() as deleted_logs;

\echo ''
\echo 'Test 14: Simulate realistic usage pattern'

DO $$
DECLARE
    i INTEGER;
    embedding_text TEXT;
    result RECORD;
BEGIN
    FOR i IN 1..10 LOOP
        -- Generate a similar embedding to first cached query (should hit)
        embedding_text := (
            SELECT array_agg((j::float / 1536 + random() * 0.01)::float4)
            FROM generate_series(1, 1536) j
        )::text;

        SELECT * INTO result
        FROM semantic_cache.get_cached_result(embedding_text, 0.90, NULL);
    END LOOP;
END $$;

\echo ''
\echo 'Final Statistics:'

SELECT
    total_hits,
    total_misses,
    ROUND(total_cost_saved::numeric, 6) as total_saved,
    ROUND((total_hits::numeric / NULLIF(total_hits + total_misses, 0) * 100), 2) as hit_rate_pct
FROM semantic_cache.cache_metadata
WHERE id = 1;

\echo ''
\echo 'Test Summary from Access Log:'

SELECT
    COUNT(*) as total_accesses,
    COUNT(*) FILTER (WHERE cache_hit = true) as hits,
    COUNT(*) FILTER (WHERE cache_hit = false) as misses,
    ROUND(AVG(similarity_score) FILTER (WHERE cache_hit = true)::numeric, 4) as avg_similarity,
    ROUND(SUM(cost_saved)::numeric, 6) as total_saved
FROM semantic_cache.cache_access_log;

\echo ''
\echo '=========================================='
\echo 'All tests completed!'
\echo '=========================================='
