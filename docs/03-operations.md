# 运维：生命周期、WSL 重启、升级与排障入口

---

## 1. 生命周期命令

| 命令 | 作用 | 数据 | 镜像 |
|---|---|---|---|
| `make up` | 不存在则创建；存在则启动/复用 | 保留 | 保留 |
| `make stop` | 停止节点容器 | 保留 | 保留 |
| `make start` | 启动已停止的集群，等待组件 Ready | 保留 | 保留 |
| `make restart` | 重启节点容器（不改配置） | 保留 | 保留 |
| `make down` | 删除集群、网络、PVC、registry | **删除** | 保留 |
| `make uninstall` | 删除集群 + k3d 二进制 | **删除** | 保留 |
| `make uninstall ARGS=--purge` | 全量清理（镜像、代理配置、缓存） | **删除** | **删除** |

`make down` / `make uninstall` 默认会交互确认；非交互场景加 `--yes`：

```bash
bash scripts/down.sh --yes
bash scripts/uninstall.sh --yes --purge
```

> `make down` 删除的是 k3d 的 Docker 容器和卷，PVC 数据在其中，无法恢复。重要清单请放在 Git 里，重要数据不要只放在本地集群。

---

## 2. WSL 重启后集群还在吗

分三层看：

### 2.1 WSL 发行版是否启动

Windows 重启后，WSL 不会自动运行，直到你打开终端或执行 `wsl.exe`。WSL 不运行，Docker 和 k3d 都不会运行。

手动启动：

```powershell
wsl.exe -d Ubuntu-22.04 -e true
```

然后：

```bash
make status
make up      # 如果容器没有自动起来
```

### 2.2 Docker 是否自动启动

`scripts/install.sh` 已执行：

```bash
sudo systemctl enable docker
```

WSL 启动后 systemd 会拉起 Docker。验证：

```bash
systemctl is-enabled docker   # enabled
systemctl is-active docker    # active
```

### 2.3 k3d 容器是否自动启动

k3d 创建的节点容器带有 Docker restart policy。Docker 启动后，容器通常会自己回来；如果显示 `Exited`：

```bash
make up       # 会执行 k3d cluster start
# 或
make start
```

`make up` 是幂等的，重复执行不会重建集群。

### 2.4 可选：Windows 登录时自动启动 WSL

如果希望登录 Windows 后集群自动可用，创建一个计划任务：

```powershell
schtasks /Create /TN "Start WSL for k3d" /SC ONLOGON /TR "wsl.exe -d Ubuntu-22.04 -e true" /F
```

删除：

```powershell
schtasks /Delete /TN "Start WSL for k3d" /F
```

这不是必须的；不创建也能在需要时手动 `wsl` 进入。

---

## 3. WSL 资源限制

默认 WSL 可能只分到一半内存。当前机器 3.8 GB，运行 1 server + 1 agent + 几个 demo 没问题；如果要跑更多服务，在 Windows 用户目录创建 `C:\Users\<you>\.wslconfig`：

```ini
[wsl2]
memory=6GB
processors=4
swap=2GB
```

然后：

```powershell
wsl --shutdown
```

重新进入 WSL 生效。验证：

```bash
free -h
nproc
```

> 不要把 `memory` 设得超过 Windows 物理内存；也不要设得太小，k3s + Traefik + 镜像导入会 OOM。

---

## 4. 端口与冲突

默认映射：

| 端口 | 用途 |
|---|---|
| 6443 | Kubernetes API |
| 8080 | HTTP Ingress（Traefik） |
| 8443 | HTTPS Ingress（Traefik） |
| 5000 | 本地 registry |

查占用：

```bash
ss -lntp | grep -E ':(6443|8080|8443|5000)\b'
```

Windows 侧：

```powershell
netstat -ano | findstr ":8080"
```

改端口：编辑 `config/cluster.env.local`：

```bash
API_PORT=16443
HTTP_PORT=18080
HTTPS_PORT=18443
REGISTRY_PORT=15000
```

然后必须重建集群（端口是创建时固定的）：

```bash
make down
make up
```

> 不要只改配置后 `make start`，端口不会变。

---

## 5. 升级 k3d / k3s

