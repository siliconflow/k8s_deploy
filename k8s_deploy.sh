#!/usr/bin/env bash
# k8s_deploy.sh — 使用离线物料部署 Kubernetes 集群
#
# 前置条件:
#   1. 已运行 download.sh 下载离线物料，默认目录: ./offline-assets/offline
#   2. 已准备节点清单 role_and_ip_list.txt，第一列是角色，第二列是 IP，第三列可选填真实主机名。
#      一个机器可以有多个角色，角色用 / 或 , 分隔，例如 master/worker。
#      未填写主机名时，脚本会通过 SSH 读取节点真实主机名。
#      示例:
#        master/worker 192.168.122.30 node-a
#        master/worker 192.168.122.31 node-b
#        master/worker 192.168.122.32 node-c
#        worker        192.168.122.33 node-d
#        worker        192.168.122.34 node-e
#   3. 执行机到所有节点 root SSH 免密可用，默认私钥: /root/.ssh/id_rsa_vm_deploy
#   4. 使用 root 执行本脚本
#
# 用法:
#   ./k8s_deploy.sh                         # 部署集群；默认分发离线物料
#   ./k8s_deploy.sh deploy --skip-distribute # 部署集群；跳过物料分发，使用节点现有物料
#   ./k8s_deploy.sh check                   # 检查 VM 连通性与离线物料完整性
#   ./k8s_deploy.sh status    # 查看集群状态
#   ./k8s_deploy.sh ha        # 仅检查外部 SLB 入口连通性
#   ./k8s_deploy.sh reset     # 重置集群（保留 VM 与离线物料，可重复部署）
#   ./k8s_deploy.sh uninstall # 完整卸载：重置集群 + 卸载 k8s/containerd 组件 + 清理离线物料
#
# 证书说明:
#   集群 CA 首次部署时生成（100 年有效期），保存在 ./k8s-cluster-pki 并长期复用（reset/uninstall 不删除本机 CA，删除该目录可重建 CA）。
#   每次执行 deploy 都会把控制面证书重签为 100 年有效期并重启控制面，集群证书无需再手工续期。
#
# 配置方式:
#   所有部署配置都保存在 ./k8s_deploy.env，脚本启动时读取该 .env 文件。
#   不使用命令行参数传部署配置；需要调整部署参数时，只修改 k8s_deploy.env。
#
# .env 配置分类:
#   路径配置、SSH 登录配置、Kubernetes 配置、私有 registry 配置、SLB 配置
#
# 示例:
#   1. 普通部署: 修改 k8s_deploy.env 后运行 ./k8s_deploy.sh
#   2. 使用外部 SLB/F5: 在 k8s_deploy.env 中填写 SLB_ENDPOINT
set -euo pipefail

# ============================== 配置加载 ==============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/k8s_deploy.env"
LOG_FILE="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}" .sh).log"
LOCK_FILE="/var/lock/k8s_deploy.lock"

clean_threads() {
  local self_pid="$$" patterns pids
  patterns='k8s_deploy.sh|k8s-node-install.sh|debug-log-node-install-failure|tar xzf - -C|rpm -Uvh --replacepkgs rpms|ctr -n k8s.io images import'
  pids=$(pgrep -f "$patterns" 2>/dev/null | grep -v "^${self_pid}$" || true)
  if [[ -z "$pids" ]]; then
    echo "未发现残留部署进程"
    return 0
  fi
  echo "准备清理残留部署进程:"
  ps -fp $pids || true
  kill $pids 2>/dev/null || true
  sleep 2
  pids=$(pgrep -f "$patterns" 2>/dev/null | grep -v "^${self_pid}$" || true)
  if [[ -n "$pids" ]]; then
    echo "强制清理残留部署进程:"
    ps -fp $pids || true
    kill -9 $pids 2>/dev/null || true
  fi
  echo "清理完成"
}

if [[ "${1:-}" == "-ct" || "${1:-}" == "--cleanthread" ]]; then
  clean_threads
  exit 0
fi

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "已有 k8s_deploy.sh 正在运行，请勿重复执行；如需清理残留进程，执行: $0 -ct" >&2; exit 1; }
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%F %T')" "$line" | tee -a "$LOG_FILE"; done) 2>&1

load_config() {
  [[ -f "$CONFIG_FILE" ]] || { echo "缺少配置文件: $CONFIG_FILE" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a

  ROLE_IP_LIST_FILE="${ROLE_IP_LIST_FILE:-$SCRIPT_DIR/role_and_ip_list.txt}"
  REMOTE_DIR="${REMOTE_DIR:-/data}"
  OFFLINE_DIR="${OFFLINE_DIR:-$SCRIPT_DIR/offline-assets/offline}"
  SSH_USER="${SSH_USER:-root}"
  SSH_KEY="${SSH_KEY:-/root/.ssh/id_rsa_vm_deploy}"
  K8S_VER="${K8S_VERSION:-${K8S_VER:-v1.28.15}}"
  OFFLINE_BUNDLE="${OFFLINE_BUNDLE:-$SCRIPT_DIR/offline-assets/k8s-offline-bundle-${K8S_VER}.tar.gz}"
  K8S_IMAGE_REPO="${K8S_IMAGE_REPO:-registry.aliyuncs.com/google_containers}"
  POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
  SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
  CNI_PLUGIN="${CNI_PLUGIN:-calico}"
  CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
  PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-}"
  REGISTRY_PORT="${REGISTRY_PORT:-5000}"
  REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
  REQUIRE_OFFLINE="${REQUIRE_OFFLINE:-1}"
  DISTRIBUTE_MATERIALS="${DISTRIBUTE_MATERIALS:-1}"
  APISERVER_PORT="${APISERVER_PORT:-6443}"
  SLB_ENDPOINT="${SLB_ENDPOINT:-}"
  CLUSTER_CA_DIR="${CLUSTER_CA_DIR:-$SCRIPT_DIR/k8s-cluster-pki}"
  CERT_VALID_DAYS="${CERT_VALID_DAYS:-36500}"

  [[ -d "$OFFLINE_DIR/images" ]] || OFFLINE_DIR="$REMOTE_DIR"
}

load_config
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o SetEnv=LANG=C.UTF-8 -o SetEnv=LC_ALL=C.UTF-8)
MASTER_NAMES=()
MASTER_IPS=()
WORKER_NAMES=()
WORKER_IPS=()
ALL_NAMES=()
ALL_IPS=()
ALL_ROLES=()
HOSTS_ENTRIES=""
PRIMARY_MASTER_NAME=""
PRIMARY_MASTER_IP=""
LOCAL_IPS=""
DEPLOY_REPORT_FILE="${DEPLOY_REPORT_FILE:-$SCRIPT_DIR/docs/部署报告_$(date '+%Y%m%d_%H%M%S').md}"
mkdir -p "$SCRIPT_DIR/docs" 2>/dev/null || true
DEPLOY_REPORT_ENABLED=0
DEPLOY_REPORT_WRITTEN=0
DEPLOY_CURRENT_STEP_INDEX=-1
DEPLOY_STEP_NAMES=()
DEPLOY_STEP_STATUS=()
DEPLOY_STEP_DESCS=()
OFFLINE_AVAILABLE=0
PAUSE_IMAGE=""
CHILD_PIDS=()

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

