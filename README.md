# k8s-deploy 使用说明

本项目用于在麒麟 V10（Kylin V10）服务器上，使用离线物料一键部署 Kubernetes 集群。

当前脚本默认部署 Kubernetes `v1.28.15`，支持多 master（高可用控制面）+ worker 节点部署，并内置：

- 100 年有效期集群 CA 与控制面证书自动重签（免手工续期）。
- 私有 registry（内网镜像仓库）部署。
- 外部 SLB 高可用入口支持。
- 部署报告与调试日志自动生成。

## 文件说明

- `download.sh`：下载部署所需离线物料（RPM 包、容器镜像、清单、helm）。
- `k8s_deploy.env`：部署配置文件，所有部署参数只改这个文件。
- `k8s_deploy.sh`：Kubernetes 集群部署、检查、状态查看、重置和卸载脚本。
- `role_and_ip_list.txt`：节点角色与 IP 清单。
- `offline-assets/offline/`：离线安装包、镜像和 manifest 存放目录。
- `offline-assets/k8s-offline-bundle-v1.28.15.tar.gz`：`download.sh` 生成的离线物料打包文件。
- `k8s-cluster-pki/`：集群 CA 保存目录，首次部署生成 100 年 CA 后长期复用（reset/uninstall 不删除）。
- `docs/`：部署报告输出目录（`部署报告_<时间戳>.md`）。
- `logs/`：调试日志输出目录（`debug-log-*.ndjson`）。
- `k8s_deploy.log`：脚本执行主日志，每行带时间戳。

## 部署流程总览

```text
第 1 步  准备节点        节点之间网络互通，执行机可 root SSH 免密登录所有节点
第 2 步  下载离线物料    在能访问外网的机器上执行 ./download.sh
第 3 步  填写配置        修改 k8s_deploy.env 与 role_and_ip_list.txt
第 4 步  检查环境        ./k8s_deploy.sh check
第 5 步  部署集群        ./k8s_deploy.sh
第 6 步  验证集群        ./k8s_deploy.sh status 或 kubectl get nodes
```

## 第 1 步：准备节点与 SSH 免密

1. 准备好麒麟 V10 节点（物理机或 VM）。
2. 在执行机（部署机）上生成 SSH 私钥并分发到所有节点的 root 账户：

```bash
# 私钥路径默认为 /root/.ssh/id_rsa_vm_deploy，可在 k8s_deploy.env 中修改
ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa_vm_deploy -N ''
ssh-copy-id -i /root/.ssh/id_rsa_vm_deploy root@<节点IP>
```

3. 使用 `root` 用户在执行机上运行本项目的脚本。

## 第 2 步：下载离线物料（download）

在能访问外网的机器上（可以在执行机上，也可以下载后拷贝过来）执行：

```bash
cd /data/k8s-deploy_kylinv10
./download.sh
```

常用参数：

```bash
./download.sh --force    # 强制重新下载已存在文件
./download.sh -h         # 查看帮助
```

`download.sh` 会自动完成：

1. 通过 yum/dnf 解析依赖闭包，下载 kubeadm/kubelet/kubectl/containerd 等 RPM 包（含麒麟 V10 运行库兜底包、bind-utils）。
2. 提取 kubeadm 二进制获取精确镜像列表，经 Docker Hub 加速源拉取全部控制面镜像。
3. 下载 flannel 与 Calico 清单及其镜像（Calico 清单中 Pod 网段已自动改为 `10.244.0.0/16`）。
4. 下载 registry、busybox、curl、nginx 等辅助镜像。
5. 下载 helm 二进制。
6. 生成验收用 `tool.yaml` 清单。
7. 生成 `sha256sums.txt` 并全量校验。
8. 打包为 `offline-assets/k8s-offline-bundle-v1.28.15.tar.gz`。

下载完成后物料目录结构：

```text
offline-assets/offline/
├── rpms/        # 全部 RPM 包
├── images/      # 全部镜像 tar + images.txt 清单
├── manifests/   # calico.yaml / kube-flannel.yml / tool.yaml
├── bin/         # helm 二进制
├── bundle-info.txt
├── os-type.txt
└── sha256sums.txt
```

> 下载过程日志记录在 `download.log`。脚本具备断点续传能力：已通过 sha256 校验的文件会自动跳过，重新执行 `./download.sh` 即可继续未完成的下载。

## 第 3 步：填写配置

### 节点清单 role_and_ip_list.txt

格式：第一列角色，第二列 IP，第三列可选填真实主机名。一个机器可以有多个角色，角色用 `/` 或 `,` 分隔。未填写主机名时，脚本会通过 SSH 读取节点真实主机名。

```text
master/worker   192.168.122.38
worker          192.168.122.39
```

