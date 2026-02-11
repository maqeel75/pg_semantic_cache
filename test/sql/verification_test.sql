-- pg_semantic_cache verification test
-- Covers: dimension changes, rebuild_index(), semantic similarity (hit/miss),
-- tags, invalidate_cache(), eviction strategies, monitoring views,
-- cost tracking, HNSW index switching, and clear_cache().

-- Setup: create extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- ============================================================================
-- Test 1: Initial cache stats (empty cache)
-- ============================================================================
SELECT total_entries, total_hits, total_misses, hit_rate_percent
FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 2: Configure for small vectors (8 dimensions) using rebuild_index()
-- ============================================================================
SELECT semantic_cache.set_vector_dimension(8);
SELECT semantic_cache.rebuild_index();

-- Verify dimension was applied
SELECT semantic_cache.get_vector_dimension() AS dimension;
SELECT semantic_cache.get_index_type() AS index_type;

-- ============================================================================
-- Test 3: Cache three query results with 8-dim embeddings
-- ============================================================================

-- Transactions entry
SELECT semantic_cache.cache_query(
    'How does PostgreSQL handle transactions?',
    '[0.12, 0.85, 0.44, 0.31, 0.67, 0.22, 0.91, 0.15]',
    '{"answer": "PostgreSQL implements MVCC for transaction management."}'::jsonb,
    7200,
    ARRAY['postgres', 'concepts']
) > 0 AS inserted_transactions;

-- Indexing entry
SELECT semantic_cache.cache_query(
    'What types of indexes does PostgreSQL support?',
    '[0.33, 0.18, 0.72, 0.55, 0.11, 0.88, 0.29, 0.64]',
    '{"answer": "PostgreSQL supports B-tree, Hash, GiST, SP-GiST, GIN, and BRIN indexes."}'::jsonb,
    7200,
    ARRAY['postgres', 'indexing']
) > 0 AS inserted_indexing;

-- Replication entry
SELECT semantic_cache.cache_query(
    'How do I set up replication in PostgreSQL?',
    '[0.78, 0.42, 0.15, 0.93, 0.37, 0.56, 0.08, 0.71]',
    '{"answer": "PostgreSQL supports streaming replication and logical replication."}'::jsonb,
    7200,
    ARRAY['postgres', 'replication']
) > 0 AS inserted_replication;

-- Verify 3 entries cached
SELECT total_entries, total_hits, total_misses
FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 4: Semantic similarity lookup - cache HIT
-- Similar embedding to the transactions entry (should match at 0.95 threshold)
-- ============================================================================
SELECT
    found,
    result_data->>'answer' AS answer,
    similarity_score >= 0.99 AS high_similarity
FROM semantic_cache.get_cached_result(
    '[0.13, 0.83, 0.46, 0.29, 0.65, 0.24, 0.89, 0.17]',
    0.95
);

-- ============================================================================
-- Test 5: Semantic similarity lookup - cache MISS
-- Completely different topic embedding (should NOT match at 0.95 threshold)
-- ============================================================================
SELECT
    found,
    result_data IS NULL AS no_result,
    similarity_score < 0.95 AS below_threshold
FROM semantic_cache.get_cached_result(
    '[0.95, 0.05, 0.10, 0.02, 0.88, 0.03, 0.50, 0.40]',
    0.95
);

-- ============================================================================
-- Test 6: Stats after lookups (1 hit, 1 miss, 50% rate)
-- ============================================================================
SELECT total_entries, total_hits, total_misses, hit_rate_percent
FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 7: Tags - add entries with different tags
-- ============================================================================

-- Weather entry
SELECT semantic_cache.cache_query(
    'What is the weather in New York?',
    '[0.45, 0.67, 0.23, 0.89, 0.12, 0.56, 0.78, 0.34]',
    '{"temperature": "42F", "conditions": "Partly cloudy"}'::jsonb,
    1800,
    ARRAY['weather', 'location-ny']
) > 0 AS inserted_weather;

-- Docker entry
SELECT semantic_cache.cache_query(
    'Explain Docker networking',
    '[0.22, 0.91, 0.55, 0.13, 0.77, 0.38, 0.64, 0.09]',
    '{"answer": "Docker provides bridge, host, overlay, and macvlan network drivers."}'::jsonb,
    86400,
    ARRAY['devops', 'docker']
) > 0 AS inserted_docker;

-- Verify tags exist via cache_by_tag view
SELECT tag, entry_count FROM semantic_cache.cache_by_tag ORDER BY tag;

