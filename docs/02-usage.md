# 使用：日常开发工作流

集群创建完成后，所有操作和在普通 Kubernetes 上一样。本文只列最常用的路径。

---

## 1. 基本上下文

```bash
kubectl config current-context       # k3d-dev
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass             # local-path (default)
kubectl get ingressclass             # traefik
```

如果上下文丢了：

```bash
k3d kubeconfig merge dev --kubeconfig-switch-context
# 或
kubectl config use-context k3d-dev
```

`make up` 和 `make start` 都会自动切换到 `k3d-dev`。

---

## 2. 部署第一个应用

```bash
kubectl create namespace demo
kubectl -n demo create deployment whoami --image=traefik/whoami:v1.10.2 --replicas=2
kubectl -n demo expose deployment whoami --port=80 --target-port=80
```

访问方式一：port-forward（不需要 Ingress）

```bash
kubectl -n demo port-forward svc/whoami 9000:80
# 浏览器/curl: http://127.0.0.1:9000
```

访问方式二：Ingress（推荐，走固定的 8080 端口）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: demo
spec:
  ingressClassName: traefik
  rules:
    - host: demo.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: whoami
                port:
                  number: 80
```

```bash
kubectl apply -f whoami-ingress.yaml
curl -H 'Host: demo.localhost' http://127.0.0.1:8080/
```

`*.localhost` 在大多数系统上自动解析到 127.0.0.1；如果浏览器打不开，用：

```bash
curl --resolve demo.localhost:8080:127.0.0.1 http://demo.localhost:8080/
```

或在 Windows 的 `C:\Windows\System32\drivers\etc\hosts` 加：

```text
127.0.0.1 demo.localhost
```

> Windows 浏览器访问 `http://localhost:8080` 正常，但访问 `http://demo.localhost:8080` 需要该域名能解析。Windows 通常会把 `*.localhost` 当回环地址，若不支持就加 hosts。

---

## 3. 本地镜像仓库（最常用的开发闭环）

集群内置了一个 `registry:2`，宿主机端口 `5000`。

### 3.1 构建并推送

```bash
# 在项目目录
docker build -t localhost:5000/team/myapp:dev .
docker push localhost:5000/team/myapp:dev
```

验证：

```bash
curl -s http://localhost:5000/v2/_catalog
# {"repositories":["team/myapp"]}
```

### 3.2 在 Pod 中使用

**关键：Pod 里的镜像地址不是 `localhost:5000`，而是 `k3d-registry-dev:5000`。**

```bash
kubectl create deployment myapp \
  --image=k3d-registry-dev:5000/team/myapp:dev
```

Deployment YAML：

```yaml
containers:
  - name: myapp
    image: k3d-registry-dev:5000/team/myapp:dev
    imagePullPolicy: IfNotPresent
```

原因：

- `localhost:5000` 是 WSL 宿主（也是 Docker daemon 所在 network namespace）的地址；
- Pod 在 k3d 的 Docker 网络里，`localhost` 指向 Pod 自己；
- k3d 已经把这个 registry 以 `k3d-registry-dev:5000` 的名字接入集群，并写入节点的 `registries.yaml`（HTTP、非 TLS）。

### 3.3 更新镜像

```bash
docker build -t localhost:5000/team/myapp:dev .
docker push localhost:5000/team/myapp:dev
kubectl rollout restart deployment/myapp
kubectl rollout status deployment/myapp
```

> 用固定 tag（如 `:dev`）+ `imagePullPolicy: Always` 会每次拉取；用 `IfNotPresent` 时同 tag 不会自动更新，需要 `rollout restart` 或换 tag。开发环境建议每次用唯一 tag（git sha）。

### 3.4 从别的机器访问 registry

不要直接把 5000 暴露到公网；它默认是 HTTP 明文。需要远程访问时，加 SSH 隧道：

```bash
ssh -L 5000:localhost:5000 user@windows-host
```

---

## 4. 存储：local-path

默认 StorageClass 是 `local-path`，PVC 会自动创建本地目录。

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: demo
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

挂载到 Pod：

```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
```

验证：

```bash
kubectl -n demo get pvc
kubectl -n demo get pv
```

注意：

- 数据实际落在 k3s 节点容器的 `/var/lib/rancher/k3s/storage/` 下；
- `make down` / `scripts/down.sh` 删除集群时，**PVC 数据一起删除**；
- 需要跨集群删除保留数据时，把宿主机目录挂进节点：

