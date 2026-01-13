#!/bin/bash
# Test script for pg_semantic_cache integration

set -e

BASE_URL="http://localhost:8080"

echo "========================================="
echo "pg_semantic_cache RAG Server Test Suite"
echo "========================================="
echo ""

# Wait for server to be ready
echo "⏳ Waiting for server to be ready..."
for i in {1..30}; do
    if curl -s "$BASE_URL/health" > /dev/null 2>&1; then
        echo "✓ Server is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "✗ Server failed to start"
        exit 1
    fi
    sleep 1
done
echo ""

# Test 1: First query (cache miss)
echo "Test 1: First query (cache miss)"
echo "--------------------------------"
RESPONSE=$(curl -s -w "\nTime: %{time_total}s\n" -X POST "$BASE_URL/v1/query" \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}')
echo "$RESPONSE"
echo ""

# Test 2: Identical query (cache hit)
echo "Test 2: Identical query (cache hit - should be <50ms)"
echo "-----------------------------------------------------"
RESPONSE=$(curl -s -w "\nTime: %{time_total}s\n" -X POST "$BASE_URL/v1/query" \
  -H "Content-Type: application/json" \
  -d '{"query": "What is PostgreSQL?"}')
echo "$RESPONSE"
echo ""

# Test 3: Semantically similar query
echo "Test 3: Semantically similar query"
echo "-----------------------------------"
RESPONSE=$(curl -s -w "\nTime: %{time_total}s\n" -X POST "$BASE_URL/v1/query" \
  -H "Content-Type: application/json" \
  -d '{"query": "Tell me about PostgreSQL database"}')
echo "$RESPONSE"
echo ""

# Test 4: Different query (cache miss)
echo "Test 4: Different query (cache miss)"
echo "-------------------------------------"
RESPONSE=$(curl -s -w "\nTime: %{time_total}s\n" -X POST "$BASE_URL/v1/query" \
  -H "Content-Type: application/json" \
  -d '{"query": "How do I install Python?"}')
echo "$RESPONSE"
echo ""

# Test 5: Cache statistics
echo "Test 5: Cache Statistics"
echo "------------------------"
STATS=$(curl -s "$BASE_URL/cache/stats")
echo "$STATS" | python3 -m json.tool 2>/dev/null || echo "$STATS"
echo ""

# Test 6: Multiple rapid requests (demonstrate speedup)
echo "Test 6: Performance test (10 identical queries)"
echo "------------------------------------------------"
echo "This will send 10 identical queries to demonstrate cache speedup..."
START_TIME=$(date +%s%N)
for i in {1..10}; do
    curl -s -X POST "$BASE_URL/v1/query" \
      -H "Content-Type: application/json" \
      -d '{"query": "What are PostgreSQL features?"}' > /dev/null
done
END_TIME=$(date +%s%N)
ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))
echo "Total time for 10 queries: ${ELAPSED}ms"
echo "Average per query: $((ELAPSED / 10))ms"
echo "Expected: First query ~2000ms, rest ~5-10ms each"
echo ""

echo "========================================="
echo "Test Complete!"
echo "========================================="
echo ""
echo "To view detailed cache stats in PostgreSQL:"
echo "docker compose -f docker-compose.test-rag.yml exec postgres \\"
echo "  psql -U postgres -d rag_db -c 'SELECT * FROM semantic_cache.cache_stats();'"
echo ""
echo "To clear cache:"
echo "curl -X DELETE $BASE_URL/cache/clear"
