#!/bin/bash
# Quick script to build and test in Docker
# Must be run from project root

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "Building Docker test image..."
docker build -f testing/docker/Dockerfile.test -t pg_semantic_cache:test .

echo ""
echo "Running tests in container..."
docker run --rm pg_semantic_cache:test

echo ""
echo "Build and test completed successfully!"
