-- pg_semantic_cache Examples and Testing
-- This file demonstrates typical usage patterns

-- ============================================================================
-- SETUP
-- ============================================================================

-- Install extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Verify installation
SELECT * FROM semantic_cache.cache_health;

-- ============================================================================
-- EXAMPLE 1: Basic Caching with Hardcoded Embeddings
-- ============================================================================

-- Cache a query result (simulating embeddings from OpenAI ada-002)
-- In production, you'd generate this from an embedding model
SELECT semantic_cache.cache_query(
    query_text := 'SELECT * FROM orders WHERE status = ''pending'' AND created_at > NOW() - INTERVAL ''7 days''',
    query_embedding := (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
    result_data := '{"total": 42, "orders": [{"id": 1, "amount": 100}, {"id": 2, "amount": 200}]}'::jsonb,
    ttl_seconds := 3600,  -- Cache for 1 hour
    tags := ARRAY['orders', 'pending']
);

-- Retrieve cached result with similar query
-- In production, this embedding would be generated for the user's query
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
    similarity_threshold := 0.95,
    max_age_seconds := NULL
);

-- ============================================================================
-- EXAMPLE 2: Caching Expensive Analytical Queries
-- ============================================================================

-- Simulate caching a complex analytics query
DO $$
DECLARE
    embedding vector(1536);
BEGIN
    -- Generate consistent embedding for testing
    SELECT array_agg((i::float / 1536)::float4) INTO embedding 
    FROM generate_series(1, 1536) i;
    
    -- Cache the result
    PERFORM semantic_cache.cache_query(
        'SELECT date_trunc(''month'', created_at) as month, 
                SUM(amount) as total_revenue,
                COUNT(*) as order_count
         FROM orders 
         WHERE created_at >= NOW() - INTERVAL ''1 year''
         GROUP BY 1 
         ORDER BY 1',
        embedding,
        '{"results": [
            {"month": "2024-01-01", "total_revenue": 150000, "order_count": 450},
            {"month": "2024-02-01", "total_revenue": 162000, "order_count": 489}
        ]}'::jsonb,
        7200,  -- 2 hour TTL for analytics
        ARRAY['analytics', 'revenue']
    );
END $$;

-- ============================================================================
-- EXAMPLE 3: AI/LLM Query Caching
-- ============================================================================

-- Cache results from an LLM query (RAG use case)
-- This would typically be used to cache expensive AI API calls

DO $$
DECLARE
    query_emb vector(1536);
    similar_emb vector(1536);
BEGIN
    -- Generate embeddings for "What was our Q4 revenue?"
    SELECT array_agg(sin(i::float / 100)::float4) INTO query_emb 
    FROM generate_series(1, 1536) i;
    
    -- Cache the LLM response
    PERFORM semantic_cache.cache_query(
        'What was our Q4 revenue in 2024?',
        query_emb,
        '{
            "answer": "Based on your sales data, Q4 2024 revenue was $2.4M, up 23% from Q4 2023.",
            "sources": ["sales_2024.csv", "quarterly_reports.pdf"],
            "confidence": 0.95
        }'::jsonb,
        1800,  -- 30 minute TTL for AI responses
        ARRAY['llm', 'revenue', 'q4']
    );
    
    -- Now query with slightly different phrasing: "Show me revenue for last quarter"
    -- Generate slightly different but semantically similar embedding
    SELECT array_agg(sin(i::float / 100 + 0.01)::float4) INTO similar_emb 
    FROM generate_series(1, 1536) i;
    
    -- This should hit the cache due to semantic similarity
    RAISE NOTICE 'Cache lookup result: %', 
        semantic_cache.get_cached_result(similar_emb, 0.90);
END $$;

-- ============================================================================
-- EXAMPLE 4: Monitoring and Statistics
-- ============================================================================

-- View overall cache statistics
SELECT * FROM semantic_cache.cache_stats();

-- Get current hit rate
SELECT semantic_cache.cache_hit_rate() || '%' as hit_rate;

-- View cache health
SELECT * FROM semantic_cache.cache_health;

-- See recent cache activity
SELECT * FROM semantic_cache.recent_cache_activity;

-- Get top cached queries
SELECT * FROM semantic_cache.cache_top_entries(10);

-- View cache size distribution
SELECT * FROM semantic_cache.cache_size_distribution();

-- Get statistics for last 24 hours
SELECT * FROM semantic_cache.cache_stats_by_period(24);

-- View cache by tag
SELECT * FROM semantic_cache.cache_by_tag;

-- ============================================================================
-- EXAMPLE 5: Cache Management
-- ============================================================================

-- Invalidate cache by pattern
SELECT semantic_cache.invalidate_cache(
    pattern := 'revenue',
    tag := NULL
);

-- Invalidate cache by tag
SELECT semantic_cache.invalidate_cache(
    pattern := NULL,
    tag := 'orders'
);

-- Manually evict expired entries
SELECT semantic_cache.evict_expired();

-- Evict least recently used entries if cache is too large
SELECT semantic_cache.evict_lru(limit_mb := 500);

