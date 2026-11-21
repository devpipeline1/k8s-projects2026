# Kubernetes Microservices Shopping Workshop - NGINX Ingress + Volumes

This project contains a small shopping application with a frontend, Product API, Order API and PostgreSQL. The Kubernetes manifests use a ConfigMap, a Secret, NGINX Ingress, and separate hands-on Pods for `emptyDir`, `hostPath`, and NFS volume demonstrations.

## Project structure

```text
k8s-microservices-workshop/
├── frontend/
├── product-api/
├── order-api/
├── docker-compose.yml
├── README.md
└── k8s/
    ├── deployments.yaml
    ├── configmap.yaml
    ├── ingress.yaml
    └── storage-volumes-demo.yaml
```

## Prerequisites

- `kubectl` configured for your EKS application cluster.
- NGINX Ingress Controller installed with an IngressClass named `nginx`.
- The three application images referenced in `deployments.yaml` available in the registry and pullable by EKS.
- For NFS: a reachable NFS server, export `/srv/k8s-share`, TCP 2049 allowed from EKS worker nodes, and NFS client utilities on the nodes.
- The PostgreSQL Deployment in this version uses NFS for database files, `emptyDir` for `/tmp`, and `hostPath` for `/backups`. It is a single-replica workshop demonstration, not a production database architecture.

## 1. Create namespace and ConfigMap

```bash
kubectl create namespace microservices-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/configmap.yaml
```

The namespace is also included in `deployments.yaml`, so applying that file later is safe. Create the ConfigMap and Secret before deploying the application workloads.

## 2. Create the Secret

Use a strong password and use the same password in both Secret values. Do not commit real credentials to source control.

```bash
kubectl create secret generic shopping-secret \
  --namespace microservices-demo \
  --from-literal=POSTGRES_PASSWORD='CHANGE_ME' \
  --from-literal=DATABASE_URL='postgresql://shopuser:CHANGE_ME@postgres:5432/shop'
```

Replace `CHANGE_ME` in both values with the same password. If the Secret already exists and needs updating:

```bash
kubectl create secret generic shopping-secret \
  --namespace microservices-demo \
  --from-literal=POSTGRES_PASSWORD='CHANGE_ME' \
  --from-literal=DATABASE_URL='postgresql://shopuser:CHANGE_ME@postgres:5432/shop' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Kubernetes Secret values are base64-encoded, not automatically encrypted merely because they are Secrets. Enable encryption at rest and restrict RBAC for production use.

## 3. Deploy the application

Recommended order:

```bash
kubectl create namespace microservices-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/configmap.yaml
# Create the shopping-secret using the command above.
kubectl apply -f k8s/deployments.yaml
kubectl get pods -n microservices-demo
kubectl get svc -n microservices-demo
```

The frontend proxies its API calls to `product-service` and `order-service` using the environment variables in the ConfigMap. The Ingress sends browser traffic to `frontend-service`; API paths are handled by the frontend's NGINX configuration.

## 4. Configure NGINX Ingress

```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress -n microservices-demo
```

For local workstation testing, map the NGINX Ingress Controller external address to `myfirst-web.com` in the workstation hosts file. On Windows, the file is `C:\Windows\System32\drivers\etc\hosts`:

```text
<NGINX_INGRESS_EXTERNAL_IP> myfirst-web.com
```

The Ingress manifest assumes the controller uses `ingressClassName: nginx`. It does not install the controller.

## 5. Prepare the NFS server for PostgreSQL and the volume demos

Create an Ubuntu EC2 instance in the same VPC (or a network with private routing) as the EKS worker nodes. Give it a private IP. In its security group, allow **TCP 2049** from the EKS worker-node security group only. Do not expose NFS to the public internet.

On the Ubuntu NFS server:

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
sudo mkdir -p /srv/k8s-share/postgres
sudo mkdir -p /srv/k8s-share
```

The PostgreSQL official Debian image runs as UID/GID `999`. Prepare its directory on the NFS server (not inside the Pod):

```bash
sudo chown -R 999:999 /srv/k8s-share/postgres
sudo chmod 700 /srv/k8s-share/postgres
```

For the separate NFS two-Pod exercise, the general `/srv/k8s-share` export is also used. A simple workshop export can be configured in `/etc/exports` with your **actual EKS worker-node CIDR** (the CIDR below is only an example):

```text
/srv/k8s-share 10.10.0.0/16(rw,sync,no_subtree_check)
```

Then run:

```bash
sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server
sudo exportfs -v
```

Get the NFS server's private IPv4 address from the EC2 console. Replace `REPLACE_WITH_NFS_PRIVATE_IP` in both `k8s/deployments.yaml` and `k8s/storage-volumes-demo.yaml` with that address. The PostgreSQL Deployment mounts `/srv/k8s-share/postgres`; the standalone NFS exercise mounts `/srv/k8s-share`.

**EKS node requirement:** the worker nodes need NFS client utilities. On Amazon Linux 2023 nodes, install `nfs-utils` (`sudo dnf install -y nfs-utils`) using a repeatable node bootstrap/custom AMI approach. Ensure the NFS server is reachable from every node that may run these Pods.

## 6. PostgreSQL volume demonstration (all three volume types)

The PostgreSQL Deployment in `k8s/deployments.yaml` has these mounts:

