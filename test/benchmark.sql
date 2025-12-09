-- pg_semantic_cache Performance Benchmarks
-- Run this file to evaluate cache performance

\timing on

-- ============================================================================
-- SETUP
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Clean slate
SELECT semantic_cache.clear_cache();
SELECT semantic_cache.reset_cache_stats();

-- ============================================================================
-- BENCHMARK 1: Cache Insert Performance
-- ============================================================================

\echo '=== Benchmark 1: Cache Insert Performance ==='

DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    i int;
    test_embedding vector(1536);
BEGIN
    start_time := clock_timestamp();
    
    -- Insert 1000 entries
    FOR i IN 1..1000 LOOP
        SELECT array_agg(random()::float4) INTO test_embedding 
        FROM generate_series(1, 1536);
        
        PERFORM semantic_cache.cache_query(
            'SELECT * FROM test_table WHERE id = ' || i,
            test_embedding,
            ('{"id": ' || i || ', "data": "test data"}')::jsonb,
            3600,
            ARRAY['benchmark']
        );
    END LOOP;
    
    end_time := clock_timestamp();
    
    RAISE NOTICE 'Inserted 1000 entries in: % ms', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time));
    RAISE NOTICE 'Average insert time: % ms', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 1000;
END $$;

-- ============================================================================
-- BENCHMARK 2: Cache Lookup Performance (IVFFlat)
-- ============================================================================

\echo '=== Benchmark 2: Cache Lookup Performance ==='

DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    i int;
    test_embedding vector(1536);
    result RECORD;
BEGIN
    -- Generate random embedding
    SELECT array_agg(random()::float4) INTO test_embedding 
    FROM generate_series(1, 1536);
    
    start_time := clock_timestamp();
    
    -- Perform 100 lookups
    FOR i IN 1..100 LOOP
        SELECT * INTO result 
        FROM semantic_cache.get_cached_result(test_embedding, 0.95);
    END LOOP;
    
    end_time := clock_timestamp();
    
    RAISE NOTICE 'Performed 100 lookups in: % ms', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time));
    RAISE NOTICE 'Average lookup time: % ms', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 100;
END $$;

-- ============================================================================
-- BENCHMARK 3: Hit Rate vs Similarity Threshold
-- ============================================================================

\echo '=== Benchmark 3: Hit Rate vs Similarity Threshold ==='

DO $$
DECLARE
    base_embedding vector(1536);
    similar_embedding vector(1536);
    threshold float;
    hit_count int;
    total_tests int := 100;
    result RECORD;
BEGIN
    -- Generate base embedding
    SELECT array_agg((i::float / 1536)::float4) INTO base_embedding 
    FROM generate_series(1, 1536) i;
    
    -- Cache it
    PERFORM semantic_cache.cache_query(
        'SELECT * FROM test_similarity',
        base_embedding,
        '{"test": "similarity"}'::jsonb,
        3600,
        NULL
    );
    
    -- Test different similarity thresholds
    FOR threshold IN 
        SELECT * FROM generate_series(0.85, 0.99, 0.02)
    LOOP
        hit_count := 0;
        
        -- Generate slightly different embeddings and test
        FOR i IN 1..total_tests LOOP
            SELECT array_agg(
                ((i2::float / 1536) + (random() - 0.5) * 0.1)::float4
            ) INTO similar_embedding 
            FROM generate_series(1, 1536) i2;
            
            SELECT * INTO result 
            FROM semantic_cache.get_cached_result(similar_embedding, threshold);
            
            IF result.hit THEN
                hit_count := hit_count + 1;
            END IF;
        END LOOP;
        
        RAISE NOTICE 'Threshold %.2f: Hit rate = %% (%/%)', 
            threshold, 
            (hit_count::float / total_tests * 100)::int,
            hit_count,
            total_tests;
    END LOOP;
END $$;

-- ============================================================================
-- BENCHMARK 4: Cache Size Impact on Performance
-- ============================================================================

\echo '=== Benchmark 4: Cache Size Impact on Performance ==='

DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    test_embedding vector(1536);
    result RECORD;
    cache_sizes int[] := ARRAY[100, 500, 1000, 5000, 10000];
    size int;
    i int;
    lookup_time_ms float;
BEGIN
    FOREACH size IN ARRAY cache_sizes LOOP
        -- Clear and repopulate cache
        PERFORM semantic_cache.clear_cache();
        
        RAISE NOTICE 'Populating cache with % entries...', size;
        FOR i IN 1..size LOOP
            SELECT array_agg(random()::float4) INTO test_embedding 
            FROM generate_series(1, 1536);
            
            PERFORM semantic_cache.cache_query(
                'SELECT ' || i,
                test_embedding,
                ('{"id": ' || i || '}')::jsonb,
                3600,
                NULL
            );
        END LOOP;
        
        -- Benchmark lookup time
        SELECT array_agg(random()::float4) INTO test_embedding 
        FROM generate_series(1, 1536);
        
        start_time := clock_timestamp();
        FOR i IN 1..50 LOOP
            SELECT * INTO result 
            FROM semantic_cache.get_cached_result(test_embedding, 0.95);
        END LOOP;
        end_time := clock_timestamp();
        
        lookup_time_ms := EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 50;
        
        RAISE NOTICE 'Cache size %: Avg lookup time = % ms', 
            size, 
            ROUND(lookup_time_ms::numeric, 2);
    END LOOP;
END $$;

-- ============================================================================
-- BENCHMARK 5: Eviction Performance
-- ============================================================================

\echo '=== Benchmark 5: Eviction Performance ==='

DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    evicted_count bigint;
BEGIN
    -- Clear and populate cache
    PERFORM semantic_cache.clear_cache();
    
    FOR i IN 1..5000 LOOP
        PERFORM semantic_cache.cache_query(
            'SELECT ' || i,
            (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
            ('{"id": ' || i || '}')::jsonb,
            3600,
            NULL
        );
    END LOOP;
    
    RAISE NOTICE 'Cache populated with 5000 entries';
    
    -- Benchmark LRU eviction
    start_time := clock_timestamp();
    SELECT semantic_cache.evict_lru(limit_mb := 1) INTO evicted_count;
    end_time := clock_timestamp();
    
    RAISE NOTICE 'LRU eviction: Removed % entries in % ms', 
        evicted_count,
        EXTRACT(MILLISECONDS FROM (end_time - start_time));
    
    -- Benchmark expired eviction
    UPDATE semantic_cache.cache_entries 
    SET expires_at = NOW() - INTERVAL '1 hour'
    WHERE id <= 1000;
    
    start_time := clock_timestamp();
    SELECT semantic_cache.evict_expired() INTO evicted_count;
    end_time := clock_timestamp();
    
    RAISE NOTICE 'TTL eviction: Removed % entries in % ms', 
        evicted_count,
        EXTRACT(MILLISECONDS FROM (end_time - start_time));
END $$;

-- ============================================================================
-- BENCHMARK 6: Concurrent Access Simulation
-- ============================================================================

\echo '=== Benchmark 6: Statistics Function Performance ==='

DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    stats RECORD;
    i int;
BEGIN
    start_time := clock_timestamp();
    
    FOR i IN 1..1000 LOOP
        SELECT * INTO stats FROM semantic_cache.cache_stats();
    END LOOP;
    
    end_time := clock_timestamp();
    
    RAISE NOTICE 'Stats retrieval (1000x): % ms (avg: % ms)', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time)),
        EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 1000;
END $$;

-- ============================================================================
-- SUMMARY
-- ============================================================================

\echo '=== Benchmark Summary ==='
SELECT * FROM semantic_cache.cache_stats();
SELECT * FROM semantic_cache.cache_size_distribution();

-- ============================================================================
-- CLEANUP
-- ============================================================================

\echo '=== Cleaning up ==='
SELECT semantic_cache.clear_cache();
SELECT semantic_cache.reset_cache_stats();

\timing off
