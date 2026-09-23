#!/usr/bin/env bash
# download.sh — 下载麒麟 V10 的 k8s 离线部署物料
# 支持:
#   kylin-v10 : 下载 .rpm 包 + 容器镜像 + flannel/Calico 清单 + HA/registry/验收物料 + helm
# 用法:
#   ./download.sh [--force]
set -euo pipefail

# ============ 版本与源配置 ==========
K8S_MINOR="v1.28"
K8S_VER="v1.28.15"
FLANNEL_VER="v0.26.7"
CALICO_VER="v3.28.2"
REGISTRY_VER="2"
BUSYBOX_VER="1.36"
CURL_VER="8.10.1"
NGINX_VER="1.27.3"
HELM_VER="v3.16.4"

OS_TYPE="kylin-v10"
FORCE=""

ALIYUN_K8S_RPM="https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_MINOR}/rpm"
OFFICIAL_K8S_RPM="https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm"
ALIYUN_DOCKER_RPM="https://mirrors.aliyun.com/docker-ce/linux/centos/8/x86_64/stable"
K8S_IMAGE_REPO="registry.aliyuncs.com/google_containers"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}" .sh).log"
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%F %T')" "$line" | tee -a "$LOG_FILE"; done) 2>&1

BASE_DIR="$SCRIPT_DIR"
ASSETS_DIR="$BASE_DIR/offline-assets"
OFFLINE_DIR="$ASSETS_DIR/offline"
BUNDLE="$ASSETS_DIR/k8s-offline-bundle-${K8S_VER}.tar.gz"

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

usage() {
  cat <<EOF
用法: $0 [--force]

选项:
  --force          重新下载已存在文件
  -h, --help       显示帮助

说明:
  当前脚本固定下载麒麟 V10/RPM 系统的离线包。
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --os)
        [[ $# -ge 2 ]] || die "--os 需要参数: kylin-v10"
        [[ "$2" == "kylin-v10" ]] || die "当前脚本仅支持麒麟 V10: --os kylin-v10"
        OS_TYPE="kylin-v10"
        shift 2
        ;;
      --force)
        FORCE="--force"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done

  if [[ "$OS_TYPE" != "kylin-v10" ]]; then
    die "当前脚本仅支持麒麟 V10"
  fi
}

verified_file() {
  local file="$1" rel
  [[ "$FORCE" != "--force" && -f "$file" && -f "$OFFLINE_DIR/sha256sums.txt" ]] || return 1
  rel="./${file#"$OFFLINE_DIR/"}"
  (cd "$OFFLINE_DIR" && grep -F "  $rel" sha256sums.txt | sha256sum -c --status) 2>/dev/null
}

download_file() {
  local url="$1" dest="$2"
  if verified_file "$dest"; then
    log "已校验，跳过: $(basename "$dest")"
    return 0
  fi
  if [[ -f "$dest" && "$FORCE" != "--force" ]]; then
    warn "已存在但未通过校验，重新下载: $(basename "$dest")"
  fi
  rm -f "${dest}.part"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "${dest}.part" "$url" && mv "${dest}.part" "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "${dest}.part" "$url" && mv "${dest}.part" "$dest"
  else
    die "未找到 curl 或 wget，无法下载文件"
  fi
}

ensure_deps() {
  if ! command -v skopeo >/dev/null 2>&1; then
    log "安装 skopeo..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq skopeo >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q skopeo >/dev/null
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q skopeo >/dev/null
    else
      die "未找到 apt-get/dnf/yum，无法自动安装 skopeo"
    fi
  fi
}

prepare_dirs() {
  mkdir -p "$OFFLINE_DIR"/{rpms,images,manifests,bin}
  echo "$OS_TYPE" > "$OFFLINE_DIR/os-type.txt"
}

