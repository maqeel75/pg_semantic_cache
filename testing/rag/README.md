# pgEdge RAG Server Testing with pg_semantic_cache

This directory contains a Docker Compose setup for testing the pg_semantic_cache extension with a simplified RAG server.

## Quick Start

### 1. Start the Services

```bash
# From the pg_semantic_cache root directory
docker compose -f docker-compose.test-rag.yml up --build
```

This will start:
- PostgreSQL 17 with pg_semantic_cache and pgvector extensions
- A minimal RAG server (Go) that demonstrates cache integration

### 2. Test the Setup

**Health Check:**
```bash
curl http://localhost:8080/health
```

**First Query (Cache Miss):**
```bash
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}'
```

Expected response time: ~2000ms (simulated LLM call)

**Second Query (Cache Hit):**
```bash
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}'
```

Expected response time: ~5-10ms (cache lookup)

**Check Cache Statistics:**
```bash
curl http://localhost:8080/cache/stats
```

### 3. Test Semantic Similarity

Try queries that are semantically similar:

```bash
# Original query
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}'

# Similar query (should hit cache with high similarity)
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Tell me about PostgreSQL"}'

# Different query (cache miss)
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "How do I install Python?"}'
```

### 4. Monitor Cache Performance

**View cache stats from PostgreSQL:**
```bash
docker compose -f docker-compose.test-rag.yml exec postgres \
  psql -U postgres -d rag_db -c "SELECT * FROM semantic_cache.cache_stats();"
```

**View cached entries:**
```bash
docker compose -f docker-compose.test-rag.yml exec postgres \
  psql -U postgres -d rag_db -c "SELECT query_hash, hit_count, miss_count, total_cost_saved FROM semantic_cache.cache_entries ORDER BY created_at DESC LIMIT 10;"
```

**Clear cache:**
```bash
curl -X DELETE http://localhost:8080/cache/clear
```

### 5. Benchmark Cache Performance

Run multiple queries to see cache impact:

```bash
# Install hey (HTTP load testing tool) if not already installed
# macOS: brew install hey
# Linux: go install github.com/rakyll/hey@latest

# Benchmark with same query (high cache hit rate)
hey -n 100 -c 10 -m POST \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}' \
  http://localhost:8080/v1/query
```

Expected results:
- First request: ~2000ms (cache miss)
- Subsequent 99 requests: ~5-10ms (cache hits)
- Overall average: ~25-50ms

## Architecture

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ HTTP POST /v1/query
       ▼
┌─────────────────────────────┐
│     RAG Server (Go)         │
│                             │
│  1. Generate embedding      │
│  2. Check semantic cache ◄──┼─────┐
│  3. If miss:                │     │
│     - Search documents      │     │
│     - Call LLM (mock)       │     │
│     - Cache result          │     │
└──────────┬──────────────────┘     │
           │                        │
           ▼                        │
┌──────────────────────────┐       │
│   PostgreSQL 17          │       │
│                          │       │
│  • pgvector extension    │       │
│  • pg_semantic_cache ────┼───────┘
│  • Sample documents      │
└──────────────────────────┘
```

## Configuration

Edit `docker-compose.test-rag.yml` to adjust:

- `CACHE_SIMILARITY_THRESHOLD`: 0.0-1.0 (default: 0.95)
  - Higher = stricter matching, fewer cache hits
  - Lower = looser matching, more cache hits

- `CACHE_TTL_SECONDS`: Cache entry lifetime (default: 3600 = 1 hour)

## Cleanup

```bash
# Stop and remove containers
docker compose -f docker-compose.test-rag.yml down

# Remove volumes (clears database)
docker compose -f docker-compose.test-rag.yml down -v
```

## Notes

- This is a **simplified test setup** with mock embeddings and LLM responses
- Real pgEdge RAG server would integrate OpenAI/Anthropic APIs
- The mock server simulates 2-second LLM latency to demonstrate cache speedup
- Cache statistics and cost tracking are fully functional
- Database is pre-populated with 10 PostgreSQL documentation entries

## Next Steps

Once you've tested this setup and understand the integration:

1. Clone the actual pgEdge RAG server repository
2. Apply the integration code from `PGEDGE_RAG_INTEGRATION_ANALYSIS.md`
3. Test with real embeddings and LLM APIs
4. Monitor cost savings and performance improvements
