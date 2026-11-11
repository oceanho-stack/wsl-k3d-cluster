# 坑与排错

这份文档记录本项目在 WSL + Docker 29 + k3d v5.9.0 + k3s v1.35.5 上实际踩过的坑。按“症状 → 原因 → 解决”组织。

---

## 0. 先按这个顺序排查

```bash
make status
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -40
docker ps -a --filter name=k3d
docker logs --tail 100 k3d-dev-server-0
docker logs --tail 100 k3d-dev-agent-0
```

90% 的问题能在 `kubectl get events` 和节点日志里看到直接原因。

---

## 坑 1：节点 Ready，但所有系统 Pod 卡在 ContainerCreating

### 症状

```text
$ kubectl get pods -A
NAMESPACE     NAME                                      READY   STATUS              RESTARTS   AGE
kube-system   coredns-...                               0/1     ContainerCreating   0          3m
kube-system   local-path-provisioner-...                0/1     ContainerCreating   0          3m
kube-system   metrics-server-...                        0/1     ContainerCreating   0          3m
```

`kubectl describe pod` 里：

```text
Failed to create pod sandbox: ... failed to get sandbox image "rancher/mirrored-pause:3.6":
failed to pull image ... dial tcp 185.60.216.50:443: i/o timeout
```

节点本身是 `Ready` 的。

### 原因

k3d 节点是 Docker 容器，节点里的容器运行时是 **containerd**，不是宿主 Docker。

- `docker pull` 只把镜像放到 WSL 的 Docker 镜像库；
- k3s 的 containerd 有自己的镜像库（在每个节点容器里）；
- 国内网络下 containerd 访问 `registry-1.docker.io` 超时，pause 镜像拉不到，任何 Pod 都创建不了 sandbox。

**只给 Docker daemon 配代理也不够**：Docker daemon 的代理环境变量不会被节点里的 containerd 继承。

### 解决

本项目已经内置了完整解法：

```bash
# 1. 预拉所有镜像到 WSL Docker
make images

# 2. 创建集群（脚本会自动 import 系统镜像 + 重启节点）
make up
```

脚本内部做了：

```bash
# 1. 生成单平台 archive（skopeo）
bash scripts/prepare-images.sh --system-tars

# 2. 导入 8 个 archive（含 local-path helper）
k3d image import -c dev images/cache/*.tar

# 3. 重启节点，让 kubelet 命中本地镜像
k3d cluster restart dev --wait
```

验证：

```bash
docker exec k3d-dev-server-0 crictl images
docker exec k3d-dev-agent-0 crictl images
```

应该能看到 8 个系统镜像（pause、coredns、local-path、metrics-server、klipper-helm、klipper-lb、traefik、mirrored-library-busybox）。然后：

```bash
kubectl get pods -A
```

### 如果已经卡住了，不想重建

```bash
# 1. 生成/补齐 archive
bash scripts/prepare-images.sh --system-tars

# 2. 导入现有集群
k3d image import -c dev images/cache/*.tar

# 3. 让 kubelet 重新解析镜像
k3d cluster restart dev --wait

# 或者删掉卡住的 Pod 让它们重建
kubectl -n kube-system delete pod --all
```

### 想用镜像加速而不是 import

给 k3d 传 containerd 的 `registries.yaml`：

```yaml
mirrors:
  docker.io:
    endpoint:
      - https://docker.m.daocloud.io
      - https://registry-1.docker.io
```

```bash
# config/cluster.env.local
REGISTRY_CONFIG=/mnt/d/projects/oceanho-stack-infra/config/registries.yaml
```

然后重建集群。注意：k3d 会合并这个文件，但 **不会把 `proxy:` 字段传进去**（实测会被丢掉），所以“节点走 HTTP 代理”只能靠 `--env HTTP_PROXY=...` 或预导入；最稳的还是预导入。

---

## 坑 2：registry 容器名冲突，集群创建回滚

### 症状

```text
ERRO Failed Cluster Preparation: Failed to create registry: ...
Error response from daemon: Conflict. The container name "/registry" is already in use
by container "4c3333e9ce3a..."
```

或者创建到一半失败，留下 `k3d-dev` 网络：

```text
$ docker network ls | grep k3d
k3d-dev
```

### 原因

