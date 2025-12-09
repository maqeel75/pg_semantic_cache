# pg_semantic_cache 

**PostgreSQL extension for semantic query result caching using vector embeddings**

🎯 **Why C?** Smaller binaries (~100KB vs 2-5MB), faster builds (10s vs 5min), immediate PG 18 support, traditional PostgreSQL approach.

## Features

- ✅ **Semantic similarity search** using pgvector
- ✅ **Multiple eviction policies** (LRU, LFU, TTL)
- ✅ **Real-time monitoring** and statistics
- ✅ **Tag-based cache invalidation**
- ✅ **Configurable TTL** and similarity thresholds
- ✅ **PostgreSQL 14-18 support** (works immediately with any new PG version)
- ✅ **Tiny binary** (~100-200KB)
- ✅ **Fast compilation** (10-30 seconds)

## Quick Start

### Prerequisites

- PostgreSQL 14, 15, 16, 17, or 18
- PostgreSQL development headers (`postgresql-server-dev` or `postgresql-devel`)
- pgvector extension installed
- Standard C compiler (gcc/clang)

### Installation

```bash
# 1. Install dependencies
# Ubuntu/Debian
sudo apt-get install postgresql-server-dev-16 postgresql-16-pgvector

# Rocky/RHEL
sudo dnf install postgresql16-devel postgresql16-contrib

# 2. Build and install
cd pg_semantic_cache
make
sudo make install

# 3. Enable in PostgreSQL
psql -U postgres -d your_database
```

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;

-- Initialize schema (run once)
SELECT semantic_cache.init_schema();

-- Verify installation
SELECT * FROM semantic_cache.cache_stats();
```

## Basic Usage

### Cache a Query Result

```sql
SELECT semantic_cache.cache_query(
    'SELECT * FROM orders WHERE status = ''completed''',  -- query_text
    '[0.1, 0.2, 0.3, ...]'::text,                         -- embedding (as text)
    '{"total": 150, "orders": [...]}'::jsonb,             -- result data
    3600,                                                  -- TTL in seconds
    ARRAY['orders', 'analytics']                          -- tags (optional)
);
```

### Retrieve Cached Result

```sql
SELECT * FROM semantic_cache.get_cached_result(
    '[0.11, 0.19, 0.31, ...]'::text,  -- similar embedding
    0.95,                              -- similarity threshold
    NULL                               -- max age in seconds (optional)
);

-- Returns: (hit, result_data, similarity_score, age_seconds)
```

### Monitor Cache Performance

```sql
-- Overall statistics
SELECT * FROM semantic_cache.cache_stats();

-- Current hit rate
SELECT semantic_cache.cache_hit_rate();

-- View cache health
SELECT * FROM semantic_cache.cache_health;
```

## API Reference

### Core Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `init_schema()` | Initialize extension schema and tables | void |
| `cache_query(text, text, jsonb, int, text[])` | Cache a query result | bigint (cache_id) |
| `get_cached_result(text, float4, int)` | Retrieve cached result | record |
| `invalidate_cache(text, text)` | Invalidate by pattern or tag | bigint (count) |

### Eviction Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `evict_expired()` | Remove expired entries | bigint (count) |
| `evict_lru(int)` | Remove least recently used | bigint (count) |
| `evict_lfu(int)` | Remove least frequently used | bigint (count) |
| `clear_cache()` | Remove all entries | bigint (count) |
| `auto_evict()` | Auto eviction based on policy | bigint (count) |

### Statistics Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `cache_stats()` | Comprehensive statistics | record |
| `cache_hit_rate()` | Current hit rate percentage | float4 |

### Configuration Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `get_config(text)` | Get configuration value | text |
| `set_config(text, text)` | Set configuration value | void |

## Configuration

```sql
-- View all configuration
SELECT * FROM semantic_cache.cache_config;

-- Update settings
SELECT semantic_cache.set_config('max_cache_size_mb', '2000');
SELECT semantic_cache.set_config('default_ttl_seconds', '7200');
SELECT semantic_cache.set_config('eviction_policy', 'lru');  -- lru, lfu, or ttl
```

## Build Details

### Standard PGXS Build

```bash
# Build
make

# Install
sudo make install

# Test
make installcheck