多 master 高可用示例：

```text
master        192.168.122.101
master        192.168.122.102
master        192.168.122.103
worker        192.168.122.104
```

### 部署配置 k8s_deploy.env

所有部署参数集中在 `k8s_deploy.env`，脚本启动时读取，不支持命令行参数传部署配置。主要配置项：

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `ROLE_IP_LIST_FILE` | 本目录 `role_and_ip_list.txt` | 节点角色与 IP 清单路径 |
| `REMOTE_DIR` | `/data/k8s_data` | 离线物料在各节点上的存放目录 |
| `OFFLINE_DIR` | 本目录 `offline-assets/offline` | 本地离线物料目录 |
| `SSH_USER` / `SSH_KEY` | `root` / `/root/.ssh/id_rsa_vm_deploy` | SSH 登录用户与私钥 |
| `K8S_VERSION` | `v1.28.15` | 必须与 download.sh 下载的版本一致 |
| `K8S_IMAGE_REPO` | `registry.aliyuncs.com/google_containers` | kubeadm 镜像仓库 |
| `POD_CIDR` / `SERVICE_CIDR` | `10.244.0.0/16` / `10.96.0.0/12` | Pod / Service 网段 |
| `CNI_PLUGIN` | `calico` | CNI 网络插件，可选 `calico` 或 `flannel` |
| `REQUIRE_OFFLINE` | `1` | `1` 离线物料不完整时直接报错；`0` 自动降级为在线安装 |
| `CONTROL_PLANE_ENDPOINT` | 留空 | 留空时按 `SLB_ENDPOINT`、首个 master IP 顺序自动生成 |
| `CLUSTER_CA_DIR` | 本目录 `k8s-cluster-pki` | 集群 CA 保存目录，删除该目录可重建 CA |
| `CERT_VALID_DAYS` | `36500` | 集群证书有效期（100 年），每次 deploy 都会重签 |
| `PRIVATE_REGISTRY` / `REGISTRY_PORT` | `192.168.122.38` / `5000` | 私有镜像仓库；留空表示不启用 |
| `SLB_ENDPOINT` | `192.168.122.100:6443` | 外部 SLB 入口，后端需转发到所有 master 的 6443 |

## 第 4 步：检查环境

部署前先检查执行机依赖、SSH 连通性和离线物料完整性：

```bash
cd /data/k8s-deploy_kylinv10
./k8s_deploy.sh check
```

该命令会检查：

- 执行机依赖命令是否齐全。
- 所有节点是否可通过 SSH 访问。
- 本地离线 RPM/镜像物料是否完整。
- 各节点上的离线物料是否已存在且 sha256 校验通过（未分发过会提示部署时重新分发）。

## 第 5 步：部署集群

执行默认部署：

```bash
cd /data/k8s-deploy_kylinv10
./k8s_deploy.sh
```

等价于 `./k8s_deploy.sh deploy`。如果节点上已有校验通过的物料，可跳过分发：

```bash
./k8s_deploy.sh deploy --skip-distribute
```

部署流程按以下步骤顺序执行：

1. 前置条件检查：校验执行机依赖与 SSH 免密连通性，核验离线物料完整性。
2. 分发离线物料：将 RPM 包、容器镜像与清单分发至全部节点并做 sha256 校验。
3. 安装节点基础组件：安装 containerd/kubelet 等，配置内核参数、导入容器镜像。
4. 配置高可用入口：校验 SLB 入口与各 master apiserver 监听状态。
5. 启动私有 registry：启动节点本地镜像仓库，支撑内网环境镜像分发。
6. 准备集群 CA（100 年）：首次生成后长期复用。
7. 初始化主 master：kubeadm 初始化控制面，安装 CNI 网络插件。
8. 加入其他 master：构成高可用控制面。
9. 加入 worker 节点。
10. 重签证书为 100 年有效期并重启控制面。
11. 标记 worker 节点角色标签。
12. 移除 master 污点，允许业务负载与控制面共存。
13. 等待全部节点 Ready（最长 10 分钟）。
14. 部署验收工具：nginx 验收负载 + network-test 网络 Pod。

部署完成后会输出部署结果清单（版本、控制面入口、CNI、registry、证书有效期、节点/Pod 状态、验收资源），并生成部署报告。

## 第 6 步：验证集群

```bash
cd /data/k8s-deploy_kylinv10
./k8s_deploy.sh status
```

等价于在主 master 上执行：

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

也可以直接登录主 master 操作集群：

```bash
ssh -i /root/.ssh/id_rsa_vm_deploy root@<主master IP>
kubectl get nodes
```

验收资源：集群内会自动部署 `nginx-test` Deployment/Service 与 `network-test` Pod，可用于验证调度与网络连通性：