`k3d cluster create --registry-create registry:0.0.0.0:5000` 会创建一个名为 `registry` 的容器。很多机器上已经有 Harbor 的 `registry` 容器（即使已停止），名字冲突。

### 解决

用带命名空间的 registry 名：

```bash
REGISTRY_NAME=k3d-registry-dev
```

本项目默认就是 `k3d-registry-${CLUSTER_NAME}`，不会撞名。

清理回滚残留：

```bash
docker network rm k3d-dev
# 如果有半成品容器
docker rm -f registry k3d-dev-server-0 k3d-dev-agent-0 k3d-dev-serverlb 2>/dev/null || true
```

然后 `make up`。

> 不要删除别人的 `registry` 容器（可能是 Harbor 的数据）。先 `docker inspect` 确认。

---

## 坑 3：WSL 重启后 Docker 没起来

### 症状

```text
Cannot connect to the Docker daemon at unix:///var/run/docker.sock.
Is the docker daemon running?
```

或者 `make up` 报 Docker 不可用。

### 原因

WSL 里的 Docker 服务默认可能是 `disabled`。当前机器安装前就是：

```text
$ systemctl is-enabled docker
disabled
```

WSL 重启后 systemd 不会自动启动它。

### 解决

```bash
sudo systemctl enable --now docker
systemctl is-enabled docker    # enabled
systemctl is-active docker     # active
```

`make install` 会自动做这一步。

另外，Windows 重启后 WSL 本身不会运行，需要先启动 WSL：

```powershell
wsl.exe -d Ubuntu-22.04 -e true
```

再 `make up`。

---

## 坑 4：代理配了，但节点里还是拉不到镜像

### 症状

WSL 里 `docker pull` 很快，但 k3s 节点日志仍然：

```text
failed to pull image "rancher/mirrored-pause:3.6":
dial tcp 185.60.216.50:443: i/o timeout
```

### 原因

- Docker daemon 的代理只作用于 `docker pull`；
- k3s 节点里的 containerd 不继承 Docker daemon 的 systemd 环境；
- 节点容器的网络是 Docker bridge，`127.0.0.1:7897` 指向节点自己，不是 Windows 代理。

### 解决

按优先级：

1. **预导入镜像**（本项目默认，最稳）：
   ```bash
   make images
   make up
   ```
2. 如果坚持让节点自己拉，创建集群时给节点传代理环境变量：
   ```bash
   K3D_CREATE_EXTRA_ARGS='--env HTTP_PROXY=http://192.168.0.111:7897@server:* --env HTTPS_PROXY=http://192.168.0.111:7897@server:* --env HTTP_PROXY=http://192.168.0.111:7897@agent:* --env HTTPS_PROXY=http://192.168.0.111:7897@agent:*' make up
   ```
   注意 `NO_PROXY` 要包含 `172.22.0.0/16,10.42.0.0/16,10.43.0.0/16,localhost,127.0.0.1`，否则 k3s 自己访问 API 也会走代理。
3. 用镜像加速 `registries.yaml`，见坑 1。

### 代理地址怎么找

```bash
# 从 WSL 测试
curl -x http://192.168.0.111:7897 -I https://github.com

# 如果局域网 IP 不通，用 WSL 网关
ip route show default | awk '{print $3}'
curl -x http://172.30.240.1:7897 -I https://github.com
```

Windows 代理需要允许局域网（Clash: Allow LAN），并且 Windows 防火墙放行。

代理 IP 变化后，修改 `config/cluster.env.local` 的 `PROXY_URL`，重新 `make install`（会重启 Docker，集群需 `make up`）。

---

## 坑 5：flannel `subnet.env` 不存在

### 症状

```text
FailedCreatePodSandBox: ... plugin type="flannel" failed (add):
failed to load flannel 'subnet.env' file:
open /run/flannel/subnet.env: no such file or directory
```

通常出现在集群刚创建、agent 比 server 的 flannel 先就绪的几秒内。

### 原因

flannel 的 subnet 文件还没写入，Pod 调度抢先了。多数情况下是瞬态的。

### 解决

等 30–60 秒，Pod 会自动重试成功。如果持续：

```bash
# 重启节点
k3d cluster restart dev --wait

# 还不行就看节点日志
make logs ARGS="agent"
make logs ARGS="server"
```