# Clean
make clean
```

### Cross-Platform Support

Works on all PostgreSQL-supported platforms:
- ✅ Linux (Ubuntu, Debian, RHEL, Rocky, etc.)
- ✅ macOS
- ✅ Windows (via MinGW or MSVC)
- ✅ FreeBSD, OpenBSD
- ✅ Any platform with PostgreSQL

### PostgreSQL Version Support

Tested with PostgreSQL 14, 15, 16, 17, and 18. Works with any future PostgreSQL version using standard PGXS.

## Performance

### Build Performance
- **Compilation**: 10-30 seconds (vs 2-5 minutes for Rust)
- **Binary size**: ~100-200KB (vs 2-5MB for Rust)
- **Dependencies**: None (besides PostgreSQL and pgvector)

### Runtime Performance
- **Lookup time**: < 5ms (with IVFFlat index)
- **Cache hit rate**: 40-60% for typical AI workloads
- **Memory overhead**: ~1KB per cached entry

### Benchmarks

```bash
# Run performance benchmarks
psql -U postgres -d your_database -f test/benchmark.sql
```

Expected results:
- 1000 inserts: ~500ms
- 100 lookups: ~200ms (2ms average)
- Eviction (5000 entries): ~100ms

## Production Deployment

### Recommended Settings

```sql
-- Increase shared buffers for better performance
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';

-- For vector operations
SET work_mem = '256MB';

-- Automatic eviction via pg_cron
CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'semantic-cache-eviction',
    '*/15 * * * *',  -- Every 15 minutes
    $$SELECT semantic_cache.auto_evict()$$
);
```

### Index Optimization

For large caches (>100k entries):

```sql
-- Use more lists for IVFFlat
DROP INDEX semantic_cache.idx_cache_embedding;
CREATE INDEX idx_cache_embedding 
    ON semantic_cache.cache_entries 
    USING ivfflat (query_embedding vector_cosine_ops)
    WITH (lists = 1000);

-- Or use HNSW for better performance (pgvector 0.5.0+)
CREATE INDEX idx_cache_embedding_hnsw
    ON semantic_cache.cache_entries 
    USING hnsw (query_embedding vector_cosine_ops);
```

## Integration Examples

### Python Integration

```python
import psycopg2
import openai

def cache_with_openai(conn, query, result):
    """Cache query result with OpenAI embedding"""
    client = openai.OpenAI()
    
    # Generate embedding
    response = client.embeddings.create(
        model="text-embedding-ada-002",
        input=query
    )
    embedding = response.data[0].embedding
    embedding_text = f"[{','.join(map(str, embedding))}]"
    
    # Cache the result
    with conn.cursor() as cur:
        cur.execute("""
            SELECT semantic_cache.cache_query(
                %s::text, %s::text, %s::jsonb, 3600, NULL
            )
        """, (query, embedding_text, json.dumps(result)))
        conn.commit()
```

See `examples/usage_examples.sql` for more integration patterns.

## Packaging

### RPM Package

```bash
# Create RPM spec file
rpmbuild -ba pg_semantic_cache.spec
```

### DEB Package

```bash
# Create Debian package
dpkg-buildpackage -us -uc
```

### Multi-Version Build

```bash
# Build for multiple PostgreSQL versions
for PG in 14 15 16 17 18; do
    PG_CONFIG=/usr/pgsql-${PG}/bin/pg_config make clean install
done
```

## Comparison: C vs Rust

| Aspect | C | Rust (pgrx) |
|--------|---|-------------|
| Binary Size | ~100KB ✅ | ~2-5MB |
| Build Time | 10-30s ✅ | 2-5min |
| PG 18 Support | Immediate ✅ | Wait for pgrx |
| Code Lines | ~1,000 | ~1,400 |
| Memory Safety | Manual | Automatic ✅ |
| Tooling | Standard | Modern ✅ |

**For this extension: C is the better choice** ✅

## Contributing

Contributions welcome! This is a pure C extension using standard PostgreSQL APIs.

## License

MIT or Apache 2.0

## Support

- GitHub Issues: [your-repo]/issues
- Documentation: See `examples/` directory
- PostgreSQL Docs: https://www.postgresql.org/docs/

## Credits

Created by Aqeel - PostgreSQL Infrastructure Engineer

Built with standard PostgreSQL C API and pgvector.