# ---------- 麒麟 V10: 下载 .rpm 包 ----------
resolve_rpms() {
  local pkg_mgr=""
  local cachedir="/tmp/k8s-yum-resolv"
  local yumconf="$cachedir/k8s-offline.repo"
  local downloader=""

  command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf"
  [[ -n "$pkg_mgr" ]] || { command -v yum >/dev/null 2>&1 && pkg_mgr="yum"; }
  [[ -n "$pkg_mgr" ]] || die "麒麟 V10/RPM 模式需要 yum 或 dnf"

  mkdir -p "$cachedir" "$OFFLINE_DIR/rpms"
  cat > "$yumconf" <<EOF
[kubernetes]
name=Kubernetes
baseurl=$ALIYUN_K8S_RPM $OFFICIAL_K8S_RPM
enabled=1
gpgcheck=0

[docker-ce-stable]
name=Docker CE Stable
baseurl=$ALIYUN_DOCKER_RPM
enabled=1
gpgcheck=0
EOF

  if command -v yumdownloader >/dev/null 2>&1; then
    downloader="yumdownloader"
  elif command -v dnf >/dev/null 2>&1 && dnf download --help >/dev/null 2>&1; then
    downloader="dnf-download"
  else
    log "安装 yum-utils/dnf plugins，用于下载 rpm 依赖..."
    if [[ "$pkg_mgr" == "dnf" ]]; then
      dnf install -y -q 'dnf-command(download)' yum-utils >/dev/null || dnf install -y -q yum-utils >/dev/null
      downloader="dnf-download"
    else
      yum install -y -q yum-utils >/dev/null
      downloader="yumdownloader"
    fi
  fi

  log "解析依赖闭包并下载 .rpm（kylin-v10/RPM）..."
  local pkgs=(kubeadm kubelet kubectl kubernetes-cni cri-tools containerd.io socat conntrack-tools ebtables ethtool keepalived haproxy ipset ipvsadm)
  # 运行库兜底：--alldeps 会受"执行机已安装"影响而漏下载这些已装运行库，
  # 导致生产精简机上 rpm -Uvh 报 failed dependencies。这里显式补齐。
  # 注意 net-snmp-libs 必须与 net-snmp 保持同版本。
  local extra_deps=(
    net-snmp-libs-5.9-8.p04.ky10
    net-snmp-5.9-8.p04.ky10
    ipset-libs-7.6-0.p01.ky10
    libseccomp-2.5.0-5.p03.ky10
    libnetfilter_cthelper
    libnetfilter_cttimeout
    libnetfilter_queue
    container-selinux
    haproxy-help-2.2.16-10.ky10
    ipvsadm-help-1.31-4.ky10
    keepalived-help-2.0.20-19.p03.ky10
    policycoreutils
    ca-certificates
  )
  local arch
  arch=$(uname -m)
  if [[ "$downloader" == "dnf-download" ]]; then
    dnf download -y --resolve --alldeps --destdir "$OFFLINE_DIR/rpms" \
      --repofrompath kubernetes,"$ALIYUN_K8S_RPM $OFFICIAL_K8S_RPM" \
      --repofrompath docker-ce-stable,"$ALIYUN_DOCKER_RPM" \
      --setopt=kubernetes.gpgcheck=0 \
      --setopt=docker-ce-stable.gpgcheck=0 \
      --archlist="$arch,noarch" \
      "${pkgs[@]}"
    dnf download -y --destdir "$OFFLINE_DIR/rpms" \
      --archlist="$arch,noarch" \
      "${extra_deps[@]}" || warn "运行库兜底下载有遗漏，后续将校验"
  else
    yumdownloader -y --resolve --destdir "$OFFLINE_DIR/rpms" \
      --config "$yumconf" \
      --archlist="$arch,noarch" \
      "${pkgs[@]}"
    yumdownloader -y --destdir "$OFFLINE_DIR/rpms" \
      --config "$yumconf" \
      --archlist="$arch,noarch" \
      "${extra_deps[@]}" || warn "运行库兜底下载有遗漏，后续将校验"
  fi
  # bind-utils（nslookup/dig）来自系统 OS 源，依赖 bind-libs/bind-license；
  # 单独一次下载并用 --resolve 带上依赖闭包，失败不阻塞其他物料。
  if [[ "$downloader" == "dnf-download" ]]; then
    dnf download -y --resolve --alldeps --destdir "$OFFLINE_DIR/rpms" \
      --archlist="$arch,noarch" \
      bind-utils || warn "bind-utils 下载失败，离线节点将缺少 nslookup/dig"
  else
    yumdownloader -y --resolve --destdir "$OFFLINE_DIR/rpms" \
      --config "$yumconf" \
      --archlist="$arch,noarch" \
      bind-utils || warn "bind-utils 下载失败，离线节点将缺少 nslookup/dig"
  fi
  log ".rpm 下载完成，共 $(find "$OFFLINE_DIR/rpms" -maxdepth 1 -name '*.rpm' | wc -l) 个"
}

