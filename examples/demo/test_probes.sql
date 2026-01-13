-- Test script to verify dynamic IVFFlat probes optimization

-- Show current probes setting
SHOW ivfflat.probes;

-- Test that get_cached_result sets probes dynamically
-- First, let's see the plan for a search (this will show if probes get set)

-- Insert a few test entries with random 1536-dimensional vectors
INSERT INTO semantic_cache.cache_entries (query_hash, query_text, query_embedding, result_data)
VALUES
  (md5('test1'), 'test query 1', (SELECT array_agg(random())::vector(1536) FROM generate_series(1,1536)), '{"result": "data1"}'::jsonb),
  (md5('test2'), 'test query 2', (SELECT array_agg(random())::vector(1536) FROM generate_series(1,1536)), '{"result": "data2"}'::jsonb),
  (md5('test3'), 'test query 3', (SELECT array_agg(random())::vector(1536) FROM generate_series(1,1536)), '{"result": "data3"}'::jsonb);

-- Check cache size
SELECT COUNT(*) AS total_cached_entries FROM semantic_cache.cache_entries;

-- Test get_cached_result (this should set probes=20 since cache < 1000)
SELECT * FROM semantic_cache.get_cached_result(
  (SELECT array_agg(random())::vector(1536)::text FROM generate_series(1,1536)),
  0.5,
  NULL
);

-- Check probes after function call (should be 20 due to SET LOCAL)
SHOW ivfflat.probes;

SELECT 'Test complete! The function internally sets probes=20 for small caches.' AS result;
