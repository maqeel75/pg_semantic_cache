# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`pg_semantic_cache` is a PostgreSQL extension written in C that implements semantic query result caching using vector embeddings. It leverages pgvector to perform similarity searches on cached queries, enabling efficient reuse of expensive query results (particularly useful for AI/LLM applications).

**Key Design Decision:** This extension is implemented in pure C rather than Rust (pgrx) to achieve:
- Smaller binary size (~100KB vs 2-5MB)
- Faster build times (10-30s vs 2-5min)
- Immediate PostgreSQL version support (no waiting for pgrx updates)
- Standard PGXS build system for easier packaging

## Build Commands

### Standard Build
```bash
# Clean and build
make clean
make

# Install extension (requires sudo for system directories)
sudo make install

# View build configuration
make info
```

### Development
```bash
# Build and install for development
make dev-install

# Run tests (requires running PostgreSQL instance)
make installcheck

# Run benchmarks
psql -U postgres -d your_db -f test/benchmark.sql

# Format C code
make format
```

### Multi-Version PostgreSQL Build
```bash
# Build for multiple PostgreSQL versions
for PG in 14 15 16 17 18; do
    PG_CONFIG=/usr/pgsql-${PG}/bin/pg_config make clean install
done
```

## Extension Installation and Usage

After building and installing, enable the extension in PostgreSQL:

```sql
CREATE EXTENSION IF NOT EXISTS vector;  -- Required dependency
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Initialize schema (creates tables, indexes, views)
SELECT semantic_cache.init_schema();

-- Verify installation
SELECT * FROM semantic_cache.cache_stats();
```

## Architecture

### Core Components

**Main Source:** `pg_semantic_cache.c` (~929 lines)
- Uses standard PostgreSQL C API (SPI, executor, utils)
- No external dependencies besides PostgreSQL and pgvector
- All functions use `PG_FUNCTION_INFO_V1` macro for registration

**Database Schema:** Created by `init_schema()` function
- `semantic_cache.cache_entries` - Stores cached queries with vector embeddings
- `semantic_cache.cache_metadata` - Tracks hits/misses and statistics
- `semantic_cache.cache_config` - Runtime configuration settings

**Key Indexes:**
- IVFFlat index on `query_embedding` vector column for fast similarity search
- B-tree indexes on `query_hash`, `expires_at`, `last_accessed_at`

### Function Categories

**Caching Functions:**
- `cache_query(text, text, jsonb, int, text[])` - Store query result with embedding
- `get_cached_result(text, float4, int)` - Retrieve by similarity search
- `invalidate_cache(text, text)` - Invalidate by pattern or tag

**Eviction Functions:**
- `evict_expired()` - Remove expired entries
- `evict_lru(int)` - Least Recently Used eviction
- `evict_lfu(int)` - Least Frequently Used eviction
- `auto_evict()` - Automatic eviction based on policy
- `clear_cache()` - Remove all entries

**Monitoring Functions:**
- `cache_stats()` - Comprehensive statistics record
- `cache_hit_rate()` - Current hit rate percentage

**Configuration Functions:**
- `get_config(text)` - Get configuration value
- `set_config(text, text)` - Set configuration value

### Vector Embedding Handling

Embeddings are stored as `vector(1536)` (dimensionality for OpenAI ada-002 model). The extension accepts embeddings as text representations (e.g., `'[0.1,0.2,0.3,...]'::text`) which are cast to the vector type internally.

Similarity search uses cosine distance operator (`<=>`) from pgvector:
- Similarity score = `1 - (query_embedding <=> search_embedding)`
- Configurable threshold (default 0.95)

## Code Patterns

### SPI (Server Programming Interface) Usage

All SQL execution uses SPI:
```c
SPI_connect();
ret = SPI_execute(query, false, 0);  // false = read-write, 0 = no limit
// ... process results ...
SPI_finish();
```

Always check return codes and handle errors appropriately.