extract_kubeadm_bin() {
  local xdir="/tmp/kubeadm-extract"
  rm -rf "$xdir"
  mkdir -p "$xdir"

  command -v rpm2cpio >/dev/null 2>&1 || die "RPM 模式需要 rpm2cpio"
  command -v cpio >/dev/null 2>&1 || die "RPM 模式需要 cpio"
  (cd "$xdir" && rpm2cpio "$OFFLINE_DIR"/rpms/kubeadm-*.rpm | cpio -idmu >/dev/null 2>&1)

  find "$xdir" -name kubeadm -type f | head -1
}

# Docker Hub 加速源（多源容错：运行时探测剔除失效源，逐源轮询重试）
DOCKER_HUB_MIRRORS=(
  "docker.m.daocloud.io"
  "docker.1ms.run"
  "dockerproxy.net"
)

declare -A _MIRROR_ALIVE
mirror_alive() {
  local m="$1" code
  if [[ -z "${_MIRROR_ALIVE[$m]:-}" ]]; then
    code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "https://$m/v2/" 2>/dev/null) || code=000
    case "$code" in
      200|401) _MIRROR_ALIVE[$m]=1 ;;
      *)       _MIRROR_ALIVE[$m]=0 ;;
    esac
  fi
  [[ "${_MIRROR_ALIVE[$m]}" == "1" ]]
}

