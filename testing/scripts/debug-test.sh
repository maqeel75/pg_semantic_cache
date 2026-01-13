#!/bin/bash
# Debug test script for Docker
# Must be run from project root

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "Building Docker image..."
docker build -q -f testing/docker/Dockerfile.test -t pg_semantic_cache:test .

echo "Running debug test..."
docker run --rm pg_semantic_cache:test bash -c '
echo "Initializing PostgreSQL..."
su postgres -c "/usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/data" > /dev/null 2>&1

echo "Starting PostgreSQL..."
su postgres -c "pg_ctl -D /var/lib/postgresql/data -l /tmp/postgres.log start" > /dev/null 2>&1
sleep 2

echo "Creating test database..."
su postgres -c "createdb test_cache" > /dev/null 2>&1

echo "Creating vector extension..."
su postgres -c "psql test_cache -c \"CREATE EXTENSION IF NOT EXISTS vector;\"" > /dev/null 2>&1

echo ""
echo "Attempting to create pg_semantic_cache extension..."
su postgres -c "psql test_cache -c \"CREATE EXTENSION pg_semantic_cache;\"" 2>&1 || {
    echo ""
    echo "========================================="
    echo "PostgreSQL Error Log:"
    echo "========================================="
    cat /tmp/postgres.log
}
'