```bash
kubectl get deploy,svc,pod -l app=nginx-test -o wide
kubectl exec network-test -- curl nginx-test.default.svc.cluster.local
```

## 常用命令汇总

```bash
cd /data/k8s-deploy_kylinv10

# 下载离线物料
./download.sh

# 检查环境
./k8s_deploy.sh check

# 部署集群（默认分发物料）
./k8s_deploy.sh

# 部署集群；跳过物料分发，使用节点现有物料
./k8s_deploy.sh deploy --skip-distribute

# 仅检查外部 SLB 入口连通性
./k8s_deploy.sh ha

# 查看集群状态
./k8s_deploy.sh status

# 重置集群（保留 VM 与离线物料，可重复部署）
./k8s_deploy.sh reset

# 完整卸载：重置集群 + 卸载 k8s/containerd 组件 + 清理远端离线物料
./k8s_deploy.sh uninstall

# 清理残留部署进程（部署中断后使用）
./k8s_deploy.sh -ct
```

## 重置 / 卸载

### 重置集群 reset

部署失败或需要重新部署时执行：

```bash
./k8s_deploy.sh reset
./k8s_deploy.sh
```

`reset` 会在所有节点执行 `kubeadm reset`，清理 `/etc/kubernetes`、`/var/lib/etcd`、CNI 配置、kubeconfig、iptables/ipvs 规则和 `/etc/hosts` 中的节点条目。

`reset` 会保留：

- 节点本身（VM/物理机）与离线物料。
- 已安装的 RPM 包、containerd、kubelet/kubeadm/kubectl。
- 本机集群 CA（`k8s-cluster-pki`），重置后重新部署继续复用同一 CA。

### 卸载 uninstall

`uninstall` 是完整卸载：在 reset 基础上额外停用并删除 kubelet/kubeadm/kubectl/containerd 等 RPM 包、清理节点镜像、`/var/lib/kubelet`、`/etc/containerd`、内核参数配置，并删除各节点 `REMOTE_DIR` 下的远端离线物料。

注意：

- 卸载属于破坏性操作，执行前应确认不再需要该集群。
- 本地 `offline-assets/` 离线物料目录不会被删除，如需可手动清理。
- 本机 CA 目录 `k8s-cluster-pki` 不会被删除；如需彻底重建 CA，手动删除该目录。

## 安装中断与失败处理

脚本具备一定幂等能力：远端物料已存在且校验通过会跳过重新分发；主 master 已初始化会跳过 `kubeadm init`；节点已加入集群会跳过 join。可以直接重新执行部署命令：

```bash
./k8s_deploy.sh
```

但如果中断发生在 `kubeadm init` / `kubeadm join` 的半完成状态，节点上可能残留不完整配置，推荐先重置再部署：

```bash
./k8s_deploy.sh reset
./k8s_deploy.sh
```

如果部署中断后有残留进程（tar 分发、rpm 安装、镜像导入等）导致锁冲突，先清理残留进程：

```bash
./k8s_deploy.sh -ct
```

## 日志与报告

| 文件 | 说明 |
|---|---|
| `k8s_deploy.log` | 部署主日志，每行带时间戳，用于排查部署失败原因 |
| `logs/debug-log-k8s-deploy-failure.ndjson` | 部署失败时的调试事件日志 |
| `logs/debug-log-node-install-failure-<IP>.ndjson` | 各节点安装失败时的远端调试日志 |
| `docs/部署报告_<时间戳>.md` | 每次部署自动生成的部署报告（步骤状态、节点清单、部署结果） |
| `download.log` | download.sh 下载日志 |

## 常见问题

### 下载的物料能拷贝到其他机器使用吗？

可以。将整个 `offline-assets/` 目录拷贝到目标执行机的项目目录下即可，部署时脚本会自动分发到各节点。

### 没有外网时如何部署？

只要 `offline-assets/offline/` 物料完整（`check` 命令可验证），整个部署完全离线。若物料缺失且 `REQUIRE_OFFLINE=0`，脚本会尝试在线安装；生产环境建议保持 `REQUIRE_OFFLINE=1` 强校验。

### 证书有效期如何管理？

集群 CA 首次部署时生成（100 年有效期），保存在 `k8s-cluster-pki/` 并长期复用；每次执行 `deploy` 都会把控制面证书重签为 100 年有效期并重启控制面，无需手工续期。

### 如何启用外部 SLB / F5？

在 `k8s_deploy.env` 中填写 `SLB_ENDPOINT=<VIP>:6443`，SLB 后端需转发到所有 master 的 6443 端口，证书 SAN 会自动包含该地址。可单独执行 `./k8s_deploy.sh ha` 检查 SLB 连通性。
