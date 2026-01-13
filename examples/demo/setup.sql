-- Setup script for pg_semantic_cache demo with mxbai-embed-large (1024 dimensions)

-- Create vector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create pg_semantic_cache extension (creates tables with default 1536 dims)
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Configure for your embedding model (common options):
-- 384: all-minilm, snowflake-arctic-embed-m (fast, efficient)
-- 768: nomic-embed-text, bge-base (balanced)
-- 1024: mxbai-embed-large, bge-m3 (high quality, Ollama default)
-- 1536: OpenAI ada-002 (requires API key)
-- 3072: OpenAI text-embedding-3-large (requires API key)

-- Update configuration for mxbai-embed-large
SELECT semantic_cache.set_vector_dimension(1024);
SELECT semantic_cache.set_index_type('hnsw');

-- Alter the table to change vector dimensions
-- First drop the index (can't alter column type with index)
DROP INDEX IF EXISTS semantic_cache.idx_cache_embedding;

-- Change vector column dimensions from 1536 to 1024
ALTER TABLE semantic_cache.cache_entries
ALTER COLUMN query_embedding TYPE vector(1024);

-- Recreate index with HNSW (better than IVFFlat)
CREATE INDEX idx_cache_embedding ON semantic_cache.cache_entries
USING hnsw (query_embedding vector_cosine_ops);

-- Verify configuration
SELECT semantic_cache.get_vector_dimension() AS configured_dimension;
SELECT semantic_cache.get_index_type() AS configured_index_type;

-- Show initial cache stats
SELECT * FROM semantic_cache.cache_stats();

SELECT 'Setup complete! Extension configured for 1024-dimensional vectors (mxbai-embed-large).' AS status;
