#!/bin/bash
# Quick script to build and test in Docker

set -e

echo "Building Docker test image..."
docker build -f Dockerfile.test -t pg_semantic_cache:test .

echo ""
echo "Running tests in container..."
docker run --rm pg_semantic_cache:test

echo ""
echo "Build and test completed successfully!"
