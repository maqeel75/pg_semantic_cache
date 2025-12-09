#!/bin/bash
# Quick installation script for pg_semantic_cache (C version)

set -e

echo "=========================================="
echo "pg_semantic_cache - C Version Installer"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check PostgreSQL
if ! command -v pg_config &> /dev/null; then
    echo -e "${RED}❌ PostgreSQL not found${NC}"
    echo "Please install PostgreSQL first."
    exit 1
fi

PG_VERSION=$(pg_config --version | grep -oP '\d+' | head -1)
echo -e "${GREEN}✓${NC} PostgreSQL found: $(pg_config --version)"

# Check development headers
if [ ! -f "$(pg_config --includedir-server)/postgres.h" ]; then
    echo -e "${YELLOW}⚠${NC} PostgreSQL development headers not found"
    echo "Install postgresql-server-dev-${PG_VERSION} or postgresql${PG_VERSION}-devel"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check pgvector
if ! psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_available_extensions WHERE name = 'vector'" | grep -q 1; then
    echo -e "${YELLOW}⚠${NC} pgvector not found"
    echo "Install postgresql-${PG_VERSION}-pgvector"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Build
echo ""
echo "Building pg_semantic_cache..."
make clean
make

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Build successful"
else
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

# Install
echo ""
echo "Installing pg_semantic_cache..."
sudo make install

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Installation successful"
else
    echo -e "${RED}❌ Installation failed${NC}"
    exit 1
fi

# Test database setup
echo ""
read -p "Create test database? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    DB_NAME="pg_semantic_cache_test"
    
    # Create database
    psql -U postgres -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null || echo "Database already exists"
    
    # Install extensions
    psql -U postgres -d ${DB_NAME} <<EOF
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_semantic_cache;
SELECT semantic_cache.init_schema();
SELECT * FROM semantic_cache.cache_stats();
EOF
    
    echo -e "${GREEN}✓${NC} Test database created: ${DB_NAME}"
fi

# Show next steps
echo ""
echo "=========================================="
echo -e "${GREEN}Installation Complete!${NC} 🎉"
echo "=========================================="
echo ""
echo "Binary size: $(ls -lh $(pg_config --pkglibdir)/pg_semantic_cache.so | awk '{print $5}')"
echo "Build time: ~10-30 seconds"
echo ""
echo "Next steps:"
echo "1. Connect to your database:"
echo "   psql -U postgres -d your_database"
echo ""
echo "2. Enable the extension:"
echo "   CREATE EXTENSION pg_semantic_cache;"
echo "   SELECT semantic_cache.init_schema();"
echo ""
echo "3. Try examples:"
echo "   \\i examples/usage_examples.sql"
echo ""
echo "4. Run benchmarks:"
echo "   \\i test/benchmark.sql"
echo ""
