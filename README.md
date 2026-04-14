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
  --set expose.type=loadBalancer
```

