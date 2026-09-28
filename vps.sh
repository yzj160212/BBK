#!/bin/bash

# Debian 12 VPS 设置脚本
# 优化版本，确保与 Debian 12 完全兼容

set -e  # 如果任何命令失败，立即退出

# 设置非交互式模式，避免安装过程中的交互提示
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a  # 自动重启服务，不询问

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志变量
CONFIG_LIST=""

# 函数：打印彩色信息
print_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# 函数：检查命令执行状态
check_command() {
    if [ $? -eq 0 ]; then
        print_info "$1 成功"
        CONFIG_LIST+="✓ $1 成功\n"
    else
        print_error "$1 失败"
        exit 1
    fi
}

# ============================================================================
# 非交互模式支持（由 deploy-a.sh / deploy-b.sh 调用时使用）
# ----------------------------------------------------------------------------
# 设计原则：不传任何参数 = 行为与原来完全一致（纯交互式）。
# 这样 deploy-*.sh 可以无人值守调用，而 vps.sh 单独用也照旧。
# ============================================================================
VPS_SSH_PORT="${VPS_SSH_PORT:-}"
VPS_SSH_PUBLIC_KEY="${VPS_SSH_PUBLIC_KEY:-}"
VPS_SSH_KEY_FILE="${VPS_SSH_KEY_FILE:-}"
VPS_ASSUME_YES="${VPS_ASSUME_YES:-0}"
VPS_NO_REBOOT="${VPS_NO_REBOOT:-0}"
VPS_FORCE_REBOOT="${VPS_FORCE_REBOOT:-0}"
VPS_SKIP_DEBIAN_CHECK="${VPS_SKIP_DEBIAN_CHECK:-0}"

# ============================================================================
# 配置文件下载地址
# ----------------------------------------------------------------------------
# sshd_config / jail.local 从本仓库 raw 地址下载。
# 好处：只改仓库里的配置文件就能给所有已分发的 vps.sh 打补丁，不必改脚本。
# ============================================================================
VPS_RAW="${VPS_RAW:-https://raw.githubusercontent.com/yzj160212/BBK/main}"

# 管理员 IP：会被写进 fail2ban 的 ignoreip，永不封禁。
# 为什么需要：本脚本禁用了密码登录 + 开启 aggressive 模式的 fail2ban，
#   任何一次「未完成密钥认证的断开」都会计为失败。管理员自己调试时
#   很容易在 3 次之内把自己的出口 IP 封掉（实测踩过：整个局域网被锁死）。
# 留空则不加。可用 --admin-ip 传入，也可用 VPS_ADMIN_IP 环境变量。
VPS_ADMIN_IP="${VPS_ADMIN_IP:-}"

# 从终端读一行。
# 为什么不用裸 read：`curl ... | bash` 时 bash 自己正在从 stdin 读脚本，
# 如果脚本里的 read 也去读 stdin，会把还没执行的脚本文本吃掉 —— 灾难。
# 所以 stdin 不是终端时，一律改从 /dev/tty 读。
vps_read_tty() {
    local __var="$1" __prompt="$2" __val=""
    # ⚠️ 必须用 %b 而不是 %s。
    #    提示语里带颜色码（$GREEN / $NC 的值是字面量 "\033[0;32m" 这种反斜杠转义），
    #    而 printf '%s' 不解析反斜杠转义，会把 "\033[0;32m" 原样打印到终端上，
    #    用户看到的就是一串乱码般的 "\033[0;32m请输入...\033[0m"。%b 才会解析。
    #    注意：下面回写变量的那句必须保持 %s —— 用户输入的内容里若含反斜杠，
    #    绝不能被解释成转义。
    if [[ -t 0 ]]; then
        printf '%b' "$__prompt" >&2
        IFS= read -r __val || __val=""
    elif [[ -r /dev/tty ]]; then
        printf '%b' "$__prompt" >&2
        IFS= read -r __val < /dev/tty || __val=""
    else
        # 既没有终端也没有 stdin —— 交给调用方按默认值处理
        printf '%b' "$__prompt" >&2
        __val=""
    fi
    printf -v "$__var" '%s' "$__val"
}

# 是否具备「能问用户」的条件
vps_can_ask() {
    [[ -t 0 || -r /dev/tty ]]
}

# 确认对话框。--yes 时直接返回 0；无法询问时返回 1（调用方决定默认动作）
vps_confirm() {
    local prompt="$1" ans=""
    if [[ "$VPS_ASSUME_YES" == "1" ]]; then
        return 0
    fi
    if ! vps_can_ask; then
        return 1
    fi
    vps_read_tty ans "${prompt} (y/N): "
    [[ "$ans" =~ ^[Yy]$ ]]
}

