#!/usr/bin/env bash
#
# deploy-landing.sh — 落地机（出口端）一键部署
#
#   = 开荒（vps.sh：SSH 加固 / fail2ban / UFW / 日志优化）
#   + 安装 Snell v5 服务端（供中转机转发过来的流量出网）
#
# 架构：Surge --Snell--> 中转机(纯转发，不解密) --> 落地机(snell-server) --> Internet
#
# 用法：
#   bash deploy-landing.sh --relay-ip <中转机公网IP>
#   bash deploy-landing.sh --relay-ip <中转机IP> --snell-port 6160 --ssh-port 22222
#   bash deploy-landing.sh --skip-bootstrap --relay-ip <中转机IP>   # 已开荒过的机器
#   bash deploy-landing.sh --help
#
# 配套脚本：deploy-relay.sh（在中转机上运行）
#
set -euo pipefail

VERSION="1.0.0"

# ============================ 开荒参数（第 1 步，传给 vps.sh）============================
VPS_SH=""                    # vps.sh 路径；留空则自动查找同目录，找不到就下载
VPS_SH_URL="https://raw.githubusercontent.com/yzj160212/BBK/main/vps.sh"
SSH_PORT=""                  # 开荒后 SSH 使用的端口；留空 = 自动随机挑一个高位端口
SSH_KEY=""                   # 开荒要写入 authorized_keys 的 SSH 公钥串
SSH_KEY_FILE=""              # 从文件读取 SSH 公钥（与 SSH_KEY 二选一）
SSH_PORT_MIN=20000           # 自动挑 SSH 端口的下界
SSH_PORT_MAX=60000           # 自动挑 SSH 端口的上界
SKIP_BOOTSTRAP=0             # 1 = 跳过开荒，只装 Snell
KEEP_SSH_PORT=0              # 1 = 不改动 SSH 端口
BOOTSTRAP_YES=0              # 1 = 开荒阶段不再交互确认
BOOTSTRAP_MARKER="/etc/bbk/bootstrap.done"   # 开荒完成标记（用于识别重跑）

# ============================ Snell 参数（第 2 步）============================
SNELL_VER="v5.0.1"
SNELL_PORT="6160"            # snell-server 监听端口
SNELL_PSK=""                 # 预共享密钥；留空 = 自动生成
RELAY_IP=""                  # 中转机公网 IP（填了就只允许它访问本机 Snell 端口）
FORCE=0
DRY_RUN=0
STATE_DIR="/etc/bbk"
SNELL_DIR="/etc/snell"
SNELL_CONF="$SNELL_DIR/snell-server.conf"
SNELL_BIN="/usr/local/bin/snell-server"

# ============================ 输出工具 ============================
if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '%s[·]%s %s\n' "$C_D" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

