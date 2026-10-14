# 反检测加固措施（TTL / NTP / DNS / DHCP / IPv6）

> ⚠️ 这一部分**主动对抗校园网的多设备检测**。使用它**可能违反你所在学校的网络使用
> 规定**，后果由使用者承担。这些措施都可以被绕过，也不保证有效。
> 完整的检测方式清单、证据强度与自检方法见 [detection.md](detection.md)。

---

## TTL 归一化

### 开关

五项统一由 `autoverify-hardening` 控制，**改的是 UCI，然后调用 `autoverify-apply` 落地**：

```sh
autoverify-hardening status            # 看五项开关 + 系统实际状态
```

所以 UCI 里的 `ttl.enabled` / `ntp.enabled` / `dns.enabled` / `dhcp.enabled` /
`ipv6.enabled` 才是事实来源，LuCI 页面、`uci set`、命令行开关三种途径改的是同一个地方，
不会互相覆盖。

### 解决什么

路由器转发时先把 TTL 减 1，于是不同系统出来的包 TTL 各不相同（Windows 128、
Linux/Android 64），NAT 出去后呈现“一台机器后面有很多终端”的特征。统一 TTL
之后这个特征就消失了。

### 用法

```sh
autoverify-hardening ttl on          # 启用, 默认 TTL=64（Linux/Android）
autoverify-hardening ttl on 128      # 想让外部看起来是 Windows
autoverify-hardening status      # 含已匹配包数
autoverify-hardening ttl off         # 关闭
```

规则写在 `/etc/nftables.d/20-ttl-normalize.nft`，由 firewall4 包含进 `inet fw4` 表，
所以**重启和 `fw4 reload` 后都还在**，且 `off` 就能完全回滚。

### 代价（必须知道）

**对外的 `traceroute` / `mtr` 只能看到第一跳。** 这是 TTL 被改写的必然结果。
实测对比：

```
启用前:  1: 192.168.1.1 → 2: 100.105.0.1 → 3: 100.105.0.1 → 5: 183.207.67.9 → 6: 223.110.20.210
启用后:  1: 192.168.1.1 → 2: 223.5.5.5        （中间跳点全部消失）
```

排障时先 `autoverify-hardening ttl off`，否则分不清是校园网丢了包还是 TTL 被自己改了。

### 选择 TTL 值时想一下

不改 TTL 的指纹只有“TTL 差异”；改了之后多出一层一致性风险：TTL 64 对应 Linux，
而你实际设备可能是 Windows。**如果门户同时看 UA 和 TTL，两者不一致反而更异常。**
要么统一成 64 并保证没有其他 Windows 泄露点，要么干脆统一成你主力设备的值。

### 没覆盖的

- 只处理 **IPv4**。这台路由器 WAN 上没有 IPv6（`wan6` 是 down 的）。
- 只匹配 `iifname "br-lan"`。若以后新增 LAN 侧接口（访客网、VLAN），要把它加进去。

### 风险

这属于主动消除运营方的检测特征，不是普通配置优化。后果（包括账号被停）
由你承担。

### 注意：不关 flow offloading 的话，TTL 改写是假的

