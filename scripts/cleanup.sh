#!/bin/bash
# Clean up and reorganize Mosaic project structure

set -e

echo "🧹 Cleaning up Mosaic project structure..."

# Remove unnecessary files
rm -f semantic_fabric_enhanced.ex  # This should be in lib/, not root
rm -f install.sh  # Duplicate of setup.sh
rm -f DEPLOYMENT_GUIDE.md  # Too much, put in docs/
rm -f ARCHITECTURE.md  # Move to docs/

# Create proper structure
mkdir -p docs
mkdir -p scripts

# Move documentation
echo "📚 Organizing documentation..."
[ -f ARCHITECTURE.md ] && mv ARCHITECTURE.md docs/ 2>/dev/null || true
[ -f DEPLOYMENT_GUIDE.md ] && mv DEPLOYMENT_GUIDE.md docs/ 2>/dev/null || true

# Move scripts
echo "📝 Organizing scripts..."
mv backup.sh scripts/ 2>/dev/null || true
mv deploy.sh scripts/ 2>/dev/null || true

# Create .env.example if it doesn't exist
if [ ! -f .env.example ]; then
cat > .env.example <<'EOF'
# Mosaic Configuration
PORT=4040
EMBEDDING_MODEL=local
STORAGE_PATH=/data/shards
EOF
fi

# Create simple README
cat > README.md <<'EOF'
# Mosaic Search Engine

Distributed semantic search using SQLite shards.

## Quick Start

```bash
./setup.sh
docker-compose up
```

Visit http://localhost/health

## Structure

```
mosaic/
├── lib/mosaic/          # Elixir application code
├── config/              # Application config
├── scripts/             # Utility scripts
├── docs/                # Documentation
├── docker-compose.yml   # Services
├── Dockerfile           # Container build
└── setup.sh             # Initial setup
```

## Development

```bash
mix deps.get
mix run --no-halt
```

## Production

See `docs/DEPLOYMENT_GUIDE.md`
EOF

echo ""
echo "✅ Project structure cleaned up!"
echo ""
echo "Current structure:"
tree -L 2 -I '_build|deps' . 2>/dev/null || ls -la

echo ""
echo "Next: docker-compose up"