# ============================ 用法 ============================
usage() {
  cat <<'EOF'
deploy-landing.sh v1.0.0 — 落地机（出口端）一键部署（开荒 + Snell v5）

部署顺序：先跑本脚本（落地机），再跑 deploy-relay.sh（中转机）。
两台机器的 IP 你都事先知道，所以顺序不强制，但先落地机更顺。

Snell 参数：
  --relay-ip <IP>        中转机公网 IP。填了就只允许它访问本机 Snell 端口，
                         落地机对外完全隐形；同时客户端配置会用它作为服务器地址。
  --snell-port <端口>    snell-server 监听端口（默认 6160）
  --psk <密钥>           预共享密钥；不填自动生成（推荐自动生成）
  --force                已部署过时强制重做（会重新生成 PSK！客户端要同步改）

开荒参数（第 1 步，会改动 SSH 登录方式）：
  --ssh-port <端口>      开荒后 SSH 使用的端口（默认随机挑 20000-60000）
  --ssh-key <公钥串>     写入服务器的 SSH 公钥
  --ssh-key-file <路径>  从文件读取 SSH 公钥（默认自动从 ~/.ssh/*.pub 找）
  --keep-ssh-port        不改动当前 SSH 端口
  --skip-bootstrap       跳过开荒，只装 Snell（机器已开荒过时用）
  --vps-sh <路径>        指定 vps.sh 路径（默认自动查找/下载）
  --yes                  不再交互确认（无人值守）
  --dry-run              只打印将要做什么，不改动系统
  -h, --help             显示本帮助

例子：
  bash deploy-landing.sh --relay-ip 203.0.113.10
  bash deploy-landing.sh --relay-ip 203.0.113.10 --snell-port 443 --ssh-port 22022
EOF
}

# ============================ 参数解析 ============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-ip)          RELAY_IP="${2:-}";       shift; [[ $# -gt 0 ]] && shift || true ;;
    --snell-port)        SNELL_PORT="${2:-}";     shift; [[ $# -gt 0 ]] && shift || true ;;
    --psk)               SNELL_PSK="${2:-}";      shift; [[ $# -gt 0 ]] && shift || true ;;
    --force)             FORCE=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --ssh-port)          SSH_PORT="${2:-}";       shift; [[ $# -gt 0 ]] && shift || true ;;
    --ssh-key)           SSH_KEY="${2:-}";        shift; [[ $# -gt 0 ]] && shift || true ;;
    --ssh-key-file)      SSH_KEY_FILE="${2:-}";   shift; [[ $# -gt 0 ]] && shift || true ;;
    --keep-ssh-port)     KEEP_SSH_PORT=1; shift ;;
    --skip-bootstrap)    SKIP_BOOTSTRAP=1; shift ;;
    --vps-sh)            VPS_SH="${2:-}";         shift; [[ $# -gt 0 ]] && shift || true ;;
    --yes|-y)            BOOTSTRAP_YES=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   err "未知参数：$1"; usage; exit 1 ;;
  esac
done

# ============================ 开荒：辅助函数 ============================

need_cmd() { command -v "$1" >/dev/null 2>&1; }

rand_port_between() {
  local min="$1" max="$2"
  if command -v shuf >/dev/null 2>&1; then
    shuf -i "${min}-${max}" -n 1
  else
    printf '%d' $(( min + ( ((RANDOM << 15) | RANDOM) % (max - min + 1) ) ))
  fi
}

locate_vps_sh() {
  local d=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || d=""
    if [[ -n "$d" && -r "$d/vps.sh" ]]; then VPS_SH="$d/vps.sh"; return 0; fi
  fi
  if [[ -r "./vps.sh" ]]; then VPS_SH="$(pwd)/vps.sh"; return 0; fi
  return 1
}

fetch_vps_sh() {
  local tmp="" out=""
  tmp="$(mktemp -d)"
  out="$tmp/vps.sh"
  info "本地没有 vps.sh，从仓库下载：$VPS_SH_URL"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 -o "$out" "$VPS_SH_URL" || true; fi
  if [[ ! -s "$out" ]] && command -v wget >/dev/null 2>&1; then wget -q -O "$out" "$VPS_SH_URL" || true; fi
  [[ -s "$out" ]] || die "下载 vps.sh 失败，请手动把它放到本脚本同目录后重试。"
  VPS_SH="$out"
  info "vps.sh 已就绪：$VPS_SH"
}

# 读取 sshd 当前「生效」的端口列表（空格分隔）。
# 必须容错：本脚本开着 pipefail，如果 sshd 不在 PATH 里，
# 管道里第一个命令返回 127 会让整个管道失败，进而被 set -e 直接中断脚本。
sshd_effective_ports() {
  local bin="" p=""
  if command -v sshd >/dev/null 2>&1; then
    bin="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    bin="/usr/sbin/sshd"
  else
    return 0
  fi
  p="$( { "$bin" -T 2>/dev/null || true; } | awk 'tolower($1)=="port"{print $2}' | sort -un )" || true
  printf '%s' "$p" | tr '\n' ' ' | sed 's/ *$//'
}

# 监听套接字（统一封装）。
# ⚠️ `ss` / `netstat` 在「没有任何匹配」时**同样会打印表头**，
# 所以绝不能用「输出是否为空」判断端口占用。这里用状态字段过滤。
# 不使用 ss 的 -H 开关（较新 iproute2 才有，老版本会报错退出）。
listen_lines() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk '$1=="LISTEN"' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | awk '$1 ~ /^tcp/ && $6=="LISTEN"' || true
  fi
}

# 判断端口是否已被监听（LISTEN 行的 $4 就是本地端口）
port_in_use() {
  local port="$1"
  [[ -n "$(listen_lines | awk -v p="$port" '$4 ~ "[.:]"p"$"{print; exit}')" ]]
}

pick_ssh_port() {
  local cand="" i ssh_ports=""
  [[ -n "$SSH_PORT" ]] && return 0
  ssh_ports="$(sshd_effective_ports)"
  for (( i=0; i<50; i++ )); do
    cand="$(rand_port_between "$SSH_PORT_MIN" "$SSH_PORT_MAX")"
    if (( cand == 443 || cand == 80 )); then continue; fi
    if [[ -n "$ssh_ports" ]] && printf ' %s ' "$ssh_ports" | grep -qw "$cand"; then continue; fi
    if port_in_use "$cand"; then continue; fi
    SSH_PORT="$cand"
    return 0
  done
  die "连续 50 次都没挑到可用的 SSH 端口，请用 --ssh-port 手动指定一个。"
}

detect_ssh_pubkey() {
  local f=""
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    if [[ -r "$f" ]]; then SSH_KEY_FILE="$f"; return 0; fi
  done
  for f in "$HOME"/.ssh/*.pub; do
    [[ -r "$f" ]] || continue
    SSH_KEY_FILE="$f"
    return 0
  done
  return 1
}

pubkey_fingerprint() {
  local src="$1" f=""
  command -v ssh-keygen >/dev/null 2>&1 || { printf '(无 ssh-keygen，无法计算)'; return 0; }
  if [[ -r "$src" && "$src" == */* ]]; then
    ssh-keygen -lf "$src" 2>/dev/null | awk '{print $2}'
  else
    f="$(mktemp)"; printf '%s\n' "$src" > "$f"
    ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}'
    rm -f "$f"
  fi
}