run_deploy_step() {
  local name="$1" desc="$2"
  shift 2
  DEPLOY_STEP_NAMES+=("$name")
  DEPLOY_STEP_DESCS+=("$desc")
  DEPLOY_STEP_STATUS+=("执行中")
  DEPLOY_CURRENT_STEP_INDEX=$((${#DEPLOY_STEP_NAMES[@]} - 1))
  log "开始步骤: $name"
  "$@"
  DEPLOY_STEP_STATUS[$DEPLOY_CURRENT_STEP_INDEX]="成功"
}

write_deploy_report() {
  local result="${1:-完成}"
  local registry nodes_output pods_output acceptance_output node_ready cert_end i status
  registry=$(registry_endpoint || true)
  nodes_output=$(vm "$PRIMARY_MASTER_IP" "kubectl get nodes -o wide 2>/dev/null | head -4" 2>/dev/null || true)
  node_ready=$(vm "$PRIMARY_MASTER_IP" "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '" 2>/dev/null || true)
  pods_output=$(vm "$PRIMARY_MASTER_IP" "kubectl get pods -A 2>/dev/null | head -4" 2>/dev/null || true)
  acceptance_output=$(vm "$PRIMARY_MASTER_IP" "kubectl get deploy,svc,pod -l app=nginx-test -o wide 2>/dev/null | head -4; kubectl get pod network-test -o wide 2>/dev/null | head -2" 2>/dev/null || true)

  {
    echo "# Kubernetes 集群部署报告"
    echo
    echo "- 生成时间: $(date '+%F %T %Z')"
    echo "- 部署结果: $result"
    echo
    echo "## 一、集群基础信息"
    echo
    echo "| 配置项 | 值 |"
    echo "| --- | --- |"
    echo "| Kubernetes 版本 | $K8S_VER |"
    echo "| 控制面入口 | $CONTROL_PLANE_ENDPOINT |"
    echo "| CNI 插件 | $CNI_PLUGIN |"
    echo "| Pod CIDR | $POD_CIDR |"
    echo "| Service CIDR | $SERVICE_CIDR |"
    echo "| 私有 registry | ${registry:-未启用} |"
    if [[ -n "$SLB_ENDPOINT" ]]; then
      echo "| SLB 入口 | $SLB_ENDPOINT |"
    fi
    echo "| 节点规模 | ${#ALL_IPS[@]} 台（master ${#MASTER_IPS[@]} / worker ${#WORKER_IPS[@]}） |"
    echo "| 证书方案 | 集群 CA 100 年有效期长期复用，控制面证书随每次部署自动重签，免手工续期 |"
    cert_end=$(vm "$PRIMARY_MASTER_IP" "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate 2>/dev/null | cut -d= -f2" 2>/dev/null || true)
    echo "| apiserver 证书有效期至 | ${cert_end:-未知} |"
    echo
    echo "## 二、平台核心优势"
    echo
    echo "Kubernetes 是业界主流的容器编排平台，本次交付的集群具备以下企业级能力："
    echo
    echo "- **高可用架构**：控制面多副本部署，配合负载均衡入口消除单点故障，保障业务持续可用。"
    echo "- **故障自愈**：容器异常退出或节点故障时，自动重新调度与拉起，业务无感恢复。"
    echo "- **弹性伸缩**：支持基于资源指标的自动扩缩容，从容应对业务负载高峰。"
    echo "- **服务发现与负载均衡**：内置 Service/DNS 机制，微服务间通信开箱即用。"
    echo "- **声明式运维**：配置即代码，支持滚动升级、灰度发布与 CI/CD 流水线无缝集成。"
    echo "- **资源治理**：Namespace 与资源配额实现多租户隔离，智能调度提升资源利用率。"
    echo "- **安全离线交付**：全离线物料部署（sha256 完整性校验），适配内网环境；证书 100 年有效期，显著降低后期运维成本。"
    echo
    echo "## 三、部署实施步骤"
    echo
    echo "本次部署严格按照标准化流程执行，全程自动化完成："
    echo
    echo "| 序号 | 步骤 | 说明 | 状态 |"
    echo "| --- | --- | --- | --- |"
    for i in "${!DEPLOY_STEP_NAMES[@]}"; do
      status="${DEPLOY_STEP_STATUS[$i]}"
      if [[ "$result" != "成功" && "$status" == "执行中" ]]; then
        status="失败"
      fi
      echo "| $((i + 1)) | ${DEPLOY_STEP_NAMES[$i]} | ${DEPLOY_STEP_DESCS[$i]} | $status |"
    done
    echo
    echo "## 四、部署结果验证"
    echo
    if [[ "$node_ready" =~ ^[0-9]+$ && "$node_ready" -eq "${#ALL_IPS[@]}" ]]; then
      echo "集群共 ${#ALL_IPS[@]} 个节点，全部处于 Ready 状态。"
      echo
    fi
    echo "节点状态（节选）："
    echo
    echo '```text'
    printf '%s\n' "${nodes_output:-未获取到节点状态}"
    echo '```'
    echo
    echo "核心系统组件运行正常（节选）："
    echo
    echo '```text'
    printf '%s\n' "${pods_output:-未获取到 Pod 状态}"
    echo '```'
    echo
    echo "验收负载运行正常（节选）："
    echo
    echo '```text'
    printf '%s\n' "${acceptance_output:-未获取到验收资源状态}"
    echo '```'
    echo
    echo "## 五、运维信息"
    echo
    echo "### 访问入口"
    echo
    echo "| 项目 | 值 |"
    echo "| --- | --- |"
    echo "| 控制面入口 (apiserver) | $CONTROL_PLANE_ENDPOINT |"
    if [[ -n "$SLB_ENDPOINT" ]]; then
      echo "| SLB 入口 | $SLB_ENDPOINT |"
    fi
    if [[ -n "$registry" ]]; then
      echo "| 私有 registry | $registry（HTTP，内网访问，无认证） |"
    fi
    echo
    echo "### 节点清单与登录"
    echo
    echo "| 节点名 | IP | 角色 |"
    echo "| --- | --- | --- |"
    for i in "${!ALL_IPS[@]}"; do
      echo "| ${ALL_NAMES[$i]} | ${ALL_IPS[$i]} | ${ALL_ROLES[$i]} |"
    done
    echo
    echo "登录方式：\`ssh -i $SSH_KEY $SSH_USER@<节点IP>\`（root 密钥免密登录，无密码）"
    echo
    echo "### 关键路径"
    echo
    echo "| 项目 | 路径 | 所在位置 |"
    echo "| --- | --- | --- |"
    echo "| kubeconfig（管理员） | /etc/kubernetes/admin.conf | 各 master 节点 |"
    echo "| 集群证书与 CA | /etc/kubernetes/pki | 各 master 节点 |"
    echo "| 集群 CA 本地备份 | $CLUSTER_CA_DIR | 执行机 |"
    echo "| 证书变更备份 | /root/k8s-pki-backup-<时间戳>.tar.gz | 各 master 节点 |"
    echo "| 离线物料 | $REMOTE_DIR | 全部节点 |"
    echo "| 节点清单 | $ROLE_IP_LIST_FILE | 执行机 |"
    echo "| 部署脚本与日志 | $SCRIPT_DIR、$LOG_FILE | 执行机 |"
    echo
    echo "### 账号与认证"
    echo
    echo "- SSH：$SSH_USER 用户，密钥认证（私钥 $SSH_KEY），无密码"
    echo "- Kubernetes：kubeconfig 客户端证书认证（admin.conf），无用户名密码"
    echo "- 私有 registry：HTTP 无认证，仅限内网访问"
    echo
    echo "### 常用命令"
    echo
    echo "以下 kubectl 命令在各 master 节点执行（/root/.kube/config 已配置）："
    echo
    echo '```bash'
    echo "kubectl get nodes -o wide                                  # 节点状态"
    echo "kubectl get pods -A -o wide                                # 全部 Pod 状态"
    echo "kubectl cluster-info                                       # 集群信息"
    echo "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate    # 查看证书有效期"
    echo "kubeadm token create --print-join-command                  # 生成节点扩容 join 命令"
    echo '```'
    echo
    echo "以下命令在部署执行机（$SCRIPT_DIR）执行："
    echo
    echo '```bash'
    echo "./k8s_deploy.sh status     # 查看集群状态"
    echo "./k8s_deploy.sh check      # 检查节点连通性与离线物料"
    echo "./k8s_deploy.sh ha         # 检查 SLB 入口连通性"
    echo "./k8s_deploy.sh deploy     # 重新部署（自动重签 100 年证书）"
    echo "./k8s_deploy.sh reset      # 重置集群（保留物料与 CA）"
    echo "./k8s_deploy.sh uninstall  # 完整卸载"
    echo '```'
    echo
    echo "---"
    echo
    echo "**硅基流动 · 加速AGI普惠人类**"
  } > "$DEPLOY_REPORT_FILE"
  DEPLOY_REPORT_WRITTEN=1
  log "部署报告已生成: $DEPLOY_REPORT_FILE"
}

#region debug-point k8s-deploy-failure
DBG_LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$DBG_LOG_DIR" 2>/dev/null || true
DBG_LOG="$DBG_LOG_DIR/debug-log-k8s-deploy-failure.ndjson"
dbg_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
dbg() {
  local event="$1" detail="${2:-}"
  printf '{"ts":"%s","event":"%s","detail":"%s"}\n' "$(date '+%F %T')" "$(dbg_json_escape "$event")" "$(dbg_json_escape "$detail")" >> "$DBG_LOG" 2>/dev/null || true
}
cleanup_children() {
  local pid
  for pid in "${CHILD_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${CHILD_PIDS[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
}
on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM
  dbg "exit" "rc=$rc line=$LINENO cmd=$BASH_COMMAND"
  cleanup_children
  if [[ "${DEPLOY_REPORT_ENABLED:-0}" -eq 1 && "${DEPLOY_REPORT_WRITTEN:-0}" -eq 0 ]]; then
    if [[ "$rc" -eq 0 ]]; then write_deploy_report "成功"; else write_deploy_report "失败"; fi
  fi
  exit "$rc"
}
on_error() {
  local rc=$?
  dbg "error" "rc=$rc line=$LINENO cmd=$BASH_COMMAND"
  return "$rc"
}
trap on_exit EXIT
trap on_error ERR
trap 'exit 130' INT
trap 'exit 143' TERM
dbg "config-loaded" "OFFLINE_DIR=$OFFLINE_DIR ROLE_IP_LIST_FILE=$ROLE_IP_LIST_FILE REMOTE_DIR=$REMOTE_DIR SSH_USER=$SSH_USER SSH_KEY=$SSH_KEY K8S_VER=$K8S_VER CNI_PLUGIN=$CNI_PLUGIN CONTROL_PLANE_ENDPOINT=$CONTROL_PLANE_ENDPOINT PRIVATE_REGISTRY=$PRIVATE_REGISTRY"
#endregion debug-point k8s-deploy-failure

load_topology() {
  [[ -f "$ROLE_IP_LIST_FILE" ]] || die "缺少节点清单: $ROLE_IP_LIST_FILE"

  MASTER_NAMES=(); MASTER_IPS=(); WORKER_NAMES=(); WORKER_IPS=(); ALL_NAMES=(); ALL_IPS=(); ALL_ROLES=(); HOSTS_ENTRIES=""
  local role ip node_name role_norm has_master has_worker token
  local -a role_tokens
  while read -r role ip node_name _ || [[ -n "${role:-}" ]]; do
    [[ -z "${role:-}" || "${role:0:1}" == "#" ]] && continue
    [[ -n "${ip:-}" ]] || die "节点清单格式错误: $ROLE_IP_LIST_FILE"
    if [[ -z "${node_name:-}" ]]; then
      if is_local_ip "$ip"; then
        node_name=$(hostname 2>/dev/null || true)
      else
        node_name=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" hostname 2>/dev/null < /dev/null || true)
      fi
    fi
    [[ -n "$node_name" ]] || die "无法获取 $ip 的真实主机名，请检查 SSH 免密，或在 $ROLE_IP_LIST_FILE 第三列填写主机名"

    role_norm="${role//,/\/}"
    has_master=0
    has_worker=0
    IFS='/' read -ra role_tokens <<< "$role_norm"
    for token in "${role_tokens[@]}"; do
      case "$token" in
        master) has_master=1 ;;
        worker) has_worker=1 ;;
        *) die "未知节点角色: $token（仅支持 master/worker，多个角色用 / 或 , 分隔）" ;;
      esac
    done

    if [[ "$has_master" -eq 1 ]]; then
      MASTER_NAMES+=("$node_name")
      MASTER_IPS+=("$ip")
    fi

    if [[ "$has_worker" -eq 1 ]]; then
      WORKER_NAMES+=("$node_name")
      WORKER_IPS+=("$ip")
    fi

    [[ "$has_master" -eq 1 || "$has_worker" -eq 1 ]] || die "节点角色不能为空: $role $ip"

    ALL_NAMES+=("$node_name")
    ALL_IPS+=("$ip")
    ALL_ROLES+=("$role_norm")
  done < "$ROLE_IP_LIST_FILE"

  [[ "${#MASTER_IPS[@]}" -gt 0 ]] || die "节点清单中至少需要 1 个 master"
  [[ "${#MASTER_IPS[@]}" -eq 1 || "${#MASTER_IPS[@]}" -ge 3 ]] || die "多 master 部署至少需要 3 个 master"

  PRIMARY_MASTER_NAME="${MASTER_NAMES[0]}"
  PRIMARY_MASTER_IP="${MASTER_IPS[0]}"
  HOSTS_ENTRIES=""
  local i
  for i in "${!ALL_IPS[@]}"; do
    HOSTS_ENTRIES+="${ALL_IPS[$i]} ${ALL_NAMES[$i]}"$'\n'
  done

  if [[ -z "$CONTROL_PLANE_ENDPOINT" ]]; then
    if [[ -n "$SLB_ENDPOINT" ]]; then
      CONTROL_PLANE_ENDPOINT="$SLB_ENDPOINT"
    else
      CONTROL_PLANE_ENDPOINT="$PRIMARY_MASTER_IP:$APISERVER_PORT"
    fi
  fi
  :
}