如果反复出现，检查：

```bash
docker exec k3d-dev-server-0 ls -l /run/flannel/subnet.env
docker exec k3d-dev-agent-0 ls -l /run/flannel/subnet.env
```

以及节点之间 8472/UDP（VXLAN）是否被防火墙拦截。WSL 本机一般不会。

> 这条 warning 在集群刚起来时出现一次是正常的，不要被它带偏；先看 Pod 最终是否 Running。

---

## 坑 6：端口被占用

### 症状

```text
Error response from daemon: Ports are not available:
exposing port TCP 0.0.0.0:8080 -> ... bind: address already in use
```

或 k3d 创建时提示端口冲突。

### 原因

8080/8443/5000 是开发机常见端口；Harbor 常用 5000/80/443。

### 解决

```bash
ss -lntp | grep -E ':(6443|8080|8443|5000)\b'
```

改 `config/cluster.env.local`：

```bash
API_PORT=16443
HTTP_PORT=18080
HTTPS_PORT=18443
REGISTRY_PORT=15000
```

然后：

```bash
make down
make up
```

端口是创建时固定的，改完必须重建。

---

## 坑 7：Ingress 返回 404 / 默认 404

### 症状

```bash
curl http://127.0.0.1:8080/
# 404 page not found
```

但 `kubectl get ingress` 显示存在。

### 原因

Ingress 是按 Host 路由的。直接访问 `127.0.0.1` 没有匹配的 Host，Traefik 返回 404。

### 解决

```bash
curl -H 'Host: demo.localhost' http://127.0.0.1:8080/
# 或
curl --resolve demo.localhost:8080:127.0.0.1 http://demo.localhost:8080/
```

检查：

```bash
kubectl -n demo get ingress whoami -o yaml
kubectl -n demo get svc whoami
kubectl -n demo get endpoints whoami
```

常见错误：

- `ingressClassName` 没写或写错（应为 `traefik`）；
- Service 的 `targetPort` 和容器端口不一致；
- Ingress backend 的 service name/port 写错；
- 应用没 Ready，Endpoints 为空。

---

## 坑 8：registry push 成功，Pod 却 ErrImagePull

### 症状

```bash
docker push localhost:5000/team/myapp:dev   # 成功
kubectl run test --image=localhost:5000/team/myapp:dev
# ErrImagePull / ImagePullBackOff
```

### 原因

Pod 里的 `localhost` 是 Pod 自己，不是 WSL 宿主。

### 解决

Pod 里必须用 **集群内 registry 名称**：

```bash
kubectl run test --image=k3d-registry-dev:5000/team/myapp:dev
```

验证 registry 是否接入：

```bash
docker exec k3d-dev-server-0 cat /etc/rancher/k3s/registries.yaml
# 应包含 k3d-registry-dev:5000 的 mirror 配置
```

如果用了别的 registry 名，替换 `k3d-registry-dev`。

---

## 坑 9：`k3d image import` 报找不到镜像

### 症状

```text
ERRO image ... not found in docker
```

### 原因

- `docker pull` 没成功；
- 镜像名/tag 写错；
- 用了镜像站前缀（`docker.m.daocloud.io/...`）但 import 时写的是标准名（或反过来）。

### 解决

```bash
docker images | grep <name>
docker image inspect <image>
```

统一用标准名：

```bash
docker tag docker.m.daocloud.io/rancher/mirrored-pause:3.6 rancher/mirrored-pause:3.6
k3d image import -c dev rancher/mirrored-pause:3.6
```

`prepare-images.sh` 已经在镜像站拉取后自动 `docker tag` 成标准名。

---

## 坑 10：kubeconfig / context 丢失

### 症状

```text
error: context "k3d-dev" does not exist
```

或 `kubectl` 连到别的集群。

### 解决

```bash
k3d kubeconfig merge dev --kubeconfig-switch-context
kubectl config get-contexts
kubectl config use-context k3d-dev
```

如果 kubeconfig 被写坏：

```bash
k3d kubeconfig get dev > ~/.kube/config-k3d-dev
export KUBECONFIG=~/.kube/config-k3d-dev
```

---

## 坑 11：`InvalidDiskCapacity` warning

### 症状

```text
Warning InvalidDiskCapacity node/k3d-dev-server-0 invalid capacity 0 on image filesystem
```

