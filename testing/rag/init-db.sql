-- Initialize database for RAG server testing
-- This script runs automatically when the container starts

\c rag_db;

-- Install required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Initialize semantic cache schema
SELECT semantic_cache.init_schema();

-- Create sample documents table for RAG testing
CREATE TABLE IF NOT EXISTS documents (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    embedding vector(1536),
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create index for vector search
CREATE INDEX IF NOT EXISTS idx_documents_embedding
ON documents USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Insert sample documents about PostgreSQL
INSERT INTO documents (content, metadata) VALUES
    ('PostgreSQL is a powerful, open source object-relational database system with over 35 years of active development.',
     '{"category": "overview", "source": "docs"}'),
    ('PostgreSQL has earned a strong reputation for its proven architecture, reliability, data integrity, and extensibility.',
     '{"category": "features", "source": "docs"}'),
    ('PostgreSQL runs on all major operating systems, including Linux, UNIX, and Windows.',
     '{"category": "compatibility", "source": "docs"}'),
    ('PostgreSQL supports advanced data types including JSON, XML, arrays, and custom types.',
     '{"category": "data-types", "source": "docs"}'),
    ('The pgvector extension enables vector similarity search in PostgreSQL for AI applications.',
     '{"category": "extensions", "source": "docs"}'),
    ('PostgreSQL supports ACID transactions and provides robust data consistency guarantees.',
     '{"category": "reliability", "source": "docs"}'),
    ('PostgreSQL offers full text search capabilities with advanced ranking and indexing options.',
     '{"category": "search", "source": "docs"}'),
    ('PostgreSQL can be extended with custom functions, operators, and data types using C, Python, or other languages.',
     '{"category": "extensibility", "source": "docs"}'),
    ('PostgreSQL supports table partitioning for managing large datasets efficiently.',
     '{"category": "performance", "source": "docs"}'),
    ('PostgreSQL provides comprehensive security features including SSL, SCRAM authentication, and row-level security.',
     '{"category": "security", "source": "docs"}');

-- Verify cache installation
SELECT 'Cache Stats:' as info, * FROM semantic_cache.cache_stats();

-- Show configuration
SELECT 'Cache Config:' as info, * FROM semantic_cache.cache_config;

-- Create a view for easy monitoring
CREATE OR REPLACE VIEW cache_monitor AS
SELECT
    c.total_entries,
    c.total_hits,
    c.total_misses,
    c.hit_rate_percent
FROM semantic_cache.cache_stats() c;

GRANT SELECT ON cache_monitor TO PUBLIC;

\echo 'Database initialized successfully!'
\echo 'Extensions installed: vector, pg_semantic_cache'
\echo 'Sample documents loaded: 10 PostgreSQL documentation entries'
\echo 'Ready for RAG server testing'