| Volume type | Container path | What it demonstrates |
|---|---|---|
| NFS | `/var/lib/postgresql/data` | PostgreSQL database files on the NFS server; data can survive Pod replacement while the NFS data remains intact |
| `emptyDir` | `/tmp` | Temporary files; deleted when the Pod is removed |
| `hostPath` | `/backups` | Database dump files on the worker node hosting PostgreSQL; node-local, not shared storage |

Before deploying, replace the NFS private IP in the PostgreSQL Deployment. The NFS PostgreSQL directory must already be owned by UID/GID `999` as described above. The Deployment intentionally uses one replica; never scale this PostgreSQL Deployment above one while all replicas point to the same data directory.

After applying the ConfigMap and Secret (sections 1 and 2), deploy:

```bash
kubectl apply -f k8s/deployments.yaml
kubectl get pods -n microservices-demo -w
```

Check PostgreSQL:

```bash
kubectl exec -it -n microservices-demo deployment/postgres -- \
  psql -U shopuser -d shop
```

Inside `psql`, create sample data:

```sql
CREATE TABLE IF NOT EXISTS volume_demo (
  id SERIAL PRIMARY KEY,
  message VARCHAR(100)
);
INSERT INTO volume_demo (message) VALUES ('Data stored on NFS');
SELECT * FROM volume_demo;
\q
```

Create a PostgreSQL logical backup in the hostPath mount:

```bash
kubectl exec -n microservices-demo deployment/postgres -- \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /backups/shop.sql'
kubectl exec -n microservices-demo deployment/postgres -- ls -lh /backups/
```

Demonstrate `emptyDir`:

```bash
kubectl exec -n microservices-demo deployment/postgres -- \
  sh -c 'echo temporary-data > /tmp/volume-demo.txt && cat /tmp/volume-demo.txt'
```

The database itself is stored on NFS, not in `emptyDir` or `hostPath`. The backup is stored on the worker node and can be lost if that node or its local disk is lost. Copy backups off the node for real backup protection.

## 7. Configure and deploy the three standalone volume demos


Edit `k8s/storage-volumes-demo.yaml` before applying:

- Replace `REPLACE_WITH_WORKER_NODE_NAME` with a node name from `kubectl get nodes`.
- Replace both occurrences of `REPLACE_WITH_NFS_PRIVATE_IP` with the NFS server's private IP.
- Confirm the NFS export path is `/srv/k8s-share`.

Then deploy:

```bash
kubectl apply -f k8s/storage-volumes-demo.yaml
kubectl get pods -n microservices-demo -o wide
```

### emptyDir test

```bash
kubectl exec volume-emptydir-demo -n microservices-demo -- sh -c 'echo Hello-emptyDir > /data/demo.txt'
kubectl exec volume-emptydir-demo -n microservices-demo -- cat /data/demo.txt
```

To demonstrate the lifecycle, terminate the container's main process; Kubernetes restarts the container and the file remains in the same Pod:

```bash
kubectl exec volume-emptydir-demo -n microservices-demo -- sh -c 'kill 1'
kubectl get pod volume-emptydir-demo -n microservices-demo -w
```

After it restarts, read the file again. Deleting and recreating the Pod creates a new emptyDir, so the old file is gone.

### hostPath test

```bash
kubectl exec volume-hostpath-demo -n microservices-demo -- sh -c 'echo Hello-hostPath > /data/demo.txt'
kubectl exec volume-hostpath-demo -n microservices-demo -- cat /data/demo.txt
```

The Pod is pinned to the selected node. If you delete and recreate it on that same node, the file remains in `/tmp/shopping-workshop-data` on that node. On another node, it is a different local directory. Use hostPath only for controlled demonstrations or appropriate node-level workloads; it can expose host files to containers.

### NFS test

```bash
kubectl exec volume-nfs-demo-1 -n microservices-demo -- sh -c 'echo Hello-NFS > /data/demo.txt'
kubectl exec volume-nfs-demo-2 -n microservices-demo -- cat /data/demo.txt
```

The second Pod reads the file written by the first because both mount the same NFS export. These Pods may run on different nodes; NFS provides the shared network storage.

## 8. Cleanup

Remove only the volume demonstration Pods:

```bash
kubectl delete -f k8s/storage-volumes-demo.yaml
```

Remove the application if required:

```bash
kubectl delete -f k8s/ingress.yaml
kubectl delete -f k8s/deployments.yaml
kubectl delete -f k8s/configmap.yaml
kubectl delete secret shopping-secret -n microservices-demo
```

## Important database and safety notes

- This workshop intentionally demonstrates a raw NFS volume directly in a Pod spec; it does not use a PersistentVolume or PersistentVolumeClaim.
- NFS-backed PostgreSQL is for learning only. A self-managed NFS server is a single point of failure and requires careful validation of filesystem semantics, locking, latency, durability, permissions, monitoring and backups. For production on EKS, prefer Amazon RDS/Aurora or a properly designed EBS-backed PostgreSQL StatefulSet with a PersistentVolumeClaim.
- `hostPath` backup files exist only on the worker node where the PostgreSQL Pod ran. They are not a substitute for off-node backups.
- Do not run multiple PostgreSQL replicas against the same `PGDATA` directory.
- The NFS directory permissions shown are specific to this workshop. Tighten permissions and security controls for any shared or production environment.