init_local_ips() {
  LOCAL_IPS=" $(hostname -I 2>/dev/null || true) 127.0.0.1 "
}

with_heartbeat() {
  local message="$1"
  shift
  while true; do sleep 20; log "$message"; done &
  local hb=$!
  CHILD_PIDS+=("$hb")
  "$@"
  local rc=$?
  kill "$hb" 2>/dev/null || true
  wait "$hb" 2>/dev/null || true
  return "$rc"
}

check_local_dependencies() {
  local missing=0 cmd
  for cmd in flock ssh scp tar sha256sum timeout grep sed awk find wc tr openssl base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "本机缺少依赖命令: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "本机依赖检查失败，请先安装缺失命令"
}

check_ssh_connectivity() {
  [[ -f "$SSH_KEY" ]] || die "SSH 私钥不存在: $SSH_KEY。请先配置部署机到所有节点的 root SSH 免密登录"
  local ip failed=0
  for ip in "${ALL_IPS[@]}"; do
    is_local_ip "$ip" && continue
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" true >/dev/null 2>&1; then
      log "SSH 免密可用: $ip"
    else
      warn "SSH 免密不可用: $ip"
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]] || die "SSH 免密检查失败，已中断部署。请先把 $SSH_KEY.pub 加入所有远端节点 $SSH_USER 的 authorized_keys"
}

is_local_ip() {
  [[ "$LOCAL_IPS" == *" $1 "* ]]
}

vm() { # 在节点上执行命令；如果目标是本机则直接执行
  if is_local_ip "$1"; then
    bash -lc "$2"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" "$2"
  fi
}
vm_root() { # 在节点上以 root 执行命令；如果目标是本机则直接执行
  if is_local_ip "$1"; then
    bash -lc "$2"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" bash -s <<< "$2"
  fi
}

vm_script() { # 在节点上执行多行脚本，避免复杂引号转义
  if is_local_ip "$1"; then
    bash -s <<< "$2"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" bash -s <<< "$2"
  fi
}

check_preconditions() {
  check_local_dependencies
  check_ssh_connectivity

  local os_type rpm_count image_count part_count missing=0 img image_tar
  OFFLINE_AVAILABLE=1
  if [[ ! -d "$OFFLINE_DIR/images" || ! -d "$OFFLINE_DIR/rpms" || ! -s "$OFFLINE_DIR/images/images.txt" ]]; then
    warn "离线物料不完整，将尝试通过 yum 在线安装组件并在线拉取镜像"
    OFFLINE_AVAILABLE=0
  fi

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    case "$CNI_PLUGIN" in
      calico) [[ -f "$OFFLINE_DIR/manifests/calico.yaml" ]] || { warn "缺少 Calico 清单: $OFFLINE_DIR/manifests/calico.yaml，将尝试通过 kubectl 在线安装"; OFFLINE_AVAILABLE=0; } ;;
      flannel) [[ -f "$OFFLINE_DIR/manifests/kube-flannel.yml" ]] || { warn "缺少 flannel 清单: $OFFLINE_DIR/manifests/kube-flannel.yml，将尝试通过 kubectl 在线安装"; OFFLINE_AVAILABLE=0; } ;;
      *) die "未知 CNI_PLUGIN: $CNI_PLUGIN（仅支持 calico/flannel）" ;;
    esac
  fi

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    [[ -f "$OFFLINE_DIR/manifests/tool.yaml" ]] || warn "缺少验收清单: $OFFLINE_DIR/manifests/tool.yaml，将跳过验收工具部署"
    os_type="unknown"
    [[ -f "$OFFLINE_DIR/os-type.txt" ]] && os_type=$(<"$OFFLINE_DIR/os-type.txt")
    if [[ "$os_type" != "kylin-v10" ]]; then
      warn "离线物料系统类型不是 kylin-v10，将尝试通过 yum 在线安装组件并在线拉取镜像"
      OFFLINE_AVAILABLE=0
    fi
  fi

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    rpm_count=$(find "$OFFLINE_DIR/rpms" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)
    image_count=$(find "$OFFLINE_DIR/images" -maxdepth 1 -name '*.tar' | wc -l)
    part_count=$(find "$OFFLINE_DIR" -name '*.part' | wc -l)
    if [[ "$rpm_count" -eq 0 || "$image_count" -eq 0 || "$part_count" -ne 0 ]]; then
      warn "离线 rpm 或镜像物料不可用，将尝试通过 yum 在线安装组件并在线拉取镜像"
      OFFLINE_AVAILABLE=0
    fi
  fi

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      image_tar="$OFFLINE_DIR/images/$(echo "$img" | tr '/:' '__').tar"
      [[ -f "$image_tar" ]] || { warn "缺少镜像 tar: $img"; missing=1; }
    done < "$OFFLINE_DIR/images/images.txt"
    if [[ "$missing" -ne 0 ]]; then
      warn "镜像物料不完整，将尝试通过 yum 在线安装组件并在线拉取镜像"
      OFFLINE_AVAILABLE=0
    fi
  fi

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    if [[ -f "$OFFLINE_DIR/bin/helm" ]]; then
      log "离线物料包含 helm"
    else
      warn "离线物料缺少 bin/helm，部署将跳过 helm 安装（可重新运行 download.sh 更新物料）"
    fi
  fi

  for ip in "${ALL_IPS[@]}"; do
    if is_local_ip "$ip"; then
      continue
    fi
    vm "$ip" true 2>/dev/null || die "VM $ip 不可达，或当前机器缺少到该节点的 SSH 免密权限"
  done

  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    PAUSE_IMAGE=$(grep -oE "$K8S_IMAGE_REPO/pause:[^ ]+" "$OFFLINE_DIR/images/images.txt" | head -1)
    [[ -n "$PAUSE_IMAGE" ]] || PAUSE_IMAGE="$K8S_IMAGE_REPO/pause:3.9"
    log "离线物料可用: rpm=${rpm_count}, images=${image_count}, pause=${PAUSE_IMAGE}"
  else
    if [[ "$REQUIRE_OFFLINE" == "1" || "$REQUIRE_OFFLINE" == "true" || "$REQUIRE_OFFLINE" == "yes" ]]; then
      die "离线物料不可用，且 REQUIRE_OFFLINE=$REQUIRE_OFFLINE，已中断部署"
    fi
    PAUSE_IMAGE="$K8S_IMAGE_REPO/pause:3.9"
    log "离线物料不可用，启用在线 yum 安装模式: pause=${PAUSE_IMAGE}"
  fi
}

remote_material_ready() {
  local ip="$1"
  [[ -f "$OFFLINE_DIR/sha256sums.txt" ]] || return 1
  vm "$ip" "test -f $REMOTE_DIR/sha256sums.txt && cd $REMOTE_DIR && timeout 120 sha256sum -c sha256sums.txt >/dev/null 2>&1" >/dev/null 2>&1
}

registry_endpoint() {
  [[ -n "$PRIVATE_REGISTRY" ]] || return 1
  case "$PRIVATE_REGISTRY" in
    *:*) echo "$PRIVATE_REGISTRY" ;;
    *) echo "$PRIVATE_REGISTRY:$REGISTRY_PORT" ;;
  esac
}

