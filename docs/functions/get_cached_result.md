# get_cached_result

Retrieve a cached result by semantic similarity search.

## Signature

```sql
semantic_cache.get_cached_result(
    query_embedding text,
    similarity_threshold float4 DEFAULT 0.95,
    max_age_seconds integer DEFAULT NULL
) RETURNS TABLE(
    found boolean,
    result_data jsonb,
    similarity_score float4,
    age_seconds integer
)
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query_embedding` | text | required | Vector embedding as text (e.g., `'[0.1, 0.2, ...]'`) |
| `similarity_threshold` | float4 | 0.95 | Minimum cosine similarity (0.0-1.0) for a cache hit |
| `max_age_seconds` | integer | NULL | Optional maximum age of cached entry (NULL = no limit) |

## Returns

Returns a table with the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `found` | boolean | `true` if cache hit, no rows returned if miss |
| `result_data` | jsonb | The cached query result |
| `similarity_score` | float4 | Cosine similarity score (0.0-1.0) |
| `age_seconds` | integer | Age of cached entry in seconds |

!!! important "Return Behavior"
    - **Cache Hit**: Returns one row with `found = true`
    - **Cache Miss**: Returns zero rows (empty result set)

    Always check if rows were returned, not just the `found` value.

## Description

This function searches for cached results using semantic similarity based on vector embeddings. It uses cosine distance for comparison and returns the best match above the similarity threshold.

### Automatic Statistics Tracking

Every call to `get_cached_result()` automatically:
- Increments `total_hits` on cache hit
- Increments `total_misses` on cache miss
- Updates global cache statistics

### Search Behavior

1. Filters out expired entries
2. Calculates cosine similarity: `1 - (vector1 <=> vector2)`
3. Applies similarity threshold filter
4. Applies optional age filter
5. Returns the **single best match** (highest similarity)
6. Updates statistics in `cache_metadata`

## Examples

### Basic Cache Lookup

```sql
-- Try to get cached result
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := '[0.123, 0.456, 0.789, ...]'::text,
    similarity_threshold := 0.95
);
```

**Cache Hit Response:**
```
 found | result_data                      | similarity_score | age_seconds
-------+----------------------------------+------------------+-------------
 t     | {"count": 1542}                  | 0.98             | 145
```

**Cache Miss Response:**
```
(0 rows)
```

### Checking for Cache Hit

```sql
-- Application pattern for checking cache
DO $$
DECLARE
    cached RECORD;
BEGIN
    -- Try cache lookup
    SELECT * INTO cached FROM semantic_cache.get_cached_result(
        '[0.123, 0.456, ...]'::text,
        0.95
    );

    IF cached.found IS NOT NULL THEN
        RAISE NOTICE 'Cache HIT! Similarity: %, Age: %s',
            cached.similarity_score,
            cached.age_seconds;
        RAISE NOTICE 'Result: %', cached.result_data;
    ELSE
        RAISE NOTICE 'Cache MISS - need to execute query';
    END IF;
END $$;
```

### With Age Filter

```sql
-- Only accept results cached within last 5 minutes
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := '[0.234, 0.567, ...]'::text,
    similarity_threshold := 0.95,
    max_age_seconds := 300  -- 5 minutes
);
```

This is useful when:
- Data changes frequently
- Freshness is more important than cache hit rate
- Different queries have different freshness requirements

### Lenient Similarity Threshold

```sql
-- Accept more variation in queries (90% similarity)
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := '[0.345, 0.678, ...]'::text,
    similarity_threshold := 0.90,  -- More lenient
    max_age_seconds := NULL
);
```

**Trade-offs:**
- **Lower threshold (0.85-0.92)**: More cache hits, potentially less relevant results
- **Higher threshold (0.95-0.99)**: Fewer hits, more accurate results
- **Recommended**: Start with 0.93-0.95

### Strict Similarity Threshold

```sql
-- Require very similar queries (99% similarity)
SELECT * FROM semantic_cache.get_cached_result(
    query_embedding := '[0.456, 0.789, ...]'::text,
    similarity_threshold := 0.99,  -- Very strict
    max_age_seconds := NULL
);
```

## Integration Patterns

### Application-Level Caching Function

```sql
CREATE OR REPLACE FUNCTION my_app.cached_query(
    query_text TEXT,
    query_embedding TEXT
) RETURNS JSONB AS $$
DECLARE
    cached_result RECORD;
    actual_result JSONB;
BEGIN
    -- 1. Try cache first
    SELECT * INTO cached_result
    FROM semantic_cache.get_cached_result(query_embedding, 0.93);

    -- 2. Return cached result if found
    IF cached_result.found IS NOT NULL THEN
        RETURN cached_result.result_data;
    END IF;

    -- 3. Cache miss - execute actual query
    -- (Your expensive query logic here)
    actual_result := '{"executed": true, "timestamp": "' || NOW()::text || '"}';

    -- 4. Cache the new result
    PERFORM semantic_cache.cache_query(
        query_text,
        query_embedding,
        actual_result,
        3600,  -- 1 hour TTL
        ARRAY['app']
    );

    -- 5. Return result
    RETURN actual_result;
END;
$$ LANGUAGE plpgsql;
```

### Python Integration

