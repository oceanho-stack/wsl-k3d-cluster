# 安装：从零到可用的 k3d on WSL

本文按“Windows + WSL2 + Ubuntu 22.04 + WSL 内原生 Docker”编写。当前机器已经按本文完成安装，版本见文末。

---

## 1. 前置条件

| 项目 | 要求 | 检查命令（WSL 内） |
|---|---|---|
| Windows | Windows 10 21H2+ / Windows 11，启用 WSL2 | `wsl.exe -l -v` |
| 发行版 | Ubuntu 22.04（本文验证版本） | `lsb_release -a` |
| systemd | WSL 内 PID 1 是 systemd | `ps -p 1 -o comm=` |
| Docker | 原生 Docker Engine，daemon 可访问 | `docker version` |
| kubectl | 与集群交互（脚本依赖） | `kubectl version --client` |
| 用户权限 | 当前用户在 `docker` 组 | `id -nG` |
| 资源 | 建议 ≥ 4 GB 内存、≥ 10 GB 磁盘 | `free -h`、`df -h /` |
| 端口 | 6443 / 8080 / 8443 / 5000 空闲 | `ss -lntp` |
| inotify | `max_user_instances` ≥ 8192（机器上还跑着别的 kind/k8s 时必须） | `sysctl fs.inotify.max_user_instances` |

当前机器实测：Ubuntu 22.04.5、内核 6.18 WSL2、Docker 29.1.3、2 vCPU / 3.8 GB 内存，可正常运行 1 server + 1 agent。

### 1.1 确认 systemd

```bash
ps -p 1 -o comm=
# 期望输出：systemd
```

如果不是 systemd，编辑 `/etc/wsl.conf`：

```ini
[boot]
systemd=true
```

然后在 Windows 执行 `wsl --shutdown`，重新打开 Ubuntu。

### 1.2 安装 Docker（WSL 内原生，不用 Docker Desktop）

```bash
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

退出 WSL 再进入（或 `newgrp docker`），验证：

```bash
docker version
docker run --rm hello-world
```

> 也可以用 Docker 官方 apt 源安装更新版本。本项目在 Docker 29.1.3 上验证。
>
> 如果使用 Docker Desktop 的 WSL integration，k3d 也能工作，但镜像/端口/代理由 Docker Desktop 管理，本文的 Docker daemon 代理步骤不适用。建议 WSL 内原生 Docker，行为最可控。

`scripts/status.sh`、`scripts/test.sh`、`scripts/up.sh` 依赖 `kubectl`。当前机器已有 v1.36；没有的话按官方文档安装：

```bash
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 1.3 让 Docker 随 WSL 启动

```bash
systemctl is-enabled docker
# 期望：enabled
```

