#!/bin/sh
# Semantic Fabric Backup Script
# Backs up routing indexes and shard metadata

set -e

BACKUP_DIR="/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="semantic_fabric_${TIMESTAMP}"

echo "Starting backup: ${BACKUP_NAME}"

# Create backup directory
mkdir -p "${BACKUP_DIR}/${BACKUP_NAME}"

# Backup coordinator routing database
echo "Backing up coordinator routing database..."
if [ -f "/data/routing/index.db" ]; then
    sqlite3 /data/routing/index.db ".backup '${BACKUP_DIR}/${BACKUP_NAME}/coordinator_routing.db'"
    echo "✓ Coordinator routing database backed up"
else
    echo "⚠ Coordinator routing database not found"
fi

# Backup shard metadata (lightweight)
echo "Backing up shard metadata..."
if [ -d "/data/shards" ]; then
    find /data/shards -name "*.db" -type f | while read -r shard; do
        shard_name=$(basename "$shard")
        shard_rel_path=$(realpath --relative-to=/data/shards "$shard")
        backup_shard_dir="${BACKUP_DIR}/${BACKUP_NAME}/shards/$(dirname "$shard_rel_path")"
        
        mkdir -p "$backup_shard_dir"
        
        # Extract just metadata (first 1MB) for quick recovery
        dd if="$shard" of="${backup_shard_dir}/${shard_name}.meta" bs=1M count=1 2>/dev/null || true
    done
    echo "✓ Shard metadata backed up"
else
    echo "⚠ Shards directory not found"
fi

# Create manifest
echo "Creating backup manifest..."
cat > "${BACKUP_DIR}/${BACKUP_NAME}/manifest.txt" <<EOF
Backup Name: ${BACKUP_NAME}
Timestamp: ${TIMESTAMP}
Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Host: $(hostname)

Contents:
- coordinator_routing.db: Routing index database
- shards/: Shard metadata (first 1MB of each shard)

Restore Instructions:
1. Stop all semantic fabric services
2. Restore routing database: sqlite3 /data/routing/index.db ".restore '${BACKUP_NAME}/coordinator_routing.db'"
3. Use shard metadata to rebuild index if needed
4. Restart services
EOF

# Compress backup
echo "Compressing backup..."
cd "${BACKUP_DIR}"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"
rm -rf "${BACKUP_NAME}"

# Clean up old backups (keep last 7 days)
echo "Cleaning up old backups..."
find "${BACKUP_DIR}" -name "semantic_fabric_*.tar.gz" -type f -mtime +7 -delete

# Calculate backup size
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)
echo "✓ Backup complete: ${BACKUP_NAME}.tar.gz (${BACKUP_SIZE})"

# Optional: Upload to S3 or remote storage
# aws s3 cp "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" "s3://your-bucket/backups/"

exit 0
