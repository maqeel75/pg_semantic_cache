#!/bin/bash
set -e

# PostgreSQL paths
PGDATA="/var/lib/postgresql/data"
PGBIN="/usr/lib/postgresql/18/bin"

# Function to initialize database
init_database() {
    echo "Initializing PostgreSQL database..."
    $PGBIN/initdb -D "$PGDATA"

    # Configure PostgreSQL to accept connections
    echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
    echo "listen_addresses='*'" >> "$PGDATA/postgresql.conf"

    echo "Database initialized successfully"
}

# Function to start PostgreSQL temporarily for setup
start_postgres_temp() {
    echo "Starting PostgreSQL temporarily for setup..."
    $PGBIN/pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start
}

# Function to stop temporary PostgreSQL
stop_postgres_temp() {
    echo "Stopping temporary PostgreSQL..."
    $PGBIN/pg_ctl -D "$PGDATA" -m fast -w stop
}

# Function to run setup SQL
run_setup() {
    echo "Setting postgres password..."
    $PGBIN/psql -U postgres -d postgres -c "ALTER USER postgres WITH PASSWORD 'postgres';"

    echo "Running setup.sql..."
    $PGBIN/psql -U postgres -d postgres -f /tmp/setup.sql
    echo "Setup completed successfully"
}

# Main execution
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "==================================================================="
    echo "First run detected - initializing fresh database..."
    echo "==================================================================="

    # Initialize database
    init_database

    # Start PostgreSQL temporarily
    start_postgres_temp

    # Run setup script
    run_setup

    # Stop temporary PostgreSQL
    stop_postgres_temp

    echo "==================================================================="
    echo "Initialization complete - starting PostgreSQL normally..."
    echo "==================================================================="
else
    echo "==================================================================="
    echo "Existing database found - starting PostgreSQL..."
    echo "==================================================================="
fi

# Start PostgreSQL in foreground
exec $PGBIN/postgres -D "$PGDATA"
