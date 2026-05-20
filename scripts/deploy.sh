#!/bin/bash
# ============================================================================
# MosaicDB Deployment Script
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
CHART_DIR="./charts/mosaicdb"
RELEASE_NAME="${RELEASE_NAME:-mosaicdb}"
NAMESPACE="${NAMESPACE:-default}"

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl is not installed"
    exit 1
fi

if ! command -v helm &>/dev/null; then
    log_error "helm is not installed"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

log_info "Kubernetes cluster connected"

# Install or upgrade
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_info "Upgrading existing release $RELEASE_NAME..."
    helm upgrade "$RELEASE_NAME" "$CHART_DIR" -n "$NAMESPACE" \
        --set persistence.enabled=true \
        --set persistence.size=50Gi \
        --wait --timeout 10m
else
    log_info "Installing $RELEASE_NAME..."
    helm install "$RELEASE_NAME" "$CHART_DIR" -n "$NAMESPACE" --create-namespace \
        --set persistence.enabled=true \
        --set persistence.size=50Gi \
        --wait --timeout 10m
fi

# Verify
sleep 3
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=mosaicdb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD" ]; then
    STATUS=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$STATUS" = "Running" ]; then
        log_info "Pod $POD is Running"

        # Port-forward for local testing
        log_info "Port-forwarding 4040..."
        kubectl port-forward -n "$NAMESPACE" "pod/$POD" 4040:4040 &
        PF_PID=$!
        sleep 2

        if curl -sf http://localhost:4040/health >/dev/null; then
            log_info "Health check passed"
        else
            log_warn "Health check failed"
        fi

        kill $PF_PID 2>/dev/null || true
    else
        log_error "Pod status: $STATUS"
    fi
else
    log_error "No pod found"
fi

log_info ""
log_info "Commands:"
log_info "  Status:   kubectl get all -n $NAMESPACE -l app.kubernetes.io/name=mosaicdb"
log_info "  Logs:     kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=mosaicdb"
log_info "  Port fwd: kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-mosaicdb 4040:4040"
log_info "  Uninstall: helm uninstall $RELEASE_NAME -n $NAMESPACE"
log_info ""
log_info "Production deployment:"
log_info "  helm install $RELEASE_NAME $CHART_DIR \\"
log_info "    --namespace mosaicdb --create-namespace \\"
log_info "    --set replicaCount=3 \\"
log_info "    --set persistence.enabled=true \\"
log_info "    --set persistence.size=200Gi \\"
log_info "    --set ingress.enabled=true \\"
log_info "    --set auth.enabled=true \\"
log_info "    --set monitoring.serviceMonitor.enabled=true"
