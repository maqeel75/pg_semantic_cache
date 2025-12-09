# pg_semantic_cache PostgreSQL Extension Makefile
# Uses standard PGXS build system

EXTENSION = pg_semantic_cache
DATA = sql/pg_semantic_cache--0.1.0.sql
MODULES = pg_semantic_cache

# PostgreSQL extension metadata
DOCS = README.md
REGRESS = semantic_cache_test

# Get PostgreSQL configuration
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Compiler flags
PG_CPPFLAGS = -I$(shell $(PG_CONFIG) --includedir-server)

# Installation
install: all
	$(INSTALL_DATA) $(EXTENSION).control '$(DESTDIR)$(datadir)/extension/'
	$(INSTALL_DATA) $(DATA) '$(DESTDIR)$(datadir)/extension/'

# Testing
installcheck: install
	$(prove_installcheck)

# Clean
clean:
	rm -f $(MODULES).so $(MODULES).o
	rm -f $(MODULES).bc

# Development helpers
.PHONY: dev-install test bench format

dev-install: install
	@echo "Extension installed for development"

test: installcheck
	@echo "Tests complete"

bench:
	@echo "Running benchmarks..."
	$(PG_CONFIG) -d postgres -f test/benchmark.sql

format:
	clang-format -i *.c

# Print configuration info
info:
	@echo "PostgreSQL Config: $(PG_CONFIG)"
	@echo "PostgreSQL Version: $(shell $(PG_CONFIG) --version)"
	@echo "Extension: $(EXTENSION)"
	@echo "Data files: $(DATA)"
	@echo "Installation dir: $(DESTDIR)$(datadir)/extension/"
