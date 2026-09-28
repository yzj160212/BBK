#!/usr/bin/env bash
#
# deploy-relay.sh — 中转机（入口端）一键部署
#
#   = 开荒（vps.sh：SSH 加固 / fail2ban / UFW / 日志优化）
#   + 纯 TCP/UDP 转发（iptables DNAT），把客户端流量原样送到落地机的 snell-server
#
# 架构：Surge --Snell--> 中转机(纯转发，不解密) --> 落地机(snell-server) --> Internet
#
# ⚠️ 本脚本**不安装任何代理软件**，中转机只是一个"透明管道"：
#    Snell 加密是端到端（客户端 <-> 落地机）的，中转机全程看不到内容，
#    因此没有任何加解密开销。
#
# TCP 和 UDP 都转发。UDP 是给 QUIC（HTTP/3）用的 —— Snell v5 的 QUIC Proxy Mode
# 走的是 UDP over UDP，只转发 TCP 会让这类流量失败并回退到 TCP，每次连接慢一拍。
#
# ============================ 两种转发模式（--mode）============================
#
#   --mode dnat（默认）      内核态 iptables DNAT。客户端与落地机是**一条端到端 TCP**。
#                            · 优点：零用户态开销、不需要额外组件
#                            · 缺点：leg1/leg2 的丢包会**互相拖累**（端到端拥塞控制）
#
#   --mode userspace        用户态转发（gost）。中转机终结客户端 TCP，另开一条到落地机。
#                            · 优点：**两条 TCP 独立**，丢包互不影响；中转机缓冲区能吸收抖动
#                            · 缺点：多一个组件、有用户态拷贝开销
#
#   ⚠️ 两者的**延迟基本一样**（数据路径的逻辑往返距离都是 leg1+leg2），
#      差别在丢包链路上的吞吐和抗抖动。选哪个看实测：
#          mtr -rwzc 50 <落地机IP>     # 在中转机上跑，看 leg2 丢包
#      丢包 ≈ 0 → dnat 够用；有持续丢包 → userspace 明显更好。
#
#   ⚠️ 两种模式**互斥**：脚本会自动清掉另一种模式的配置，不会出现两套并存
#      （否则 DNAT 会在 PREROUTING 就截走流量，gost 永远收不到包，排查起来很费劲）。
#
# 用法：
#   bash deploy-relay.sh --landing-ip <落地机公网IP>
#   bash deploy-relay.sh --landing-ip <落地机IP> --landing-port 6160 --listen-port 6160
#   bash deploy-relay.sh --skip-bootstrap --landing-ip <落地机IP>   # 已开荒过的机器
#   bash deploy-relay.sh --help
#
# 配套脚本：deploy-landing.sh（在落地机上运行）
#
set -euo pipefail

VERSION="1.0.0"

# ============================ 开荒参数（第 1 步，传给 vps.sh）============================
VPS_SH=""
VPS_SH_URL="https://raw.githubusercontent.com/yzj160212/BBK/main/vps.sh"
SSH_PORT=""
SSH_KEY=""
SSH_KEY_FILE=""
SSH_PORT_MIN=20000
SSH_PORT_MAX=60000
SKIP_BOOTSTRAP=0
KEEP_SSH_PORT=0
BOOTSTRAP_YES=0
BOOTSTRAP_MARKER="/etc/bbk/bootstrap.done"

# ============================ 转发参数（第 2 步）============================
LANDING_IP=""                # 落地机公网 IP（必填）
LANDING_PORT="6160"          # 落地机上 snell-server 的端口
LISTEN_PORT=""               # 中转机对外监听端口；留空 = 与 LANDING_PORT 相同
MODE="dnat"                  # 转发模式：dnat（默认，内核态）| userspace（gost，TCP 分段）
FORCE=0
DRY_RUN=0
STATE_DIR="/etc/bbk"
UFW_BEFORE="/etc/ufw/before.rules"
UFW_DEFAULT="/etc/default/ufw"
SYSCTL_CONF="/etc/sysctl.d/99-bbk-forward.conf"
MARK_BEGIN="# BEGIN BBK-RELAY"
MARK_END="# END BBK-RELAY"
GOST_VER="3.3.0"
GOST_BIN="/usr/local/bin/gost"
GOST_UNIT="/etc/systemd/system/bbk-gost.service"

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
deploy-relay.sh v1.0.0 — 中转机（入口端）一键部署（开荒 + 纯 TCP/UDP 转发）

