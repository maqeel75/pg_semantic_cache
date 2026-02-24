-- Upgrade script from pg_semantic_cache 0.2.0 to 0.3.0
--
-- Major improvements in this version:
-- 1. Dynamic IVFFlat probes optimization (fixes cache retrieval bugs)
-- 2. Configurable vector dimensions (768, 1536, 3072, etc.)
-- 3. Configurable index type (IVFFlat vs HNSW)
-- 4. Automatic index optimization based on cache size

-- ============================================================================
-- NEW CONFIGURATION FUNCTIONS
-- ============================================================================

CREATE FUNCTION set_vector_dimension(dimension integer)
RETURNS void
AS 'MODULE_PATHNAME', 'set_vector_dimension'
LANGUAGE C STRICT;

CREATE FUNCTION get_vector_dimension()
RETURNS integer
AS 'MODULE_PATHNAME', 'get_vector_dimension'
LANGUAGE C STRICT;

CREATE FUNCTION set_index_type(index_type text)
RETURNS void
AS 'MODULE_PATHNAME', 'set_index_type'
LANGUAGE C STRICT;

CREATE FUNCTION get_index_type()
RETURNS text
AS 'MODULE_PATHNAME', 'get_index_type'
LANGUAGE C STRICT;

CREATE FUNCTION rebuild_index()
RETURNS void
AS 'MODULE_PATHNAME', 'rebuild_index'
LANGUAGE C STRICT;

-- ============================================================================
-- UPDATE COMMENTS FOR IMPROVED FUNCTIONS
-- ============================================================================

COMMENT ON FUNCTION get_cached_result(text, float4, integer) IS
  'Retrieve cached result by semantic similarity (automatically optimizes IVFFlat probes for reliable results)';

-- ============================================================================
-- ADD COMMENTS FOR NEW FUNCTIONS
-- ============================================================================

COMMENT ON FUNCTION set_vector_dimension(integer) IS
  'Configure vector embedding dimension (768, 1536, 3072, etc.) - call rebuild_index() to apply changes';

COMMENT ON FUNCTION get_vector_dimension() IS
  'Get configured vector embedding dimension';

COMMENT ON FUNCTION set_index_type(text) IS
  'Set vector index type: "ivfflat" (default, fast, approximate) or "hnsw" (accurate, requires pgvector 0.5.0+) - call rebuild_index() to apply';

COMMENT ON FUNCTION get_index_type() IS
  'Get configured vector index type (ivfflat or hnsw)';

COMMENT ON FUNCTION rebuild_index() IS
  'Rebuild cache table and index with current configuration (WARNING: clears all cached data)';
