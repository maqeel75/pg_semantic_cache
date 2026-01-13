#!/bin/bash
# Quick start script for RAG server testing

set -e

cd "$(dirname "$0")/.."

echo "========================================="
echo "Starting pgEdge RAG Server Test Environment"
echo "========================================="
echo ""

echo "Building and starting containers..."
docker compose -f docker-compose.test-rag.yml up --build -d

echo ""
echo "Waiting for services to be ready..."
echo ""

# Wait for PostgreSQL
echo -n "PostgreSQL: "
for i in {1..30}; do
    if docker compose -f docker-compose.test-rag.yml exec -T postgres pg_isready -U postgres > /dev/null 2>&1; then
        echo "✓ Ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "✗ Failed to start"
        exit 1
    fi
    sleep 1
done

# Wait for RAG server
echo -n "RAG Server: "
for i in {1..30}; do
    if curl -s http://localhost:8080/health > /dev/null 2>&1; then
        echo "✓ Ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "✗ Failed to start"
        exit 1
    fi
    sleep 1
done

echo ""
echo "========================================="
echo "✓ Services are ready!"
echo "========================================="
echo ""
echo "Test endpoints:"
echo "  Health:       http://localhost:8080/health"
echo "  Query API:    http://localhost:8080/v1/query"
echo "  Cache Stats:  http://localhost:8080/cache/stats"
echo ""
echo "Quick tests:"
echo "  1. Run automated tests:"
echo "     ./test-rag/test-queries.sh"
echo ""
echo "  2. Send a test query:"
echo "     curl -X POST http://localhost:8080/v1/query \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"query\": \"What is PostgreSQL?\"}'"
echo ""
echo "  3. View cache statistics:"
echo "     curl http://localhost:8080/cache/stats"
echo ""
echo "  4. View PostgreSQL cache stats:"
echo "     docker compose -f docker-compose.test-rag.yml exec postgres \\"
echo "       psql -U postgres -d rag_db -c 'SELECT * FROM semantic_cache.cache_stats();'"
echo ""
echo "View logs:"
echo "  docker compose -f docker-compose.test-rag.yml logs -f"
echo ""
echo "Stop services:"
echo "  docker compose -f docker-compose.test-rag.yml down"
echo ""