# 校验 SSH 公钥格式与长度。合法返回 0，非法返回 1（并打印原因）。
# 抽成函数是为了让「交互输入」和「命令行/文件指定」两条路径共用同一套规则，
# 避免以后只改一处造成行为不一致。
vps_pubkey_valid() {
    local key="$1" key_length="" key_type=""
    if [[ -z "$key" ]]; then
        print_error "SSH 公钥为空"
        return 1
    fi
    if [[ ! "$key" =~ ^ssh-(rsa|dss|ecdsa|ed25519)[[:space:]]+[A-Za-z0-9+/]+=*[[:space:]]*.*$ ]]; then
        print_error "SSH 公钥格式无效，公钥应该以 'ssh-rsa', 'ssh-ed25519', 'ssh-ecdsa' 等开头"
        return 1
    fi
    key_length=${#key}
    key_type=$(echo "$key" | awk '{print $1}')
    case "$key_type" in
        "ssh-ed25519")
            if [ "$key_length" -gt 50 ] && [ "$key_length" -lt 200 ]; then
                print_info "SSH ed25519 公钥验证通过"
                return 0
            fi
            print_error "SSH ed25519 公钥长度异常 ($key_length 字符)，请检查公钥完整性"
            return 1
            ;;
        "ssh-rsa")
            if [ "$key_length" -gt 200 ] && [ "$key_length" -lt 1000 ]; then
                print_info "SSH RSA 公钥验证通过"
                return 0
            fi
            print_error "SSH RSA 公钥长度异常 ($key_length 字符)，请检查公钥完整性"
            return 1
            ;;
        "ssh-ecdsa")
            if [ "$key_length" -gt 100 ] && [ "$key_length" -lt 500 ]; then
                print_info "SSH ECDSA 公钥验证通过"
                return 0
            fi
            print_error "SSH ECDSA 公钥长度异常 ($key_length 字符)，请检查公钥完整性"
            return 1
            ;;
        *)
            if [ "$key_length" -gt 50 ] && [ "$key_length" -lt 1000 ]; then
                print_info "SSH 公钥验证通过"
                return 0
            fi
            print_error "SSH 公钥长度异常 ($key_length 字符)，请检查公钥完整性"
            return 1
            ;;
    esac
}

# 解析 sshd 可执行文件路径（/usr/sbin 不一定在 PATH 里）
vps_sshd_bin() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s' /usr/sbin/sshd
    else
        printf '%s' ""
    fi
}

vps_usage() {
    cat <<'EOF'
vps.sh — Debian 12 VPS 开荒脚本（SSH 加固 + fail2ban + UFW + 日志优化）

不传任何参数时：完全交互式，行为和以前一样。

非交互参数（供 deploy-a.sh / deploy-b.sh 调用）：
  --ssh-port <端口>      直接指定 SSH 端口，跳过交互提问（1024-65535）
  --ssh-key <公钥串>     直接指定 SSH 公钥，跳过交互提问
  --ssh-key-file <路径>  从文件读取 SSH 公钥
  --admin-ip <IP>        把该 IP 加入 fail2ban 白名单（永不封禁），强烈建议填
  --yes                  所有确认一律回答「是」（无人值守）
  --no-reboot            结束时不要重启（deploy-*.sh 默认使用，避免打断后续步骤）
  --reboot               结束时强制重启
  --skip-debian-check    跳过「非 Debian 12」的确认提示
  -h, --help             显示本帮助

对应环境变量：
  VPS_SSH_PORT  VPS_SSH_PUBLIC_KEY  VPS_SSH_KEY_FILE  VPS_ADMIN_IP
  VPS_ASSUME_YES=1  VPS_NO_REBOOT=1  VPS_FORCE_REBOOT=1  VPS_SKIP_DEBIAN_CHECK=1
EOF
}

# 参数解析：只在顶层消费参数，main() 本身不接参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port)          VPS_SSH_PORT="${2:-}"; shift; [[ $# -gt 0 ]] && shift || true ;;
        --ssh-key)           VPS_SSH_PUBLIC_KEY="${2:-}"; shift; [[ $# -gt 0 ]] && shift || true ;;
        --ssh-key-file)      VPS_SSH_KEY_FILE="${2:-}"; shift; [[ $# -gt 0 ]] && shift || true ;;
        --admin-ip)          VPS_ADMIN_IP="${2:-}"; shift; [[ $# -gt 0 ]] && shift || true ;;
        --yes|-y)            VPS_ASSUME_YES=1; shift ;;
        --no-reboot)         VPS_NO_REBOOT=1; shift ;;
        --reboot)            VPS_FORCE_REBOOT=1; VPS_NO_REBOOT=0; shift ;;
        --skip-debian-check) VPS_SKIP_DEBIAN_CHECK=1; shift ;;
        -h|--help)           vps_usage; exit 0 ;;
        *)                   print_error "未知参数：$1"; vps_usage; exit 1 ;;
    esac
done

# 函数：检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 函数：配置 APT 以避免交互式提示
configure_apt_noninteractive() {
    print_info "配置 APT 非交互式模式..."
    
    # 创建 APT 配置文件，自动处理配置文件冲突
    cat > /etc/apt/apt.conf.d/99-noninteractive << 'EOF'
// 非交互式配置，自动处理配置文件冲突
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
}

// 禁用服务重启提示
DPkg::Post-Invoke { "systemctl daemon-reload || true"; };
EOF
    
    # 配置 needrestart 不询问重启服务
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sed -i 's/#$nrconf{restart} = .*/\$nrconf{restart} = '\''a'\'';/' /etc/needrestart/needrestart.conf
    fi
    
    check_command "APT 非交互式配置"
}

