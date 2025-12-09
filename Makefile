# pg_semantic_cache Makefile
# PostgreSQL extension using PGXS

EXTENSION = pg_semantic_cache
DATA = sql/pg_semantic_cache--0.1.0.sql
MODULES = pg_semantic_cache

# Regression tests (if you add them later)
REGRESS = semantic_cache_test

# PostgreSQL configuration
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
