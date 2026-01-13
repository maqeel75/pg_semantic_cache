# Testing Directory

This directory contains all testing and development-related files for pg_semantic_cache.

## Directory Structure

```
testing/
├── docker/           # Docker-based testing environment
│   ├── Dockerfile.test
│   ├── Dockerfile.rag-test
│   ├── docker-compose.test-rag.yml
│   └── docker-entrypoint-test.sh
├── scripts/          # Test execution scripts
│   ├── TEST_PLAN.sh
│   ├── debug-test.sh
│   └── docker-test.sh
└── rag/             # RAG integration testing
    ├── README.md
    ├── SUCCESS.md
    ├── quick-start.md
    ├── .env.example
    ├── start.sh
    ├── test-queries.sh
    └── server/
        └── Dockerfile
```

## Quick Start

### Docker-based Testing

**Note:** All scripts must be run from the project root directory.

```bash
# From project root
./testing/scripts/docker-test.sh

# Run debug tests
./testing/scripts/debug-test.sh

# Run test plan locally (requires PostgreSQL installed)
./testing/scripts/TEST_PLAN.sh
```

### Docker Compose (RAG Integration)

```bash
# From testing/docker/ directory
cd testing/docker
docker-compose -f docker-compose.test-rag.yml up
```

### RAG Integration Testing

```bash
cd testing/rag
# Follow instructions in README.md
```

## Test Categories

- **Unit Tests:** SQL regression tests in `test/sql/`
- **Integration Tests:** Docker-based full-stack tests in `docker/`
- **RAG Tests:** Real-world RAG application tests in `rag/`
- **Manual Tests:** Developer test scripts in `scripts/`

## Running Tests

### Regression Tests (recommended)

```bash
# From project root
make clean && make
sudo make install
make installcheck
```

### Docker Tests

```bash
# From project root
./testing/scripts/docker-test.sh
```

### RAG Integration

```bash
cd testing/rag
./start.sh
./test-queries.sh
```

## Notes

- **Production installation:** Use `install.sh` in the project root, not these test scripts
- **CI/CD:** Docker tests are suitable for automated testing pipelines
- **Development:** Use manual scripts for quick iteration during development