# 公钥必须真的能被 ssh-keygen 解析。
# 为什么必须查：开荒在写入公钥的同时会禁用密码登录。如果公钥是「格式看着对
# 但内容坏了」（粘贴截断、Base64 被改坏），它会照常写进 authorized_keys，
# 然后密码登录又被关掉 —— 结果就是彻底锁死在门外。
pubkey_parsable() {
  local src="$1" f="" out=""
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  if [[ -r "$src" && "$src" == */* ]]; then
    out="$(ssh-keygen -lf "$src" 2>/dev/null || true)"
  else
    f="$(mktemp)"; printf '%s\n' "$src" > "$f"
    out="$(ssh-keygen -lf "$f" 2>/dev/null || true)"
    rm -f "$f"
  fi
  [[ -n "$out" ]]
}

# 从终端确认。0=同意，1=不同意或无法询问。
# 优先读 /dev/tty：`curl ... | bash` 时 stdin 是脚本文本本身，绝不能去读它。
# 提示语用 printf '%b' 输出：%s 不解析反斜杠转义，带颜色码时会原样显示成乱码。
ask_confirm() {
  local prompt="$1" ans=""
  if [[ "$BOOTSTRAP_YES" -eq 1 ]]; then return 0; fi
  if [[ -t 0 ]]; then
    printf '%b' "$prompt" >&2
    IFS= read -r ans || ans=""
  elif [[ -r /dev/tty ]]; then
    printf '%b' "$prompt" >&2
    IFS= read -r ans < /dev/tty || ans=""
  else
    return 1
  fi
  [[ "$ans" =~ ^[Yy] ]]
}

# ============================ 第 1 步：开荒 ============================
run_bootstrap() {
  if [[ "$SKIP_BOOTSTRAP" -eq 1 ]]; then
    log "已跳过开荒（--skip-bootstrap），直接安装 Snell"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "dry-run：跳过开荒步骤（不会改动系统）"
    return 0
  fi

  hr
  printf '%s第 1 步 / 共 2 步：开荒%s\n' "$C_B" "$C_0"
  printf '  SSH 加固 / fail2ban / UFW / 日志优化（调用 vps.sh）\n'
  hr

  # 只有在没显式指定 --vps-sh 时才自动查找/下载。
  if [[ -z "$VPS_SH" ]]; then
    locate_vps_sh || fetch_vps_sh
  fi
  [[ -r "$VPS_SH" ]] || die "--vps-sh 指向的文件不存在或不可读：$VPS_SH"

  # 已经开荒过的机器，默认不重复开荒：重复跑要 apt upgrade，还会 ufw --force reset
  if [[ -f "$BOOTSTRAP_MARKER" && "$FORCE" -ne 1 ]]; then
    warn "检测到本机已经开荒过（存在 $BOOTSTRAP_MARKER）。"
    warn "重复开荒会重新 apt upgrade，并 ufw --force reset 清空防火墙规则。"
    if [[ "$BOOTSTRAP_YES" -eq 1 ]]; then
      info "--yes 已指定，继续重新开荒。"
    elif ask_confirm "是否重新开荒？(y/N): "; then
      info "将重新开荒。"
    else
      log "跳过开荒，直接安装 Snell（等价于 --skip-bootstrap）"
      return 0
    fi
  fi

  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "开荒需要 root 权限（sudo bash $0 ...）"

  # --- 决定 SSH 端口 ---
  if [[ "$KEEP_SSH_PORT" -eq 1 ]]; then
    local cur=""
    cur="$(sshd_effective_ports | awk '{print $1}')"
    if [[ -n "$cur" ]] && (( cur >= 1024 && cur <= 65535 )); then
      SSH_PORT="$cur"
      info "已指定 --keep-ssh-port：SSH 端口保持 ${SSH_PORT} 不变"
    else
      warn "当前 SSH 端口是「${cur:-未知}」，开荒脚本不接受 1024 以下的端口。"
      warn "--keep-ssh-port 失效，改为自动随机挑一个。"
      pick_ssh_port
      info "开荒将把 SSH 端口设为：${SSH_PORT}"
    fi
  else
    pick_ssh_port
    info "开荒将把 SSH 端口设为：${SSH_PORT}"
  fi

  # --- 决定 SSH 公钥 ---
  if [[ -z "$SSH_KEY" && -z "$SSH_KEY_FILE" ]]; then
    detect_ssh_pubkey || die "没找到 SSH 公钥。开荒会禁用密码登录，没有可用公钥你会连不上。请用 --ssh-key 或 --ssh-key-file 指定。"
  fi
  local key_src=""
  if [[ -n "$SSH_KEY" ]]; then key_src="$SSH_KEY"; else key_src="$SSH_KEY_FILE"; fi

  if ! pubkey_parsable "$key_src"; then
    die "这个 SSH 公钥无法被 ssh-keygen 解析（可能粘贴不完整或内容被改坏）。
     开荒会同时禁用密码登录，用错公钥会把你彻底锁在门外，因此已中止。
     请检查后用 --ssh-key / --ssh-key-file 重新指定。"
  fi

  hr
  printf '%s请确认开荒参数（这一步会改动 SSH 登录方式）：%s\n' "$C_Y" "$C_0"
  printf '  SSH 端口  : %s\n' "$SSH_PORT"
  printf '  SSH 公钥  : %s\n' "$key_src"
  printf '  公钥指纹  : %s\n' "$(pubkey_fingerprint "$key_src")"
  printf '  密码登录  : 将被禁用（只允许密钥登录）\n'
  hr
  if [[ "$BOOTSTRAP_YES" -ne 1 ]]; then
    if [[ -t 0 || -r /dev/tty ]]; then
      ask_confirm "确认按以上参数开荒？(y/N): " || die "已取消，未做任何改动。"
    else
      die "无法交互确认。请加 --yes 表示你已确认以上参数（无人值守模式）。"
    fi
  fi

  # --- 调用 vps.sh（非交互）---
  local args=()
  args+=(--yes --no-reboot)
  args+=(--ssh-port "$SSH_PORT")
  if [[ -n "$SSH_KEY" ]]; then
    args+=(--ssh-key "$SSH_KEY")
  elif [[ -n "$SSH_KEY_FILE" ]]; then
    args+=(--ssh-key-file "$SSH_KEY_FILE")
  fi

  log "开始开荒：bash ${VPS_SH} ${args[*]}"
  if ! bash "$VPS_SH" "${args[@]}"; then
    die "开荒失败（vps.sh 返回非零）。系统可能处于中间状态，请检查后用 --skip-bootstrap 重跑本脚本。"
  fi

  mkdir -p "$STATE_DIR"
  printf 'bootstrapped_at=%s\nssh_port=%s\n' "$(date -Iseconds)" "${SSH_PORT:-unchanged}" > "$BOOTSTRAP_MARKER"
  chmod 600 "$BOOTSTRAP_MARKER"
  log "开荒完成"
  echo
}

# ============================ 第 2 步：安装 Snell ============================

snell_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    i386|i686)     printf 'i386' ;;
    armv7l)        printf 'armv7l' ;;
    *)             die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

gen_psk() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-20
  else
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20
  fi
}

install_snell() {
  local arch="" url="" tmp="" zip=""

  if [[ -x "$SNELL_BIN" && "$FORCE" -ne 1 ]]; then
    local cur=""
    cur="$("$SNELL_BIN" --version 2>/dev/null | head -n1 || true)"
    info "已安装 snell-server${cur:+（$cur）}，跳过下载（--force 可强制重装）"
    return 0
  fi

  arch="$(snell_arch)"
  url="https://dl.nssurge.com/snell/snell-server-${SNELL_VER}-linux-${arch}.zip"
  info "下载 snell-server ${SNELL_VER}（${arch}）"

  need_cmd unzip || { apt-get update -qq && apt-get install -y -qq unzip; }

  tmp="$(mktemp -d)"
  zip="$tmp/snell.zip"
  if ! curl -fsSL --max-time 120 -o "$zip" "$url"; then
    rm -rf "$tmp"
    die "下载失败：$url
     请检查网络，或手动下载后放到 /usr/local/bin/snell-server。"
  fi
  if ! unzip -o -q "$zip" -d "$tmp"; then
    rm -rf "$tmp"
    die "解压失败（文件可能不完整），请重试。"
  fi
  local bin=""
  bin="$(find "$tmp" -type f -name 'snell-server*' ! -name '*.zip' | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; die "解压后没找到 snell-server 可执行文件。"; }
  install -m 755 "$bin" "$SNELL_BIN"
  rm -rf "$tmp"
  log "snell-server 已安装到 $SNELL_BIN"
}

write_snell_config() {
  mkdir -p "$SNELL_DIR"
  if [[ -f "$SNELL_CONF" && "$FORCE" -ne 1 ]]; then
    # 已存在就沿用原来的 PSK，避免客户端配置失效
    local old=""
    old="$(awk -F= '/^[[:space:]]*psk[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$SNELL_CONF")"
    if [[ -n "$old" ]]; then
      SNELL_PSK="$old"
      info "沿用已有配置里的 PSK（未改动）"
    fi
  fi
  [[ -n "$SNELL_PSK" ]] || SNELL_PSK="$(gen_psk)"

  if [[ -f "$SNELL_CONF" ]]; then
    cp -a "$SNELL_CONF" "${SNELL_CONF}.bak-$(date +%Y%m%d%H%M%S)"
  fi
  cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = true
EOF
  chmod 600 "$SNELL_CONF"
  log "配置已写入 $SNELL_CONF（端口 ${SNELL_PORT}）"
}

setup_snell_service() {
  cat > /etc/systemd/system/snell-server.service <<'EOF'
[Unit]
Description=Snell Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable snell-server >/dev/null 2>&1 || true
  if ! systemctl restart snell-server; then
    err "snell-server 启动失败，最近日志："
    journalctl -u snell-server -n 20 --no-pager 2>/dev/null || true
    die "请把上面日志发给开发者。"
  fi
  sleep 1
  if ! systemctl is-active --quiet snell-server; then
    err "snell-server 未能保持运行，最近日志："
    journalctl -u snell-server -n 20 --no-pager 2>/dev/null || true
    die "请把上面日志发给开发者。"
  fi
  log "snell-server 已启动并设为开机自启"
}

configure_firewall() {
  command -v ufw >/dev/null 2>&1 || { warn "没有 ufw，跳过防火墙配置"; return 0; }
  if [[ -n "$RELAY_IP" ]]; then
    ufw allow from "$RELAY_IP" to any port "$SNELL_PORT" proto tcp >/dev/null 2>&1 || true
    log "防火墙：只放行中转机 ${RELAY_IP} 访问 ${SNELL_PORT}/tcp（落地机对外隐形）"
  else
    ufw allow "${SNELL_PORT}/tcp" >/dev/null 2>&1 || true
    warn "未指定 --relay-ip，${SNELL_PORT}/tcp 对全网开放。"
    warn "建议加上 --relay-ip <中转机IP> 重跑，让落地机对外隐形。"
  fi
}

enable_bbr() {
  local avail=""
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ "$avail" != *bbr* ]]; then
    warn "内核未提供 BBR，跳过拥塞控制优化（不影响功能）"
    return 0
  fi
  cat > /etc/sysctl.d/99-bbk-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  log "已开启 BBR（拥塞控制 bbr + 队列 fq）"
}

public_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS --max-time 8 "$u" 2>/dev/null || true)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# ============================ 主流程 ============================
main() {
  hr
  printf '%s落地机（出口端）部署%s  v%s' "$C_B" "$C_0" "$VERSION"
  [[ "$DRY_RUN" -eq 1 ]] && printf '  %s[dry-run]%s' "$C_Y" "$C_0"
  printf '\n'
  hr

  # --- 参数校验 ---
  [[ "$SNELL_PORT" =~ ^[0-9]+$ ]] && (( SNELL_PORT >= 1 && SNELL_PORT <= 65535 )) \
    || die "--snell-port 必须是 1-65535 之间的数字：$SNELL_PORT"

  # 端口占用检查（跳过开荒阶段、dry-run 除外）
  if [[ "$DRY_RUN" -eq 0 && "$SKIP_BOOTSTRAP" -eq 1 ]] && port_in_use "$SNELL_PORT"; then
    if [[ ! -x "$SNELL_BIN" ]]; then
      die "端口 ${SNELL_PORT} 已被其它程序占用，请换一个：--snell-port <端口>"
    fi
  fi

  run_bootstrap

  hr
  printf '%s第 2 步 / 共 2 步：安装 Snell%s\n' "$C_B" "$C_0"
  printf '  落地机对外只跑 snell-server，中转机只做转发不解密\n'
  hr

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "dry-run：以下动作不会真正执行"
    info "  下载并安装 snell-server ${SNELL_VER}（架构 $(snell_arch)）"
    info "  写入 ${SNELL_CONF}（listen 0.0.0.0:${SNELL_PORT}）"
    info "  创建 systemd 服务 snell-server"
    info "  防火墙放行 ${SNELL_PORT}/tcp${RELAY_IP:+（仅限 ${RELAY_IP}）}"
    info "  开启 BBR"
    echo
    log "dry-run 完成，未改动系统"
    hr
    return 0
  fi

  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "安装 Snell 需要 root 权限（sudo bash $0 ...）"

  install_snell
  write_snell_config
  setup_snell_service
  configure_firewall
  enable_bbr

  # --- 验证 ---
  echo
  printf '%s验证%s\n' "$C_B" "$C_0"
  hr
  printf '  %-40s' "1. snell-server 服务状态"
  if systemctl is-active --quiet snell-server; then printf '%sactive%s\n' "$C_G" "$C_0"; else printf '%s未运行%s\n' "$C_R" "$C_0"; fi

  printf '  %-40s' "2. 监听端口"
  local listen=""
  listen="$(listen_lines | awk -v p="$SNELL_PORT" '$4 ~ "[.:]"p"$"' || true)"
  if [[ -n "$listen" ]]; then printf '%s监听中%s\n' "$C_G" "$C_0"; else printf '%s未监听%s\n' "$C_R" "$C_0"; fi

  printf '  %-40s' "3. 出口 IP"
  local myip=""
  myip="$(public_ip || true)"
  printf '%s\n' "${myip:-（无法访问外网，请手动检查）}"

  hr
  log "落地机部署完成"
  hr

  # --- 客户端配置 ---
  local srv=""
  srv="${RELAY_IP:-${myip:-<中转机IP>}}"
  echo
  printf '%s【Surge 配置】把下面这行加进 Surge 的 [Proxy] 段：%s\n' "$C_B" "$C_0"
  echo
  printf '  落地机 = snell, %s, %s, psk=%s, version=5\n' "$srv" "$SNELL_PORT" "$SNELL_PSK"
  echo
  if [[ -n "$RELAY_IP" ]]; then
    printf '%s  服务器地址填的是中转机 %s（客户端连中转机，不直连本机）%s\n' "$C_D" "$RELAY_IP" "$C_0"
  else
    printf '%s  未指定 --relay-ip，上面填的是本机地址。%s\n' "$C_D" "$C_0"
    printf '%s  建议加上 --relay-ip <中转机IP> 重跑，让落地机对外隐形。%s\n' "$C_D" "$C_0"
  fi
  echo
  printf '%s  本机状态文件：%s/state.env（含 PSK，请勿外发）%s\n' "$C_D" "$STATE_DIR" "$C_0"
  hr

  # 落状态文件
  mkdir -p "$STATE_DIR"
  {
    printf '# 由 deploy-landing.sh 生成于 %s\n' "$(date -Iseconds)"
    printf 'SNELL_PORT=%s\n' "$SNELL_PORT"
    printf 'SNELL_PSK=%s\n' "$SNELL_PSK"
    printf 'RELAY_IP=%s\n' "${RELAY_IP:-}"
    printf 'LANDING_IP=%s\n' "${myip:-}"
    printf 'SNELL_VER=%s\n' "$SNELL_VER"
  } > "$STATE_DIR/state.env"
  chmod 600 "$STATE_DIR/state.env"
}

main "$@"