### 原因

k3s 在 Docker 容器里对 image filesystem 的统计不准确，这是已知的良性告警。

### 解决

忽略。只要节点 `Ready`、Pod 能跑、磁盘没真的满，就不影响使用。

---

## 坑 12：metrics-server 启动初期 500 / `kubectl top` 不可用

### 症状

```text
Error from server (ServiceUnavailable): the server is currently unable to handle the request
```

或：

```text
error: Metrics API not available
```

### 原因

metrics-server 刚启动，APIService 还没就绪；或镜像没拉到。

### 解决

```bash
kubectl -n kube-system get deploy metrics-server
kubectl -n kube-system logs deploy/metrics-server --tail=50
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
```

等 30–60 秒。如果 `ImagePullBackOff`，回到坑 1 导入镜像。

---

## 坑 13：WSL 内存不足 / OOM

### 症状

- Pod 随机被 OOMKilled；
- `kubectl describe pod` 显示 `OOMKilled`；
- WSL 整体卡死；
- `docker stats` 看到内存接近上限。

### 原因

WSL 默认内存约为物理内存的 50%，当前只有 3.8 GB；k3s + Traefik + 镜像导入 + 应用容易打满。

### 解决

`.wslconfig`（Windows 用户目录）：

```ini
[wsl2]
memory=6GB
processors=4
swap=2GB
```

```powershell
wsl --shutdown
```

然后重新进入 WSL。给应用设置 requests/limits，不要无限跑。

---

## 坑 14：Docker Desktop 与原生 Docker 混用

### 症状

- 有时 `docker context` 指向 `desktop-linux`；
- k3d 网络/端口行为不一致；
- 代理配置不生效；
- 文件路径/性能异常。

### 原因

Docker Desktop 的 daemon 在 Windows 侧，WSL 只是客户端；k3d 节点实际跑在 Docker Desktop 的 VM 里，和 WSL 内原生 Docker 不是一个环境。

### 解决

统一用一个：

```bash
docker context ls
docker context use default
```

推荐 WSL 内原生 Docker（本文方案）。如果必须用 Docker Desktop，跳过本文的 Docker daemon 代理配置，改在 Docker Desktop 设置里配代理。

---

## 坑 15：集群创建超时 / 回滚不干净

### 症状

```text
FATA Cluster creation FAILED, also FAILED to rollback changes!
```

### 解决

```bash
k3d cluster list
docker ps -a --filter name=k3d-dev
docker network ls | grep k3d
docker volume ls | grep k3d
```

清理：

```bash
k3d cluster delete dev || true
docker rm -f $(docker ps -aq --filter name=k3d-dev) 2>/dev/null || true
docker network rm k3d-dev 2>/dev/null || true
docker volume rm k3d-dev-images 2>/dev/null || true
```

然后重新 `make up`。如果反复失败，先 `make images` 确认镜像齐全，再检查端口。

---

## 坑 16：时间不同步导致 TLS/证书错误

### 症状

```text
x509: certificate has expired or is not yet valid
```

### 原因

WSL 休眠/挂起后时钟漂移。

### 解决

```bash
sudo apt-get install -y systemd-timesyncd
sudo systemctl enable --now systemd-timesyncd
timedatectl
```

然后重启集群。

---

## 坑 17：`kubectl top` 正常但 `kubectl logs` 报 TLS

通常是 kubeconfig 里 server 地址和证书 SAN 不匹配。用 k3d 生成的 context：

```bash
k3d kubeconfig merge dev --kubeconfig-switch-context
```

不要手工把 server 改成 `0.0.0.0` 或容器 IP。

---

## 坑 18：卸载后残留

```bash
# 看还有什么
k3d cluster list
docker ps -a --filter name=k3d
docker network ls | grep k3d
docker volume ls | grep k3d
ls ~/.k3d 2>/dev/null
grep -r "k3d-on-wsl" ~/.bashrc
```

全量清理：

```bash
bash scripts/uninstall.sh --yes --purge
```

如果之前手工创建过集群：

```bash
k3d cluster delete --all
docker network rm $(docker network ls -q --filter name=k3d) 2>/dev/null || true
```

---

## 坑 19：Docker 29 + containerd image store，`docker save` 导出的 tar 导入失败

### 症状

