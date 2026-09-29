# BBK

一键部署：**中转机 + 落地机** 的 Snell v5 代理，中转机做纯转发、不解密，延迟最低。

---

## 这是什么

```
Surge 客户端 ──Snell v5──▶ 中转机（纯转发）──▶ 落地机（snell-server）──▶ Internet
```

- **落地机**：跑 `snell-server`，负责真正出网。可以只放行中转机的 IP，对外完全隐形。
- **中转机**：**不安装任何代理软件**，只做纯转发（TCP + UDP）。两种方式可选：
  - `--mode dnat`（默认）：内核态 iptables 转发，零额外组件
  - `--mode userspace`：用户态转发（gost），两条 TCP 独立，抗丢包更好

> UDP 是给 **QUIC（HTTP/3）** 用的 —— 不转发的话这类流量会失败并回退到 TCP，
> 每次访问都慢一拍。详见文末「常见问题」。

**为什么这样最快**：Snell 加密是**端到端**的（客户端 ↔ 落地机），中转机全程看不到内容，
所以没有任何加解密开销，延迟最低。

**客户端配置只改一个 IP**：中转机默认用和落地机相同的端口，所以 Surge 里
把服务器地址从中转机 IP 换成落地机 IP 就行，端口、PSK 都不用动。

---

## 文件

| 文件 | 用途 |
| --- | --- |
| `deploy-landing.sh` | **落地机**一键部署：开荒 + 安装 snell-server v5 |
| `deploy-relay.sh` | **中转机**一键部署：开荒 + 配置纯转发 |
| `vps.sh` | 开荒脚本：SSH 加固 / fail2ban / UFW / 日志优化（被上面两个脚本调用） |
| `sshd_config`、`jail.local` | 开荒用的配置文件（由 `vps.sh` 下载使用） |

---

## 部署

### 第 1 步 · 落地机（出口端）

在落地机上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yzj160212/BBK/main/deploy-landing.sh) \
  --relay-ip <中转机公网IP>
```

跑完会打印一行 **Surge 配置**，**先记下来**（里面有自动生成的 PSK）：

```
落地机 = snell, <中转机IP>, 443, psk=xxxxxxxxxxxxxxxxxxxx, version=5
```

### 第 2 步 · 中转机（入口端）

在中转机上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yzj160212/BBK/main/deploy-relay.sh) \
  --landing-ip <落地机公网IP>
```

跑完也会打印一行 Surge 配置，把 `psk=` 换成**第 1 步记下的那个**即可。

### 第 3 步 · 客户端

把那一行粘进 Surge 的 `[Proxy]` 段：

```
落地机 = snell, <中转机IP>, 443, psk=你的PSK, version=5
```

> 服务器地址填的是**中转机**的 IP，不是落地机的。

---

## 参数