`scripts/install.sh` 会自动执行 `systemctl enable docker`。WSL 没有“开机自启”概念，只有 WSL 发行版被启动时 systemd 才会拉起 Docker；见 [operations](03-operations.md#wsl-重启后集群还在吗)。

### 1.4 抬升内核 inotify 限制（重要）

k3s 的 containerd 在容器里启动时，CRI 插件和 kube-apiserver 都要创建 inotify 实例。内核对**每个 UID** 只有 128 个实例额度，而容器内的 root 就是宿主 root——机器上任何以 root 运行的容器（其他 kind 集群、构建容器、watch 类工具）都共享这份额度。

额度耗尽时，containerd 的 CRI 插件加载失败（`failed to create fsnotify watcher: too many open files`），kubelet 起不来，k3d 只会看到“agent 注册超时”然后回滚。排查与完整日志见 [坑 21](04-pitfalls.md#坑-21集群创建回滚agent-报注册超时其实是内核-inotify-实例耗尽)。

```bash
sudo tee /etc/sysctl.d/99-k3d-inotify.conf >/dev/null <<'EOF'
# k3d/k3s: containerd CRI plugin and kube-apiserver need inotify instances.
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 2097152
fs.inotify.max_queued_events = 65536
EOF

sudo sysctl --system
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
# 期望：8192 / 2097152
```

这些是上限而不是预分配，只有真正存在的 watch 才占内核内存。文件放在 `/etc/sysctl.d/` 下，WSL 里由 `systemd-sysctl` 在每次发行版启动时自动应用，不需要重复执行。

> 单集群、机器上没有其他 k8s 时可跳过；一旦出现“集群创建到一半回滚”，先查这一项。

---

## 2. 配置 Windows 代理（可选，但国内强烈建议）

### 2.1 找到 WSL 能访问的代理地址

Windows 代理只监听 `127.0.0.1` 时，WSL 里访问不到；需要监听局域网或被 WSL 网关转发。当前机器的代理监听 `::7897`，WSL 可通过 Windows 局域网 IP 访问：

```bash
# 在 WSL 中测试（把 IP 换成你的 Windows 局域网 IP）
curl -x http://192.168.0.111:7897 -I https://github.com
# 期望 HTTP/2 200
```

如果局域网 IP 不通，试 WSL 默认网关：

```bash
ip route show default | awk '{print $3}'
# 例如 172.30.240.1
curl -x http://172.30.240.1:7897 -I https://github.com
```

> 代理软件需要允许局域网连接（Clash: Allow LAN）。网关地址在 WSL 重启后可能变化，局域网 IP 更稳定。

### 2.2 写入本机配置

```bash
cp config/cluster.env.local.example config/cluster.env.local
# 编辑 config/cluster.env.local：
# PROXY_URL="http://192.168.0.111:7897"
```

`config/cluster.env.local` 已被 `.gitignore` 忽略，不会把个人 IP 提交到仓库。

脚本会用这个地址做两件事：

1. `scripts/install.sh` 写入 Docker daemon 的 systemd drop-in，让 `docker pull` 走代理；
2. `scripts/prepare-images.sh` 的 `docker pull` 使用该代理。

如果代理地址变了：修改 `config/cluster.env.local`，重新执行 `make install`。Docker 会重启一次，集群会被停掉，随后 `make up` 即可。

### 2.3 没有代理怎么办

脚本内置镜像回退：

```bash
DOCKERHUB_MIRROR="https://docker.m.daocloud.io"
GHCR_MIRROR="https://ghcr.m.daocloud.io"
```

`docker pull` 直连失败时会自动改用镜像源，再 `docker tag` 成标准名字。镜像源可用性会变化，失败时换一个源即可。也可以手动 `docker load` 离线 tar（见第 4 节）。

---

## 3. 安装 k3d

```bash
cd /mnt/d/projects/oceanho-stack-infra
make install
```

等价于 `bash scripts/install.sh`。脚本做的事：

1. 按 CPU 架构下载固定版本 `v5.9.0` 的 k3d 二进制；
2. 下载并校验 `checksums.txt`（SHA-256）；
3. 安装到 `~/.local/bin/k3d`，并把该目录加入 `~/.bashrc` 的 PATH；
4. 检查 Docker，必要时 `systemctl enable --now docker`；
5. 配置 Docker daemon 代理（如果设置了 `PROXY_URL`）；
6. 打印 k3d / Docker 版本。

常用参数：

```bash
bash scripts/install.sh --force                    # 强制重装
bash scripts/install.sh --version v5.9.0           # 覆盖版本
bash scripts/install.sh --dir /usr/local/bin       # 换安装目录（需要 sudo）
bash scripts/install.sh --proxy http://IP:7897     # 临时指定代理
```

验证：

```bash
k3d version
# k3d version v5.9.0
# k3s version v1.35.5-k3s1 (default)   ← k3d 默认 k3s 版本
```

> 注意：`k3d version` 打印的 k3s 版本是 k3d 的默认值，不是本项目实际使用的版本。本项目在 `config/cluster.env` 中把 `K3S_VERSION` 固定为 `v1.35.5-k3s1`。

如果 GitHub 下载失败，可以设置下载前缀（任选可用镜像）：

```bash
K3D_DOWNLOAD_MIRROR="https://ghfast.top/" make install
```

---

## 4. 预拉取镜像（关键步骤）

### 4.1 为什么要单独做

k3d 的节点是 Docker 容器，但节点里运行的是 **containerd**，不是宿主 Docker。`docker pull` 拉下来的镜像默认不会自动出现在 k3s 节点里。

如果直接 `k3d cluster create`，k3s 会从节点内部访问 `registry-1.docker.io` 拉：

- `rancher/mirrored-pause:3.6`（Pod sandbox）
- `rancher/mirrored-coredns-coredns`
- `rancher/mirrored-library-traefik`
- `rancher/local-path-provisioner`
- `rancher/mirrored-metrics-server`
- `rancher/klipper-helm` / `klipper-lb`

国内网络下这些请求会超时，表现为 `ContainerCreating` / `ImagePullBackOff`，但节点本身是 `Ready`。这是本项目遇到的最大坑，详见 [pitfalls](04-pitfalls.md#坑-1节点-ready但所有系统-pod-卡在-containercreating)。

本项目的解法：

1. 在 WSL Docker 里预拉全部镜像；
2. 用 `skopeo` 把镜像导出为**单平台** Docker archive（Docker 29 的 containerd image store 下 `docker save` 多架构镜像会失败，见 [pitfalls 坑 19](04-pitfalls.md#坑-19docker-29--containerd-image-storedocker-save-导出的-tar-导入失败)）；
3. 创建集群后，用 `k3d image import` 把这些 archive 导入每个节点的 containerd；
4. 重启节点容器一次，让 kubelet 直接命中本地镜像；
5. 之后集群启动完全不需要外网。

### 4.2 执行

```bash
make images
# 或
bash scripts/prepare-images.sh --all
```

第一次会下载约 1 GB 镜像，并额外生成约 800 MB 的单平台 archive；耗时取决于代理速度。已存在的镜像/archive 会显示 `cached` 并跳过。脚本会自动安装 `skopeo`（Ubuntu universe 包），需要 sudo 权限。

只拉集群必需的（不含 demo/test）：

```bash
bash scripts/prepare-images.sh --core
```

### 4.3 镜像清单

| 镜像 | 用途 |
|---|---|
| `rancher/k3s:v1.35.5-k3s1` | k3s 节点 |
| `ghcr.io/k3d-io/k3d-proxy:5.9.0` | k3d 负载均衡 |
| `ghcr.io/k3d-io/k3d-tools:5.9.0` | k3d 工具节点（镜像导入） |
| `registry:2` | 内置本地镜像仓库 |
| `rancher/mirrored-pause:3.6` | Pod sandbox |
| `rancher/mirrored-coredns-coredns:1.14.3` | DNS |
| `rancher/mirrored-library-traefik:3.6.13` | Ingress |
| `rancher/local-path-provisioner:v0.0.36` | local-path 存储 |
| `rancher/mirrored-metrics-server:v0.8.1` | metrics-server |
| `rancher/klipper-helm:v0.10.0-build20260513` | HelmChart 安装器 |
| `rancher/klipper-lb:v0.4.17` | ServiceLB |
| `rancher/mirrored-library-busybox:1.37.0` | local-path 创建 PVC 的 helper Pod |
| `traefik/whoami:v1.10.2` | 冒烟测试 demo |
| `busybox:1.36.1` | PVC 测试 Pod |

共 14 个镜像（12 个核心 + 2 个测试）。`make images` 会同时维护两份缓存：

- WSL Docker 镜像库（给 k3d 节点镜像和日常 `docker run` 用）；
- `images/cache/*.tar` 单平台 archive（给 `k3d image import` 用）。

这些 tag 与 `K3S_VERSION=v1.35.5-k3s1` 绑定。升级 k3s 后必须重新确认清单，不能只改版本号。

### 4.4 离线保存 / 迁移

```bash
make save-images
# 生成 images/k3d-base-v1.35.5-k3s1.tar
```

> **临时下载地址（阿里云盘快传，24 小时有效）**
>
> 已经导出好的离线包放在阿里云盘快传，可直接下载，省去在新机器上重新拉取约 1 GB 镜像：
>
> <https://www.alipan.com/t/3zjxwqm0q3qvwwYpTvC1>
>
> | 项目 | 值 |
> |---|---|
> | 文件名 | `k3d-base-v1.35.5-k3s1.tar` |
> | 大小 | 1,240,494,080 字节（约 1.16 GB） |
> | SHA-256 | `cfaa9011f8d952b2efc40edba1a67b9669084777f4443ad1e7960570cbaf77df`（本验收环境导出，供下载后校验参考） |
> | 有效期 | 2026-11-12 19:02（北京时间） |
>
> 快传链接到期后自动失效，且不保证长期可用；失效时在本机重新执行 `make save-images` 即可生成同样的包。下载后建议先校验再解包：
>
> ```bash
> sha256sum k3d-base-v1.35.5-k3s1.tar
> ```

在另一台机器（同样架构），把下载或导出的 `k3d-base-v1.35.5-k3s1.tar` 放到仓库 `images/` 下：

```bash
mkdir -p images/cache
tar -xf images/k3d-base-v1.35.5-k3s1.tar -C images/cache
for f in images/cache/*.tar; do docker load -i "$f"; done
make up
```

`make save-images` 生成的是“archive 的集合”，不是单个 `docker load` 文件，所以要先解包。`make up` 发现 Docker 镜像和 `images/cache` 都存在时不会再访问网络。

### 4.5 校验镜像

```bash
docker images | grep -E 'k3s|k3d|mirrored|local-path|whoami|busybox|registry'
```

---

## 5. 创建集群

```bash
make up
```

首次执行会：

1. 检查端口（6443/8080/8443/5000）；
2. 创建 `k3d-dev` 集群：1 server + 1 agent + Traefik + 内置 registry；
3. 把系统镜像导入两个节点；
4. `k3d cluster restart` 重启节点；
5. 等待 4 个核心 Deployment 可用；
6. 输出 endpoints。

成功输出类似：

```text
[ ok ] kube-system/coredns available
[ ok ] kube-system/traefik available
[ ok ] kube-system/local-path-provisioner available
[ ok ] kube-system/metrics-server available

[ ok ] Cluster 'dev' is ready.
  kubectl context : k3d-dev
  API             : https://127.0.0.1:6443
  HTTP ingress    : http://127.0.0.1:8080  (use a Host header, e.g. demo.localhost)
  HTTPS ingress   : https://127.0.0.1:8443
  Local registry  : localhost:5000  (in-cluster: k3d-registry-dev:5000)
```

查看状态：

```bash
make status
kubectl get nodes
kubectl get pods -A
```

---

## 6. 冒烟测试

```bash
make test
```

会验证：

- 节点 Ready、核心组件 Available；
- 部署 `examples/demo.yaml`，通过 `http://127.0.0.1:8080` + `Host: demo.localhost` 访问 Traefik Ingress；
- 创建 PVC、写入并读回文件（local-path）；
- 向 `localhost:5000` push 镜像，并以 `k3d-registry-dev:5000/...` 在集群内拉取。

保留 demo 方便查看：

```bash
KEEP=1 make test
kubectl -n demo get pods,svc,ingress
curl -H 'Host: demo.localhost' http://127.0.0.1:8080/
```

清理 demo：

```bash
kubectl delete namespace demo
```

---

## 7. 安装完成检查清单

```bash
# 1. 版本
k3d version
kubectl version --client
docker version

# 2. 集群
kubectl config current-context     # k3d-dev
kubectl get nodes                  # 2 个 Ready
kubectl get pods -A                # 系统 Pod 全部 Running/Completed

# 3. Ingress
kubectl -n kube-system get svc traefik

# 4. 存储
kubectl get storageclass           # local-path (default)

# 5. 本机 registry
curl -s http://localhost:5000/v2/_catalog
# {"repositories":[]} 或已 push 的仓库
```

当前机器安装后的实际结果记录在 [README 的验收部分](../README.md#验收记录)。