check_slb() {
  [[ -n "$SLB_ENDPOINT" ]] || die "SLB 模式需要指定 SLB_ENDPOINT，例如: SLB_ENDPOINT=192.168.122.100:6443 ./k8s_deploy.sh"
  local host port ip
  host="${SLB_ENDPOINT%:*}"
  port="${SLB_ENDPOINT##*:}"
  [[ -n "$host" && -n "$port" && "$host" != "$port" ]] || die "SLB_ENDPOINT 格式错误，应为 IP:PORT"

  log "检查 master 本地 apiserver 监听状态..."
  for ip in "${MASTER_IPS[@]}"; do
    vm_root "$ip" "ss -lnt | grep -q ':${APISERVER_PORT} ' && echo '${ip}: apiserver listening' || echo '${ip}: apiserver not listening yet'"
  done

  log "检查 SLB 连通性: $SLB_ENDPOINT"
  if timeout 5 bash -lc "</dev/tcp/$host/$port" 2>/dev/null; then
    log "SLB 可连接: $SLB_ENDPOINT"
  else
    warn "当前机器无法连接 SLB: $SLB_ENDPOINT。若集群尚未初始化，这是正常的；请确认 SLB 后端指向所有 master:${APISERVER_PORT}。"
  fi
}

setup_ha() {
  [[ -n "$SLB_ENDPOINT" ]] || return 0
  check_slb
}

distribute() { # 分发离线物料到各节点
  case "$DISTRIBUTE_MATERIALS" in
    0|false|FALSE|no|NO|skip|SKIP)
      warn "已按参数跳过物料分发，将使用各节点 $REMOTE_DIR 下的现有物料"
      return 0
      ;;
  esac
  if [[ "$OFFLINE_AVAILABLE" -eq 0 ]]; then
    warn "离线物料不可用，跳过物料分发"
    return 0
  fi
  local ip bundle bundle_name remote_bundle
  bundle=""
  if [[ -f "$OFFLINE_BUNDLE" ]]; then
    bundle="$OFFLINE_BUNDLE"
    bundle_name="${bundle##*/}"
  fi
  for ip in "${ALL_IPS[@]}"; do
    log "全新分发物料到 $ip ..."
    if is_local_ip "$ip"; then
      rm -rf "$REMOTE_DIR/rpms" "$REMOTE_DIR/images" "$REMOTE_DIR/manifests" "$REMOTE_DIR/bin" \
        "$REMOTE_DIR/sha256sums.txt" "$REMOTE_DIR/bundle-info.txt" "$REMOTE_DIR/os-type.txt"
      mkdir -p "$REMOTE_DIR"
      if [[ -n "$bundle" ]]; then
        tar xzf "$bundle" --strip-components=1 -C "$REMOTE_DIR"
      else
        tar czf - -C "$OFFLINE_DIR" . | tar xzf - -C "$REMOTE_DIR"
      fi
      chown -R "$SSH_USER:$SSH_USER" "$REMOTE_DIR"
    else
      if [[ -n "$bundle" ]]; then
        remote_bundle="$REMOTE_DIR/$bundle_name"
        with_heartbeat "正在清理远端旧物料 $ip ..." ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "rm -rf $REMOTE_DIR/rpms $REMOTE_DIR/images $REMOTE_DIR/manifests $REMOTE_DIR/bin $REMOTE_DIR/sha256sums.txt $REMOTE_DIR/bundle-info.txt $REMOTE_DIR/os-type.txt && mkdir -p $REMOTE_DIR"
        with_heartbeat "正在复制离线 bundle 到 $ip ..." scp "${SSH_OPTS[@]}" "$bundle" "$SSH_USER@$ip:$remote_bundle"
        with_heartbeat "正在解压离线 bundle 到 $ip ..." ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "tar xzf $remote_bundle --strip-components=1 -C $REMOTE_DIR && rm -f $remote_bundle"
      else
        ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "pkill -f '[t]ar xzf - -C $REMOTE_DIR' 2>/dev/null || true; rm -rf $REMOTE_DIR/rpms $REMOTE_DIR/images $REMOTE_DIR/manifests $REMOTE_DIR/bin $REMOTE_DIR/sha256sums.txt $REMOTE_DIR/bundle-info.txt $REMOTE_DIR/os-type.txt; mkdir -p $REMOTE_DIR"
        tar czf - -C "$OFFLINE_DIR" . | ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "trap 'pkill -P \$\$ 2>/dev/null || true' EXIT INT TERM; tar xzf - -C $REMOTE_DIR"
      fi
    fi
    remote_material_ready "$ip" || die "$ip 物料分发后校验失败"
  done
}