-- ============================================================================
-- Test 8: Invalidate by tag
-- ============================================================================
SELECT semantic_cache.invalidate_cache(tag := 'weather') AS invalidated_by_tag;

SELECT total_entries FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 9: Invalidate by pattern
-- ============================================================================
SELECT semantic_cache.invalidate_cache(pattern := '%Docker%') AS invalidated_by_pattern;

SELECT total_entries FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 10: Eviction strategies
-- ============================================================================
SELECT semantic_cache.evict_expired() AS expired_evicted;
SELECT semantic_cache.evict_lru(1000) AS lru_evicted;
SELECT semantic_cache.evict_lfu(1000) AS lfu_evicted;
SELECT semantic_cache.auto_evict() AS auto_evicted;

-- ============================================================================
-- Test 11: Monitoring views return data
-- ============================================================================

-- cache_health view
SELECT
    total_entries >= 0 AS health_works,
    hit_rate_pct IS NOT NULL AS has_hit_rate
FROM semantic_cache.cache_health;

-- recent_cache_activity view
SELECT COUNT(*) >= 0 AS activity_works FROM semantic_cache.recent_cache_activity;

-- ============================================================================
-- Test 12: Cost tracking with log_cache_access
-- ============================================================================
SELECT semantic_cache.log_cache_access(
    md5('How does PostgreSQL handle transactions?'),
    true,
    0.9991,
    0.03
);

SELECT semantic_cache.log_cache_access(
    md5('Completely new question about Kubernetes'),
    false,
    0.68,
    0.03
);

-- Verify cost savings report
SELECT
    total_queries >= 2 AS has_queries,
    cache_hits >= 1 AS has_hits,
    cache_misses >= 1 AS has_misses,
    total_cost_saved > 0 AS has_savings
FROM semantic_cache.get_cost_savings(7);

-- Verify daily view
SELECT COUNT(*) > 0 AS daily_view_works FROM semantic_cache.cost_savings_daily;

-- ============================================================================
-- Test 13: Switch to HNSW index using rebuild_index()
-- ============================================================================
SELECT semantic_cache.set_index_type('hnsw');
SELECT semantic_cache.rebuild_index();

SELECT semantic_cache.get_index_type() AS index_type_after_switch;

-- ============================================================================
-- Test 14: Verify HNSW works (cache + lookup after index switch)
-- ============================================================================
SELECT semantic_cache.cache_query(
    'HNSW test query',
    '[0.50, 0.50, 0.50, 0.50, 0.50, 0.50, 0.50, 0.50]',
    '{"answer": "HNSW index works"}'::jsonb,
    3600,
    ARRAY['hnsw-test']
) > 0 AS hnsw_insert_works;

SELECT found FROM semantic_cache.get_cached_result(
    '[0.51, 0.49, 0.50, 0.50, 0.50, 0.50, 0.50, 0.51]',
    0.95
);

-- ============================================================================
-- Test 15: Switch back to IVFFlat using rebuild_index()
-- ============================================================================
SELECT semantic_cache.set_index_type('ivfflat');
SELECT semantic_cache.rebuild_index();

SELECT semantic_cache.get_index_type() AS index_type_restored;

-- ============================================================================
-- Test 16: Dimension change using rebuild_index()
-- ============================================================================
SELECT semantic_cache.set_vector_dimension(768);
SELECT semantic_cache.rebuild_index();

SELECT semantic_cache.get_vector_dimension() AS dimension_after_change;

-- Verify cache was cleared (rebuild_index truncates)
SELECT total_entries FROM semantic_cache.cache_stats();

-- ============================================================================
-- Test 17: Cache works with new dimension (768)
-- ============================================================================
SELECT semantic_cache.cache_query(
    'Test with 768 dimensions',
    (SELECT replace(replace(array_agg(0.1::float4)::text, '{', '['), '}', ']')
     FROM generate_series(1, 768)),
    '{"answer": "768-dim cache works"}'::jsonb,
    3600,
    NULL
) > 0 AS dim768_insert_works;

SELECT found FROM semantic_cache.get_cached_result(
    (SELECT replace(replace(array_agg(0.1::float4)::text, '{', '['), '}', ']')
     FROM generate_series(1, 768)),
    0.95
);

-- ============================================================================
-- Test 18: Clear cache
-- ============================================================================
SELECT semantic_cache.clear_cache() >= 0 AS cleared;

SELECT total_entries FROM semantic_cache.cache_stats();

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP EXTENSION pg_semantic_cache CASCADE;
DROP EXTENSION vector CASCADE;