OpenWrt 可能默认开软件/硬件流量卸载。被卸载的连接走 fastpath，**直接跳过 netfilter 的
postrouting hook** —— `ip ttl set` 对它们根本不执行。表现为“规则计数在涨，但实际只覆盖了
一部分流量”，很难发现。`autoverify-hardening status` 会检测并告警。

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall && /etc/init.d/firewall restart
```

## NTP 收敛

### 解决什么

不同设备的默认 NTP 服务器和对时频率都不一样（time.windows.com / time.apple.com /
各家厂商自己的）——这些 `udp/123` 请求直接出去，对上游就是“同一个 IP 下面有一组
互不相同的 NTP 客户端”的特征。把 LAN 的 `udp/123` DNAT 到路由器，
并让路由器自己当 NTP server，对外就只剩一个 NTP 客户端。

### 用法

```sh
autoverify-hardening ntp on                        # 启用
autoverify-hardening ntp on ntp.aliyun.com         # 顺便换上游服务器
autoverify-hardening ntp off                       # 关闭
autoverify-hardening ntp status                    # 查看状态
```

实现为一个 UCI `config redirect`（在 LuCI 的防火墙页面里也看得到），
加上 `system.ntp.enable_server=1`。因此**重启后仍然生效**，`off` 就能完整回滚。

### 为什么客户端感知不到

DNAT 的回包靠 conntrack 反向改写源地址。实测：

```
客户端发:  src=192.168.1.156 dst=203.107.6.88 dport=123
路由器回:  src=192.168.1.1   dst=192.168.1.156
客户端看到: 回包源地址仍是 203.107.6.88
```

所以 NTP 客户端不会因为“源地址不符”丢弃回包，不会报错。

### 代价

路由器时钟不准时，后面所有设备跟着不准（TLS 证书校验依赖时间）。
路由器没认证上不了网时，上游同步会停，时间靠本地晶振维持。

## 路由器 DoH 与可选 DNS 收敛

### 解决什么

默认只为路由器 dnsmasq 设置 DoH 上游，不强制接管局域网 DNS。使用路由器作为
DNS 的设备通过它解析；Clash、TUN 或私有 VPN 客户端可以继续使用自己的解析器。
设备到路由器的普通 DNS 查询仍是明文，仅路由器到 DoH 上游的查询加密。

可选的强制接管与 NTP 同一思路。不同设备的默认解析器、DoH 开关、EDNS/ECS 行为、查询 ID 随机化
方式都不一样，这些 `udp/tcp 53` 请求直接出去，对上游就是“同一 IP 下有一组互不相同的
DNS 客户端”。重定向到路由器后，由 dnsmasq 统一对外解析。

DNS 和 NTP 是最容易被忽略的两个多设备特征源 —— 因为它们跟网页浏览无关，
但每台设备都会自己发。

### 用法

```sh
autoverify-hardening dns on          # 启用路由器 DoH，不改变接管开关
autoverify-hardening dns off         # 关闭 DoH、清理接管规则、恢复原上游
autoverify-hardening status          # 含 dnsmasq / DoH 代理监听和规则计数

# 推荐的兼容模式（DoH 开启，强制接管关闭）
uci set autoverify.dns.enabled='1'
uci set autoverify.dns.redirect='0'
uci commit autoverify
autoverify-apply

# 如确需强制接管，再显式设置 redirect=1 并提交、应用。
```

启用前会先检查本机 53 端口真的在监听，否则拒绝启用（重定向过去没人应答 = 客户端直接断解析）。
代理启动后最多等待 5 秒确认 `127.0.0.1:5053` 的 UDP 监听，仅在 `dns.redirect=1`
且 `dns.enabled=1` 时添加 DNS 重定向。`redirect` 缺失时默认 `0`，适用于保留旧配置的升级。
每次应用先清理插件旧重定向；即使 DoH 启动失败也不会保留上次的接管规则。
关闭接管仍保留 DoH；关闭 DoH 则移除接管并恢复原上游，不清除保存的接管开关偏好。
监听检查只证明本机代理存在，不代表 DoH 网络可达或 TLS 握手成功。

### 可选接管的工作方式

启用强制接管时，和 NTP 一样靠 conntrack 反向改写。此前接管模式实测：

```
客户端发:  src=192.168.1.156 dst=8.8.8.8 dport=53
路由器回:  src=192.168.1.1   dst=192.168.1.156 sport=53
客户端看到: 回包源地址仍是 8.8.8.8
```

路由器上游改为 `dnsmasq → 127.0.0.1:5053 → https-dns-proxy → DoH`。
所有 dnsmasq UCI 实例均设置 `noresolv=1`，替换 `server`（含分域转发）并移除
`serversfile`，不再读取 WAN 下发的明文 DNS，也不在 DoH 失败时回退明文上游。

套件依赖 `https-dns-proxy` 和 `ca-bundle`。LuCI 提供三个预设，UCI 配置项为
`autoverify.dns.doh_provider`（旧配置缺失时默认 `tencent`）：

| 预设 | DoH 端点 | Bootstrap DNS |
| --- | --- | --- |
| `tencent`（默认） | `https://doh.pub/dns-query` | `119.29.29.29` |
| `aliyun` | `https://dns.alidns.com/dns-query` | `223.5.5.5,223.6.6.6` |
| `custom` | `autoverify.dns.doh_url` | `autoverify.dns.doh_bootstrap`（逗号分隔的 IPv4） |