`k3d image import` 报：

```text
ctr: content digest sha256:0fe79da57a2637b5644b904fa5436fbf09acfed4e9ccb28c08ecb651d26e2a13: not found
```

或 `docker save` 报：

```text
Error response from daemon: no suitable export target found: image with reference
rancher/mirrored-metrics-server:v0.8.1 was found but does not provide the specified platform (linux/amd64)
```

### 原因

Docker 29 默认使用 **containerd image store**：

```text
$ docker info | grep -A1 'Storage Driver'
 Storage Driver: overlayfs
  driver-type: io.containerd.snapshotter.v1
```

镜像的 tag 指向多架构 manifest list，而本地只缓存了 amd64 的层。`docker save` 仍会把 manifest list 写进 tar，并引用其他平台（arm64 等）的 blob；节点里的 `ctr images import` 找不到这些 blob，于是报 `content digest ... not found`。

这不是 k3d 的 bug，也不是镜像坏了，是 Docker 29 存储驱动的导出行为。

### 解决

用 `skopeo` 按当前架构导出单平台 **docker-archive**，再交给 `k3d image import`：

```bash
# 安装（Ubuntu 22.04 universe 自带）
sudo apt-get install -y skopeo

# 导出（走代理时带 HTTPS_PROXY）
HTTPS_PROXY=http://192.168.0.111:7897 \
skopeo copy --override-os linux --override-arch amd64 \
  docker://docker.io/rancher/mirrored-metrics-server:v0.8.1 \
  docker-archive:/tmp/metrics.tar:rancher/mirrored-metrics-server:v0.8.1

k3d image import -c dev /tmp/metrics.tar
```

本项目已经自动化：

- `scripts/prepare-images.sh` 生成 `images/cache/*.tar`；
- `scripts/up.sh` 用这些 archive 导入并校验；
- 批量导入不完整时会逐个重试。

不要用 `docker save` 直接喂给 k3d（尤其是 Docker 29+）。如果必须用，先 `docker pull --platform linux/amd64` 也不能保证修复，实测 metrics-server 仍然失败。

---

## 坑 20：PVC 一直 Pending，local-path helper Pod 拉 `mirrored-library-busybox`

### 症状

```bash
kubectl -n demo get pvc
# STATUS: Pending，事件里 ProvisioningFailed
kubectl -n kube-system describe pod helper-pod-create-pvc-...
# Image: rancher/mirrored-library-busybox:1.37.0
# ErrImagePull: dial tcp ... i/o timeout
```

### 原因

`local-path-provisioner` 创建/删除 PVC 时会起一个 helper Pod，它用的不是普通的 `busybox`，而是 k3s 内置的：

```text
rancher/mirrored-library-busybox:1.37.0
```

这个镜像不在“系统 Pod”列表里，容易漏导入。漏了之后 PVC 会卡在 Pending，`storage-test` 也 Pending。

### 解决

```bash
# 1. 拉取并导出 helper 镜像
docker pull rancher/mirrored-library-busybox:1.37.0

HTTPS_PROXY=http://192.168.0.111:7897 \
skopeo copy --override-os linux --override-arch amd64 \
  docker://docker.io/rancher/mirrored-library-busybox:1.37.0 \
  docker-archive:images/cache/rancher_mirrored-library-busybox_1.37.0.tar:rancher/mirrored-library-busybox:1.37.0

# 2. 导入
k3d image import -c dev images/cache/rancher_mirrored-library-busybox_1.37.0.tar

# 3. 让 provisioner 重试（删掉卡住的 helper/claim 或等它自动重试）
kubectl -n kube-system delete pod -l app=local-path-provisioner 2>/dev/null || true
```

本项目的 `HELPER_IMAGE` 默认就是 `rancher/mirrored-library-busybox:1.37.0`，`make images` / `make up` 会自动处理。

> 如果升级 k3s，helper 镜像 tag 可能变化。用
> `kubectl -n kube-system describe pod helper-pod-... | grep Image:`
> 确认实际 tag，再更新 `HELPER_IMAGE`。

---

## 仍然解决不了？

收集这些信息再查：

```bash
uname -a
cat /etc/os-release
docker version
docker info
k3d version
kubectl version --client
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -80
docker ps -a --filter name=k3d
make logs ARGS="all"
```