中转机不安装任何代理软件，只做 iptables DNAT 转发：
客户端连中转机的端口，流量被原样送到落地机的 snell-server，中转机不解密。
TCP 和 UDP 都转发 —— UDP 是为了让 QUIC（HTTP/3）能正常走 UDP-over-UDP，
不然这类流量会失败并回退到 TCP，每次连接都慢一拍。

转发参数：
  --landing-ip <IP>      落地机公网 IP（必填）
  --landing-port <端口>  落地机上 snell-server 的端口（默认 6160）
  --listen-port <端口>   中转机对外监听端口（默认与 --landing-port 相同，
                         这样客户端配置只需改 IP、不用改端口）
  --mode <模式>          转发方式，二选一（默认 dnat）：
                           dnat       内核态 iptables DNAT，零额外组件。
                                      客户端与落地机是一条端到端 TCP，
                                      leg1/leg2 的丢包会互相拖累。
                           userspace  用户态转发（gost），两条 TCP 独立，
                                      丢包互不影响、能吸收抖动。多一个组件。

                         ⚠️ 两者延迟基本一样，差别在丢包链路下的吞吐。
                            建议先在中转机跑 `mtr -rwzc 50 <落地机IP>` 看 leg2 丢包：
                            丢包 ≈ 0 用 dnat；有持续丢包用 userspace。
                            两种模式互斥，重跑会自动清掉另一种。