预设固定使用对应域名端点与 bootstrap，自定义字段只在 `custom` 时生效。
自定义 URL 必须使用 HTTPS，可含端口及查询参数；不支持 URL 用户名/密码和 IPv6 字面量。
始终保持 TLS 证书验证。Bootstrap 使用明文 DNS，仅用于解析 DoH 服务自身的域名，
普通客户端查询不会被发送给 bootstrap，也不会在 DoH 失败时回退到它。
域名端点符合 DNSPod [官方接入建议](https://docs.dnspod.cn/notices/mian-fei-ban-dot-dohbu-zai-gong-kai-ipjie-ru-de-gong-gao/)
和[阿里公共 DNS 说明](https://alidns.com/)。

```sh
uci set autoverify.dns.doh_provider='aliyun'
uci commit autoverify
autoverify-apply
# 自定义：同时设置 doh_provider=custom、doh_url 和 doh_bootstrap。
```

首次启用保存原 https-dns-proxy 配置及启用/运行状态到 `/etc/autoverify-dns/`，
dnsmasq 原上游保存在各实例的 `av_doh_*` UCI 选项；重复应用不覆盖备份。
关闭路由器 DoH 时恢复这些配置和服务状态。启用期间由本套件接管代理配置，
不要同时用其他插件改 DNS 上游，也不要手动删除备份或重新排列 dnsmasq 实例。
自定义 dnsmasq `confdir`/`conf-file` 中的上游配置不由 UCI 管理，需先移除。

实现使用 OpenWrt [https-dns-proxy 的 UCI 接口](https://github.com/openwrt/packages/tree/master/net/https-dns-proxy)，
关闭其自动 dnsmasq 更新和强制 DNS 规则；本套件仅在显式启用接管时创建 LAN 53 重定向。

### 没覆盖的

**DoH（HTTPS 上的 DNS）绕过这里。** 浏览器/系统启用 DoH 后直接走 443，
要阻断需要屏蔽一长串不断变化的域名和 IP，副作用大且封不全，本脚本不做。

### 代价

需要运行 DoH 代理，增加 HTTPS 请求开销。默认允许客户端使用自定义 DNS；只有启用
强制接管才限制客户端的普通 DNS，并可能干扰 Clash 类客户端。dnsmasq 原分域上游
在 DoH 启用期间会暂停。DoH 不可达、TLS 时间/证书
错误或校园网认证前禁止 HTTPS 时，外部域名解析会失败；门户可使用 IP 地址配置，
也可关闭路由器 DoH 恢复原上游后完成认证。启用前应验证网络可访问所选端点。

## DHCP 伪装

### 解决什么

校园网的 DHCP 服务器会记录每个客户端报上来的三个字段。OpenWrt 的默认值
**全部都在直接自报家门**：

| 字段 | OpenWrt 默认值 | 问题 |
|---|---|---|
| 主机名 (12) | `OpenWrt` | DHCP 服务器专门记录这个字段，很多管理后台的设备列表直接显示它 |
| client-id (61) | 一串 DUID | 普通终端发的是 `01:<MAC>`（类型 1 + 硬件地址）。DUID 是路由器/服务端的写法 |
| 厂商号 (60) | `udhcp <版本号>` | **连 DHCP 客户端实现和版本号都报出去了** |

另外 DHCPv6 的 `Client-FQDN` 用的是系统主机名，会把 `OpenWrt` 再泄露一次。

> 这三个字段不只是给学校 DHCP 服务器看的。DHCP 用的是二层广播，
> **同一广播域内的其他主机也能看到** —— 在扁平化的校园网里就是同一层楼的其他人。

### 用法

```sh
autoverify-hardening dhcp on                    # 主机名留空 = 自动随机生成
autoverify-hardening dhcp on MY-PC              # 指定主机名
autoverify-hardening dhcp on MY-PC 'MSFT 5.0'   # 顺便指定厂商号
autoverify-hardening dhcp off                   # 恢复 OpenWrt 默认
```

主机名留空时，首次应用会生成一个形如 `LAPTOP-XXXXXXXX` 的名字（Windows 默认命名风格）
并**写回 `/etc/config/autoverify`**，之后保持不变 —— 每次 apply 都换名字本身就是个特征。

client-id 不需要配置，从 WAN 口 MAC 自动推导成 `01:<MAC>` —— 刚好就是你其它真实设备在发的格式。

### 代价（必须知道）

**改 client-id 有可能让 DHCP 服务器重新分配地址。** 不少 DHCP 服务器是按 client-id
绑定租约的。换了 IP 会短暂断网（本项目会自动重新认证），但如果你在开会/打游戏，
选个合适的时间做。

> 本项目只在值**真的变了**的时候才重开接口，所以开机不会反复 ifup。

### 没覆盖的

内核的 DHCP 客户端实现本身没变 —— 参数请求列表（option 55）、报文时序、
超时行为仍然是 busybox `udhcpc` 的。这些不如上面三个字段显眼，但也没藏住。

## IPv6 防护

### 解决什么

这个开关防的是**全军覆没**级别的事故。

本项目所有 L3/L4 措施的前提是「设备藏在 NAT 后面」。而 **IPv6 不做 NAT** ——
只要上游下发一个全局前缀、且 LAN 还在发 RA，每台客户端就会直接拿到可路由的
IPv6 地址，绕过本机所有出站检查，**TTL / NTP / DNS / UA 全部失效**。

关掉 LAN 的 `ra` 与 `dhcpv6` 后，LAN 只跑 IPv4，从结构上不可能发生这种泄露。

### 用法

```sh
autoverify-hardening ipv6 on     # 关掉 LAN 的 RA 与 DHCPv6
autoverify-hardening ipv6 off    # 恢复（ra=server, dhcpv6=server, ra_slaac=1）
```

### 代价

**局域网内也没有 IPv6 了。** 当前校园网本来就不提供 IPv6，所以实际影响为零；
如果你把这个包用在有 IPv6 的家庭网络上，请把它关掉。

### 怎么知道真的生效了

不要只看配置。看**客户端地址的生命周期是否还在被续期**：

```powershell
# Windows，看 fd16:/你的前缀开头的地址，间隔 100 秒采两次
Get-NetIPAddress -AddressFamily IPv6 | Where-Object { $_.PrefixOrigin -eq 'RouterAdvertisement' }
```

RA 还在的话，每次通告都会把 lifetime 刷新回满值；RA 停了则只会单调递减。
实测中 100 秒内减少了 101 秒，就说明确实停了。

---

## 五项反检测措施一览

| 措施 | 收敛/伪装的是 | 写入位置 | 开关 |
|---|---|---|---|
| TTL | IPv4 TTL | `/etc/nftables.d/20-ttl-normalize.nft` | `uci set autoverify.ttl.enabled` |
| NTP | LAN `udp/123` | UCI `firewall.ntp_converge` | `uci set autoverify.ntp.enabled` |
| DNS | dnsmasq DoH；可选 LAN `udp/tcp 53` 接管 | DoH 代理；可选 `firewall.dns_converge_{udp,tcp}` | `autoverify.dns.enabled` / `autoverify.dns.redirect` |
| DHCP | hostname / client-id / vendor-class / DHCPv6 FQDN | `network.<iface>.*` + `network.<iface>6.noclientfqdn` | `uci set autoverify.dhcp.enabled` |
| IPv6 | LAN 不发 RA / DHCPv6 | `dhcp.lan.ra` / `dhcp.lan.dhcpv6` | `uci set autoverify.ipv6.enabled` |

五项都不随 autoverify 的认证进程一起跑，开机时由 `/etc/init.d/autoverify` 调用
`autoverify-apply` 从 UCI 落地，重启和 `fw4 reload` 后都仍在。改完 UCI 后执行
`/usr/sbin/autoverify-apply` 落地（或 `/etc/init.d/autoverify reload`）。

## 其它可能的检测方式

TTL 和 NTP 只是两个维度。TLS 指纹（JA3/JA4）、IPID、TCP 时间戳、HTTP/2 指纹、
QUIC、IPv6 泄露、并发连接数等的原理、证据强度、代价与自检方法，
见 **[detection.md](detection.md)**。
