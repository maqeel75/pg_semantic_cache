# pg_semantic_cache Makefile
# PostgreSQL extension using PGXS

EXTENSION = pg_semantic_cache
DATA = sql/pg_semantic_cache--0.1.0.sql sql/pg_semantic_cache--0.2.0.sql sql/pg_semantic_cache--0.3.0.sql sql/pg_semantic_cache--0.1.0--0.2.0.sql sql/pg_semantic_cache--0.2.0--0.3.0.sql
MODULES = pg_semantic_cache

# Regression tests
REGRESS = semantic_cache_test
REGRESS_OPTS = --inputdir=test --outputdir=test

# PostgreSQL configuration
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