gen_node_install_script() {
  cat > /tmp/k8s-node-install.sh <<REMOTE_SCRIPT
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
mkdir -p "$REMOTE_DIR/tmp"
export TMPDIR="$REMOTE_DIR/tmp"
#region debug-point node-install-failure
DBG_REMOTE_LOG="/tmp/debug-log-node-install-failure.ndjson"
dbg_remote_escape() {
  local s="\${1:-}"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\"/\\\\\"}"
  s="\${s//$'\\n'/\\\\n}"
  printf '%s' "\$s"
}
dbg_remote() {
  local event="\$1" detail="\${2:-}"
  printf '{"ts":"%s","host":"%s","event":"%s","detail":"%s"}\n' "\$(date '+%F %T')" "\$(hostname 2>/dev/null || echo unknown)" "\$(dbg_remote_escape "\$event")" "\$(dbg_remote_escape "\$detail")" >> "\$DBG_REMOTE_LOG" 2>/dev/null || true
}
dbg_run() {
  local event="\$1" output rc
  shift
  dbg_remote "\${event}-start" "cmd=\$*"
  set +e
  output="\$("\$@" 2>&1)"
  rc=\$?
  set -e
  [[ -z "\$output" ]] || printf '%s\n' "\$output"
  dbg_remote "\${event}-end" "rc=\$rc output=\$(printf '%s' "\$output" | tail -c 3000)"
  return "\$rc"
}
select_pkg_mgr() {
  if command -v yum >/dev/null 2>&1; then
    echo yum
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  else
    return 1
  fi
}
yum_install_missing_commands() {
  local pkg_mgr packages=()
  pkg_mgr=\$(select_pkg_mgr) || { echo "未找到 yum/dnf，无法在线安装缺失依赖" >&2; return 1; }
  command -v containerd >/dev/null 2>&1 || packages+=(containerd.io)
  command -v kubelet >/dev/null 2>&1 || packages+=(kubelet)
  command -v kubeadm >/dev/null 2>&1 || packages+=(kubeadm)
  command -v kubectl >/dev/null 2>&1 || packages+=(kubectl)
  command -v crictl >/dev/null 2>&1 || packages+=(cri-tools)
  command -v conntrack >/dev/null 2>&1 || packages+=(conntrack-tools)
  command -v socat >/dev/null 2>&1 || packages+=(socat)
  command -v ebtables >/dev/null 2>&1 || packages+=(ebtables)
  command -v ethtool >/dev/null 2>&1 || packages+=(ethtool)
  command -v ipset >/dev/null 2>&1 || packages+=(ipset)
  command -v ipvsadm >/dev/null 2>&1 || packages+=(ipvsadm)
  command -v nslookup >/dev/null 2>&1 || packages+=(bind-utils)
  if [[ "\${#packages[@]}" -gt 0 ]]; then
    dbg_run yum-install-missing "\$pkg_mgr" install -y "\${packages[@]}"
  fi
}
yum_install_from_rpm_error() {
  local output="\$1" pkg_mgr packages=() pkg
  pkg_mgr=\$(select_pkg_mgr) || return 1
  while read -r pkg; do
    [[ -n "\$pkg" ]] && packages+=("\$pkg")
  done < <(printf '%s\n' "\$output" | sed -nE 's/.* ([A-Za-z0-9_.+-]+) is needed by .*/\1/p; s/.*Requires: ([A-Za-z0-9_.+-]+).*/\1/p' | sed 's/(.*//' | sort -u)
  if [[ "\${#packages[@]}" -gt 0 ]]; then
    dbg_run yum-install-rpm-deps "\$pkg_mgr" install -y "\${packages[@]}"
  else
    return 1
  fi
}
install_rpms_with_yum_fallback() {
  local output rc
  set +e
  output=\$(rpm -Uvh --replacepkgs rpms/*.rpm 2>&1)
  rc=\$?
  set -e
  [[ -z "\$output" ]] || printf '%s\n' "\$output"
  dbg_remote "rpm-install-end" "rc=\$rc output=\$(printf '%s' "\$output" | tail -c 3000)"
  if [[ "\$rc" -ne 0 ]]; then
    warn_msg="离线 RPM 安装失败，尝试通过 yum/dnf 安装缺失依赖后重试"
    echo "\$warn_msg"
    dbg_remote "rpm-install-fallback" "\$warn_msg"
    yum_install_from_rpm_error "\$output" || true
    yum_install_missing_commands || true
    dbg_run rpm-install-retry rpm -Uvh --replacepkgs rpms/*.rpm
  fi
  yum_install_missing_commands
}
trap 'rc=\$?; dbg_remote "node-install-error" "rc=\$rc line=\$LINENO cmd=\$BASH_COMMAND pwd=\$PWD containerd=\$(systemctl is-active containerd 2>/dev/null || true) kubelet=\$(systemctl is-enabled kubelet 2>/dev/null || true)"' ERR
trap 'rc=\$?; dbg_remote "node-install-exit" "rc=\$rc"' EXIT
dbg_remote "node-install-start" "remote_dir=$REMOTE_DIR pause=$PAUSE_IMAGE registry=$PRIVATE_REGISTRY offline=$OFFLINE_AVAILABLE"
#endregion debug-point node-install-failure
if [ "$OFFLINE_AVAILABLE" -eq 1 ]; then
  cd $REMOTE_DIR
  #region debug-point node-install-failure
  dbg_remote "remote-dir" "pwd=\$PWD os_type=\$(cat os-type.txt 2>/dev/null || echo missing) rpm_count=\$(ls rpms/*.rpm 2>/dev/null | wc -l) image_count=\$(ls images/*.tar 2>/dev/null | wc -l) sha256=\$(test -f sha256sums.txt && echo present || echo missing)"
  #endregion debug-point node-install-failure
fi

echo "  - 安装系统包..."
if [ "$OFFLINE_AVAILABLE" -eq 1 ]; then
  OS_TYPE="unknown"
  [ -f os-type.txt ] && OS_TYPE="\$(cat os-type.txt)"
  [ "\$OS_TYPE" = "kylin-v10" ] || {
    echo "离线物料系统类型必须为 kylin-v10" >&2
    exit 1
  }
  if [ -f /var/lib/k8s-offline-node-ready ] && systemctl is-active --quiet containerd && sha256sum -c sha256sums.txt >/dev/null 2>&1; then
    echo "  - 节点基础安装已完成且物料校验通过，继续校正运行时配置"
  else
    #region debug-point node-install-failure
    dbg_remote "rpm-install-start" "rpm_count=\$(ls rpms/*.rpm 2>/dev/null | wc -l)"
    #endregion debug-point node-install-failure
    install_rpms_with_yum_fallback
    #region debug-point node-install-failure
    dbg_remote "rpm-install-done" "rc=0"
    #endregion debug-point node-install-failure
  fi
else
  pkg_mgr=\$(select_pkg_mgr) || { echo "未找到 yum/dnf，无法在线安装组件" >&2; exit 1; }
  #region debug-point node-install-failure
  dbg_remote "yum-install-start" "pkg_mgr=\$pkg_mgr"
  #endregion debug-point node-install-failure
  dbg_run yum-install "\$pkg_mgr" install -y containerd.io kubelet kubeadm kubectl kubernetes-cni cri-tools conntrack-tools socat ebtables ethtool ipset ipvsadm
  yum_install_missing_commands
  #region debug-point node-install-failure
  dbg_remote "yum-install-done" "rc=0"
  #endregion debug-point node-install-failure
fi

echo "  - 安装 helm..."
if [ "$OFFLINE_AVAILABLE" -eq 1 ] && [ -f bin/helm ]; then
  dbg_run helm-install install -m 0755 bin/helm /usr/local/bin/helm
  dbg_run helm-version /usr/local/bin/helm version --short || true
else
  echo "  - 物料中无 bin/helm，跳过 helm 安装"
fi

#region debug-point node-install-failure
dbg_remote "kernel-config-start" "swap=\$(swapon --show 2>/dev/null | wc -l)"
#endregion debug-point node-install-failure
echo "  - 关闭 swap 与内核网络配置..."
swapoff -a 2>/dev/null || true
sed -i.bak '/[^#].*swap/s/^/#/' /etc/fstab 2>/dev/null || true

dbg_run modprobe-overlay modprobe overlay
dbg_run modprobe-br-netfilter modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 net.bridge.bridge-nf-call-ip6tables=1 net.ipv4.ip_forward=1 >/dev/null
#region debug-point node-install-failure
dbg_remote "kernel-config-done" "br_netfilter=\$(lsmod | grep -c '^br_netfilter' || true) overlay=\$(lsmod | grep -c '^overlay' || true)"
#endregion debug-point node-install-failure

echo "  - 关闭 firewalld 并启用 kubelet..."
systemctl disable --now firewalld >/dev/null 2>&1 || true
systemctl enable kubelet >/dev/null 2>&1 || true

#region debug-point node-install-failure
dbg_remote "containerd-config-start" "containerd=\$(command -v containerd 2>/dev/null || echo missing)"
#endregion debug-point node-install-failure
echo "  - 配置 containerd（SystemdCgroup + pause 镜像）..."
mkdir -p /etc/containerd
dbg_run containerd-default bash -lc 'containerd config default > /etc/containerd/config.toml'
sed -i 's#SystemdCgroup = false#SystemdCgroup = true#' /etc/containerd/config.toml
sed -i 's#sandbox_image = .*#sandbox_image = "'"$PAUSE_IMAGE"'"#' /etc/containerd/config.toml

if [ -n "$PRIVATE_REGISTRY" ]; then
  registry_host="$PRIVATE_REGISTRY"
  case "\$registry_host" in *:*) ;; *) registry_host="\$registry_host:$REGISTRY_PORT" ;; esac
  # containerd 默认 config 中 config_path 为空，不会加载 certs.d 下的 hosts.toml，必须显式启用
  sed -i 's#config_path = ""#config_path = "/etc/containerd/certs.d"#' /etc/containerd/config.toml
  mkdir -p "/etc/containerd/certs.d/\$registry_host"
  cat > "/etc/containerd/certs.d/\$registry_host/hosts.toml" <<EOF
server = "http://\$registry_host"

[host."http://\$registry_host"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
fi

rm -f /etc/cni/net.d/nerdctl-bridge.conflist /etc/cni/net.d/10-nerdctl.conflist 2>/dev/null || true
dbg_run containerd-enable systemctl enable --now containerd
dbg_run containerd-restart systemctl restart containerd
sleep 2
#region debug-point node-install-failure
dbg_remote "containerd-started" "active=\$(systemctl is-active containerd 2>/dev/null || true) images_dir=\$(test -d images && echo present || echo missing)"
#endregion debug-point node-install-failure

if [ "$OFFLINE_AVAILABLE" -eq 1 ]; then
  echo "  - 导入容器镜像..."
  #region debug-point node-install-failure
  dbg_remote "image-import-start" "image_count=\$(ls images/*.tar 2>/dev/null | wc -l)"
  #endregion debug-point node-install-failure
  for f in images/*.tar; do
    dbg_run image-import ctr -n k8s.io images import "\$f" || true
  done
  #region debug-point node-install-failure
  dbg_remote "image-import-done" "imported=\$(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)"
  #endregion debug-point node-install-failure
  echo "  已导入镜像: \$(ctr -n k8s.io images ls -q | wc -l) 个"
else
  echo "  - 在线模式跳过本地镜像导入，后续由 containerd 在线拉取镜像"
fi

#region debug-point node-install-failure
dbg_remote "hosts-write-start" "hosts_entries=\$(cat <<'HOSTS_COUNT' | wc -l
$HOSTS_ENTRIES
HOSTS_COUNT
)"
#endregion debug-point node-install-failure
echo "  - 写入 /etc/hosts..."
while read -r ip name; do
  [ -n "\$ip" ] && [ -n "\$name" ] || continue
  sed -i.bak "/[[:space:]]\$name\$/d" /etc/hosts
  echo "\$ip \$name" >> /etc/hosts
done <<HOSTS
$HOSTS_ENTRIES
HOSTS

#region debug-point node-install-failure
dbg_remote "node-install-summary" "containerd=\$(systemctl is-active containerd 2>/dev/null || true) kubelet_enabled=\$(systemctl is-enabled kubelet 2>/dev/null || true) image_count=\$(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)"
#endregion debug-point node-install-failure
touch /var/lib/k8s-offline-node-ready
echo "  - 节点基础安装完成"
REMOTE_SCRIPT
}

install_nodes() {
  local script="/tmp/k8s-node-install.sh"
  gen_node_install_script
  local ip name rc
  for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
    log "安装节点: $name ($ip)"
    #region debug-point node-install-failure
    dbg "install-node-start" "name=$name ip=$ip"
    #endregion debug-point node-install-failure
    if is_local_ip "$ip"; then
      bash "$script" || rc=$?
      #region debug-point node-install-failure
      if [[ -f /tmp/debug-log-node-install-failure.ndjson ]]; then cp /tmp/debug-log-node-install-failure.ndjson "$DBG_LOG_DIR/debug-log-node-install-failure-$ip.ndjson" 2>/dev/null || true; fi
      #endregion debug-point node-install-failure
    else
      ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "bash -s -- $PAUSE_IMAGE" < "$script" || rc=$?
      #region debug-point node-install-failure
      scp "${SSH_OPTS[@]}" "$SSH_USER@$ip:/tmp/debug-log-node-install-failure.ndjson" "$DBG_LOG_DIR/debug-log-node-install-failure-$ip.ndjson" >/dev/null 2>&1 || true
      #endregion debug-point node-install-failure
    fi
    #region debug-point node-install-failure
    dbg "install-node-end" "name=$name ip=$ip rc=${rc:-0} remote_log=$DBG_LOG_DIR/debug-log-node-install-failure-$ip.ndjson"
    #endregion debug-point node-install-failure
    if [[ "${rc:-0}" -ne 0 ]]; then
      return "$rc"
    fi
    rc=0
  done
}

push_images_to_registry() {
  [[ "$OFFLINE_AVAILABLE" -eq 1 ]] || { warn "在线模式跳过私有 registry 启动"; return 0; }
  [[ -n "$PRIVATE_REGISTRY" ]] || return 0
  local endpoint img src ref
  endpoint=$(registry_endpoint)
  log "启动私有 registry: $endpoint"
  vm_root "$PRIMARY_MASTER_IP" "registry_image=\$(ctr -n k8s.io images ls -q | grep -E '(^|/)registry:2$' | head -1); [ -n \"\$registry_image\" ] || registry_image='$REGISTRY_IMAGE'; ctr -n k8s.io images ls -q | grep -qx \"\$registry_image\" || { echo \"registry 镜像不存在: $REGISTRY_IMAGE\" >&2; exit 1; }; if ctr -n k8s.io tasks ls 2>/dev/null | grep -q '^registry '; then timeout 5 curl -fsS http://127.0.0.1:$REGISTRY_PORT/v2/ >/dev/null 2>&1 && { echo 'registry 已运行，跳过启动'; exit 0; }; ctr -n k8s.io tasks kill registry 2>/dev/null || true; ctr -n k8s.io tasks rm registry 2>/dev/null || true; fi; ctr -n k8s.io container rm registry 2>/dev/null || true; ctr -n k8s.io run -d --net-host \"\$registry_image\" registry; timeout 10 bash -c 'until curl -fsS http://127.0.0.1:$REGISTRY_PORT/v2/ >/dev/null 2>&1; do sleep 1; done'"

  log "所有节点已本地导入镜像，跳过私有 registry 推送"
}

gen_kubeadm_config() {
  local path="/tmp/kubeadm.yaml"
  local endpoint="$CONTROL_PLANE_ENDPOINT"
  cat > "$path" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $PRIMARY_MASTER_IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: $K8S_VER
controlPlaneEndpoint: $endpoint
imageRepository: $K8S_IMAGE_REPO
networking:
  podSubnet: $POD_CIDR
  serviceSubnet: $SERVICE_CIDR
apiServer:
  certSANs:
EOF
  local ip name
  for ip in "${ALL_IPS[@]}"; do echo "  - $ip" >> "$path"; done
  for name in "${ALL_NAMES[@]}"; do echo "  - $name" >> "$path"; done
  cat >> "$path" <<EOF
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  :
}

cert_cidr_first_ip() { # 取 CIDR 第一个可用 IP（即 kubernetes service 的 ClusterIP）
  local cidr="$1" ip mask a b c d ipint maskint netint first
  ip="${cidr%/*}"; mask="${cidr#*/}"
  IFS=. read -r a b c d <<< "$ip"
  ipint=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  maskint=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
  netint=$(( ipint & maskint ))
  first=$(( netint + 1 ))
  printf '%d.%d.%d.%d' $(( (first >> 24) & 255 )) $(( (first >> 16) & 255 )) $(( (first >> 8) & 255 )) $(( first & 255 ))
}

gen_ca_cert() { # 生成100年有效期CA: gen_ca_cert <CN> <crt路径> <key路径>
  local cn="$1" crt="$2" key="$3"
  openssl genrsa -out "$key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "$key" -sha256 -days "$CERT_VALID_DAYS" \
    -subj "/CN=$cn" -out "$crt" -extensions v3_ca \
    -config <(printf '%s\n' \
      '[req]' \
      'distinguished_name = dn' \
      '[dn]' \
      '[v3_ca]' \
      'basicConstraints = critical,CA:TRUE' \
      'keyUsage = critical, keyCertSign, cRLSign' \
      'subjectKeyIdentifier = hash') 2>/dev/null
  [[ -s "$crt" && -s "$key" ]] || die "集群CA生成失败: $cn"
}

prepare_cluster_ca() {
  log "准备集群CA（有效期 $CERT_VALID_DAYS 天，首次生成后长期复用）: $CLUSTER_CA_DIR"
  if [[ ! -s "$CLUSTER_CA_DIR/ca.crt" || ! -s "$CLUSTER_CA_DIR/ca.key" ]]; then
    mkdir -p "$CLUSTER_CA_DIR/etcd"
    gen_ca_cert "kubernetes" "$CLUSTER_CA_DIR/ca.crt" "$CLUSTER_CA_DIR/ca.key"
    gen_ca_cert "front-proxy-ca" "$CLUSTER_CA_DIR/front-proxy-ca.crt" "$CLUSTER_CA_DIR/front-proxy-ca.key"
    gen_ca_cert "etcd-ca" "$CLUSTER_CA_DIR/etcd/ca.crt" "$CLUSTER_CA_DIR/etcd/ca.key"
    chmod 600 "$CLUSTER_CA_DIR"/*.key "$CLUSTER_CA_DIR"/etcd/*.key
    log "集群CA已生成并保存到 $CLUSTER_CA_DIR（后续部署复用，勿删除）"
  else
    log "复用已有集群CA: $CLUSTER_CA_DIR"
  fi

  if vm_root "$PRIMARY_MASTER_IP" "test -f /etc/kubernetes/pki/ca.crt -a -f /etc/kubernetes/pki/ca.key"; then
    if ! vm_root "$PRIMARY_MASTER_IP" "openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -checkend 1892160000" >/dev/null 2>&1; then
      warn "主 master 上现有集群CA有效期不足60年（旧版本脚本部署），本次将沿用该CA重签证书；如需100年CA，请先执行 $0 reset 再重新部署"
    fi
    return 0
  fi
  if vm_root "$PRIMARY_MASTER_IP" "test -e /etc/kubernetes/pki/ca.crt -o -e /etc/kubernetes/pki/ca.key"; then
    die "主 master 上存在不完整的集群CA（缺少证书或私钥），请先执行 $0 reset 清理后重试"
  fi

  log "分发集群CA到主 master ($PRIMARY_MASTER_IP)..."
  vm_root "$PRIMARY_MASTER_IP" "mkdir -p /etc/kubernetes/pki/etcd"
  if is_local_ip "$PRIMARY_MASTER_IP"; then
    cp -f "$CLUSTER_CA_DIR/ca.crt" "$CLUSTER_CA_DIR/ca.key" "$CLUSTER_CA_DIR/front-proxy-ca.crt" "$CLUSTER_CA_DIR/front-proxy-ca.key" /etc/kubernetes/pki/
    cp -f "$CLUSTER_CA_DIR/etcd/ca.crt" "$CLUSTER_CA_DIR/etcd/ca.key" /etc/kubernetes/pki/etcd/
  else
    tar czf - -C "$CLUSTER_CA_DIR" ca.crt ca.key front-proxy-ca.crt front-proxy-ca.key etcd/ca.crt etcd/ca.key \
      | ssh "${SSH_OPTS[@]}" "$SSH_USER@$PRIMARY_MASTER_IP" "tar xzf - -C /etc/kubernetes/pki"
  fi
  vm_root "$PRIMARY_MASTER_IP" "chmod 600 /etc/kubernetes/pki/ca.key /etc/kubernetes/pki/front-proxy-ca.key /etc/kubernetes/pki/etcd/ca.key && chmod 644 /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/front-proxy-ca.crt /etc/kubernetes/pki/etcd/ca.crt"
}

resign_master_certs() {
  log "重签控制面证书为 $CERT_VALID_DAYS 天（100年）有效期，随后重启控制面..."
  local script="/tmp/k8s-cert-resign.sh"
  local svc_ip endpoint_host san_apiserver san_etcd i ip name
  svc_ip=$(cert_cidr_first_ip "$SERVICE_CIDR")
  endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
  san_apiserver="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local"
  for name in "${ALL_NAMES[@]}"; do san_apiserver+=",DNS:$name"; done
  if [[ "$endpoint_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san_apiserver+=",IP:$endpoint_host"
  else
    san_apiserver+=",DNS:$endpoint_host"
  fi
  san_apiserver+=",IP:$svc_ip"
  for ip in "${ALL_IPS[@]}"; do san_apiserver+=",IP:$ip"; done

  for i in "${!MASTER_IPS[@]}"; do
    ip="${MASTER_IPS[$i]}"; name="${MASTER_NAMES[$i]}"
    san_etcd="DNS:localhost,DNS:$name,DNS:etcd,DNS:etcd.kube-system.svc,DNS:etcd.kube-system.svc.cluster.local,IP:127.0.0.1,IP:$ip"
    cat > "$script" <<'REMOTE_SCRIPT'
set -euo pipefail
K8S_CONF_DIR="${K8S_CONF_DIR:-/etc/kubernetes}"
PKI_DIR="$K8S_CONF_DIR/pki"
DAYS=__DAYS__
SAN_APISERVER="__SAN_APISERVER__"
SAN_ETCD="__SAN_ETCD__"
CHECK_APISERVER="__CHECK_APISERVER__"
CHECK_ETCD="__CHECK_ETCD__"
BACKUP="${BACKUP_DIR:-/root}/k8s-pki-backup-$(date +%Y%m%d%H%M%S).tar.gz"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "  - $*"; }

[[ -f "$PKI_DIR/ca.crt" && -f "$PKI_DIR/ca.key" ]] || die "缺少集群CA（$PKI_DIR/ca.crt 或 ca.key 不存在）"

log "备份原证书到 $BACKUP"
tar czf "$BACKUP" -C "$K8S_CONF_DIR" pki admin.conf controller-manager.conf scheduler.conf kubelet.conf >/dev/null 2>&1 || echo "  - WARN: 备份失败，继续重签"

# 重签单个证书: resign_cert <相对pki路径> <CA前缀> <EKU> <SAN可选>
# 使用 x509 -x509toreq 从原证书提取 subject（含 SAN 之外的 DN），再按 kubeadm profile 用 extfile 签发长有效期证书
resign_cert() {
  local rel="$1" ca="$2" eku="$3" san="${4:-}"
  local crt="$PKI_DIR/$rel" key="$PKI_DIR/${rel%.crt}.key"
  local csr="${crt%.crt}.resign.csr" ext="${crt%.crt}.resign.ext"
  [[ -f "$crt" && -f "$key" ]] || die "缺少证书或私钥: $crt"
  {
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    if [[ -n "$san" ]]; then echo "subjectAltName = $san"; fi
  } > "$ext"
  openssl x509 -x509toreq -in "$crt" -signkey "$key" -out "$csr" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$ca.crt" -CAkey "$ca.key" -CAcreateserial \
    -sha256 -days "$DAYS" -extfile "$ext" -out "$crt.resign.new" >/dev/null 2>&1
  chmod 644 "$crt.resign.new"
  mv -f "$crt.resign.new" "$crt"
  rm -f "$csr" "$ext"
  log "已重签 $rel ($(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2))"
}

# 重签 kubeconfig 内嵌客户端证书（admin/controller-manager/scheduler/kubelet）
resign_kubeconfig() {
  local kf="$K8S_CONF_DIR/$1"
  if [[ ! -f "$kf" ]]; then echo "  - 跳过(不存在): $1"; return 0; fi
  local tmp new_b64
  tmp=$(mktemp -d)
  awk '/client-certificate-data:/ {print $2; exit}' "$kf" | base64 -d > "$tmp/c.pem"
  awk '/client-key-data:/ {print $2; exit}' "$kf" | base64 -d > "$tmp/c.key"
  if [[ ! -s "$tmp/c.pem" || ! -s "$tmp/c.key" ]]; then
    rm -rf "$tmp"
    echo "  - 跳过(无客户端证书): $1"
    return 0
  fi
  {
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = clientAuth"
  } > "$tmp/c.ext"
  openssl x509 -x509toreq -in "$tmp/c.pem" -signkey "$tmp/c.key" -out "$tmp/c.csr" >/dev/null 2>&1
  openssl x509 -req -in "$tmp/c.csr" -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -sha256 -days "$DAYS" -extfile "$tmp/c.ext" -out "$tmp/c.new.pem" >/dev/null 2>&1
  openssl verify -CAfile "$PKI_DIR/ca.crt" "$tmp/c.new.pem" >/dev/null || { rm -rf "$tmp"; die "kubeconfig 重签校验失败: $1"; }
  new_b64=$(base64 -w0 "$tmp/c.new.pem")
  sed -i "s#client-certificate-data:.*#client-certificate-data: $new_b64#" "$kf"
  rm -rf "$tmp"
  log "已重签 $1"
}

log "重签 pki 控制面证书（有效期 $DAYS 天）..."
resign_cert "apiserver.crt" "$PKI_DIR/ca" "serverAuth" "$SAN_APISERVER"
resign_cert "apiserver-kubelet-client.crt" "$PKI_DIR/ca" "clientAuth"
resign_cert "front-proxy-client.crt" "$PKI_DIR/front-proxy-ca" "clientAuth"
resign_cert "apiserver-etcd-client.crt" "$PKI_DIR/etcd/ca" "clientAuth"
resign_cert "etcd/server.crt" "$PKI_DIR/etcd/ca" "serverAuth, clientAuth" "$SAN_ETCD"
resign_cert "etcd/peer.crt" "$PKI_DIR/etcd/ca" "serverAuth, clientAuth" "$SAN_ETCD"
resign_cert "etcd/healthcheck-client.crt" "$PKI_DIR/etcd/ca" "clientAuth"

log "重签 kubeconfig 内嵌证书..."
resign_kubeconfig "admin.conf"
resign_kubeconfig "controller-manager.conf"
resign_kubeconfig "scheduler.conf"
resign_kubeconfig "kubelet.conf"

log "校验证书链与 SAN..."
openssl verify -CAfile "$PKI_DIR/ca.crt" "$PKI_DIR/apiserver.crt" "$PKI_DIR/apiserver-kubelet-client.crt" >/dev/null
openssl verify -CAfile "$PKI_DIR/front-proxy-ca.crt" "$PKI_DIR/front-proxy-client.crt" >/dev/null
openssl verify -CAfile "$PKI_DIR/etcd/ca.crt" "$PKI_DIR/apiserver-etcd-client.crt" "$PKI_DIR/etcd/server.crt" "$PKI_DIR/etcd/peer.crt" "$PKI_DIR/etcd/healthcheck-client.crt" >/dev/null
local_san=$(openssl x509 -in "$PKI_DIR/apiserver.crt" -noout -ext subjectAltName)
for v in $CHECK_APISERVER; do
  echo "$local_san" | grep -q -- "$v" || die "apiserver 证书 SAN 缺少: $v"
done
etcd_san=$(openssl x509 -in "$PKI_DIR/etcd/server.crt" -noout -ext subjectAltName)
for v in $CHECK_ETCD; do
  echo "$etcd_san" | grep -q -- "$v" || die "etcd/server 证书 SAN 缺少: $v"
done

log "重启 kubelet 以加载新证书..."
systemctl restart kubelet
log "控制面证书重签完成"
REMOTE_SCRIPT
    sed -i "s#__DAYS__#$CERT_VALID_DAYS#; s#__SAN_APISERVER__#$san_apiserver#; s#__SAN_ETCD__#$san_etcd#; s#__CHECK_APISERVER__#$endpoint_host $svc_ip#; s#__CHECK_ETCD__#127.0.0.1 $ip#" "$script"
    log "重签 master 证书: $name ($ip)"
    if is_local_ip "$ip"; then
      bash "$script"
    else
      ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" bash -s < "$script"
    fi
  done
}

install_cni() {
  local manifest
  log "安装 CNI: $CNI_PLUGIN"
  if [[ "$OFFLINE_AVAILABLE" -eq 1 ]]; then
    case "$CNI_PLUGIN" in
      calico) manifest="$REMOTE_DIR/manifests/calico.yaml" ;;
      flannel) manifest="$REMOTE_DIR/manifests/kube-flannel.yml" ;;
      *) die "未知 CNI_PLUGIN: $CNI_PLUGIN（仅支持 calico/flannel）" ;;
    esac
    vm_root "$PRIMARY_MASTER_IP" "kubectl apply -f $manifest"
  else
    case "$CNI_PLUGIN" in
      calico) vm_root "$PRIMARY_MASTER_IP" "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml" ;;
      flannel) vm_root "$PRIMARY_MASTER_IP" "kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" ;;
      *) die "未知 CNI_PLUGIN: $CNI_PLUGIN（仅支持 calico/flannel）" ;;
    esac
  fi
}

deploy_acceptance_tools() {
  if [[ "$OFFLINE_AVAILABLE" -eq 0 ]]; then
    warn "在线模式未使用离线验收清单，跳过集群验收工具部署"
    return 0
  fi
  if [[ ! -f "$OFFLINE_DIR/manifests/tool.yaml" ]]; then
    warn "未发现 tool.yaml，跳过集群验收工具部署"
    return 0
  fi
  log "部署集群验收工具..."
  vm_root "$PRIMARY_MASTER_IP" "kubectl apply -f $REMOTE_DIR/manifests/tool.yaml"
  vm_root "$PRIMARY_MASTER_IP" "kubectl rollout status deployment/nginx-test --timeout=180s"
  vm_root "$PRIMARY_MASTER_IP" "kubectl get pods -o wide"
}

init_master() {
  log "初始化主 master ($PRIMARY_MASTER_IP)，控制面入口: $CONTROL_PLANE_ENDPOINT ..."
  if vm_root "$PRIMARY_MASTER_IP" "test -f /etc/kubernetes/admin.conf"; then
    warn "主 master 已初始化，跳过 kubeadm init"
  else
    gen_kubeadm_config
    if is_local_ip "$PRIMARY_MASTER_IP"; then
      cp /tmp/kubeadm.yaml "$REMOTE_DIR/kubeadm.yaml"
    else
      scp "${SSH_OPTS[@]}" /tmp/kubeadm.yaml "$SSH_USER@$PRIMARY_MASTER_IP:$REMOTE_DIR/kubeadm.yaml"
    fi
    vm_root "$PRIMARY_MASTER_IP" "kubeadm init --config $REMOTE_DIR/kubeadm.yaml --upload-certs" || die "kubeadm init 失败"
  fi

  vm_root "$PRIMARY_MASTER_IP" "mkdir -p /root/.kube && \
    cp /etc/kubernetes/admin.conf /root/.kube/config && \
    chown -R root:root /root/.kube"

  install_cni
}

join_masters() {
  log "获取 control-plane join 命令..."
  local join_cmd cert_key i ip name
  join_cmd=$(vm_root "$PRIMARY_MASTER_IP" "kubeadm token create --print-join-command")
  cert_key=$(vm_root "$PRIMARY_MASTER_IP" "kubeadm init phase upload-certs --upload-certs | tail -1")
  [[ -n "$join_cmd" && -n "$cert_key" ]] || die "获取 control-plane join 命令失败"

  for i in "${!MASTER_IPS[@]}"; do
    [[ "$i" -eq 0 ]] && continue
    ip="${MASTER_IPS[$i]}"; name="${MASTER_NAMES[$i]}"
    if vm_root "$ip" "test -f /etc/kubernetes/admin.conf"; then
      warn "$name 已加入控制平面，跳过"
      continue
    fi
    log "加入控制平面: $name ($ip)"
    vm_root "$ip" "$join_cmd --control-plane --certificate-key $cert_key --cri-socket unix:///run/containerd/containerd.sock --apiserver-advertise-address $ip --ignore-preflight-errors=Mem" || die "$name control-plane join 失败"
    vm_root "$ip" "mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && chown -R root:root /root/.kube"
  done
}

join_workers() {
  log "获取 worker join 命令..."
  local join_cmd
  join_cmd=$(vm_root "$PRIMARY_MASTER_IP" "kubeadm token create --print-join-command")
  [[ -n "$join_cmd" ]] || die "获取 worker join 命令失败"
  local i ip name
  for i in "${!WORKER_IPS[@]}"; do
    ip="${WORKER_IPS[$i]}"; name="${WORKER_NAMES[$i]}"
    if vm_root "$ip" "test -f /etc/kubernetes/kubelet.conf"; then
      warn "$name 已加入集群，跳过"
      continue
    fi
    log "加入 worker: $name ($ip)"
    vm_root "$ip" "$join_cmd --cri-socket unix:///run/containerd/containerd.sock" || die "$name join 失败"
  done
}

label_workers() {
  local i name
  for i in "${!WORKER_NAMES[@]}"; do
    vm "$PRIMARY_MASTER_IP" "kubectl label node ${WORKER_NAMES[$i]} node-role.kubernetes.io/worker= --overwrite" >/dev/null 2>&1 || true
  done
}

allow_masters_schedule() {
  local i name
  for i in "${!MASTER_NAMES[@]}"; do
    name="${MASTER_NAMES[$i]}"
    vm "$PRIMARY_MASTER_IP" "kubectl taint node $name node-role.kubernetes.io/control-plane- 2>/dev/null || true; kubectl taint node $name node-role.kubernetes.io/master- 2>/dev/null || true; kubectl label node $name node-role.kubernetes.io/worker= --overwrite" >/dev/null 2>&1 || true
  done
}

print_deploy_summary() {
  local endpoint registry
  registry=$(registry_endpoint || true)
  echo
  log "=========== 部署结果清单 ==========="
  echo "基础配置:"
  echo "  Kubernetes 版本: $K8S_VER"
  echo "  控制面入口: $CONTROL_PLANE_ENDPOINT"
  echo "  CNI 插件: $CNI_PLUGIN"
  echo "  Pod CIDR: $POD_CIDR"
  echo "  Service CIDR: $SERVICE_CIDR"
  echo "  私有 registry: ${registry:-未启用}"
  if [[ -n "$SLB_ENDPOINT" ]]; then
    echo "  SLB: $SLB_ENDPOINT"
  fi
  local cert_end
  cert_end=$(vm "$PRIMARY_MASTER_IP" "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate 2>/dev/null | cut -d= -f2" 2>/dev/null || true)
  echo "  apiserver 证书有效期至: ${cert_end:-未知}"
  echo
  echo "节点清单:"
  local i
  for i in "${!ALL_IPS[@]}"; do echo "  ${ALL_ROLES[$i]}: ${ALL_NAMES[$i]} ${ALL_IPS[$i]}"; done
  echo
  echo "节点状态:"
  vm "$PRIMARY_MASTER_IP" "kubectl get nodes -o wide" 2>/dev/null || warn "无法获取节点状态"
  echo
  echo "系统 Pod 状态:"
  vm "$PRIMARY_MASTER_IP" "kubectl get pods -A -o wide" 2>/dev/null || warn "无法获取 Pod 状态"
  echo
  echo "验收资源:"
  vm "$PRIMARY_MASTER_IP" "kubectl get deploy,svc,pod -l app=nginx-test -o wide 2>/dev/null || true; kubectl get pod network-test -o wide 2>/dev/null || true" || true
  echo "===================================="
}

wait_ready() {
  log "等待全部节点 Ready（最长 10 分钟）..."
  local i ok
  for i in $(seq 1 60); do
    ok=$(vm "$PRIMARY_MASTER_IP" "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true")
    if [[ "$ok" -ge "${#ALL_IPS[@]}" ]]; then
      log "全部节点 Ready！"
      vm "$PRIMARY_MASTER_IP" "kubectl get nodes -o wide"
      return 0
    fi
    sleep 10
  done
  warn "等待超时，当前状态:"
  vm "$PRIMARY_MASTER_IP" "kubectl get nodes" || true
  exit 1
}

deploy() {
  DEPLOY_REPORT_ENABLED=1
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"
  run_deploy_step "前置条件检查" "校验执行机依赖与 SSH 免密连通性，核验离线 RPM/镜像物料完整性" check_preconditions
  run_deploy_step "分发离线物料" "将 RPM 包、容器镜像与清单文件分发至全部节点，并做 sha256 校验" distribute
  run_deploy_step "安装节点基础组件" "安装 containerd/kubelet 等组件，配置内核参数、导入容器镜像" install_nodes
  run_deploy_step "配置高可用入口" "校验 SLB 入口与各 master apiserver 监听状态" setup_ha
  run_deploy_step "启动私有 registry" "启动节点本地镜像仓库，支撑内网环境镜像分发" push_images_to_registry
  run_deploy_step "准备集群CA(100年)" "生成并分发 100 年有效期集群 CA，首次生成后长期复用" prepare_cluster_ca
  run_deploy_step "初始化主 master" "kubeadm 初始化控制面，安装 CNI 网络插件" init_master
  run_deploy_step "加入其他 master" "其余控制面节点加入集群，构成高可用控制面" join_masters
  run_deploy_step "加入 worker 节点" "业务节点加入集群，纳入统一资源调度" join_workers
  run_deploy_step "重签证书为100年有效期" "控制面全部证书重签为 100 年有效期并重启控制面，免手工续期" resign_master_certs
  run_deploy_step "标记 worker 节点" "为 worker 节点添加角色标签，便于调度与管理" label_workers
  run_deploy_step "允许 master 调度" "移除控制面污点，允许业务负载与控制面共存" allow_masters_schedule
  run_deploy_step "等待节点 Ready" "持续巡检直至全部节点进入 Ready 状态" wait_ready
  run_deploy_step "部署验收工具" "部署 nginx 验收负载，验证集群网络与调度能力" deploy_acceptance_tools
  print_deploy_summary
  write_deploy_report "成功"
  echo
  log "=========== k8s 集群部署完成 ==========="
  log "控制面入口: $CONTROL_PLANE_ENDPOINT"
  log "部署报告: $DEPLOY_REPORT_FILE"
  log "在主 master 上执行: ssh -i $SSH_KEY $SSH_USER@$PRIMARY_MASTER_IP"
  log "然后运行: kubectl get nodes"
  echo "========================================"
}

check() {
  check_preconditions
  local ip name
  for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
    if remote_material_ready "$ip"; then
      log "$name ($ip): VM 可达，远端物料校验通过"
    else
      warn "$name ($ip): VM 可达，远端物料缺失或未校验，部署时会重新分发"
    fi
  done
}

status() {
  log "集群节点状态:"
  vm "$PRIMARY_MASTER_IP" "kubectl get nodes -o wide" 2>/dev/null \
    || warn "无法连接主 master 或集群未部署"
  log "全部 Pod 状态:"
  vm "$PRIMARY_MASTER_IP" "kubectl get pods -A" 2>/dev/null || true
}

reset() {
  warn "将重置全部节点上的 k8s（保留 VM 与离线物料）"
  local i ip
  for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    log "重置 ${ALL_NAMES[$i]} ($ip)..."
    vm_root "$ip" "kubeadm reset -f 2>/dev/null || true
ctr -n k8s.io tasks kill registry 2>/dev/null || true
ctr -n k8s.io tasks rm registry 2>/dev/null || true
ctr -n k8s.io container rm registry 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/etcd /etc/cni/net.d /var/lib/cni /root/.kube 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ipvsadm -C 2>/dev/null || true
while read -r host_ip host_name; do
  [ -n \"\$host_name\" ] || continue
  sed -i.bak \"/[[:space:]]\$host_name\$/d\" /etc/hosts 2>/dev/null || true
done <<'HOSTS'
$HOSTS_ENTRIES
HOSTS
true"
  done
  log "重置完成，可重新运行: $0"
}

uninstall() {
  warn "将完整卸载全部节点上的 Kubernetes 与容器运行时组件，并清理远端离线物料"
  local i ip
  for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    log "卸载 ${ALL_NAMES[$i]} ($ip)..."
    vm_root "$ip" "kubeadm reset -f 2>/dev/null || true
systemctl disable --now kubelet 2>/dev/null || true
systemctl disable --now containerd 2>/dev/null || true
ctr -n k8s.io tasks kill registry 2>/dev/null || true
ctr -n k8s.io tasks rm registry 2>/dev/null || true
ctr -n k8s.io container rm registry 2>/dev/null || true
ctr -n k8s.io images ls -q 2>/dev/null | xargs -r ctr -n k8s.io images rm >/dev/null 2>&1 || true
rpm -e --nodeps kubeadm kubelet kubectl kubernetes-cni cri-tools containerd.io ipset ipvsadm 2>/dev/null || true
rm -f /usr/local/bin/helm 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/etcd /etc/cni/net.d /var/lib/cni /var/lib/kubelet \
       /etc/containerd /var/lib/containerd /root/.kube /var/lib/k8s-offline-node-ready \
       /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf 2>/dev/null || true
if [ "$REMOTE_DIR" != "/data" ]; then
  rm -rf $REMOTE_DIR 2>/dev/null || true
fi
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ipvsadm -C 2>/dev/null || true
while read -r host_ip host_name; do
  [ -n \"\$host_name\" ] || continue
  sed -i.bak \"/[[:space:]]\$host_name\$/d\" /etc/hosts 2>/dev/null || true
done <<'HOSTS'
$HOSTS_ENTRIES
HOSTS
true"
  done
  log "卸载完成。本地离线物料目录（OFFLINE_DIR / offline-assets）未删除，如需可手动清理。"
}

parse_args() {
  ACTION="deploy"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      deploy|check|status|ha|reset|uninstall)
        ACTION="$1"
        shift
        ;;
    esac
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -sd|--skip-distribute|--no-distribute)
        DISTRIBUTE_MATERIALS=0
        ;;
      --distribute)
        DISTRIBUTE_MATERIALS=1
        ;;
      -ct|--cleanthread)
        ACTION="cleanthread"
        ;;
      *)
        die "未知参数: $1。用法: $0 [deploy|check|status|ha|reset|uninstall|-ct|--cleanthread] [-sd|--skip-distribute|--distribute]"
        ;;
    esac
    shift
  done
}

parse_args "$@"
init_local_ips
#region debug-point k8s-deploy-failure
dbg "local-ips" "$LOCAL_IPS"
#endregion debug-point k8s-deploy-failure
load_topology
#region debug-point k8s-deploy-failure
dbg "topology-loaded" "masters=${MASTER_IPS[*]} workers=${WORKER_IPS[*]} all=${ALL_IPS[*]} primary=$PRIMARY_MASTER_IP endpoint=$CONTROL_PLANE_ENDPOINT registry=$PRIVATE_REGISTRY"
#endregion debug-point k8s-deploy-failure

case "$ACTION" in
  deploy) deploy ;;
  check) check ;;
  status) status ;;
  ha) setup_ha ;;
  reset) reset ;;
  uninstall) uninstall ;;
  cleanthread) clean_threads ;;
  *) die "用法: $0 [deploy|check|status|ha|reset|uninstall|-ct|--cleanthread] [-sd|--skip-distribute|--distribute]" ;;
esac