```bash
# 在 config/cluster.env.local 里追加
K3D_CREATE_EXTRA_ARGS="--volume /home/me/k3d-data:/data@server:0 --volume /home/me/k3d-data:/data@agent:0"
```

然后在 PVC/PV 里使用 hostPath `/data`（或改用 NFS/CSI）。这是本地开发集群，不提供高可用存储。

---

## 5. 常用 kubectl 操作

```bash
# 看全部
kubectl get all -A
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp

# 排错
kubectl -n demo describe pod <pod>
kubectl -n demo logs <pod> -f
kubectl -n demo logs deploy/myapp --tail=100
kubectl -n demo exec -it <pod> -- sh

# 进入节点（调试 k3s/containerd）
docker exec -it k3d-dev-server-0 sh
docker exec -it k3d-dev-agent-0 sh
docker exec k3d-dev-server-0 crictl ps
docker exec k3d-dev-server-0 crictl images

# 资源
kubectl top nodes
kubectl top pods -A

# 端口转发
kubectl -n demo port-forward svc/myapp 9001:80
kubectl -n kube-system port-forward deploy/traefik 9000:9000   # 需先启用 dashboard

# 扩缩容 / 滚动更新
kubectl -n demo scale deploy/myapp --replicas=3
kubectl -n demo set image deploy/myapp myapp=k3d-registry-dev:5000/team/myapp:v2
kubectl -n demo rollout status deploy/myapp
kubectl -n demo rollout undo deploy/myapp
```

---

## 6. Helm

WSL 里已有 Helm 4（当前 `v4.2.4`）。k3d 集群可直接用：

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install redis bitnami/redis -n demo --create-namespace
```

注意：Helm 能解析 chart 不等于镜像能拉下来。国内环境需要：

1. 先把 chart 用到的镜像 `docker pull` 到 WSL；
2. `k3d image import -c dev <image...>`；
3. 再 `helm install`，并设置 `imagePullPolicy: IfNotPresent`（多数 chart 支持）。

更省事的做法是给节点配置镜像加速（见 [pitfalls](04-pitfalls.md#坑-2节点里-containerd-拉不到镜像)），或使用本地 registry 把镜像重新 tag 后推送。

---

## 7. 多集群

同一套脚本可以创建多个集群，只要名字和端口不冲突：

```bash
CLUSTER_NAME=test \
HTTP_PORT=18080 \
HTTPS_PORT=18443 \
API_PORT=16443 \
REGISTRY_PORT=15000 \
make up

kubectl config use-context k3d-test
```

清理：

```bash
CLUSTER_NAME=test make down
```

注意 `REGISTRY_NAME` 默认是 `k3d-registry-${CLUSTER_NAME}`，会自动区分。

---

## 8. 从 Windows 访问

| 场景 | 地址 |
|---|---|
| WSL 内 curl | `http://127.0.0.1:8080` |
| Windows 浏览器 | `http://localhost:8080` |
| 带 Host 的 Ingress | `http://demo.localhost:8080`（需能解析） |
| API | `https://127.0.0.1:6443` |
| Registry | `localhost:5000` |

Windows 的 `kubectl` 如果存在，可以直接用 WSL 生成的 kubeconfig：

```powershell
# Windows 上
$env:KUBECONFIG="\\wsl$\Ubuntu-22.04\home\<user>\.kube\config"
kubectl get nodes
```

但 kubeconfig 里的 server 是 `https://0.0.0.0:6443` 或 `https://127.0.0.1:6443`。Windows 访问 WSL 的 localhost 通常可用；不行就：

```powershell
kubectl config set-cluster k3d-dev --server=https://<WSL-IP>:6443 --insecure-skip-tls-verify=true
```

WSL IP：

```powershell
wsl.exe -d Ubuntu-22.04 hostname -I
```

更推荐直接在 WSL 里用 kubectl，避免证书/IP 问题。

---

## 9. 开发环境建议

- 每个项目一个 namespace：`kubectl create ns myproject`。
- 用 `kubectl apply -k overlays/dev` 管理清单，不要手工改集群。
- 资源限制从小开始（`requests.cpu: 10m`、`memory: 32Mi`），2 vCPU / 4 GB 的 WSL 很容易被多个 Java 服务打满。
- 不在集群里跑数据库持久化生产数据；本地集群随时可能被 `make down`。
- 镜像统一走 `localhost:5000`，避免每个 Pod 都从外网拉。