# 函数：检查磁盘空间
check_disk_space() {
    print_info "检查磁盘空间..."
    
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    
    print_info "可用磁盘空间: ${available_gb}GB"
    
    if [ "$available_gb" -lt 1 ]; then
        print_warning "磁盘空间不足 1GB，建议清理后再运行脚本"
        print_info "可以运行以下命令清理："
        print_info "sudo apt clean && sudo apt autoclean"
        print_info "sudo journalctl --vacuum-size=50M"
        if [[ "$VPS_ASSUME_YES" == "1" ]]; then
            print_warning "已指定 --yes，忽略磁盘空间警告继续执行"
        else
            local __ans=""
            vps_read_tty __ans "是否继续执行？(y/N): "
            if [[ ! "$__ans" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# 函数：检查网络连接
check_network() {
    print_info "检查网络连接..."
    
    # 检查是否能访问 GitHub（使用更安全的方式）
    if ! timeout 10 wget --spider --quiet --no-check-certificate --user-agent="VPS-Setup-Script/1.0" https://raw.githubusercontent.com/yzj160212/vps/main/sshd_config; then
        print_warning "无法访问 GitHub，配置文件下载可能失败"
        print_info "脚本将使用备用配置继续执行"
    else
        print_info "网络连接正常"
    fi
}

# 函数：检查系统版本
check_debian_version() {
    if [[ "$VPS_SKIP_DEBIAN_CHECK" == "1" ]]; then
        print_warning "已指定 --skip-debian-check，跳过发行版检查"
        return 0
    fi
    if [ -f /etc/debian_version ]; then
        debian_version=$(cat /etc/debian_version)
        print_info "检测到 Debian 版本: $debian_version"
        
        # 检查是否为 Debian 12
        if [[ $debian_version == 12* ]] || grep -q "bookworm" /etc/os-release 2>/dev/null; then
            print_info "确认为 Debian 12，继续执行..."
        else
            print_warning "此脚本专为 Debian 12 优化，当前版本可能存在兼容性问题"
            if [[ "$VPS_ASSUME_YES" == "1" ]]; then
                print_warning "已指定 --yes，忽略版本警告继续执行"
            else
                local __ans=""
                vps_read_tty __ans "是否继续执行？(y/N): "
                if [[ ! "$__ans" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
    else
        print_error "无法检测系统版本，请确认运行在 Debian 系统上"
        exit 1
    fi
}

# 函数：配置 SSH
configure_ssh() {
    local ssh_port="$1"
    local ssh_public_key="$2"
    
    print_info "正在配置 SSH..."
    
    # 备份原始配置
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup_file"
    print_info "SSH 配置已备份到: $backup_file"
    
    # 下载 SSH 配置文件
    if wget -O /etc/ssh/sshd_config "$VPS_RAW/sshd_config"; then
        print_info "SSH 配置文件下载成功"
    else
        print_warning "SSH 配置文件下载失败，使用内置兜底配置"
        # 如果下载失败，恢复备份并手动配置关键选项
        cp "$backup_file" /etc/ssh/sshd_config
        
        # 手动配置关键安全选项
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        # 降低日志级别以减少日志量（低配置VPS优化）
        sed -i 's/^#*LogLevel.*/LogLevel INFO/' /etc/ssh/sshd_config

        # ⚠️ 必须把 MaxStartups 放宽。
        #    仓库里的 sshd_config 用的是 MaxStartups 10:30:60；如果下载失败退回
        #    Debian 默认值也是 10:30:100，都没问题。但如果系统上残留了过窄的值
        #    （例如 5:30:10），公网 IP 被扫描时会频繁触发「超限即直接断连」，
        #    表现为「TCP 能连上、但拿不到 SSH banner」，极难排查。
        sed -i 's/^[[:space:]]*MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
        grep -qE '^[[:space:]]*MaxStartups' /etc/ssh/sshd_config || \
            echo "MaxStartups 10:30:60" >> /etc/ssh/sshd_config
    fi
    
    # 修改 SSH 端口
    sed -i "s/^#*Port.*/Port $ssh_port/" /etc/ssh/sshd_config
    # 确保端口配置生效，如果上面的替换没有匹配到任何行，则添加端口配置
    if ! grep -q "^Port $ssh_port" /etc/ssh/sshd_config; then
        echo "Port $ssh_port" >> /etc/ssh/sshd_config
    fi
    # 针对低配置VPS，降低日志级别（如果配置文件中是VERBOSE）
    sed -i 's/LogLevel VERBOSE/LogLevel INFO/' /etc/ssh/sshd_config
    check_command "SSH 端口修改为 $ssh_port"
    
    # 确保 root 用户的 .ssh 目录存在并设置权限
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # 确保 authorized_keys 文件存在并设置权限
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    
    # 写入公钥（避免重复）
    # 使用更安全的方式检查和添加公钥
    local key_fingerprint=$(echo "$ssh_public_key" | awk '{print $2}')
    
    # 如果 key_fingerprint 为空，使用整个公钥的一部分作为标识
    if [ -z "$key_fingerprint" ]; then
        key_fingerprint=$(echo "$ssh_public_key" | cut -d' ' -f1-2)
    fi
    
    if ! grep -q "$key_fingerprint" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$ssh_public_key" >> /root/.ssh/authorized_keys
        print_info "SSH 公钥已添加"
    else
        print_info "SSH 公钥已存在，跳过添加"
    fi
    
    # 测试 SSH 配置
    local __sshd=""
    __sshd="$(vps_sshd_bin)"
    if [[ -z "$__sshd" ]]; then
        print_warning "未找到 sshd 可执行文件，跳过配置语法检查"
    elif "$__sshd" -t; then
        print_info "SSH 配置语法检查通过"
    else
        print_error "SSH 配置语法错误，请检查"
        exit 1
    fi
}

# 函数：重启 SSH 服务
restart_ssh() {
    print_info "正在重启 SSH 服务..."
    
    # Debian 12 兼容的重启方式
    if systemctl restart ssh; then
        print_info "SSH 服务重启成功"
    elif systemctl restart sshd; then
        print_info "SSH 服务重启成功 (使用 sshd)"
    elif service ssh restart; then
        print_info "SSH 服务重启成功 (使用 service)"
    else
        print_error "SSH 服务重启失败"
        exit 1
    fi
    
    # 检查服务状态
    if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
        print_info "SSH 服务运行正常"
    else
        print_error "SSH 服务未正常运行"
        exit 1
    fi
}

# 函数：把 jail.local 中 [sshd] 段的 port 设成指定端口
# 用 awk 按「当前处于哪个段」来定位，不依赖空格数量，避免静默替换失败。
set_fail2ban_port() {
    local port="$1" f=/etc/fail2ban/jail.local tmp
    [ -f "$f" ] || return 1
    tmp="$(mktemp)"
    awk -v p="$port" '
        /^[[:space:]]*\[/ { in_sshd = ($0 ~ /^[[:space:]]*\[sshd\]/) }
        in_sshd && /^[[:space:]]*port[[:space:]]*=/ { print "port    = " p; next }
        { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    grep -qE "^[[:space:]]*port[[:space:]]*=[[:space:]]*${port}[[:space:]]*$" "$f"
}

# 函数：把管理员 IP 追加进 fail2ban 的 ignoreip（幂等）
# 为什么必须做：本套配置禁用了密码登录，fail2ban 又开了 aggressive 模式，
#   任何一次「未完成密钥认证的断开」都算失败。管理员自己调试（比如换了台机器、
#   密钥没加载、用 BatchMode 探测）很容易在 3 次之内把自己的出口 IP 封掉。
#   实测踩过：把整个局域网的出口 IP 封了 7 天，只能重装系统才能救回来。
add_fail2ban_ignoreip() {
    local ip="$1" f="${2:-/etc/fail2ban/jail.local}" tmp
    [ -n "$ip" ] || return 0
    [ -f "$f" ] || return 1

    if awk -v ip="$ip" '
        /^[[:space:]]*\[/ { in_def = ($0 ~ /^[[:space:]]*\[DEFAULT\]/) }
        in_def && /^[[:space:]]*ignoreip[[:space:]]*=/ {
            n = split($0, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] == ip) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$f"; then
        print_info "  管理员 IP ${ip} 已在 fail2ban 白名单中，跳过"
        return 0
    fi

    tmp="$(mktemp)"
    awk -v ip="$ip" '
        /^[[:space:]]*\[/ { in_def = ($0 ~ /^[[:space:]]*\[DEFAULT\]/) }
        in_def && /^[[:space:]]*ignoreip[[:space:]]*=/ { print $0 " " ip; seen = 1; next }
        { print }
        END { if (!seen) print "ignoreip = 127.0.0.1/8 ::1 " ip }
    ' "$f" > "$tmp" && mv "$tmp" "$f"

    if grep -qF "$ip" "$f"; then
        print_info "  已把管理员 IP ${ip} 加入 fail2ban 白名单（永不封禁）"
        return 0
    fi
    print_warning "  管理员 IP ${ip} 写入 fail2ban 白名单失败"
    return 1
}

# 函数：fail2ban 部署后自检
# 为什么必须自检：fail2ban 最典型的失败模式是「服务正常启动、但完全不封禁」，
# 常见原因有两个，而且都不报错：
#   ① jail.local 里的 port 不是真实 SSH 端口 → 封禁规则打到 22 上，等于没封；
#   ② filter 模式用了默认的 normal → 禁用密码登录后，密钥爆破的日志不计入失败。
# 只能靠实测发现，所以这里用一个保留地址试封一次，直接看 iptables 规则落在哪个端口。
verify_fail2ban() {
    local ssh_port="$1" testip="203.0.113.1" rule="" ok=1

    print_info "fail2ban 自检..."

    if ! systemctl is-active --quiet fail2ban; then
        print_error "  ✗ fail2ban 服务未运行"
        return 1
    fi
    print_info "  ✓ 服务运行中"

    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        print_error "  ✗ sshd jail 未加载"
        return 1
    fi
    print_info "  ✓ sshd jail 已加载"

    # 用 TEST-NET-3 保留地址试封，不会影响任何真实用户，测完立刻解封
    fail2ban-client set sshd banip "$testip" >/dev/null 2>&1
    sleep 1
    rule="$(iptables -S 2>/dev/null | grep -m1 'dports')"
    fail2ban-client set sshd unbanip "$testip" >/dev/null 2>&1

    if printf '%s' "$rule" | grep -q -- "--dports ${ssh_port}"; then
        print_info "  ✓ 封禁规则指向正确端口 ${ssh_port}"
    else
        print_error "  ✗ 封禁规则没有指向 ${ssh_port}"
        print_error "    实际规则：${rule:-（未生成）}"
        print_error "    → 这就是「fail2ban 正常启动但毫无保护」的典型症状，请检查 jail.local 的 port"
        ok=0
    fi

    # filter 模式检查。
    # 必须显式写成 filter = sshd[mode=aggressive] 或 [mode=ddos]。
    # ⚠️ 写成单独一行 "mode = aggressive" 是**无效**的 —— fail2ban 不会把 jail 级的
    #    mode 选项转发给 filter（filter 文件里那句"在 jail 里写 mode = extra"的注释是错的）。
    #    实测：单独写 mode = aggressive 时识别 0 次；写成 sshd[mode=aggressive] 识别 4 次。
    if grep -qE '^[[:space:]]*filter[[:space:]]*=[[:space:]]*sshd\[mode=(aggressive|ddos)\]' /etc/fail2ban/jail.local 2>/dev/null; then
        print_info "  ✓ filter 模式已覆盖密钥爆破场景"
    else
        print_warning "  ! sshd 的 filter 没有指定 mode=aggressive/ddos"
        print_warning "    本机已禁用密码登录，攻击者只能试密钥；默认的 normal 模式不计入"
        print_warning "    「预认证阶段断开连接」，等于密钥爆破永远不会被封禁。"
        print_warning "    正确写法：filter = sshd[mode=aggressive]"
        print_warning "    注意：单独写一行 mode = aggressive 是无效的，必须写在 filter 的方括号里。"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        print_info "  ✓ fail2ban 自检通过"
    else
        print_warning "  ! fail2ban 自检发现问题，见上面标记"
    fi
    return 0
}

# 函数：配置 fail2ban
configure_fail2ban() {
    local ssh_port="$1"
    
    print_info "正在安装和配置 fail2ban..."
    
    # 安装 fail2ban 和相关依赖
    apt install fail2ban iptables -y
    check_command "fail2ban 安装"
    
    # 创建本地配置目录
    mkdir -p /etc/fail2ban
    
    # 确保日志文件存在并配置大小限制
    touch /var/log/auth.log
    chmod 640 /var/log/auth.log
    chown root:adm /var/log/auth.log
    
    # 配置 rsyslog 确保 SSH 日志正确记录
    cat > /etc/rsyslog.d/49-vps-optimize.conf << 'EOF'
# 确保 SSH 认证日志正确记录到 auth.log
auth,authpriv.*                 /var/log/auth.log

# 减少其他不必要的日志（但不影响 SSH 日志）
:msg, contains, "systemd-logind" stop
:msg, contains, "CRON" stop
EOF
    
    # 确保 rsyslog 服务运行
    systemctl enable rsyslog
    systemctl restart rsyslog
    
    # 等待 rsyslog 重启完成，确保日志文件可用
    sleep 3
    
    # 生成一些初始日志内容，确保文件不为空
    logger -p auth.info "fail2ban setup: SSH service configured"
    
    # 创建备用配置的函数
    # ⚠️ 这里的兜底配置必须和仓库里的 jail.local 保持同一套关键参数，否则一旦
    #    下载失败就会静默退化成一个「看着正常、实际毫无保护」的配置：
    #      · filter 必须写 sshd[mode=aggressive]（单独一行 mode = ... 是无效的）
    #      · backend 必须用 systemd（file 后端在 Debian 12 上常常读不到日志）
    #      · bantime 不能太长：7 天会把管理员自己锁死，1 小时足够起到威慑作用
    create_fallback_config() {
        cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

[sshd]
enabled = true
port = $ssh_port
filter = sshd[mode=aggressive]
maxretry = 5
EOF
    }
    
    # 下载你的自定义配置文件
    if wget -O /etc/fail2ban/jail.local "$VPS_RAW/jail.local"; then
        print_info "fail2ban 配置文件下载成功"
        
        # 修改配置文件中的 SSH 端口
        # ⚠️ 早先这里写的是 sed "s/port = ssh/..."，只认「单空格」。
        #    配置文件里一旦对齐成 "port    = ssh" 就替换失败 —— 而失败是静默的，
        #    结果是 fail2ban 把封禁规则打到 22 端口上：服务看着完全正常，
        #    对真实 SSH 端口却毫无保护。改用按段定位、容忍任意空白的写法。
        if set_fail2ban_port "$ssh_port"; then
            print_info "fail2ban SSH 端口已更新为: $ssh_port"
        else
            print_error "fail2ban 的 SSH 端口未能设为 $ssh_port —— 封禁会打到错误端口上！"
        fi
        
        # 验证下载的配置文件
        if ! fail2ban-client -t 2>/dev/null; then
            print_warning "下载的配置文件有问题，使用备用配置"
            create_fallback_config
        fi
    else
        print_warning "fail2ban 配置文件下载失败，使用基础配置"
        create_fallback_config
    fi

    # ------------------------------------------------------------------
    # 白名单：把管理员自己的出口 IP 排除在封禁之外
    # ------------------------------------------------------------------
    # 优先用 --admin-ip 显式指定的；没指定就尝试从当前 SSH 会话推断
    # （SSH_CLIENT="<客户端IP> <客户端端口> <服务端端口>"）。
    # 注意：出口 IP 可能会变（换代理节点、换网络），变了就要重新加一次。
    local __admin_ip="$VPS_ADMIN_IP"
    if [ -z "$__admin_ip" ] && [ -n "${SSH_CLIENT:-}" ]; then
        __admin_ip="$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')"
        [ -n "$__admin_ip" ] && print_info "  从当前 SSH 会话推断管理员 IP：$__admin_ip"
    fi
    if [ -n "$__admin_ip" ]; then
        add_fail2ban_ignoreip "$__admin_ip" || true
    else
        print_warning "  未提供管理员 IP（--admin-ip），fail2ban 白名单里只有内网段。"
        print_warning "  提醒：连续 5 次认证失败会封禁 1 小时，请务必确认密钥可用。"
    fi
    
    # 设置 IPv6 支持。
    # ⚠️ allowipv6 是 fail2ban「主配置」的选项，不是 jail 的选项。
    #    写进 jail.local 只会得到一句 WARNING 且完全不生效（实测过）。
    #    写到 fail2ban.local 覆盖主配置，不动包管理的 fail2ban.conf。
    #    不设的话每次 fail2ban-client -t 都会抱怨：
    #      WARNING 'allowipv6' not defined in 'Definition'. Using default one: 'auto'
    #    （默认值就是 auto，功能上没影响，只是噪音）
    printf '[Definition]\nallowipv6 = auto\n' > /etc/fail2ban/fail2ban.local

    # 验证配置文件
    print_info "验证 fail2ban 配置..."
    if ! fail2ban-client -t 2>/dev/null; then
        print_warning "配置验证失败，使用简化配置"
        create_fallback_config
        
        # 再次验证
        if ! fail2ban-client -t 2>/dev/null; then
            print_warning "使用最基础配置"
            cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
EOF
        fi
    fi
    
    print_info "fail2ban 配置验证完成"
    
    # 启动并启用 fail2ban 服务
    systemctl enable fail2ban
    
    # 确保日志文件有内容后再启动
    if [ ! -s /var/log/auth.log ]; then
        print_info "初始化 auth.log 文件..."
        logger -p auth.info "fail2ban: Initial log entry for SSH monitoring"
        echo "$(date) sshd[$$]: Server listening on 0.0.0.0 port $ssh_port." >> /var/log/auth.log
    fi
    
    # 启动服务
    systemctl start fail2ban
    
    # 等待服务完全启动
    sleep 8
    
    # 验证 fail2ban 是否正常运行
    local retry_count=0
    while [ $retry_count -lt 5 ]; do
        if systemctl is-active --quiet fail2ban; then
            print_info "fail2ban 服务运行正常"
            
            # 等待 jail 完全加载
            sleep 3
            
            # 显示 fail2ban 状态
            if fail2ban-client status 2>/dev/null | grep -q "sshd"; then
                print_info "fail2ban SSH jail 运行正常"
                fail2ban-client status sshd 2>/dev/null || true
            else
                print_warning "fail2ban SSH jail 可能未正确加载"
            fi
            break
        else
            retry_count=$((retry_count + 1))
            print_warning "fail2ban 启动中，等待重试... ($retry_count/5)"
            
            # 查看启动错误
            if [ $retry_count -eq 3 ]; then
                print_info "检查启动错误:"
                journalctl -u fail2ban --no-pager -l --lines=10
            fi
            
            sleep 5
            systemctl restart fail2ban
        fi
    done
    
    if ! systemctl is-active --quiet fail2ban; then
        print_error "fail2ban 服务启动失败"
        print_info "尝试查看服务日志:"
        journalctl -u fail2ban --no-pager -l --lines=20
        print_warning "继续执行脚本，但 fail2ban 保护可能不可用"
        return 1
    else
        print_info "fail2ban 服务启动和启用 成功"
        CONFIG_LIST+="✓ fail2ban 服务启动和启用 成功\n"
    fi
    
    # 确保函数返回成功状态
    return 0
}

# 函数：配置日志轮转和清理（针对低配置VPS优化）
configure_logs() {
    print_info "正在配置日志管理（低配置VPS优化）..."
    
    # 配置 systemd-journald 限制日志大小
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size-limit.conf << 'EOF'
[Journal]
# 小VPS激进优化 - 限制日志总大小为 30MB
SystemMaxUse=30M
# 限制单个日志文件大小
SystemMaxFileSize=5M
# 保留时间 3 天
MaxRetentionSec=3d
# 压缩日志
Compress=yes
# 限制日志级别，减少不必要的日志
MaxLevelStore=info
# 保持持久化存储但限制大小
Storage=persistent
EOF
    
    # 重启 journald 服务应用配置
    systemctl restart systemd-journald
    check_command "systemd 日志配置优化"
    
    # 配置 logrotate 更频繁地轮转日志
    cat > /etc/logrotate.d/vps-optimize << 'EOF'
# 针对低配置VPS的日志轮转优化 - 更激进的清理
/var/log/auth.log {
    daily
    rotate 2
    maxsize 5M
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
        systemctl reload fail2ban > /dev/null 2>&1 || true
    endscript
}

/var/log/fail2ban.log {
    daily
    rotate 2
    maxsize 2M
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    postrotate
        systemctl reload fail2ban > /dev/null 2>&1 || true
    endscript
}

/var/log/syslog {
    daily
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
    create 640 syslog adm
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/ufw.log {
    weekly
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    
    # 立即清理旧日志
    print_info "清理现有大日志文件..."
    journalctl --vacuum-size=30M
    journalctl --vacuum-time=3d
    
    # 清理 apt 缓存
    apt clean
    apt autoclean
    
    # 添加定期清理的 cron 任务
    cat > /etc/cron.weekly/vps-cleanup << 'EOF'
#!/bin/bash
# 每周清理日志和缓存（小VPS激进优化）

# 清理 systemd 日志 - 更激进
journalctl --vacuum-size=20M
journalctl --vacuum-time=3d

# 清理 apt 缓存
apt clean
apt autoclean
apt autoremove -y

# 清理临时文件
find /tmp -type f -atime +3 -delete 2>/dev/null || true
find /var/tmp -type f -atime +3 -delete 2>/dev/null || true

# 清理旧的日志文件
find /var/log -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null || true
find /var/log -name "*.gz" -type f -mtime +7 -delete 2>/dev/null || true

# 清理 fail2ban 数据库（如果太大）
if [ -f /var/lib/fail2ban/fail2ban.sqlite3 ]; then
    sqlite3_size=$(stat -c%s /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null || echo 0)
    if [ "$sqlite3_size" -gt 10485760 ]; then  # 如果大于10MB
        systemctl stop fail2ban
        rm -f /var/lib/fail2ban/fail2ban.sqlite3
        systemctl start fail2ban
    fi
fi

# 记录清理日志（限制大小）
echo "$(date): VPS cleanup completed, freed space: $(df -h / | awk 'NR==2{print $4}')" >> /var/log/vps-cleanup.log

# 严格限制清理日志大小
tail -n 20 /var/log/vps-cleanup.log > /tmp/cleanup.log && mv /tmp/cleanup.log /var/log/vps-cleanup.log
EOF
    
    chmod +x /etc/cron.weekly/vps-cleanup
    
    check_command "日志轮转和清理配置"
}

# 函数：配置防火墙
configure_firewall() {
    local ssh_port="$1"
    
    print_info "正在配置 UFW 防火墙..."
    
    # 安装 UFW
    apt install ufw -y
    check_command "UFW 安装"
    
    # 重置防火墙规则
    ufw --force reset
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许 SSH 端口
    ufw allow "$ssh_port"/tcp
    check_command "放行 SSH 端口 $ssh_port"
    
    # 允许 HTTP 和 HTTPS 端口
    ufw allow 80/tcp
    ufw allow 443/tcp
    check_command "放行 HTTP 和 HTTPS 端口"
    
    # 启用 UFW（非交互式）
    echo "y" | ufw enable
    check_command "UFW 启用"
    
    # 显示防火墙状态
    print_info "防火墙规则:"
    ufw status numbered
}

# 主函数
main() {
    print_info "开始执行 Debian 12 VPS 配置脚本..."
    
    # 检查权限和系统版本
    check_root
    check_debian_version
    check_disk_space
    check_network
    
    # 配置非交互式模式
    configure_apt_noninteractive
    
    # 更新系统
    print_info "正在更新系统..."
    apt update && apt upgrade -y
    check_command "系统更新"
    
    # 安装必要的工具
    print_info "正在安装必要工具..."
    apt install -y wget curl sudo systemd-timesyncd openssh-server rsyslog
    check_command "必要工具安装"
    
    # 确保 SSH 服务已启动并启用
    systemctl enable ssh
    systemctl start ssh
    
    # 更改时区
    print_info "正在设置时区为亚洲/上海..."
    timedatectl set-timezone Asia/Shanghai
    check_command "时区设置"
    
    # 获取用户输入 - SSH 端口
    if [[ -n "$VPS_SSH_PORT" ]]; then
        # 非交互：由 --ssh-port / VPS_SSH_PORT 指定
        if [[ ! "$VPS_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$VPS_SSH_PORT" -lt 1024 ] || [ "$VPS_SSH_PORT" -gt 65535 ]; then
            print_error "--ssh-port 无效：$VPS_SSH_PORT（需为 1024-65535 之间的数字）"
            exit 1
        fi
        # 端口占用检查。注意：如果占用者就是 sshd 自己（重跑场景），不算冲突。
        local __occ=""
        if command -v ss >/dev/null 2>&1; then
            __occ="$(ss -ltnp 2>/dev/null | awk -v p="$VPS_SSH_PORT" '$4 ~ "[.:]"p"$"' || true)"
        elif command -v netstat >/dev/null 2>&1; then
            __occ="$(netstat -tulnp 2>/dev/null | awk -v p="$VPS_SSH_PORT" '$4 ~ "[.:]"p"$"' || true)"
        fi
        if [[ -n "$__occ" ]]; then
            if printf '%s' "$__occ" | grep -qi 'sshd'; then
                print_warning "端口 $VPS_SSH_PORT 当前由 sshd 占用（说明是重跑），按继续处理"
            else
                print_error "端口 $VPS_SSH_PORT 已被其他进程占用，SSH 会起不来，请换一个："
                printf '%s\n' "$__occ"
                exit 1
            fi
        fi
        SSH_PORT="$VPS_SSH_PORT"
        print_info "SSH 端口（非交互指定）: $SSH_PORT"
    else
        # 没有终端就没有输入来源。如果不拦住，下面这个 while true 会
        # 因为「读不到值 -> 校验失败 -> 再读」而无限空转，把日志刷爆。
        if ! vps_can_ask; then
            print_error "需要交互输入 SSH 端口，但当前没有可用终端。"
            print_info "请改用: vps.sh --ssh-port <端口>"
            exit 1
        fi
        while true; do
            vps_read_tty SSH_PORT "${GREEN}请输入自定义 SSH 端口号 (1024-65535，建议使用 10000-65535):${NC} "
            
            # 输入验证
            if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then
                # 检查端口是否被占用
                if netstat -tuln 2>/dev/null | grep -q ":$SSH_PORT " || ss -tuln 2>/dev/null | grep -q ":$SSH_PORT "; then
                    print_warning "端口 $SSH_PORT 可能已被占用，请选择其他端口"
                    continue
                fi
                print_info "SSH 端口设置为: $SSH_PORT"
                break
            else
                print_error "无效的端口号，请输入 1024-65535 之间的数字"
            fi
        done
    fi
    
    # 获取用户输入 - SSH 公钥
    if [[ -z "$VPS_SSH_PUBLIC_KEY" && -n "$VPS_SSH_KEY_FILE" ]]; then
        if [[ -r "$VPS_SSH_KEY_FILE" ]]; then
            VPS_SSH_PUBLIC_KEY="$(cat "$VPS_SSH_KEY_FILE")"
            print_info "已从文件读取 SSH 公钥：$VPS_SSH_KEY_FILE"
        else
            print_error "公钥文件不存在或不可读：$VPS_SSH_KEY_FILE"
            exit 1
        fi
    fi
    
    if [[ -n "$VPS_SSH_PUBLIC_KEY" ]]; then
        SSH_PUBLIC_KEY="$VPS_SSH_PUBLIC_KEY"
        if ! vps_pubkey_valid "$SSH_PUBLIC_KEY"; then
            print_error "非交互指定的 SSH 公钥未通过校验，已中止（避免写错公钥把你锁在门外）"
            exit 1
        fi
        print_info "SSH 公钥（非交互指定）校验通过"
    else
        # 同上：没有终端就没有输入来源，必须拦住，否则 while true 会空转
        if ! vps_can_ask; then
            print_error "需要交互输入 SSH 公钥，但当前没有可用终端。"
            print_info "请改用: vps.sh --ssh-key '<公钥>' 或 vps.sh --ssh-key-file <路径>"
            exit 1
        fi
        while true; do
            vps_read_tty SSH_PUBLIC_KEY "${GREEN}请输入您的 SSH 公钥:${NC} "
            
            if vps_pubkey_valid "$SSH_PUBLIC_KEY"; then
                break
            else
                print_info "示例 RSA: ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host"
                print_info "示例 Ed25519: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host"
                print_info "示例 ECDSA: ssh-ecdsa AAAAE2VjZHNhLXNoYTItbmlzdHA... user@host"
            fi
        done
    fi
    
    # 配置 SSH
    configure_ssh "$SSH_PORT" "$SSH_PUBLIC_KEY"
    
    # 配置 fail2ban
    if configure_fail2ban "$SSH_PORT"; then
        print_info "fail2ban 配置完成"
        verify_fail2ban "$SSH_PORT"
    else
        print_warning "fail2ban 配置可能有问题，但脚本继续执行"
    fi
    
    # 配置防火墙
    configure_firewall "$SSH_PORT"
    
    # 配置日志管理（低配置VPS优化）
    configure_logs
    
    # 重启 SSH 服务（在防火墙配置完成后）
    restart_ssh
    
    # 显示配置摘要
    print_info "=== 配置完成摘要 ==="
    printf "${CONFIG_LIST}"
    
    print_info "=== 重要信息 ==="
    print_warning "SSH 端口已修改为: $SSH_PORT"
    print_warning "请确保在断开连接前，用新端口测试 SSH 连接!"
    print_warning "测试命令: ssh -p $SSH_PORT root@$(hostname -I | awk '{print $1}')"
    print_warning "如果连接失败，可以通过 VPS 控制台恢复访问"
    
    print_info "=== 服务状态 ==="
    echo "SSH 服务状态:"
    systemctl status ssh --no-pager -l | head -3
    echo ""
    echo "fail2ban 服务状态:"
    systemctl status fail2ban --no-pager -l | head -3
    echo ""
    echo "UFW 防火墙状态:"
    ufw status
    echo ""
    echo "磁盘使用情况:"
    df -h / | grep -v Filesystem
    echo ""
    echo "内存使用情况:"
    free -h | grep -E "Mem|Swap"
    echo ""
    echo "日志文件占用情况:"
    echo "auth.log: $(du -h /var/log/auth.log 2>/dev/null | cut -f1 || echo '0K')"
    echo "fail2ban.log: $(du -h /var/log/fail2ban.log 2>/dev/null | cut -f1 || echo '0K')"
    echo "systemd journal: $(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]' || echo '未知')"
    echo "总日志目录: $(du -sh /var/log 2>/dev/null | cut -f1 || echo '未知')"
    
    print_info "脚本执行完成！建议重启系统以确保所有配置生效。"
    if [[ "$VPS_FORCE_REBOOT" == "1" ]]; then
        print_info "已指定 --reboot，系统将在 10 秒后重启..."
        sleep 10
        reboot
    elif [[ "$VPS_NO_REBOOT" == "1" ]]; then
        # deploy-a.sh / deploy-b.sh 走这条分支：绝不能在这里重启，
        # 否则后面的 Xray 部署步骤会被直接打断。
        print_info "已跳过重启（--no-reboot）。请稍后手动执行: sudo reboot"
    else
        local __ans=""
        vps_read_tty __ans "是否立即重启系统？(y/N): "
        if [[ "$__ans" =~ ^[Yy]$ ]]; then
            print_info "系统将在 10 秒后重启..."
            sleep 10
            reboot
        else
            print_info "请稍后手动重启系统: sudo reboot"
        fi
    fi
}

# 执行主函数
main "$@"
