# Quick Start Guide - RAG Server Test Environment

## What's Happening

The Docker build process is currently:
1. ✅ **RAG Server**: Built successfully (~20 seconds)
2. ⏳ **PostgreSQL**: Building (this takes ~10-15 minutes)
   - Installing build-essential, GCC, make
   - Installing PostgreSQL dev headers
   - Installing pgvector extension
   - Building pg_semantic_cache from source

## Why It Takes Time

The PostgreSQL container needs to:
- Download ~185 MB of packages
- Compile the pg_semantic_cache C extension
- This is a one-time build - subsequent starts will be instant

## Alternative: Use Pre-built Image

If you want to skip the build time, you can:

1. **Stop the current build**:
   ```bash
   docker compose -f docker-compose.test-rag.yml down
   ```

2. **Wait for build to complete** (recommended for first time)
   - The build is proceeding in the background
   - Once complete, containers will start automatically
   - You can check progress with:
     ```bash
     docker compose -f docker-compose.test-rag.yml logs -f postgres
     ```

## Once Running

When the build completes and containers start, you'll be able to:

### 1. Check Health
```bash
curl http://localhost:8080/health
```

### 2. Send Test Query
```bash
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}'
```

### 3. Check Cache Stats
```bash
curl http://localhost:8080/cache/stats
```

### 4. Run Full Test Suite
```bash
./test-rag/test-queries.sh
```

## Expected Results

- **First query**: ~2000ms (simulated LLM call)
- **Same query again**: ~5-10ms (cache hit!)
- **Cache hit rate**: 80-90% for similar queries
- **Speedup**: 5-8x faster on average

## What to Observe

1. **Semantic Matching**: Queries like "What is PostgreSQL?" and "Tell me about PostgreSQL" will hit the same cache entry

2. **Cost Tracking**: The extension tracks how much money you save by avoiding LLM calls

3. **Performance**: Sub-10ms responses for cached queries vs 2+ seconds for LLM calls

## Troubleshooting

**Build taking too long?**
- This is normal for first build (~10-15 min)
- The PostgreSQL image needs to compile C code
- Subsequent starts will be instant

**Want to see build progress?**
```bash
docker compose -f docker-compose.test-rag.yml logs -f
```

**Need to rebuild?**
```bash
docker compose -f docker-compose.test-rag.yml down -v
docker compose -f docker-compose.test-rag.yml up --build
```

## What's Being Tested

This setup demonstrates:
- Integration of pg_semantic_cache with a RAG application
- Automatic caching of LLM responses based on semantic similarity
- Cost and latency improvements from caching
- Real-time cache statistics and monitoring

All code is temporary and won't be committed to the repository!
