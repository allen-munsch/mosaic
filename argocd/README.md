# MosaicDB on Kubernetes

## Quick Install (Helm)

```bash
helm repo add mosaicdb https://allen-munsch.github.io/mosaic
helm install mosaicdb mosaicdb/mosaicdb \
  --set persistence.enabled=true \
  --set persistence.size=50Gi
```

## GitOps with ArgoCD

```bash
# Single environment
kubectl apply -f argocd/mosaicdb.yaml

# Multi-environment (dev/staging/prod)
kubectl apply -f argocd/appset.yaml
```

## GitOps with Flux

```bash
flux create source git mosaicdb \
  --url=https://github.com/allen-munsch/mosaic \
  --branch=main

flux create helmrelease mosaicdb \
  --source=GitRepository/mosaicdb \
  --chart=./charts/mosaicdb \
  --target-namespace=mosaicdb \
  --create-target-namespace
```

## Architecture on k8s

```
                    ┌──────────────────┐
                    │   Ingress/Nginx  │
                    │   mosaicdb.local │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ Mosaic-0 │  │ Mosaic-1 │  │ Mosaic-2 │
        │  shards  │  │  shards  │  │  shards  │
        │  [0-99]  │  │[100-199] │  │[200-299] │
        └────┬─────┘  └────┬─────┘  └────┬─────┘
             │              │              │
             └──────────────┼──────────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
        ┌──────────┐               ┌──────────┐
        │  Redis   │               │   S3/EFS │
        │  Cache   │               │  Backup  │
        └──────────┘               └──────────┘
```

## Scaling

| Environment | Replicas | Storage | Ingress |
|-------------|----------|---------|---------|
| dev | 1 | 10Gi | mosaicdb-dev.example.com |
| staging | 2 | 50Gi | mosaicdb-staging.example.com |
| prod | 3-10 (HPA) | 200Gi | mosaicdb.example.com |

## Production Checklist

- [ ] Enable persistence (PVC with SSD storage class)
- [ ] Enable Redis for distributed cache
- [ ] Set up ingress with TLS (cert-manager)
- [ ] Enable HPA for auto-scaling
- [ ] Enable Prometheus ServiceMonitor
- [ ] Set resource requests/limits
- [ ] Configure pod disruption budget
- [ ] Set up backup (Velero or S3 sync)
