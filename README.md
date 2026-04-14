# harbor

Add harbor helm repo:
```bash
helm repo add harbor https://helm.goharbor.io
```

Install harbor:
```bash
helm upgrade -i harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.type=loadBalancer \
  --set expose.tls.enabled=false \
  --set harborAdminPassword=admin \
  --set persistence.persistentVolumeClaim.registry.size=20Gi \
  --set externalURL=http://core.harbor.domain
```

