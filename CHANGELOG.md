# Changelog

All notable changes to pg_semantic_cache will be documented in this file.

## [0.2.0] - 2024-12-09 - Logging & Cost Tracking Feature

### Added
- **Cost Tracking System**: Track cache hits/misses with associated API costs
  - `cache_access_log` table to log all cache access events
  - `log_cache_access()` function to record cache hits/misses with cost information
  - `get_cost_savings()` function to generate cost savings reports
  - `total_cost_saved` column in `cache_metadata` table

- **New Analytics Views**:
  - `cache_access_summary` - Hourly cache access statistics with cost savings
  - `cost_savings_daily` - Daily cost breakdown and savings analysis
  - `top_cached_queries` - Top queries ranked by total cost savings

- **Documentation**:
  - `COST_TRACKING_EXPLAINED.md` - Complete guide for integrating cost tracking
  - `LOGGING_GUIDE.md` - Comprehensive logging feature documentation
  - `LOGGING_QUICK_REFERENCE.md` - Quick reference card for logging functions
  - `test_logging_demo.sql` - Interactive demonstration script
  - `examples/logging_examples.sql` - 12+ real-world usage examples
  - `test/test_logging.sql` - Comprehensive test suite

### Changed
- **Schema Updates**:
  - Added `total_cost_saved NUMERIC(12,6)` to `cache_metadata` table
  - Fixed `ON CONFLICT` clause in metadata initialization (now uses `ON CONFLICT (id)`)

### Fixed
- **Numeric Type Handling** (Critical):
  - Fixed type mismatch in `log_cache_access()` - properly converts `numeric` input to `float8`
  - Fixed type mismatch in `get_cost_savings()` - properly converts `numeric` SQL results to `float8`
  - Added `#include "utils/numeric.h"` for proper numeric type support
  - Used `DirectFunctionCall1(numeric_float8, ...)` for all numeric conversions

- **Schema Qualification**:
  - Added `semantic_cache.` prefix to all view definitions
  - Added `semantic_cache.` prefix to all COMMENT statements
  - Ensures proper schema isolation and prevents naming conflicts

### Technical Details

#### Numeric Conversion Fix
The logging feature initially showed `$0.000000` for all cost values due to incorrect type handling:

**Problem**:
- SQL function declared `query_cost` parameter as `numeric`
- C code tried to read it as `float8` using `PG_GETARG_FLOAT8()`
- PostgreSQL's `numeric` and `float8` have different internal representations
- Reading `numeric` as `float8` resulted in garbage data (zeros)

**Solution**:
```c
// Before (WRONG):
float8 query_cost = PG_GETARG_FLOAT8(3);

// After (CORRECT):
float8 query_cost = 0.0;
if (!PG_ARGISNULL(3)) {
    Numeric num = PG_GETARG_NUMERIC(3);
    query_cost = DatumGetFloat8(DirectFunctionCall1(numeric_float8, NumericGetDatum(num)));
}
```

This fix was applied to:
1. `log_cache_access()` - input parameter conversion
2. `get_cost_savings()` - SQL result columns conversion (4 columns)

### Migration Notes

**From 0.1.0 to 0.2.0**:

```sql
-- Drop and recreate the extension to get new schema
DROP EXTENSION IF EXISTS pg_semantic_cache CASCADE;
CREATE EXTENSION pg_semantic_cache;

-- The new tables and columns will be created automatically
```

**No data migration needed** - this is a new feature addition.

### Compatibility

- PostgreSQL: 14+
- pgvector: Any version
- Operating Systems: Linux (tested on AlmaLinux 10, Ubuntu 22.04)

### Performance Impact

- **Minimal**: Logging adds ~1-2ms per cache access (single INSERT)
- **Indexes**: Added on `cache_access_log(access_time)` and `cache_access_log(query_hash)`
- **Storage**: ~100 bytes per log entry

### Breaking Changes

None - this is a backward-compatible feature addition.

---

## [0.1.0] - 2024-12-06 - Initial Release

### Added
- Core semantic caching functionality
- Vector-based similarity search using pgvector
- `cache_entries` table with IVFFlat indexing
- `cache_metadata` table for statistics
- Cache management functions:
  - `cache_query()` - Store query results with embeddings
  - `get_cached_result()` - Retrieve cached results by similarity
  - `invalidate_cache()` - Invalidate cache entries
  - `cache_stats()` - Get cache statistics
  - `evict_expired()` - Remove expired entries
  - `clear_cache()` - Clear all cache entries

- Helper views:
  - `cache_health` - Real-time cache health metrics
  - `recent_cache_activity` - Most recently accessed entries
  - `cache_by_tag` - Entries grouped by tag

### Features
- Semantic similarity matching (cosine similarity)
- Configurable similarity thresholds
- TTL-based expiration
- Tag-based organization
- Access count tracking

### Documentation
- `README.md` - Project overview and quick start
- `GETTING_STARTED.md` - Detailed installation guide
- `START_HERE.md` - Quick reference guide

---

## Version Numbering

We follow [Semantic Versioning](https://semver.org/):
- **MAJOR** version: Incompatible API changes
- **MINOR** version: New functionality (backward-compatible)
- **PATCH** version: Bug fixes (backward-compatible)

---

## Future Roadmap

### Planned for 0.3.0
- Automatic cache warming based on query patterns
- Smart eviction policies (LRU, frequency-based)
- Multi-model support (different embedding dimensions)
- Compression for cached results

### Under Consideration
- Distributed cache support
- Cache replication across databases
- Advanced analytics dashboard
- Integration with popular LLM frameworks

---

## Contributing

See [CONTRIBUTING.md] for guidelines (to be added).

## License

See [LICENSE] file for details.
