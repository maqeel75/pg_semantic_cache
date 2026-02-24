# pg_semantic_cache Makefile
# PostgreSQL extension using PGXS

EXTENSION = pg_semantic_cache
DATA = sql/pg_semantic_cache--0.1.0-beta1.sql sql/pg_semantic_cache--0.1.0-beta2.sql sql/pg_semantic_cache--0.1.0-beta3.sql sql/pg_semantic_cache--0.1.0-beta4.sql sql/pg_semantic_cache--0.1.0-beta1--0.1.0-beta2.sql sql/pg_semantic_cache--0.1.0-beta2--0.1.0-beta3.sql sql/pg_semantic_cache--0.1.0-beta3--0.1.0-beta4.sql
MODULES = pg_semantic_cache

# Regression tests
REGRESS = semantic_cache_test semantic_cache_full_test
REGRESS_OPTS = --inputdir=test --outputdir=test

# PostgreSQL configuration
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
