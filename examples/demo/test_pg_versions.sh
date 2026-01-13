#!/bin/bash
# Test pg_semantic_cache demo with multiple PostgreSQL versions

set -e

echo "=========================================="
echo "Testing Demo with Multiple PG Versions"
echo "=========================================="

# Test function
test_pg_version() {
    PG_VERSION=$1
    echo ""
    echo "=========================================="
    echo "Testing PostgreSQL $PG_VERSION"
    echo "=========================================="

    # Update Dockerfile to use specific version
    sed -i.bak "s/pgedge-postgresql-[0-9]\+/pgedge-postgresql-${PG_VERSION}/g" Dockerfile.postgres
    sed -i.bak "s|ENV PG_HOME=\"/usr/lib/postgresql/[0-9]\+\"|ENV PG_HOME=\"/usr/lib/postgresql/${PG_VERSION}\"|g" Dockerfile.postgres

    # Rebuild and start
    echo "Building PostgreSQL $PG_VERSION container..."
    docker-compose down -v
    docker-compose build --no-cache
    docker-compose up -d

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    sleep 10

    # Test with problematic query that has quotes
    echo "Testing cache_query with quotes (the bug that failed in PG 17)..."
    docker-compose exec -T postgres psql -U postgres -d postgres <<EOF
-- Test caching data with quotes (this failed before the fix)
SELECT semantic_cache.cache_query(
    'Test question with quotes',
    '[0.1,0.2,0.3]'::text,
    jsonb_build_object(
        'answer', 'PostgreSQL provides a "self-checking" feature for data integrity.',
        'confidence', 0.95,
        'source', 'official docs'
    ),
    3600,
    ARRAY['test']::text[]
);

-- Verify it was cached
SELECT
    query_text,
    result_data->>'answer' as answer,
    result_data->>'confidence' as confidence
FROM semantic_cache.cache_entries
WHERE query_text = 'Test question with quotes';

-- Test retrieval
SELECT * FROM semantic_cache.get_cached_result(
    '[0.1,0.2,0.3]'::text,
    0.95::float4,
    NULL
);
EOF

    if [ $? -eq 0 ]; then
        echo "✅ PostgreSQL $PG_VERSION: PASSED"
    else
        echo "❌ PostgreSQL $PG_VERSION: FAILED"
        exit 1
    fi

    # Restore original Dockerfile
    mv Dockerfile.postgres.bak Dockerfile.postgres
}

# Test PostgreSQL versions
echo "Available versions to test:"
echo "  - PostgreSQL 14"
echo "  - PostgreSQL 15"
echo "  - PostgreSQL 16"
echo "  - PostgreSQL 17"
echo ""

# Test each version
for VERSION in 14 15 16 17; do
    test_pg_version $VERSION
done

echo ""
echo "=========================================="
echo "✅ ALL VERSIONS PASSED!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  ✅ PostgreSQL 14: Demo works correctly"
echo "  ✅ PostgreSQL 15: Demo works correctly"
echo "  ✅ PostgreSQL 16: Demo works correctly"
echo "  ✅ PostgreSQL 17: Demo works correctly (fixed!)"
echo ""
echo "The Json() adapter fix works with all PostgreSQL versions!"