### Memory Management

- Use `palloc()`/`pfree()` for PostgreSQL memory management
- Use `text_to_cstring()` to convert TEXT to C strings
- Always free allocated memory before function return
- StringInfo utilities (`initStringInfo`, `appendStringInfo`) handle dynamic strings

### Function Argument Handling

```c
// Check if argument is NULL
if (PG_ARGISNULL(n))
    // use default value
else
    value = PG_GETARG_TYPE(n);

// Return value
PG_RETURN_TYPE(value);
```

## Testing

**Test Files:**
- `test/benchmark.sql` - Performance benchmarks
- `examples/usage_examples.sql` - Usage patterns and examples

**Manual Testing:**
```sql
-- Run full example suite
\i examples/usage_examples.sql

-- Run benchmarks
\i test/benchmark.sql
```

## Performance Considerations

**Lookup Performance:**
- Target: < 5ms with IVFFlat index
- For large caches (>100k entries), increase IVFFlat lists: `WITH (lists = 1000)`
- Consider HNSW index for better performance (pgvector 0.5.0+)

**Cache Size:**
- Default max: 1000 MB
- Configurable via `semantic_cache.set_config('max_cache_size_mb', '2000')`
- Auto-eviction based on policy (LRU, LFU, TTL)

**PostgreSQL Settings:**
For production deployments with large caches:
```sql
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
ALTER SYSTEM SET work_mem = '256MB';  -- For vector operations
```

## Packaging Notes

Uses standard PGXS Makefile:
- `EXTENSION` variable defines extension name
- `DATA` variable lists SQL installation files
- `MODULES` variable lists shared library modules
- Compatible with standard PostgreSQL packaging tools (rpmbuild, dpkg-buildpackage)

The extension control file (`pg_semantic_cache.control`) defines metadata like version, requires dependencies, and default schema.

## Common Development Tasks

### Adding a New Function

1. Declare in C source with `PG_FUNCTION_INFO_V1(function_name);`
2. Implement function following pattern:
   ```c
   Datum function_name(PG_FUNCTION_ARGS) {
       // Get arguments with PG_GETARG_TYPE(n)
       // Perform operations
       // Return with PG_RETURN_TYPE(value)
   }
   ```
3. Add SQL function declaration to `sql/pg_semantic_cache--0.1.0-beta3.sql`
4. Rebuild and reinstall

### Modifying Schema

Schema changes require:
1. Update `init_schema()` function in C source
2. Consider migration path for existing installations
3. May require version bump and upgrade SQL script

### Performance Optimization

- Profile with `EXPLAIN ANALYZE` for query performance
- Use `pg_stat_statements` to identify slow operations
- Monitor index usage with `pg_stat_user_indexes`
- Adjust IVFFlat parameters based on cache size

## Dependencies

**Required:**
- PostgreSQL 14+ (tested through PG 18)
- pgvector extension
- Standard C compiler (gcc/clang)
- PostgreSQL development headers

**Build Tools:**
- make
- pg_config (from PostgreSQL installation)
- PGXS (PostgreSQL Extension Building Infrastructure)

## Troubleshooting

**Build Failures:**
- Ensure `pg_config` is in PATH and points to correct PostgreSQL version
- Install `postgresql-server-dev-XX` (Debian/Ubuntu) or `postgresqlXX-devel` (RHEL/Rocky)
- Check for pgvector installation

**Runtime Errors:**
- Verify pgvector is installed: `SELECT * FROM pg_extension WHERE extname = 'vector';`
- Check schema initialization: `SELECT * FROM semantic_cache.cache_entries LIMIT 1;`
- Review PostgreSQL logs for detailed error messages

**Performance Issues:**
- Check index usage: `EXPLAIN SELECT ... FROM semantic_cache.cache_entries WHERE ...`
- Increase IVFFlat lists for larger caches
- Monitor cache size and eviction frequency