copy_image() {
  local img="$1" dest="$2"
  local src candidates=() hub_path ns m alive round output rc last_src last_output last_rc

  if [[ "$img" == ghcr.io/* ]]; then
    candidates+=("ghcr.nju.edu.cn/${img#ghcr.io/}")
  else
    hub_path=""
    case "$img" in
      docker.io/*) hub_path="${img#docker.io/}" ;;
      */*)
        ns="${img%%/*}"
        # 无域名前缀（如 curlimages/curl）视为 Docker Hub 用户镜像
        [[ "$ns" != *.* && "$ns" != *:* ]] && hub_path="$img"
        ;;
      *) hub_path="library/$img" ;;  # 官方库镜像（registry:2 / busybox 等）
    esac
    if [[ -n "$hub_path" ]]; then
      alive=()
      for m in "${DOCKER_HUB_MIRRORS[@]}"; do
        mirror_alive "$m" && alive+=("$m/$hub_path")
      done
      if [[ ${#alive[@]} -gt 0 ]]; then
        candidates+=("${alive[@]}")
      else
        # 探测全部失败时不剔除，保留原名单兜底
        for m in "${DOCKER_HUB_MIRRORS[@]}"; do
          candidates+=("$m/$hub_path")
        done
      fi
    fi
  fi
  candidates+=("$img")

  # 多源轮询：每轮遍历所有源各试 1 次，共 3 轮，避免卡死在单个坏源上。
  # 中间源失败只打印摘要，完整错误仅在所有源失败后输出，避免日志被临时 EOF 刷屏。
  for round in 1 2 3; do
    for src in "${candidates[@]}"; do
      log "拉取镜像: $src -> $img (第 ${round} 轮)"
      rm -f "$dest"
      set +e
      output=$(skopeo copy "docker://$src" "docker-archive:$dest:$img" 2>&1)
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        [[ -z "$output" ]] || printf '%s\n' "$output"
        return 0
      fi
      last_src="$src"
      last_output="$output"
      last_rc="$rc"
      warn "镜像拉取失败: $src (第 ${round} 轮，退出码 $rc)，继续尝试下一个源"
      sleep 2
    done
  done

  echo "========== 镜像拉取最终失败 ==========" >&2
  echo "镜像: $img" >&2
  echo "最后失败源: ${last_src:-unknown}" >&2
  echo "退出码: ${last_rc:-unknown}" >&2
  echo "完整错误输出如下:" >&2
  [[ -z "${last_output:-}" ]] || printf '%s\n' "$last_output" >&2
  echo "========== 镜像拉取最终失败结束 ==========" >&2
  return 1
}

# ---------- 下载 k8s 组件镜像 ----------
pull_k8s_images() {
  log "提取 kubeadm 二进制以获取精确镜像列表..."
  local kubeadm_bin
  kubeadm_bin=$(extract_kubeadm_bin)
  [[ -n "$kubeadm_bin" && -x "$kubeadm_bin" ]] || die "未找到可执行 kubeadm"

  "$kubeadm_bin" config images list \
    --image-repository "$K8S_IMAGE_REPO" \
    --kubernetes-version "$K8S_VER" > "$OFFLINE_DIR/images/images.txt"
  log "镜像列表:"
  cat "$OFFLINE_DIR/images/images.txt"

  local img f
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    f="$OFFLINE_DIR/images/$(echo "$img" | tr '/:' '__').tar"
    if verified_file "$f"; then
      log "已校验，跳过: $(basename "$f")"
      continue
    fi
    [[ -f "$f" && "$FORCE" != "--force" ]] && warn "已存在但未通过校验，重新拉取: $(basename "$f")"
    copy_image "$img" "$f" || die "镜像拉取失败: $img"
  done < "$OFFLINE_DIR/images/images.txt"
}

# ---------- 从清单提取并下载镜像 ----------
pull_manifest_images() {
  local yml="$1"
  local img f
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    img="${img%\"}"
    img="${img#\"}"
    img="${img%'}"
    img="${img#'}"
    echo "$img" >> "$OFFLINE_DIR/images/images.txt"
    f="$OFFLINE_DIR/images/$(echo "$img" | tr '/:' '__').tar"
    if verified_file "$f"; then
      log "已校验，跳过: $(basename "$f")"
      continue
    fi
    [[ -f "$f" && "$FORCE" != "--force" ]] && warn "已存在但未通过校验，重新拉取: $(basename "$f")"
    copy_image "$img" "$f" || die "镜像拉取失败: $img"
  done < <(grep -oE 'image: *["'"'"']?[^ "'"'"']+' "$yml" | awk '{print $2}' | sort -u)
  sort -u -o "$OFFLINE_DIR/images/images.txt" "$OFFLINE_DIR/images/images.txt"
}

# ---------- 下载 flannel 清单与镜像 ----------
pull_flannel() {
  local yml="$OFFLINE_DIR/manifests/kube-flannel.yml"
  local ok=0
  for u in \
    "https://cdn.jsdelivr.net/gh/flannel-io/flannel@${FLANNEL_VER}/Documentation/kube-flannel.yml" \
    "https://fastly.jsdelivr.net/gh/flannel-io/flannel@${FLANNEL_VER}/Documentation/kube-flannel.yml" \
    "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VER}/Documentation/kube-flannel.yml" \
    "https://ghfast.top/https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VER}/Documentation/kube-flannel.yml" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VER}/Documentation/kube-flannel.yml"; do
    if download_file "$u" "$yml"; then ok=1; log "清单下载成功: $u"; break; fi
    warn "清单下载失败: $u"
  done
  [[ $ok -eq 1 ]] || die "kube-flannel.yml 下载失败"
  pull_manifest_images "$yml"
}

# ---------- 下载 Calico 清单与镜像 ----------
pull_calico() {
  local yml="$OFFLINE_DIR/manifests/calico.yaml"
  local ok=0
  for u in \
    "https://cdn.jsdelivr.net/gh/projectcalico/calico@${CALICO_VER}/manifests/calico.yaml" \
    "https://fastly.jsdelivr.net/gh/projectcalico/calico@${CALICO_VER}/manifests/calico.yaml" \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
    "https://ghfast.top/https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml"; do
    if download_file "$u" "$yml"; then ok=1; log "清单下载成功: $u"; break; fi
    warn "清单下载失败: $u"
  done
  [[ $ok -eq 1 ]] || die "calico.yaml 下载失败"
  sed -i "s#192.168.0.0/16#10.244.0.0/16#g" "$yml"
  pull_manifest_images "$yml"
}

# ---------- 下载 registry 与验收工具镜像 ----------
pull_registry_and_test_images() {
  local imgs=("registry:${REGISTRY_VER}" "busybox:${BUSYBOX_VER}" "curlimages/curl:${CURL_VER}" "nginx:${NGINX_VER}")
  local img f
  for img in "${imgs[@]}"; do
    echo "$img" >> "$OFFLINE_DIR/images/images.txt"
    f="$OFFLINE_DIR/images/$(echo "$img" | tr '/:' '__').tar"
    if verified_file "$f"; then
      log "已校验，跳过: $(basename "$f")"
      continue
    fi
    [[ -f "$f" && "$FORCE" != "--force" ]] && warn "已存在但未通过校验，重新拉取: $(basename "$f")"
    copy_image "$img" "$f" || die "镜像拉取失败: $img"
  done
  sort -u -o "$OFFLINE_DIR/images/images.txt" "$OFFLINE_DIR/images/images.txt"
}

# ---------- 下载 helm 二进制 ----------
pull_helm() {
  local arch_name tgz ok=0 u helm_bin="$OFFLINE_DIR/bin/helm"
  case "$(uname -m)" in
    x86_64)  arch_name="amd64" ;;
    aarch64) arch_name="arm64" ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
  if verified_file "$helm_bin"; then
    log "已校验，跳过: bin/helm"
    return 0
  fi
  if [[ -f "$helm_bin" && "$FORCE" != "--force" ]]; then
    warn "已存在但未通过校验，重新下载: bin/helm"
  fi
  tgz="$OFFLINE_DIR/bin/helm-${HELM_VER}-linux-${arch_name}.tar.gz"
  for u in \
    "https://get.helm.sh/helm-${HELM_VER}-linux-${arch_name}.tar.gz" \
    "https://mirrors.huaweicloud.com/helm/${HELM_VER}/helm-${HELM_VER}-linux-${arch_name}.tar.gz" \
    "https://mirror.azure.cn/kubernetes/helm/${HELM_VER}/helm-${HELM_VER}-linux-${arch_name}.tar.gz"; do
    if download_file "$u" "$tgz"; then ok=1; log "helm 下载成功: $u"; break; fi
    warn "helm 下载失败: $u"
  done
  [[ $ok -eq 1 ]] || die "helm 二进制下载失败"
  tar xzf "$tgz" -C "$OFFLINE_DIR/bin" --strip-components=1 "linux-${arch_name}/helm"
  rm -f "$tgz"
  chmod +x "$helm_bin"
  log "helm 就绪: $helm_bin ($("$helm_bin" version --short 2>/dev/null || echo "$HELM_VER"))"
}