开荒参数（第 1 步，会改动 SSH 登录方式）：
  --ssh-port <端口>      开荒后 SSH 使用的端口（默认随机挑 20000-60000）
  --ssh-key <公钥串>     写入服务器的 SSH 公钥
  --ssh-key-file <路径>  从文件读取 SSH 公钥（默认自动从 ~/.ssh/*.pub 找）
  --keep-ssh-port        不改动当前 SSH 端口
  --skip-bootstrap       跳过开荒，只配置转发（机器已开荒过时用）
  --vps-sh <路径>        指定 vps.sh 路径（默认自动查找/下载）
  --yes                  不再交互确认（无人值守）
  --dry-run              只打印将要做什么，不改动系统
  -h, --help             显示本帮助

例子：
  bash deploy-relay.sh --landing-ip 198.51.100.20
  bash deploy-relay.sh --landing-ip 198.51.100.20 --listen-port 6160
  bash deploy-relay.sh --landing-ip 198.51.100.20 --mode userspace
EOF
}

# ============================ 参数解析 ============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --landing-ip)        LANDING_IP="${2:-}";     shift; [[ $# -gt 0 ]] && shift || true ;;
    --landing-port)      LANDING_PORT="${2:-}";   shift; [[ $# -gt 0 ]] && shift || true ;;
    --listen-port)       LISTEN_PORT="${2:-}";    shift; [[ $# -gt 0 ]] && shift || true ;;
    --mode)              MODE="${2:-}";           shift; [[ $# -gt 0 ]] && shift || true ;;
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

# UDP 监听套接字。注意 UDP 的 State 列是 UNCONN 而不是 LISTEN，
# 所以不能复用 listen_lines()（那个按 $1=="LISTEN" 过滤）。
udp_listen_lines() {
  if command -v ss >/dev/null 2>&1; then
    ss -lunp 2>/dev/null | awk 'NR>1' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ulnp 2>/dev/null | awk '$1 ~ /^udp/' || true
  fi
}

# 判断某 UDP 端口是否在监听（用户态模式下用来确认 gost 的 UDP 通道起来了）
udp_port_listening() {
  local port="$1"
  [[ -n "$(udp_listen_lines | awk -v p="$port" '$4 ~ "[.:]"p"$"{print; exit}')" ]]
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
    log "已跳过开荒（--skip-bootstrap），直接配置转发"
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

  if [[ -z "$VPS_SH" ]]; then
    locate_vps_sh || fetch_vps_sh
  fi
  [[ -r "$VPS_SH" ]] || die "--vps-sh 指向的文件不存在或不可读：$VPS_SH"

  # 已经开荒过的机器，默认不重复开荒：重复跑要 apt upgrade，还会 ufw --force reset
  if [[ -f "$BOOTSTRAP_MARKER" && "$FORCE" -ne 1 ]]; then
    warn "检测到本机已经开荒过（存在 $BOOTSTRAP_MARKER）。"
    warn "重复开荒会重新 apt upgrade，并 ufw --force reset 清空防火墙规则"
    warn "（随后本脚本会重新写入转发规则，但没必要多跑一遍）。"
    if [[ "$BOOTSTRAP_YES" -eq 1 ]]; then
      info "--yes 已指定，继续重新开荒。"
    elif ask_confirm "是否重新开荒？(y/N): "; then
      info "将重新开荒。"
    else
      log "跳过开荒，直接配置转发（等价于 --skip-bootstrap）"
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

# ============================ 第 2 步：配置转发 ============================

enable_ip_forward() {
  cat > "$SYSCTL_CONF" <<'EOF'
# BBK 中转机：DNAT 转发必须开启 IPv4 转发
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null 2>&1 || true
  # ufw 启动时也会应用自己的 sysctl，这里一并取消注释，避免两边打架
  if [[ -f /etc/ufw/sysctl.conf ]]; then
    sed -i -E 's|^[[:space:]]*#?[[:space:]]*net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
  fi
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
    log "已开启 IP 转发（net.ipv4.ip_forward=1）"
  else
    die "无法开启 IP 转发，请检查内核配置。"
  fi
}

# 允许 ufw 转发。
# ⚠️ 这一步是必须的：ufw 默认 DEFAULT_FORWARD_POLICY="DROP"，
#    会把 DNAT 之后的转发包全部丢掉 —— 表现为「端口能连上但立刻断」，
#    极难排查。中转机只有一块网卡，转发只会发生在 DNAT 的流量上，放开是安全的。
allow_ufw_forward() {
  [[ -f "$UFW_DEFAULT" ]] || die "找不到 $UFW_DEFAULT，中转机需要 ufw（开荒脚本会安装）。"
  if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY=' "$UFW_DEFAULT"; then
    sed -i -E 's|^[[:space:]]*DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' "$UFW_DEFAULT"
  else
    printf 'DEFAULT_FORWARD_POLICY="ACCEPT"\n' >> "$UFW_DEFAULT"
  fi
  if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY="ACCEPT"' "$UFW_DEFAULT"; then
    log "已允许 ufw 转发（DEFAULT_FORWARD_POLICY=ACCEPT）"
  else
    die "写入 DEFAULT_FORWARD_POLICY 失败，请检查 $UFW_DEFAULT"
  fi
}

# 判断某协议的 DNAT 规则是否已生效（$1 = tcp 或 udp）
#
# ⚠️ 不能用 `grep -- "-p tcp --dport 6160 -j DNAT"` 这种死板的写法：
#    `iptables -S` 会把匹配模块也打印出来，实际行长这样 ——
#        -A PREROUTING -p tcp -m tcp --dport 6160 -j DNAT --to-destination ...
#    中间多了个 `-m tcp`，死板模式永远匹配不上 → **规则明明生效了也报「没生效」**，
#    然后脚本 die 掉，后面的步骤（关 80/443 等）全都不会执行。
#    这里改成用 awk 分别检查三个特征，容忍中间插入的模块参数。
dnat_rule_present() {
  local proto="$1"
  iptables -t nat -S PREROUTING 2>/dev/null | awk -v p="$proto" -v d="$LISTEN_PORT" '
    index($0, "-p " p " ") && index($0, "--dport " d " ") && index($0, "-j DNAT") { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

# 把 DNAT / MASQUERADE 规则写进 /etc/ufw/before.rules。
# 为什么写这里而不是直接 iptables：`ufw reload` 会清空并重建整张表，
# 直接加的规则会丢；写在 before.rules 里才能扛住 reload 和重启。
# 带 BEGIN/END 标记，重复执行会替换旧块而不是叠加。
apply_dnat_rules() {
  [[ -f "$UFW_BEFORE" ]] || die "找不到 $UFW_BEFORE，中转机需要 ufw（开荒脚本会安装）。"
  cp -a "$UFW_BEFORE" "${UFW_BEFORE}.bak-$(date +%Y%m%d%H%M%S)"

  local tmp="" blk=""
  tmp="$(mktemp)"; blk="$(mktemp)"

  # 先剥掉旧块（幂等）
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$UFW_BEFORE" > "$tmp"

  cat > "$blk" <<EOF
${MARK_BEGIN}
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport ${LISTEN_PORT} -j DNAT --to-destination ${LANDING_IP}:${LANDING_PORT}
-A PREROUTING -p udp --dport ${LISTEN_PORT} -j DNAT --to-destination ${LANDING_IP}:${LANDING_PORT}
-A POSTROUTING -p tcp -d ${LANDING_IP} --dport ${LANDING_PORT} -j MASQUERADE
-A POSTROUTING -p udp -d ${LANDING_IP} --dport ${LANDING_PORT} -j MASQUERADE
COMMIT
${MARK_END}
EOF

  cat "$blk" "$tmp" > "$UFW_BEFORE"
  rm -f "$tmp" "$blk"
  log "已写入转发规则：${LISTEN_PORT}（TCP + UDP）  ->  ${LANDING_IP}:${LANDING_PORT}"
}

reload_ufw() {
  if ! ufw reload >/dev/null 2>&1; then
    warn "ufw reload 失败，尝试 restart"
    systemctl restart ufw >/dev/null 2>&1 || true
  fi
  sleep 1
  if dnat_rule_present tcp && dnat_rule_present udp; then
    log "转发规则已生效（TCP + UDP）"
  else
    err "转发规则没有完整生效，当前 nat PREROUTING："
    iptables -t nat -S PREROUTING 2>/dev/null | sed 's/^/    /' || true
    die "请把上面内容发给开发者。"
  fi
}

# 从本机探测转发是否真的通（连自己的公网端口，应能握手到落地机的 snell）
selftest_forward() {
  local myip="" out=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    myip="$(curl -fsS --max-time 8 "$u" 2>/dev/null || true)"
    [[ -n "$myip" ]] && break
  done
  [[ -n "$myip" ]] || { info "无法探测公网 IP，跳过转发自检"; return 0; }

  if timeout 6 bash -c "exec 3<>/dev/tcp/${myip}/${LISTEN_PORT}" 2>/dev/null; then
    printf '  %-40s%s可连通%s\n' "6. 转发链路自检（${LISTEN_PORT}）" "$C_G" "$C_0"
  else
    printf '  %-40s%s连不上（客户端仍可能可用，请以客户端实测为准）%s\n' \
      "6. 转发链路自检（${LISTEN_PORT}）" "$C_Y" "$C_0"
  fi
}

# ============================ 用户态转发（gost）============================

# gost 的资产命名和 snell 不一样：amd64 / arm64 / 386 / armv7
gost_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    i386|i686)     printf '386' ;;
    armv7l)        printf 'armv7' ;;
    *)             die "gost 不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

install_gost() {
  if [[ -x "$GOST_BIN" && "$FORCE" -ne 1 ]]; then
    info "已安装 gost（$("$GOST_BIN" -V 2>/dev/null | head -n1 || echo 未知版本)），跳过下载（--force 可强制重装）"
    return 0
  fi
  local arch="" url="" tmp="" tgz="" bin=""
  arch="$(gost_arch)"
  url="https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_linux_${arch}.tar.gz"
  info "下载 gost v${GOST_VER}（${arch}）"
  need_cmd tar || { apt-get update -qq && apt-get install -y -qq tar; }
  tmp="$(mktemp -d)"; tgz="$tmp/gost.tar.gz"
  if ! curl -fsSL --max-time 120 -o "$tgz" "$url"; then
    rm -rf "$tmp"
    die "下载失败：$url
     中转机需要能访问 GitHub。若网络不通，可手动下载后把 gost 放到 $GOST_BIN。"
  fi
  tar -xzf "$tgz" -C "$tmp" || { rm -rf "$tmp"; die "解压失败（文件可能不完整），请重试。"; }
  bin="$(find "$tmp" -type f -name gost | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; die "解压后没找到 gost 可执行文件。"; }
  install -m 755 "$bin" "$GOST_BIN"
  rm -rf "$tmp"
  log "gost 已安装到 $GOST_BIN"
}

write_gost_service() {
  cat > "$GOST_UNIT" <<EOF
[Unit]
Description=BBK gost TCP/UDP forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -L tcp://:${LISTEN_PORT}/${LANDING_IP}:${LANDING_PORT} -L udp://:${LISTEN_PORT}/${LANDING_IP}:${LANDING_PORT}
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable bbk-gost >/dev/null 2>&1 || true
  if ! systemctl restart bbk-gost; then
    err "gost 启动失败，最近日志："
    journalctl -u bbk-gost -n 20 --no-pager 2>/dev/null || true
    die "请把上面日志发给开发者。"
  fi
  sleep 1
  if ! systemctl is-active --quiet bbk-gost; then
    err "gost 未能保持运行，最近日志："
    journalctl -u bbk-gost -n 20 --no-pager 2>/dev/null || true
    die "请把上面日志发给开发者。"
  fi
  log "gost 已启动并设为开机自启（${LISTEN_PORT} TCP+UDP -> ${LANDING_IP}:${LANDING_PORT}）"
}

# 用户态转发时流量是投递到本机套接字（走 INPUT 链），
# 所以必须在 ufw 放行监听端口 —— 这点和 DNAT（走 FORWARD 链）完全不同，
# 忘了放行会表现为「端口完全连不上」。
allow_relay_port_input() {
  command -v ufw >/dev/null 2>&1 || { warn "没有 ufw，跳过防火墙配置"; return 0; }
  ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${LISTEN_PORT}/udp" >/dev/null 2>&1 || true
  log "防火墙：放行本机 ${LISTEN_PORT}（TCP + UDP）入站"
}

# 停掉用户态转发（切回 dnat 时用）
stop_gost() {
  if [[ -f "$GOST_UNIT" ]] \
     || systemctl is-enabled bbk-gost >/dev/null 2>&1 \
     || systemctl is-active bbk-gost >/dev/null 2>&1; then
    systemctl disable --now bbk-gost >/dev/null 2>&1 || true
    rm -f "$GOST_UNIT"
    systemctl daemon-reload
    info "已停用并移除用户态转发（bbk-gost）"
  fi
}

# 移除 DNAT 规则块（切到 userspace 时用）
remove_dnat_rules() {
  [[ -f "$UFW_BEFORE" ]] || return 0
  grep -qF "$MARK_BEGIN" "$UFW_BEFORE" || return 0
  cp -a "$UFW_BEFORE" "${UFW_BEFORE}.bak-$(date +%Y%m%d%H%M%S)"
  local tmp=""; tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$UFW_BEFORE" > "$tmp"
  cat "$tmp" > "$UFW_BEFORE"
  rm -f "$tmp"
  ufw reload >/dev/null 2>&1 || systemctl restart ufw >/dev/null 2>&1 || true
  info "已移除原有的 DNAT 转发规则"
}

setup_dnat() {
  enable_ip_forward
  allow_ufw_forward
  apply_dnat_rules
  reload_ufw
  stop_gost              # 互斥：清掉可能存在的用户态转发
}

setup_userspace() {
  install_gost
  write_gost_service
  allow_relay_port_input
  remove_dnat_rules      # 互斥：清掉可能存在的 DNAT 规则
}

# 关掉开荒脚本默认放行的 80 / 443。
# 为什么：开荒脚本是从 Xray 那个项目继承来的，那边 443 是用户入口端口、80 给 ACME 用；
# 而 BBK 用不到这两个端口，留着只是白白增加暴露面。
# 参数 $1 = 本方案自己要用的端口（不能误关）。
# 注意：开荒脚本挑 SSH 端口时会避开 80/443，所以不会误关掉 SSH。
close_web_ports() {
  local keep="${1:-}"
  command -v ufw >/dev/null 2>&1 || return 0
  local p="" removed="" skipped="" still="" seen=0
  for p in 80 443; do
    if [[ "$p" == "$keep" ]]; then skipped="${skipped}${p} "; continue; fi
    if ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]"; then
      seen=1
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || ufw delete allow "${p}" >/dev/null 2>&1 || true
      if ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]"; then
        still="${still}${p} "
      else
        removed="${removed}${p} "
      fi
    fi
  done
  [[ -n "$removed" ]] && log "已关闭开荒默认放行的端口：${removed}（BBK 用不到，减少暴露面）"
  [[ -n "$skipped" ]] && info "保留端口 ${skipped}（本方案自己要用的）"
  [[ -n "$still" ]] && warn "端口 ${still} 未能关闭，请手动执行：ufw delete allow <端口>/tcp"
  [[ "$seen" -eq 0 ]] && info "80/443 本来就未放行"
  return 0
}

# ============================ 主流程 ============================
main() {
  hr
  printf '%s中转机（入口端）部署%s  v%s' "$C_B" "$C_0" "$VERSION"
  [[ "$DRY_RUN" -eq 1 ]] && printf '  %s[dry-run]%s' "$C_Y" "$C_0"
  printf '\n'
  hr

  # --- 参数校验 ---
  [[ -n "$LANDING_IP" ]] || die "缺少 --landing-ip <落地机公网IP>。用法见 --help"
  [[ "$LANDING_IP" =~ ^[0-9A-Za-z._:-]+$ ]] || die "--landing-ip 格式不对：$LANDING_IP"
  [[ "$LANDING_PORT" =~ ^[0-9]+$ ]] && (( LANDING_PORT >= 1 && LANDING_PORT <= 65535 )) \
    || die "--landing-port 必须是 1-65535 之间的数字：$LANDING_PORT"
  [[ -n "$LISTEN_PORT" ]] || LISTEN_PORT="$LANDING_PORT"
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) \
    || die "--listen-port 必须是 1-65535 之间的数字：$LISTEN_PORT"
  case "$MODE" in
    dnat|userspace) ;;
    *) die "--mode 只能是 dnat 或 userspace，收到的是：$MODE" ;;
  esac

  run_bootstrap

  hr
  printf '%s第 2 步 / 共 2 步：配置转发%s\n' "$C_B" "$C_0"
  if [[ "$MODE" == "userspace" ]]; then
    printf '  模式：userspace（gost 用户态转发，两条 TCP 独立，抗丢包）\n'
  else
    printf '  模式：dnat（内核态 iptables 转发，零额外组件）\n'
  fi
  printf '  中转机不装代理软件 —— Snell 加密是端到端的，中转机不解密\n'
  hr

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "dry-run：以下动作不会真正执行"
    if [[ "$MODE" == "userspace" ]]; then
      info "  下载并安装 gost v${GOST_VER}（架构 $(gost_arch)）"
      info "  创建 systemd 服务 bbk-gost：${LISTEN_PORT}（TCP + UDP）-> ${LANDING_IP}:${LANDING_PORT}"
      info "  ufw 放行 ${LISTEN_PORT}（TCP + UDP）入站"
      info "  移除可能存在的 DNAT 规则（两种模式互斥）"
    else
      info "  开启 net.ipv4.ip_forward"
      info "  设置 ${UFW_DEFAULT} 的 DEFAULT_FORWARD_POLICY=ACCEPT"
      info "  在 ${UFW_BEFORE} 写入 DNAT：${LISTEN_PORT}（TCP + UDP）-> ${LANDING_IP}:${LANDING_PORT}"
      info "  ufw reload 并校验规则"
      info "  停用可能存在的用户态转发（两种模式互斥）"
    fi
    info "  关闭开荒默认放行的 80 / 443（BBK 用不到，减少暴露面）"
    echo
    log "dry-run 完成，未改动系统"
    hr
    return 0
  fi

  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "配置转发需要 root 权限（sudo bash $0 ...）"
  need_cmd ufw || die "找不到 ufw，请先执行开荒（它会安装 ufw）。"
  if [[ "$MODE" == "userspace" ]]; then
    setup_userspace
  else
    need_cmd iptables || die "找不到 iptables，请先执行开荒（它会安装 iptables）。"
    setup_dnat
  fi
  close_web_ports "$LISTEN_PORT"

  # --- 验证 ---
  echo
  printf '%s验证%s\n' "$C_B" "$C_0"
  hr
  printf '  %-40s' "1. 转发模式"
  if [[ "$MODE" == "userspace" ]]; then
    printf '%suserspace（gost）%s\n' "$C_G" "$C_0"
  else
    printf '%sdnat（内核态）%s\n' "$C_G" "$C_0"
  fi

  if [[ "$MODE" == "userspace" ]]; then
    printf '  %-40s' "2. gost 服务状态"
    if systemctl is-active --quiet bbk-gost; then printf '%sactive%s\n' "$C_G" "$C_0"; else printf '%s未运行%s\n' "$C_R" "$C_0"; fi

    printf '  %-40s' "3. 监听端口"
    local l_tcp="TCP✗" l_udp="UDP✗"
    if port_in_use "$LISTEN_PORT"; then l_tcp="TCP✓"; fi
    if udp_port_listening "$LISTEN_PORT"; then l_udp="UDP✓"; fi
    if [[ "$l_tcp" == "TCP✓" && "$l_udp" == "UDP✓" ]]; then
      printf '%s%s %s%s\n' "$C_G" "$l_tcp" "$l_udp" "$C_0"
    else
      printf '%s%s %s%s\n' "$C_R" "$l_tcp" "$l_udp" "$C_0"
    fi

    printf '  %-40s' "4. ufw 放行"
    if ufw status 2>/dev/null | grep -q "^${LISTEN_PORT}/tcp"; then
      printf '%s已放行%s\n' "$C_G" "$C_0"
    else
      printf '%s未见放行规则%s\n' "$C_Y" "$C_0"
    fi
  else
    printf '  %-40s' "2. IP 转发"
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
      printf '%s已开启%s\n' "$C_G" "$C_0"
    else
      printf '%s未开启%s\n' "$C_R" "$C_0"
    fi

    printf '  %-40s' "3. ufw 转发策略"
    if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY="ACCEPT"' "$UFW_DEFAULT"; then
      printf '%s已允许%s\n' "$C_G" "$C_0"
    else
      printf '%s仍为 DROP%s\n' "$C_R" "$C_0"
    fi

    printf '  %-40s' "4. DNAT 规则"
    local r_tcp="缺" r_udp="缺"
    if dnat_rule_present tcp; then r_tcp="有"; fi
    if dnat_rule_present udp; then r_udp="有"; fi
    if [[ "$r_tcp" == "有" && "$r_udp" == "有" ]]; then
      printf '%sTCP + UDP 都已写入%s\n' "$C_G" "$C_0"
    else
      printf '%sTCP:%s  UDP:%s%s\n' "$C_R" "$r_tcp" "$r_udp" "$C_0"
    fi
  fi

  printf '  %-40s' "5. 80 / 443 是否已关闭"
  local web_open=""
  if command -v ufw >/dev/null 2>&1; then
    for p in 80 443; do
      [[ "$p" == "$LISTEN_PORT" ]] && continue
      if ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]"; then web_open="${web_open}${p} "; fi
    done
  fi
  if [[ -n "$web_open" ]]; then
    printf '%s仍开放：%s%s\n' "$C_Y" "$web_open" "$C_0"
  else
    printf '%s已关闭%s\n' "$C_G" "$C_0"
  fi

  selftest_forward

  hr
  log "中转机部署完成"
  hr

  # --- 客户端配置 ---
  local myip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    myip="$(curl -fsS --max-time 8 "$u" 2>/dev/null || true)"
    [[ -n "$myip" ]] && break
  done
  echo
  printf '%s【Surge 配置】把下面这行加进 Surge 的 [Proxy] 段：%s\n' "$C_B" "$C_0"
  printf '%s  psk 用落地机脚本输出的那个，这里不需要填%s\n' "$C_D" "$C_0"
  echo
  printf '  落地机 = snell, %s, %s, psk=<落地机脚本输出的PSK>, version=5\n' "${myip:-<中转机IP>}" "$LISTEN_PORT"
  echo
  printf '%s  客户端连中转机 %s:%s，流量被原样转发到落地机 %s:%s%s\n' \
    "$C_D" "${myip:-<本机IP>}" "$LISTEN_PORT" "$LANDING_IP" "$LANDING_PORT" "$C_0"
  echo
  printf '%s  想改端口/换落地机：重跑本脚本即可（规则是幂等的，不会叠加）%s\n' "$C_D" "$C_0"
  printf '%s  想换转发模式：加 --mode userspace 或 --mode dnat 重跑（会自动切换）%s\n' "$C_D" "$C_0"
  hr

  mkdir -p "$STATE_DIR"
  {
    printf '# 由 deploy-relay.sh 生成于 %s\n' "$(date -Iseconds)"
    printf 'MODE=%s\n' "$MODE"
    printf 'RELAY_IP=%s\n' "${myip:-}"
    printf 'LISTEN_PORT=%s\n' "$LISTEN_PORT"
    printf 'LANDING_IP=%s\n' "$LANDING_IP"
    printf 'LANDING_PORT=%s\n' "$LANDING_PORT"
  } > "$STATE_DIR/state-relay.env"
  chmod 600 "$STATE_DIR/state-relay.env"
}

main "$@"