```python
import psycopg2
import openai

def get_or_compute(query_text):
    # Generate embedding
    response = openai.Embedding.create(
        model="text-embedding-ada-002",
        input=query_text
    )
    embedding = str(response['data'][0]['embedding'])

    # Try cache
    conn = psycopg2.connect("dbname=mydb")
    cur = conn.cursor()
    cur.execute("""
        SELECT found, result_data, similarity_score
        FROM semantic_cache.get_cached_result(%s, 0.95)
    """, (embedding,))

    result = cur.fetchone()

    if result:  # Cache hit
        print(f"Cache HIT! Similarity: {result[2]:.4f}")
        return result[1]  # Return result_data

    # Cache miss - compute and cache
    print("Cache MISS - computing...")
    actual_result = expensive_computation(query_text)

    cur.execute("""
        SELECT semantic_cache.cache_query(%s, %s, %s, 3600, ARRAY['app'])
    """, (query_text, embedding, actual_result))
    conn.commit()

    return actual_result
```

### Node.js/TypeScript Integration

```typescript
import { Pool } from 'pg';

async function getCachedOrExecute(
  queryText: string,
  embedding: number[]
): Promise<any> {
  const pool = new Pool();
  const embeddingStr = `[${embedding.join(',')}]`;

  // Try cache
  const cacheResult = await pool.query(
    'SELECT * FROM semantic_cache.get_cached_result($1, 0.95)',
    [embeddingStr]
  );

  if (cacheResult.rows.length > 0) {
    console.log(`Cache HIT! Similarity: ${cacheResult.rows[0].similarity_score}`);
    return cacheResult.rows[0].result_data;
  }

  // Cache miss - execute and cache
  console.log('Cache MISS - executing query');
  const result = await executeExpensiveQuery(queryText);

  await pool.query(
    'SELECT semantic_cache.cache_query($1, $2, $3, 3600, ARRAY[$4])',
    [queryText, embeddingStr, JSON.stringify(result), 'app']
  );

  return result;
}
```

## Performance Considerations

### Lookup Speed

Target performance: **< 5ms** for most queries

Factors affecting speed:
- **Cache size**: More entries = slower lookups (mitigated by indexing)
- **Vector dimension**: Higher dimensions = more computation
- **Index type**: IVFFlat (fast) vs HNSW (accurate)
- **PostgreSQL configuration**: `work_mem` affects vector operations

### Optimizing Performance

```sql
-- For large caches, adjust IVFFlat parameters
DROP INDEX semantic_cache.idx_cache_entries_embedding;
CREATE INDEX idx_cache_entries_embedding
ON semantic_cache.cache_entries
USING ivfflat (query_embedding vector_cosine_ops)
WITH (lists = 1000);  -- Increase for 100K+ entries
```

### Monitoring Performance

```sql
-- Enable timing
\timing on

-- Test lookup speed
SELECT * FROM semantic_cache.get_cached_result(
    '[0.1, 0.2, ...]'::text,
    0.95
);

-- Check index usage
SELECT * FROM pg_stat_user_indexes
WHERE schemaname = 'semantic_cache';
```

## Understanding Similarity Scores

Cosine similarity ranges from 0.0 to 1.0:

| Score Range | Meaning | Recommendation |
|-------------|---------|----------------|
| 0.98 - 1.00 | Nearly identical | Always use |
| 0.95 - 0.98 | Very similar | Safe to use |
| 0.90 - 0.95 | Similar | Use with validation |
| 0.85 - 0.90 | Somewhat related | Use with caution |
| < 0.85 | Different | Avoid |

### Adjusting Threshold by Use Case

```sql
-- Exact matching required (financial data)
similarity_threshold := 0.97

-- General queries (analytics)
similarity_threshold := 0.93

-- Lenient matching (exploratory queries)
similarity_threshold := 0.88
```

## Common Issues

### No Results Despite Cache Entries

**Problem**: Cache has entries but always returns 0 rows

**Possible Causes:**
1. Similarity threshold too high
2. Entries expired
3. Wrong vector dimensions
4. Embedding model mismatch

**Debugging:**
```sql
-- Check cache entries exist
SELECT COUNT(*) FROM semantic_cache.cache_entries;

-- Check for expired entries
SELECT COUNT(*) FROM semantic_cache.cache_entries
WHERE expires_at IS NULL OR expires_at > NOW();

-- Try with lower threshold
SELECT * FROM semantic_cache.get_cached_result(
    '[...]'::text,
    0.70  -- Very lenient for testing
);

-- Check vector dimension
SELECT semantic_cache.get_vector_dimension();
```

### Low Hit Rate

If your cache hit rate is below 50%, consider:

1. **Lower threshold**: `0.90` instead of `0.95`
2. **Longer TTL**: Entries expiring too quickly
3. **More caching**: Not caching enough varied queries
4. **Better embeddings**: Poor quality embeddings

```sql
-- Check hit rate
SELECT * FROM semantic_cache.cache_stats();
```

## See Also

- [cache_query](cache_query.md) - Store results in cache
- [cache_stats](cache_stats.md) - View hit/miss statistics
- [Configuration](../configuration.md) - Tune similarity thresholds
- [Monitoring](../monitoring.md) - Track cache performance