write_acceptance_manifest() {
  cat > "$OFFLINE_DIR/manifests/tool.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:${NGINX_VER}
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: default
spec:
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: network-test
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: curlimages/curl:${CURL_VER}
    command: ["sleep", "3600"]
EOF
}

# ---------- 校验与打包 ----------
verify_downloads() {
  local rpm_count image_count part_count pattern
  local required_rpms=(
    'libnetfilter_cthelper-*.rpm'
    'libnetfilter_cttimeout-*.rpm'
    'libnetfilter_queue-*.rpm'
    'container-selinux-*.rpm'
    'haproxy-help-2.2.16-10.ky10*.rpm'
    'ipvsadm-help-1.31-4.ky10*.rpm'
    'keepalived-help-2.0.20-19.p03.ky10*.rpm'
    'net-snmp-5.9-8.p04.ky10*.rpm'
    'net-snmp-libs-5.9-8.p04.ky10*.rpm'
  )
  rpm_count=$(find "$OFFLINE_DIR/rpms" -maxdepth 1 -name '*.rpm' | wc -l)
  image_count=$(find "$OFFLINE_DIR/images" -maxdepth 1 -name '*.tar' | wc -l)
  part_count=$(find "$OFFLINE_DIR" -name '*.part' | wc -l)
  [[ "$rpm_count" -gt 0 ]] || die "未下载到 rpm 系统包"
  [[ "$image_count" -gt 0 ]] || die "未下载到镜像 tar"
  [[ "$part_count" -eq 0 ]] || die "存在未完成下载文件: ${part_count} 个 .part"
  for pattern in "${required_rpms[@]}"; do
    compgen -G "$OFFLINE_DIR/rpms/$pattern" >/dev/null || die "缺少必要 RPM: $pattern"
  done
  [[ -x "$OFFLINE_DIR/bin/helm" ]] || die "缺少 helm 二进制: bin/helm"
  compgen -G "$OFFLINE_DIR/rpms/bind-utils-*.rpm" >/dev/null || warn "缺少 bind-utils RPM，离线节点将没有 nslookup/dig"

  log "生成 sha256 校验文件..."
  (cd "$OFFLINE_DIR" && find . -type f ! -name sha256sums.txt -exec sha256sum {} \; > sha256sums.txt)
  log "校验全部离线物料..."
  (cd "$OFFLINE_DIR" && sha256sum -c sha256sums.txt >/dev/null)
  log "校验通过: rpm=${rpm_count}, images=${image_count}"
}

