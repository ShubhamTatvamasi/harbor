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


http://core.harbor.domain

ID / Password: `admin` / `admin`


Update your `/etc/hosts` file:
```bash
➜ cat /etc/hosts | grep harbor
10.10.10.10 core.harbor.domain
```

