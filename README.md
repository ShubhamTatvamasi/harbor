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

## Harbor sync script

A small bash helper to mirror Docker images and OCI Helm charts into Harbor.

### Files

- `harbor-sync.sh` - main sync script
- `sync-config.sh` or `sync-config.yaml` - editable config file

### Usage

```bash
chmod +x harbor-sync.sh
./harbor-sync.sh --config ./sync-config.yaml
```

Dry run:

```bash
./harbor-sync.sh --config ./sync-config.yaml --dry-run
```

Allow Docker HTTP access when Harbor is HTTP-only (non-Docker Desktop):

```bash
./harbor-sync.sh --config ./sync-config.yaml --allow-http --docker
```

If you use Docker Desktop, set `core.harbor.domain` under insecure registries in Docker Desktop settings and restart Docker instead.

Example Docker Desktop JSON snippet:

```json
{
  "insecure-registries": ["core.harbor.domain"]
}
```

If using `nerdctl`, the script will automatically run it via `sudo env "PATH=$PATH" nerdctl ...` when needed.

Sync only Docker images:

```bash
./harbor-sync.sh --config ./sync-config.yaml --docker
```

Sync only OCI Helm charts:

```bash
./harbor-sync.sh --config ./sync-config.yaml --oci
```

Sync only Helm repo charts:

```bash
./harbor-sync.sh --config ./sync-config.yaml --helm
```

### Config

Edit `sync-config.sh` or `sync-config.yaml` with Harbor credentials and source-only lists.

- Docker image sources are listed under `docker_images`
- OCI Helm chart sources are listed under `oci_repos`
- Standard Helm repo chart sources are listed under `helm_repos`
- Target repository names are generated automatically using Harbor host and project

Example:

```yaml
harbor:
  protocol: http
  host: core.harbor.domain
  username: admin
  password: admin
  project: 2

docker_images:
  - docker.io/cloudpirates/postgres:0.19.0

oci_repos:
  - oci://registry-1.docker.io/cloudpirates/postgres:0.19.0

helm_repos:
  - repo: https://airflow.apache.org/
    chart: airflow
    version: 1.20.0
```

With this config, the script will mirror:

- Docker: `docker.io/cloudpirates/postgres:0.19.0` -> `core.harbor.domain/2/cloudpirates/postgres:0.19.0`
- OCI Helm: `oci://registry-1.docker.io/cloudpirates/postgres:0.19.0` -> `oci://core.harbor.domain/2/cloudpirates/postgres:0.19.0`
- Helm repo chart: `airflow/airflow` from `https://airflow.apache.org/` -> `oci://core.harbor.domain/2/airflow/airflow:1.20.0`

### Requirements

- `docker` or `nerdctl`
- `helm`
- `yq`

> This script now parses YAML using `yq`, so the config loader is simpler and more reliable.
>
> If your Harbor registry is HTTP-only, Docker also needs the host configured as an insecure registry in the daemon (there is no Docker client flag to force HTTP). If using Docker Desktop, add `core.harbor.domain` under insecure registries and restart Docker.



---

### Docker Desktop

Add `core.harbor.domain` to Docker insecure registries:
```json
{
  "builder": {
    "gc": {
      "defaultKeepStorage": "20GB",
      "enabled": true
    }
  },
  "experimental": false,
  "insecure-registries": [
    "core.harbor.domain"
  ]
}
```
