# 卸载

卸载分三档，按需要选。**先确认没有你要保留的 PVC 数据**。

---

## 1. 三档卸载

| 命令 | 删除 | 保留 | 适用 |
|---|---|---|---|
| `make down` | 集群、节点容器、网络、PVC、registry | k3d 二进制、Docker 镜像 | 只想清掉运行环境，之后还能快速 `make up` |
| `make uninstall` | 上面全部 + k3d 二进制 + kubeconfig context | Docker 镜像、Docker 代理配置 | 不再用这套脚本，但镜像留着 |
| `make uninstall ARGS=--purge` | 上面全部 + 镜像 + 代理 drop-in + 缓存 tar + `~/.k3d` | 无（除 Docker 本身） | 完全清理 |

默认都会交互确认；自动化场景：

```bash
bash scripts/down.sh --yes
bash scripts/uninstall.sh --yes
bash scripts/uninstall.sh --yes --purge
```

只想删集群、保留 k3d 工具：

```bash
bash scripts/uninstall.sh --yes --keep-k3d
```

> 没有“只删二进制、保留集群”的推荐做法：k3d 二进制是管理集群的入口，删掉后集群容器仍在，但只能手工用 Docker 清理。

---

## 2. 卸载前检查

```bash
# 集群里有什么
kubectl get all -A
kubectl get pvc -A
kubectl get ingress -A

# 有没有需要导出的数据
kubectl -n <ns> cp <pod>:/data/backup.tar ./backup.tar

# 确认当前集群名
kubectl config current-context
```

PVC 数据在节点容器的 `/var/lib/rancher/k3s/storage/` 里，`make down` 后无法恢复。需要保留就先把文件 `kubectl cp` 出来。

---

## 3. 默认卸载（保留镜像）

```bash
make uninstall
```

脚本动作：

1. `k3d cluster delete dev`；
2. 清理残留的 registry 容器；
3. 删除 kubeconfig 里的 `k3d-dev` context/cluster/user；
4. 删除 `~/.local/bin/k3d`（如果安装在那里）；
5. 保留 Docker 镜像、Docker 代理配置、`~/.k3d`。

完成后：

```bash
k3d version
# command not found（如果 PATH 里没有别的 k3d）

docker images | grep -E 'rancher/k3s|k3d-io'
# 镜像还在
```

重新安装：

```bash
make install
make up
```

镜像已缓存，`make up` 会很快。

---

## 4. 全量清理（--purge）

```bash
make uninstall ARGS=--purge
```

或：

```bash
bash scripts/uninstall.sh --yes --purge
```

额外动作：

- `docker rmi` 本项目拉取的镜像（`ALL_IMAGES`，当前 14 个）；
- 删除 `images/k3d-base-*.tar` 和 `images/cache/`；
- 删除 `~/.k3d`；
- 删除 Docker 代理 drop-in `/etc/systemd/system/docker.service.d/10-k3d-proxy.conf`（仅当文件里有本项目标记）；
- 删除 `~/.bashrc` 中本项目添加的 PATH 块；
- `systemctl daemon-reload`，必要时重启 Docker。

保留镜像：

```bash
bash scripts/uninstall.sh --yes --purge --keep-images
```

保留代理配置：

```bash
bash scripts/uninstall.sh --yes --purge --keep-proxy
```

> 如果 Docker 代理是你自己手工配的（不是本项目写的 drop-in），脚本不会删；`--purge` 只删除带 `Managed by oceanho-stack-infra` 标记的文件。

---

## 5. 手工兜底清理

如果脚本执行到一半失败，或你以前手工建过集群：

```bash
# 1. 集群
k3d cluster list
k3d cluster delete --all

# 2. 容器
docker ps -a --filter name=k3d
docker rm -f $(docker ps -aq --filter name=k3d) 2>/dev/null || true

# 3. 网络
docker network ls --filter name=k3d
docker network rm $(docker network ls -q --filter name=k3d) 2>/dev/null || true

# 4. 卷（会删除 PVC 数据）
docker volume ls --filter name=k3d
docker volume rm $(docker volume ls -q --filter name=k3d) 2>/dev/null || true

# 5. kubeconfig
kubectl config delete-context k3d-dev 2>/dev/null || true
kubectl config delete-cluster k3d-dev 2>/dev/null || true
kubectl config unset users.admin@k3d-dev 2>/dev/null || true

# 6. 二进制
rm -f ~/.local/bin/k3d
# 从 ~/.bashrc 删除 "# k3d-on-wsl PATH" 相关两行

# 7. 代理配置
sudo rm -f /etc/systemd/system/docker.service.d/10-k3d-proxy.conf
sudo systemctl daemon-reload
```

---

## 6. 卸载后验证

```bash
k3d cluster list                 # 命令不存在或列表为空
docker ps -a --filter name=k3d   # 空
docker network ls | grep k3d     # 空
docker volume ls | grep k3d      # 空
kubectl config get-contexts      # 没有 k3d-dev
ss -lntp | grep -E ':(6443|8080|8443|5000)\b'  # 空
```

如果端口仍被占用，用 `ss -lntp` 找到进程，确认是不是别的服务（Harbor 等）。

---

## 7. 连 Docker 一起卸载？

不建议为了删 k3d 卸载 Docker；机器上可能还有别的容器。确实需要：

```bash
sudo systemctl disable --now docker
sudo apt-get remove --purge -y docker.io containerd
sudo rm -rf /var/lib/docker /var/lib/containerd
```

这会删除**所有** Docker 镜像和容器，包括 Harbor、数据库等，务必确认后再执行。

WSL 发行版本身：

```powershell
wsl --unregister Ubuntu-22.04
```

会删除整个 WSL 文件系统，不可恢复。不要为了卸载 k3d 做这一步。

---

## 8. 卸载后重装

```bash
make install
make images      # 如果 --purge 删了镜像
make up
make test
```

`config/cluster.env.local` 会保留（除非你手动删），代理和端口配置不用重写。