### 5.1 升级 k3d（工具）

```bash
# 修改 config/cluster.env.local
# K3D_VERSION=v5.9.0
make install ARGS=--force
```

k3d 二进制升级不需要重建集群；但大版本升级后建议 `make down && make up` 验证。

### 5.2 升级 k3s（集群）

k3s 版本是创建时固定的，升级等于重建：

```bash
# 1. 修改 K3S_VERSION（并确认系统镜像 tag 清单，见 docs/01-install.md）
make images
make down
make up
```

重建会删除工作负载和 PVC。生产式升级（滚动替换节点）不属于本工具的定位。

### 5.3 固定版本的意义

- `K3D_VERSION`、`K3S_VERSION` 都在 `config/cluster.env`；
- 镜像 tag 与版本绑定；
- 不在脚本里使用 `latest`；
- 换机器、换时间重建，得到同一套控制面版本。

---

## 6. 备份与迁移

本地开发集群不建议做 etcd 备份，推荐“声明式重建”：

```bash
# 导出所有业务清单（排除系统命名空间）
kubectl get ns -o name | grep -vE 'kube-system|kube-public|kube-node-lease|default' \
  | xargs -I{} sh -c 'kubectl -n ${0#namespace/} get deploy,svc,ingress,cm,secret,pvc -o yaml > manifests-${0#namespace/}.yaml' {}
```

更推荐项目里保存 Helm chart / Kustomize，集群只作为运行环境。

需要搬迁镜像：

```bash
make save-images
# 另一台机器
mkdir -p images/cache
tar -xf images/k3d-base-v1.35.5-k3s1.tar -C images/cache
for f in images/cache/*.tar; do docker load -i "$f"; done
make up
```

---

## 7. 日志与健康检查

```bash
# 整体
make status

# 节点日志（k3s server）
make logs
make logs ARGS="agent -f"
make logs ARGS="lb"
make logs ARGS="all"

# 组件
kubectl -n kube-system logs deploy/traefik --tail=100
kubectl -n kube-system logs deploy/coredns --tail=100
kubectl -n kube-system logs deploy/local-path-provisioner --tail=100
kubectl -n kube-system logs deploy/metrics-server --tail=100

# 事件（排错第一入口）
kubectl get events -A --sort-by=.lastTimestamp | tail -40

# 节点容器
docker ps --filter name=k3d-dev
docker stats --no-stream
```

健康标准：

```bash
kubectl get nodes                 # 全部 Ready
kubectl get pods -A               # 无 CrashLoopBackOff / ImagePullBackOff
kubectl -n kube-system get deploy # 4 个 AVAILABLE
curl -s http://localhost:5000/v2/_catalog
```

---

## 8. 磁盘清理

```bash
docker system df
docker image prune -f          # 删除悬空镜像
docker builder prune -f        # 删除构建缓存
```

不要随手 `docker system prune -a`：会删掉 k3d 节点镜像、k3s 镜像和本地 registry 数据，集群需要重建。

查看 k3d 相关卷：

```bash
docker volume ls | grep k3d
```

`make down` 会删除集群卷；`make uninstall --purge` 会删除镜像。

---

## 9. Docker 重启后集群异常

任何 `systemctl restart docker`、Docker Desktop 重启、代理配置变更都会导致 k3d 节点容器重启。恢复：

```bash
make status
make up
```

如果节点容器一直 `Restarting`：

```bash
docker logs --tail 100 k3d-dev-server-0
docker logs --tail 100 k3d-dev-agent-0
```

常见原因是 Docker 网络未就绪、代理把集群内部地址也代理了（`NO_PROXY` 没覆盖 `172.22.0.0/16`、`10.42.0.0/16`）。见 [pitfalls](04-pitfalls.md)。

---

## 10. 安全边界

- API 绑定 `0.0.0.0:6443`，但通过 WSL 的 localhost 转发访问；不要在公网网卡上暴露。
- 内置 registry 是 HTTP，仅用于本地开发。
- k3d 节点容器是 privileged 的（k3s in Docker 的要求），不要把它当多租户隔离环境。
- 不要把生产 kubeconfig、云厂商凭证放进这个集群。
