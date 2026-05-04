#!/bin/sh
set -e

# Create required directories
mkdir -p /var/lib/mosaic/shards /var/lib/mosaic/config

# Set storage paths from env or defaults
export STORAGE_PATH="${STORAGE_PATH:-/var/lib/mosaic/shards}"
export ROUTING_DB_PATH="${ROUTING_DB_PATH:-/var/lib/mosaic/config/index.db}"

# Always in production
export MIX_ENV=prod

echo "MosaicDB starting on port ${PORT:-4040}..."
echo "Storage: $STORAGE_PATH"

exec /app/bin/mosaic "$@"
