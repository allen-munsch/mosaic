#!/bin/bash
# ============================================================================
# Semantic Fabric Deployment Script
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="semantic-fabric"
MIN_DOCKER_VERSION="20.10"
MIN_COMPOSE_VERSION="2.0"

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 is not installed"
        return 1
    fi
    return 0
}

check_version() {
    local current_version=$1
    local required_version=$2
    
    if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" != "$required_version" ]; then
        return 1
    fi
    return 0
}

# Check prerequisites
log_info "Checking prerequisites..."

if ! check_command docker; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! check_command docker-compose && ! check_command docker compose; then
    log_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+' | head -1)
if ! check_version "$DOCKER_VERSION" "$MIN_DOCKER_VERSION"; then
    log_error "Docker version $DOCKER_VERSION is too old. Minimum required: $MIN_DOCKER_VERSION"
    exit 1
fi

log_info "✓ All prerequisites met"

# Create necessary directories
log_info "Creating directory structure..."
mkdir -p config grafana/{dashboards,datasources} ssl backup

# Check if .env exists
if [ ! -f .env ]; then
    log_warn ".env file not found. Creating from template..."
    cp .env.example .env
    log_info "✓ Created .env file. Please edit it with your configuration."
    
    # Generate random secrets
    CLUSTER_SECRET=$(openssl rand -hex 32)
    COOKIE=$(openssl rand -hex 32)
    
    # Update .env with generated secrets
    sed -i "s/CLUSTER_SECRET=.*/CLUSTER_SECRET=$CLUSTER_SECRET/" .env
    sed -i "s/COOKIE=.*/COOKIE=$COOKIE/" .env
    
    log_info "✓ Generated random cluster secrets"
else
    log_info "✓ .env file found"
fi

# Check for OpenAI API key if using OpenAI embeddings
source .env
if [ "$EMBEDDING_MODEL" == "openai" ] && [ -z "$OPENAI_API_KEY" ]; then
    log_warn "EMBEDDING_MODEL is set to 'openai' but OPENAI_API_KEY is not set in .env"
    log_warn "Please add your OpenAI API key to .env or change EMBEDDING_MODEL"
fi

# Build images
log_info "Building Docker images..."
docker-compose build

# Start services
log_info "Starting services..."
docker-compose up -d

# Wait for services to be healthy
log_info "Waiting for services to be healthy..."
sleep 10

# Check health
log_info "Checking service health..."

services=("coordinator" "worker-1" "worker-2" "redis" "nginx" "prometheus" "grafana")
failed_services=()

for service in "${services[@]}"; do
    if docker-compose ps $service | grep -q "Up (healthy)"; then
        log_info "✓ $service is healthy"
    elif docker-compose ps $service | grep -q "Up"; then
        log_warn "⚠ $service is running but health check not available"
    else
        log_error "✗ $service is not running"
        failed_services+=($service)
    fi
done

if [ ${#failed_services[@]} -gt 0 ]; then
    log_error "Some services failed to start: ${failed_services[*]}"
    log_info "Check logs with: docker-compose logs ${failed_services[*]}"
    exit 1
fi

# Test API endpoint
log_info "Testing API endpoint..."
sleep 5

if curl -f -s http://localhost/health > /dev/null; then
    log_info "✓ API is responding"
else
    log_error "✗ API is not responding"
    log_info "Check logs with: docker-compose logs nginx coordinator"
    exit 1
fi

# Display access information
log_info ""
log_info "=========================================="
log_info "Semantic Fabric deployed successfully! 🎉"
log_info "=========================================="
log_info ""
log_info "Access Points:"
log_info "  API:        http://localhost"
log_info "  Grafana:    http://localhost:3000 (admin/admin)"
log_info "  Prometheus: http://localhost:9090"
log_info ""
log_info "Quick Commands:"
log_info "  Status:     docker-compose ps"
log_info "  Logs:       docker-compose logs -f"
log_info "  Stop:       docker-compose stop"
log_info "  Restart:    docker-compose restart"
log_info "  Remove:     docker-compose down"
log_info ""
log_info "Example API Request:"
log_info '  curl -X POST http://localhost/api/search \'
log_info '    -H "Content-Type: application/json" \'
log_info '    -d '\''{"query": "machine learning", "limit": 10}'\'
log_info ""
log_info "For more information, see README.md"
log_info ""

# Optional: Open Grafana in browser
read -p "Would you like to open Grafana in your browser? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v xdg-open &> /dev/null; then
        xdg-open http://localhost:3000
    elif command -v open &> /dev/null; then
        open http://localhost:3000
    else
        log_info "Please open http://localhost:3000 in your browser"
    fi
fi

exit 0
