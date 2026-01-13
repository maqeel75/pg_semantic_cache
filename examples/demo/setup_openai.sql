-- Setup script for pg_semantic_cache demo with OpenAI embeddings (1536 dimensions)

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

-- Update configuration for OpenAI embeddings (1536 dimensions)
SELECT semantic_cache.set_vector_dimension(1536);
SELECT semantic_cache.set_index_type('hnsw');

-- Note: No need to rebuild_index() on fresh install since the extension
-- creates tables with the configured dimension automatically

-- Verify configuration
SELECT semantic_cache.get_vector_dimension() AS configured_dimension;
SELECT semantic_cache.get_index_type() AS configured_index_type;

-- Show initial cache stats
SELECT * FROM semantic_cache.cache_stats();

SELECT 'Setup complete! Extension configured for 1536-dimensional vectors (OpenAI ada-002).' AS status;