### 通用（两个脚本都有）

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--ssh-port <端口>` | 开荒后 SSH 使用的端口 | 随机（20000-60000） |
| `--ssh-key <公钥>` | 写入服务器的 SSH 公钥 | 自动从 `~/.ssh/*.pub` 找 |
| `--ssh-key-file <路径>` | 从文件读取公钥 | 同上 |
| `--keep-ssh-port` | 不改动当前 SSH 端口 | 关 |
| `--skip-bootstrap` | 跳过开荒，只做部署（机器已开荒过时用） | 关 |
| `--yes` | 不再交互确认（无人值守） | 关 |
| `--dry-run` | 只打印将要做什么，不改动系统 | 关 |

### 落地机（`deploy-landing.sh`）

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--relay-ip <IP>` | 中转机 IP。填了只允许它访问 Snell 端口 | 不填则对全网开放 |
| `--snell-port <端口>` | snell-server 监听端口 | `443` |
| `--psk <密钥>` | 预共享密钥 | 自动生成 |
| `--force` | 已部署过时强制重做（**会换 PSK**） | 关 |

### 中转机（`deploy-relay.sh`）

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--landing-ip <IP>` | **必填**，落地机公网 IP | —— |
| `--landing-port <端口>` | 落地机上 snell-server 的端口 | `443` |
| `--listen-port <端口>` | 中转机对外监听端口 | 与 `--landing-port` 相同 |
| `--mode <模式>` | 转发方式：`dnat` 或 `userspace` | `dnat` |

#### 两种转发模式怎么选

| | `dnat`（默认） | `userspace` |
| --- | --- | --- |
| 实现 | 内核态 iptables DNAT | 用户态转发（gost） |
| 客户端与落地机 | **一条端到端 TCP** | **两条独立 TCP** |
| 延迟 | 基本一样 | 基本一样 |
| 丢包链路的吞吐 | ❌ leg1/leg2 丢包**互相拖累** | ✅ 两条 TCP 独立，**互不影响** |
| 抖动吸收 | ❌ 无 | ✅ 中转机缓冲区能吸收 |
| 额外组件 | 无 | 需要 gost |

**怎么判断该用哪个** —— 在中转机上测 leg2 的丢包：

```bash
apt install -y mtr-tiny
mtr -rwzc 50 <落地机IP>
```

- 全程丢包 ≈ **0%** → `dnat` 够用（更简单）
- 有**持续丢包** → `userspace` 明显更好

> 切换模式就是重跑一次（会自动清掉另一种，不会并存）：
> ```bash
> bash deploy-relay.sh --landing-ip <IP> --mode userspace
> ```

---

## ⚠️ 第一次跑之前必读

开荒会**修改 SSH 端口**并**禁用密码登录**（改为只允许密钥）。所以：

1. 提前准备好你的 **SSH 公钥**（脚本会自动从 `~/.ssh/*.pub` 找）
2. 跑完后**不要关掉当前 SSH 窗口**，另开一个新终端用新端口登录验证
3. 确认能登录后，再关旧窗口

脚本会在动手前把**新 SSH 端口**和**公钥指纹**打印出来让你确认；公钥写错会直接中止。

---

## 验证

### 落地机

```bash
systemctl status snell-server              # 应为 active
ss -ltnp | grep 443                       # TCP 监听（Snell 主通道）
ss -lunp | grep 443                       # UDP 监听（QUIC / HTTP/3 通道）
ufw status                                 # 确认 80/443 已对全网关闭
```

### 中转机

```bash
cat /etc/bbk/state-relay.env               # 看当前用的是哪种模式
```

**`dnat` 模式：**

```bash
sysctl net.ipv4.ip_forward                 # 应为 1
iptables -t nat -S PREROUTING              # 应看到 TCP 和 UDP **各 1 条** DNAT 规则
ufw status                                 # 确认 80/443 已对全网关闭
```

> 如果看到 2 条以上（重复），重跑一次脚本即可 —— 脚本会先清掉内核里的残留再重建。

### 内核参数（两台机器都会自动设置）

```bash
sysctl net.netfilter.nf_conntrack_max                # 应为 65536（默认只有 8192）
sysctl net.core.netdev_max_backlog                   # 应为 16384（默认 1000）
sysctl net.core.rmem_max                             # 应为 16777216（默认 208KB）
cat /etc/sysctl.d/99-bbk-net.conf                    # 全部参数
```

**`userspace` 模式：**

```bash
systemctl status bbk-gost                  # 应为 active
ss -ltnp | grep 443                       # TCP 监听
ss -lunp | grep 443                       # UDP 监听
ufw status                                 # 确认 80/443 已对全网关闭
```

### 客户端

Surge 里切到该节点，访问 `https://api.ipify.org`，返回的应该是**落地机的 IP**。

---

## 常用操作

**换端口 / 换落地机**：重跑对应脚本即可，转发规则是幂等的，不会叠加。

**查看已部署的参数**：

```bash
cat /etc/bbk/state.env          # 落地机：端口 + PSK
cat /etc/bbk/state-relay.env    # 中转机：端口 + 落地机地址
```

**卸载**：

```bash
# 落地机
systemctl disable --now snell-server
rm -f /etc/systemd/system/snell-server.service /usr/local/bin/snell-server
rm -rf /etc/snell /etc/bbk
systemctl daemon-reload

# 中转机
systemctl disable --now bbk-gost 2>/dev/null
rm -f /etc/systemd/system/bbk-gost.service /usr/local/bin/gost
systemctl daemon-reload
ufw disable && ufw --force reset && ufw enable
rm -f /etc/sysctl.d/99-bbk-forward.conf
sed -i '/^# BEGIN BBK-RELAY$/,/^# END BBK-RELAY$/d' /etc/ufw/before.rules
ufw reload
rm -rf /etc/bbk
```

---

## 常见问题

**Q：为什么 TCP 和 UDP 都要转发？**
UDP 是给 **QUIC（HTTP/3）** 用的。Snell v5 的 QUIC 流量走的是 **UDP over UDP**，
只转发 TCP 会让这类流量失败并回退到 TCP —— 表现为访问用 HTTP/3 的站点时每次连接慢一拍。
其他 UDP（DNS、游戏、语音等）走的是 UDP over TCP，不受影响。

**Q：落地机的 Snell 端口需要对外开放吗？**
不需要。用 `--relay-ip` 指定中转机 IP 后，只有中转机能访问（TCP 和 UDP 都是），落地机对外完全隐形。

**Q：中转机需要安装 Snell 吗？**
不需要。中转机只做 iptables 转发，不装任何代理软件。

**Q：为什么不用 Surge 的链式代理（underlying-proxy）？**
链式代理要做两层 Snell 加解密，中转机还要额外建连、客户端还要穿过隧道做嵌套握手，
延迟明显更高。纯转发不解密，开销几乎为零。

**Q：`--mode dnat` 和 `--mode userspace` 该选哪个？**
**延迟基本一样**，差别在丢包链路下的吞吐：`dnat` 是端到端一条 TCP，
leg1/leg2 的丢包会互相拖累；`userspace` 是两条独立 TCP，丢包互不影响。
在中转机上 `mtr -rwzc 50 <落地机IP>` 测一下 —— 丢包 ≈ 0 用 `dnat`，有持续丢包用 `userspace`。
详见上方「两种转发模式怎么选」。

**Q：两种模式能同时开吗？**
不能，也不需要。脚本会自动清掉另一种（否则 DNAT 会在 PREROUTING 就截走流量，
gost 永远收不到包，排查起来很费劲）。

**Q：中转机换了 IP 怎么办？**
重跑 `deploy-landing.sh --relay-ip <新IP>`，更新落地机的防火墙白名单即可。

**Q：落地机换了 IP 怎么办？**
重跑 `deploy-relay.sh --landing-ip <新IP>` 即可。客户端配置不用改（客户端连的是中转机）。

**Q：中转机↔落地机之间的传输安全吗？**
安全。Snell 加密是**端到端**的（客户端 ↔ 落地机），中转机**没有 PSK**，
转发的自始至终是密文 —— 即使中转机被入侵，也拿不到明文内容。

---

## 安全说明

### 暴露的端口

| 机器 | 端口 | 对谁开放 |
| --- | --- | --- |
| **中转机** | SSH（随机 20000-60000） | 全网（仅密钥登录 + fail2ban） |
| **中转机** | 转发端口（TCP + UDP） | 全网 —— 客户端要连，且客户端 IP 不固定，**无法限制来源** |
| **落地机** | SSH（随机） | 全网（同上） |
| **落地机** | Snell 端口（TCP + UDP） | **只对中转机 IP** —— 落地机对外完全隐形 |

> **默认端口是 443**（不用 6160 这种 Snell 招牌端口）—— 443 最不显眼，
> 而且能兼容「只放行常见端口」的公司/学校/酒店网络。
>
> 开荒脚本会默认把 80 / 443 对全网放行（那是从另一个项目继承的），
> **本脚本会把这两条「对全网」的规则收紧** —— 业务端口只按上面表格里的来源放行。
> 将来需要（比如要放网站）：`ufw allow 80/tcp && ufw allow 443/tcp`。
>
> 开荒脚本还会**清掉 VPS 商家预装的「伪优化」脚本** —— 就是那种每 30 分钟
> `sync` + 清空系统缓存（`drop_caches`）的 cron。它对代理服务有害无益
> （清空 page cache 只会让后续读盘变慢），而且常被设成 777 权限，任何本地用户
> 都能替换。**重装系统后商家预置会再次出现，所以每次开荒都会自动清掉。**
> 想留着的话加 `--keep-vendor-presets`。

### 其他

- 两台机器的 SSH 都会改为**只允许密钥登录**，并安装 fail2ban 防暴力破解
- 中转机↔落地机 之间的流量是 Snell 密文，**中转机没有 PSK，看不到内容**
- 落地机是整套里最敏感的一台（它持有 PSK、能看到明文），但它的暴露面反而最小
- UDP 端口**做不成反射放大攻击的跳板**（Snell 的 QUIC 握手带鉴权，未鉴权的包直接丢弃）
- `/etc/bbk/` 下的状态文件含 PSK，权限 600，请勿外发