make_bundle() {
  local containerd_pkg="unknown"
  for f in "$OFFLINE_DIR"/rpms/containerd.io-*.rpm; do
    [[ -e "$f" ]] && containerd_pkg=$(basename "$f") && break
  done

  cat > "$OFFLINE_DIR/bundle-info.txt" <<EOF
os_type:     $OS_TYPE
kubernetes:  $K8S_VER
containerd:  $containerd_pkg
flannel:     $FLANNEL_VER
calico:      $CALICO_VER
registry:    $REGISTRY_VER
busybox:     $BUSYBOX_VER
curl:        $CURL_VER
nginx:       $NGINX_VER
helm:        $HELM_VER
image_repo:  $K8S_IMAGE_REPO
pod_cidr:    10.244.0.0/16
created:     $(date '+%F %T')
EOF
  verify_downloads
  log "打包离线物料: $BUNDLE"
  mkdir -p "$ASSETS_DIR"
  tar czf "$BUNDLE" -C "$ASSETS_DIR" offline
  du -sh "$OFFLINE_DIR" "$BUNDLE"
  log "物料目录: $OFFLINE_DIR"
  log "离线包:   $BUNDLE"
}

parse_args "$@"
ensure_deps
prepare_dirs
resolve_rpms
pull_k8s_images
pull_flannel
pull_calico
pull_registry_and_test_images
pull_helm
write_acceptance_manifest
make_bundle
log "全部物料下载完成！"