-- Evict least frequently used entries
SELECT semantic_cache.evict_lfu(count := 10);

-- Evict old entries (older than 48 hours)
SELECT semantic_cache.evict_by_age(max_age_hours := 48);

-- Run automatic eviction based on configured policy
SELECT semantic_cache.auto_evict();

-- Clear entire cache (use with caution!)
-- SELECT semantic_cache.clear_cache();

-- ============================================================================
-- EXAMPLE 6: Configuration Management
-- ============================================================================

-- View current configuration
SELECT * FROM semantic_cache.cache_config ORDER BY key;

-- Update configuration
SELECT semantic_cache.set_config('max_cache_size_mb', '2000');
SELECT semantic_cache.set_config('default_ttl_seconds', '7200');
SELECT semantic_cache.set_config('eviction_policy', 'lru');

-- Get specific config value
SELECT semantic_cache.get_config('max_cache_size_mb');

-- ============================================================================
-- EXAMPLE 7: Production Integration Pattern
-- ============================================================================

-- Example: Application-level caching wrapper
CREATE OR REPLACE FUNCTION my_app.cached_analytics_query(
    query_text TEXT,
    params JSONB
) RETURNS JSONB AS $$
DECLARE
    query_emb vector(1536);
    cached_result RECORD;
    actual_result JSONB;
BEGIN
    -- Generate embedding for the query (this would call your embedding service)
    -- For this example, we'll use a hash-based deterministic embedding
    SELECT array_agg(
        (('x' || substring(md5(query_text || params::text), i, 8))::bit(32)::int::float / 2147483647)::float4
    ) INTO query_emb
    FROM generate_series(1, 1536, 1) i;
    
    -- Try to get from cache
    SELECT * INTO cached_result 
    FROM semantic_cache.get_cached_result(query_emb, 0.95);
    
    IF cached_result.hit THEN
        RAISE NOTICE 'Cache HIT - returning cached result';
        RETURN cached_result.result_data::jsonb;
    END IF;
    
    RAISE NOTICE 'Cache MISS - executing query';
    
    -- Execute actual query (simplified for example)
    actual_result := '{"status": "computed", "timestamp": "' || NOW()::text || '"}';
    
    -- Cache the result
    PERFORM semantic_cache.cache_query(
        query_text,
        query_emb,
        actual_result,
        3600,
        ARRAY['app_analytics']
    );
    
    RETURN actual_result;
END;
$$ LANGUAGE plpgsql;

-- Test the cached function
SELECT my_app.cached_analytics_query(
    'revenue analysis',
    '{"period": "Q4"}'::jsonb
);

-- ============================================================================
-- EXAMPLE 8: Scheduled Maintenance
-- ============================================================================

-- Set up automatic eviction with pg_cron (if available)
-- SELECT cron.schedule(
--     'semantic-cache-maintenance',
--     '*/15 * * * *',  -- Every 15 minutes
--     $$SELECT semantic_cache.auto_evict()$$
-- );

-- Manual maintenance procedure
CREATE OR REPLACE FUNCTION semantic_cache.maintenance() 
RETURNS TABLE(operation TEXT, affected_rows BIGINT) AS $$
BEGIN
    -- Evict expired entries
    RETURN QUERY SELECT 'evict_expired'::text, semantic_cache.evict_expired();
    
    -- Evict based on size limit
    RETURN QUERY SELECT 'evict_lru'::text, semantic_cache.evict_lru(NULL);
    
    -- Update statistics (if you add ANALYZE)
    EXECUTE 'ANALYZE semantic_cache.cache_entries';
    
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Run maintenance
SELECT * FROM semantic_cache.maintenance();

-- ============================================================================
-- PERFORMANCE TESTING
-- ============================================================================

-- Benchmark cache lookup performance
DO $$
DECLARE
    start_time timestamptz;
    end_time timestamptz;
    test_embedding vector(1536);
    i int;
BEGIN
    -- Generate test embedding
    SELECT array_agg(random()::float4) INTO test_embedding 
    FROM generate_series(1, 1536);
    
    -- Insert 1000 test entries
    FOR i IN 1..1000 LOOP
        PERFORM semantic_cache.cache_query(
            'SELECT ' || i,
            (SELECT array_agg(random()::float4) FROM generate_series(1, 1536))::vector,
            ('{"test": ' || i || '}')::jsonb,
            3600,
            NULL
        );
    END LOOP;
    
    -- Benchmark lookup time
    start_time := clock_timestamp();
    
    FOR i IN 1..100 LOOP
        PERFORM semantic_cache.get_cached_result(test_embedding, 0.95);
    END LOOP;
    
    end_time := clock_timestamp();
    
    RAISE NOTICE 'Average lookup time: % ms', 
        EXTRACT(MILLISECONDS FROM (end_time - start_time)) / 100;
END $$;

-- ============================================================================
-- CLEANUP (for testing only)
-- ============================================================================

-- DROP FUNCTION IF EXISTS my_app.cached_analytics_query(TEXT, JSONB);
-- DROP SCHEMA IF EXISTS my_app CASCADE;
-- SELECT semantic_cache.clear_cache();
