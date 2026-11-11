# k3d on WSL：可复用的本地 Kubernetes

在 WSL2 里用 [k3d](https://k3d.io/) 起一个带 **Traefik Ingress、local-path 存储、metrics-server、内置镜像仓库** 的单机 Kubernetes。所有安装、镜像、启停、测试、卸载都有幂等脚本；镜像预拉取后，集群启动**不需要访问外网**。

> 当前状态：已在 `Ubuntu-22.04` + Docker `29.1.3` 上部署验证，k3d `v5.9.0`，k3s `v1.35.5-k3s1`。
> 详细验收输出见文末 [验收记录](#验收记录)。

---

## 目录

- [1. 特性](#1-特性)
- [2. 快速开始](#2-快速开始)
- [3. 架构](#3-架构)
- [4. 目录结构](#4-目录结构)
- [5. 命令速查](#5-命令速查)
- [6. 配置](#6-配置)
- [7. 镜像与网络策略](#7-镜像与网络策略)
- [8. 日常使用](#8-日常使用)
- [9. 生命周期与 WSL 重启](#9-生命周期与-wsl-重启)
- [10. 卸载](#10-卸载)
- [11. 常见坑速查](#11-常见坑速查)
- [12. 已知限制](#12-已知限制)
- [13. 文档索引](#13-文档索引)
- [14. 验收记录](#14-验收记录)

---

## 1. 特性

| 能力 | 说明 |
|---|---|
| 可重复 | 所有配置集中在 `config/cluster.env`，脚本幂等；`make up` 可反复执行 |
| 可离线 | 14 个镜像预拉到 WSL Docker，并生成单平台 archive，`k3d image import` 到节点；运行时不依赖 Docker Hub |
| 版本固定 | k3d `v5.9.0`、k3s `v1.35.5-k3s1`、Traefik `3.6.13` 等全部写死 |
| 开箱即用 | 创建即带 1 server + 1 agent、Traefik Ingress、local-path、metrics-server、本地 registry |
| 生命周期完整 | 安装 / 创建 / 停止 / 启动 / 重启 / 状态 / 日志 / 测试 / 删除 / 卸载 |
| WSL 适配 | 处理 systemd、Docker 自启、Windows 代理、WSL 重启、端口转发 |
| 可迁移 | `make save-images` 导出离线归档；目标机解包并 `docker load` 后 `make up` |

---

## 2. 快速开始

在 **WSL Ubuntu** 中执行（不是 Windows PowerShell）：

```bash
cd /mnt/d/projects/oceanho-stack-infra

# 0) 可选：复制本机配置，填 Windows 代理/端口
cp config/cluster.env.local.example config/cluster.env.local
vi config/cluster.env.local

# 1) 安装 k3d（固定版本 + 校验和）
make install

# 2) 预拉全部基础镜像（第一次需要网络，约 1 GB）
make images

# 3) 创建集群（自动导入镜像、重启节点、等待组件 Ready）
make up

# 4) 看状态
make status

# 5) 冒烟测试（Ingress + PVC + registry）
make test
```

成功后：

```text
kubectl config current-context   # k3d-dev
kubectl get nodes                # 2 个 Ready
curl -H 'Host: demo.localhost' http://127.0.0.1:8080/
```

在 Windows 浏览器打开：

- `http://localhost:8080`（需要 Host 的 Ingress 用 `http://demo.localhost:8080`）
- 本地 registry：`http://localhost:5000/v2/_catalog`

> 本仓库当前目录已经包含 `config/cluster.env.local`（配置了本机代理 `192.168.0.111:7897`）。换机器时请按 `config/cluster.env.local.example` 重写，或删除该文件使用默认值。

---

## 3. 架构

```text
Windows
  │  http://localhost:8080 / 8443 / 6443
  ▼
WSL2 (Ubuntu 22.04, systemd)
  │
  ├─ Docker Engine 29.x
  │    ├─ k3d-dev-serverlb     nginx，发布 6443/8080/8443
  │    ├─ k3d-dev-server-0     k3s server（control-plane）
  │    ├─ k3d-dev-agent-0      k3s agent（worker）
  │    ├─ k3d-dev-tools        镜像导入辅助容器
  │    └─ k3d-registry-dev     registry:2，发布 localhost:5000
  │
  └─ k3d-dev Docker network (172.22.0.0/16)
       ├─ Pod network 10.42.0.0/16
       ├─ Service network 10.43.0.0/16
       ├─ Traefik Ingress (kube-system)
       ├─ CoreDNS
       ├─ local-path-provisioner
       └─ metrics-server
```

关键点：

- k3d 的“节点”是 Docker 容器，节点内的容器运行时是 **containerd**；
- 所以 `docker pull` 的镜像不会自动出现在节点里，必须 `k3d image import`；
- 本项目在创建后导入系统镜像并重启节点一次，使集群启动完全离线。

---

## 4. 目录结构

```text
.
├── Makefile                       # 统一入口
├── README.md                      # 本文
├── config/
│   ├── cluster.env                # 版本、端口、拓扑、镜像等全部配置
│   ├── cluster.env.local.example  # 本机覆盖模板（代理/端口）
│   ├── cluster.env.local          # 本机实际配置（git-ignored）
│   └── registries.yaml            # 可选的 containerd 镜像加速配置
├── scripts/
│   ├── lib.sh                     # 公共函数、镜像清单、健康检查
│   ├── install.sh                 # 安装 k3d + 校验 + Docker 准备
│   ├── prepare-images.sh          # 预拉/导出镜像
│   ├── up.sh                      # 创建或复用集群
│   ├── stop.sh / start.sh / restart.sh
│   ├── status.sh / logs.sh
│   ├── test.sh                    # 端到端冒烟测试
│   ├── down.sh                    # 删除集群
│   └── uninstall.sh               # 卸载（可选 --purge）
├── examples/
│   ├── demo.yaml                  # whoami + Ingress
│   └── storage.yaml               # PVC + busybox
├── images/                        # make save-images 的输出（git-ignored）
│   ├── cache/                     # 单平台 docker-archive，供 k3d import
│   └── k3d-base-<k3s>.tar         # 可迁移的离线包
└── docs/
    ├── 01-install.md
    ├── 02-usage.md
    ├── 03-operations.md
    ├── 04-pitfalls.md
    └── 05-uninstall.md
```

---

## 5. 命令速查

| 命令 | 作用 |
|---|---|
| `make help` | 查看所有目标 |
| `make install` | 安装固定版本 k3d，启用 Docker，配置代理 |
| `make images` | 拉取集群需要的全部镜像 |
| `make save-images` | 导出 `images/k3d-base-<k3s>.tar` |
| `make up` | 不存在则创建；存在则启动并等待 Ready |
| `make status` | 版本、容器、节点、Pod、Ingress、Endpoints |
| `make test` | 部署 demo，验证 Ingress、PVC、registry |
| `make stop` | 停止集群（保留状态） |
| `make start` | 启动已停止的集群 |
| `make restart` | 重启所有节点 |
| `make logs` | server 日志；`make logs ARGS="agent -f"` |
| `make down` | 删除集群（保留镜像和 k3d） |
| `make uninstall` | 删除集群 + k3d 二进制 |
| `make uninstall ARGS=--purge` | 全量清理（镜像、代理、缓存） |
| `make check` | 校验脚本语法（可选 shellcheck） |

直接调用脚本也可以，所有脚本都支持 `--help`：

```bash
bash scripts/up.sh
bash scripts/status.sh
bash scripts/down.sh --yes
```

---

## 6. 配置

编辑 `config/cluster.env.local`（不要改 `cluster.env` 里的默认值，便于升级对比）。

| 变量 | 默认 | 说明 |
|---|---|---|
| `CLUSTER_NAME` | `dev` | 集群名，context 为 `k3d-dev` |
| `K3D_VERSION` | `v5.9.0` | k3d 二进制版本 |
| `K3S_VERSION` | `v1.35.5-k3s1` | k3s 镜像版本 |
| `SERVERS` | `1` | server 数量 |
| `AGENTS` | `1` | agent 数量 |
| `API_PORT` | `6443` | Kubernetes API 映射端口 |
| `HTTP_PORT` | `8080` | Ingress HTTP 映射端口 |
| `HTTPS_PORT` | `8443` | Ingress HTTPS 映射端口 |
| `ENABLE_REGISTRY` | `1` | 是否创建内置 registry |
| `REGISTRY_NAME` | `k3d-registry-dev` | registry 容器名（必须唯一） |
| `REGISTRY_PORT` | `5000` | registry 宿主端口 |
| `PROXY_URL` | 空 | Windows 代理，如 `http://192.168.0.111:7897` |
| `DOCKERHUB_MIRROR` | daocloud | 直连失败时的 Docker Hub 镜像 |
| `GHCR_MIRROR` | daocloud | 直连失败时的 GHCR 镜像 |
| `HELPER_IMAGE` | `rancher/mirrored-library-busybox:1.37.0` | local-path 创建 PVC 的 helper 镜像 |
| `PREPARE_IMAGES` | `1` | 缺少镜像时自动拉取 |
| `IMPORT_IMAGES` | `1` | 创建集群后自动导入系统镜像 |
| `K3D_CREATE_EXTRA_ARGS` | 空 | 追加 k3d create 参数 |
| `REGISTRY_CONFIG` | 空 | 可选 containerd `registries.yaml` |
| `WAIT_TIMEOUT` | `300s` | 等待组件超时 |

完整变量和注释见 [`config/cluster.env`](config/cluster.env)。

---

## 7. 镜像与网络策略

### 7.1 为什么不直接在集群里拉

k3d 节点里的 containerd 无法稳定访问 Docker Hub，系统 Pod 会卡在 `ContainerCreating`。这是本项目最先遇到的问题，完整分析见 [pitfalls 坑 1](docs/04-pitfalls.md#坑-1节点-ready但所有系统-pod-卡在-containercreating)。

### 7.2 本项目的策略

```text
docker pull（WSL Docker，走代理/镜像）
        │
        ▼
skopeo copy（导出单平台 docker-archive，绕开 Docker 29 多架构 save 的坑）
        │
        ▼
k3d image import（导入每个节点的 containerd）
        │
        ▼
k3d cluster restart（kubelet 命中本地镜像，不再访问外网）
```

`make up` 自动完成全部步骤；`make images` 完成前两步。

> Docker 29 默认使用 containerd image store，`docker save` 导出的多架构 manifest 会引用本地不存在的 blob，`k3d image import` 报 `content digest ... not found`。`skopeo` 按当前架构导出单平台 archive 可以稳定解决。详见 [pitfall 19](docs/04-pitfalls.md#坑-19docker-29--containerd-image-storedocker-save-导出的-tar-导入失败)。

### 7.3 代理 vs 镜像

| 场景 | 配置 |
|---|---|
| Windows 有代理 | `PROXY_URL="http://<Windows-IP>:7897"` |
| 无代理，能访问镜像站 | 默认的 `DOCKERHUB_MIRROR` / `GHCR_MIRROR` 自动回退 |
| 完全离线 | 在别处 `make save-images`，本机解包 `images/cache` 并 `docker load` 后 `make up`（命令见 [docs/01](docs/01-install.md#44-离线保存--迁移)）；也可从[阿里云盘临时地址](https://www.alipan.com/t/3zjxwqm0q3qvwwYpTvC1)直接下载 `k3d-base-v1.35.5-k3s1.tar`（24 小时有效） |

代理只影响 `docker pull` 和 k3d 下载；节点运行时不需要网络，因为镜像已经导入。

---

## 8. 日常使用

最常用：

```bash
# 部署
kubectl apply -f examples/demo.yaml
kubectl -n demo rollout status deploy/whoami

# 访问（Ingress 按 Host 路由）
curl -H 'Host: demo.localhost' http://127.0.0.1:8080/

# 看
kubectl get pods -A
kubectl get ingress -A
kubectl top nodes
kubectl -n demo logs deploy/whoami

# 本地镜像闭环
docker build -t localhost:5000/team/app:dev .
docker push localhost:5000/team/app:dev
kubectl create deployment app --image=k3d-registry-dev:5000/team/app:dev
```

完整工作流（Ingress 规则、PVC、Helm、port-forward、多集群、Windows 访问）见 [docs/02-usage.md](docs/02-usage.md)。

---

## 9. 生命周期与 WSL 重启

```bash
make stop      # 停容器，保留数据
make start     # 启动并等待组件 Ready
make restart   # 重启节点
make down      # 删除集群和 PVC
make up        # 重建 / 复用
```

WSL 重启后：

1. 先启动 WSL：`wsl.exe -d Ubuntu-22.04 -e true`；
2. Docker 由 systemd 自动启动（`systemctl is-enabled docker` 应为 `enabled`）；
3. k3d 容器通常自动恢复；没有就 `make up`。

可选 Windows 登录自启：

```powershell
schtasks /Create /TN "Start WSL for k3d" /SC ONLOGON /TR "wsl.exe -d Ubuntu-22.04 -e true" /F
```

细节见 [docs/03-operations.md](docs/03-operations.md)。

---

## 10. 卸载

```bash
make down                          # 只删集群，保留工具和镜像
make uninstall                     # 删集群 + k3d 二进制，保留镜像/代理
make uninstall ARGS=--purge        # 全量清理
make uninstall ARGS="--purge --keep-images"
```

完整说明（含手工兜底、验证残留、Docker 是否一起删）见 [docs/05-uninstall.md](docs/05-uninstall.md)。

> `make down` 会删除 PVC 数据；需要保留先 `kubectl cp` 出来。

---

## 11. 常见坑速查

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| 节点 Ready，系统 Pod 一直 `ContainerCreating` | 节点 containerd 拉不到 pause 镜像 | `make images && make down && make up` |
| `container name "/registry" is already in use` | registry 名撞了 Harbor | 用默认的 `k3d-registry-<cluster>`，或改 `REGISTRY_NAME` |
| WSL 重启后 `Cannot connect to Docker daemon` | Docker 服务 `disabled` | `sudo systemctl enable --now docker` |
| `make up` 报端口占用 | 8080/8443/5000 被占 | 改 `config/cluster.env.local` 端口后重建 |
| `curl 127.0.0.1:8080` 返回 404 | Ingress 按 Host 路由 | 加 `-H 'Host: demo.localhost'` |
| Pod 用 `localhost:5000/...` 拉不到镜像 | Pod 里的 localhost 不是宿主 | 改用 `k3d-registry-dev:5000/...` |
| 节点日志 `dial tcp ... i/o timeout` | 节点无法访问 Docker Hub | 预导入镜像，或给节点配代理 |
| `kubectl top` 报 Metrics API 不可用 | metrics-server 刚启动/没镜像 | 等 60s，或检查镜像导入 |
| flannel `subnet.env` 不存在 | 节点启动竞态 | 等 30–60s，通常自愈 |
| WSL 卡顿/OOM | WSL 内存太小 | `.wslconfig` 调 memory，设 resources limits |

完整 20 个坑、错误日志和修复命令见 [docs/04-pitfalls.md](docs/04-pitfalls.md)。

---

## 12. 已知限制

- 单机开发集群，不做高可用；server 挂掉集群不可用。
- storage 只有 `local-path`，PVC 数据随 `make down` 删除。
- 没有 GPU、没有多租户隔离；k3d 节点是 privileged 容器。
- 未在 arm64 上实际验证（脚本支持下载 arm64 k3d，但镜像清单需重新确认）。
- 升级 k3s 需要重建集群，不做原地升级。
- 内置 registry 是 HTTP，仅限本机开发，不要暴露公网。

---

## 13. 文档索引

| 文档 | 内容 |
|---|---|
| [docs/01-install.md](docs/01-install.md) | 前置条件、systemd、Docker、代理、安装、镜像清单、创建、验证 |
| [docs/02-usage.md](docs/02-usage.md) | Ingress、本地 registry、PVC、Helm、多集群、Windows 访问 |
| [docs/03-operations.md](docs/03-operations.md) | 启停、WSL 重启、资源、端口、升级、备份、日志、安全 |
| [docs/04-pitfalls.md](docs/04-pitfalls.md) | 20 个实际踩坑与排错 |
| [docs/05-uninstall.md](docs/05-uninstall.md) | 三档卸载、手工清理、验证残留、重装 |

外部参考：

- k3d 文档：<https://k3d.io/>
- k3s 文档：<https://docs.k3s.io/>
- WSL systemd：<https://learn.microsoft.com/windows/wsl/systemd>
- Traefik：<https://doc.traefik.io/traefik/>

---

## 14. 验收记录

环境：Windows 11 + WSL2，Ubuntu 22.04.5，内核 `6.18.33.2-microsoft-standard-WSL2`，Docker `29.1.3`，2 vCPU / 3.8 GB。

版本：

```text
k3d version v5.9.0
k3s version v1.35.5-k3s1 (default)
Docker 29.1.3  storage=overlayfs  cgroup=systemd
```

节点：

```text
NAME               STATUS   ROLES           AGE   VERSION        CONTAINER-RUNTIME
k3d-dev-agent-0    Ready    <none>          4m    v1.35.5+k3s1   containerd://2.2.3-k3s1
k3d-dev-server-0   Ready    control-plane   4m    v1.35.5+k3s1   containerd://2.2.3-k3s1
```

系统组件：

```text
coredns-...                   1/1   Running
local-path-provisioner-...    1/1   Running
metrics-server-...            1/1   Running
traefik-...                   1/1   Running
svclb-traefik-... (x2)        2/2   Running
helm-install-traefik-crd-...  0/1   Completed
```

`make test`（全新创建后执行）：

```text
[ ok ] Ingress works (whoami answered)
[ ok ] PVC (local-path) works
[ ok ] Registry pull works (k3d-registry-dev:5000)
[ ok ] All smoke tests passed.
```

`kubectl top nodes`：

```text
NAME               CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k3d-dev-agent-0    39m          1%       267Mi           6%
k3d-dev-server-0   138m         6%       519Mi           13%
```

`make down` → `make up` 重建、`make stop` → `make up` 恢复均已验证；`k3d image import` 批量导入失败时脚本会逐个 archive 重试并校验两个节点。

实际镜像归档（`images/cache`）约 800 MB；首次完整安装（含下载）约 15–20 分钟，取决于代理速度。重建集群（镜像已缓存）约 2–3 分钟。
