# 校园网多设备共享检测：可能的方式与应对

这份文档是排查手册，不是教程。用途是：**当检测真的出现时，能快速定位是哪一种，而不是靠猜。**

---

## 关于证据强度（先读这段）

下面的内容**绝大多数来自个人博客、GitHub 项目和厂商宣传页**，不是同行评审或官方文档。

- 引用专利号的部分（如 `CN106411644A`）原理描述可信度较高。
- 厂商的性能与能力声明属于**自述**，没有独立验证。
- 各校部署差异极大。**任何一条都不能假定你所在的校园网启用了。**
- 文献（如 "Remote physical device fingerprinting"）证明了这些技术在通用网络里可行，
  **不等于**某个具体校园网就部署了。

判断的唯一可靠办法是**抓包观察自己的流量**（见文末自检清单）。

---

## 一、被动 L3/L4 特征（成本最低，最可能被用）

| # | 方式 | 原理 | 本部署状态 |
|---|---|---|---|
| 1 | **TTL** | OS 初始 TTL 不同（Windows 128，Linux/Android/iOS 64），每经一跳减 1。NAT 后出现离散 TTL 值即判定多设备 | ✅ 已处理（`autoverify-hardening ttl`） |
| 2 | **IPID** | IP 首部 Identification 字段。每主机独立递增，递增区间不同 → 多主机。专利 `CN104836700A` | ❌ 未处理，**证据冲突**：有来源称现代设备 IPID 已不再递增（iOS 恒 0），另有实战记录称 Windows 仍全局递增。⚠️ 见下文“**nftables 能改它，但有风险**” |
| 3 | **TCP 时间戳 / 时钟偏移** | 各主机协议栈时钟偏移不同，可用频谱分析聚类。时间戳还暴露开机时长。专利 `CN111970173A` | ❌ 未处理。**nftables 改不了 TCP option，必须用户态代理** |
| 4 | **TCP 初始窗口 / MSS / SYN 选项顺序** | OS 指纹（初始窗口、窗口缩放因子、选项顺序） | ❌ 未处理 |
| 5 | **源端口分配行为** | NAT 端口分配模式（保留/随机/递进） | ❌ 未处理 |
| 6 | **TOS / DSCP / ECN** | 部分系统会打标 | ❌ 未处理（nftables 可以改，见下文） |

### 实测：nftables 能改哪些字段

在 OpenWrt 25.12 / nftables 1.1.6 上用 `nft -c` （只检查不加载）逐个验证：

| 字段 | 能否 | 语法 |
|---|---|---|
| IPv4 TTL | ✅ | `ip ttl set 64` |
| IPv6 Hop Limit | ✅ | `ip6 hoplimit set 64` |
| **IPv4 IPID** | ✅ | **`ip id set 12345`** |
| **TCP 窗口** | ✅ | **`tcp window set 64240`** |
| TCP MSS | ✅ | `tcp option maxseg size set 1460` |
| IPv4 frag-off | ✅ | `ip frag-off set 0` |
| DSCP | ✅ | `ip dscp set 16`（`ip tos set` 语法不支持） |
| **TCP 时间戳** | ❌ | 不支持 |
| TCP SACK 选项 | ❌ | `Not supported` |

**注意这与大量教程相矛盾。** 很多指南说改 IPID 必须编译 `kmod-rkp-ipid` 内核模块、
改 TCP 窗口必须用 eBPF 或用户态代理 —— 实测 nftables 两者都能改。

### ⚠️ 但这两项不建议预防性做

**IPID：有真实的数据损坏风险。** IP 分片要求同一数据报的多个分片**共享同一个 ID**。
设成常量 → 不同数据报的分片会混淆；用 `numgen` 递增/随机 → 同一数据报的分片会拿到
不同 ID。**两种都坏。** 只有配合“只处理未分片包”的过滤才安全，而首个分片的 `frag-off`
也是 0，条件不好写。另外 `rkp-ipid` 的作者自己说过：“还没有确认哪个学校使用的是这种方法”。

**TCP 窗口：它是流控字段，不只是指纹。** SYN 里的窗口是初始接收窗口，改小可能限速，
改大可能让对端发超过接收缓冲而丢包。只改 SYN（`tcp flags & (syn\|ack) == syn`）风险小些，
但仍有降速可能。收益（一个指纹维度）不值这个风险。

## 二、被动 L7 特征

| # | 方式 | 原理 | 本部署状态 |
|---|---|---|---|
| 6 | **HTTP User-Agent** | 统计同一 IP 下出现的不同 UA 数量 | ❌ 本项目未处理。**只对明文 HTTP 有效**。可用 [UA-Mask](https://github.com/Zesuy/UA-Mask) 补上 |
| 7 | **TLS 指纹 JA3/JA4** | **ClientHello 永远明文**，不同 TLS 库（BoringSSL / NSS / Go crypto/tls）指纹截然不同。JA3 已被现代浏览器随机化削弱，**JA4 仍可区分** | ❌ 未处理。**不需要中间人解密就能做**，是目前最强的单点向量 |
| 8 | **HTTP/2 SETTINGS 指纹** | SETTINGS 帧参数 + 伪头顺序（Akamai 指纹） | ❌ 未处理 |
| 9 | **QUIC 指纹（UDP 443）** | 带类 TLS 指纹，且**绕过所有 TCP 改写链路** | ❌ 未处理 |
| 10 | **NTP 请求特征** | 各设备默认 NTP 服务器与对时频率都不同 | ✅ 已处理（`autoverify-hardening ntp`） |
| 11 | **DPI 应用特征** | 按应用特征识别（如微信）。锐捷有专利 `CN106411644A`。极耗性能，各校是否开启不定 | ❌ 只能靠加密对抗 |
| 12 | **DNS 查询模式 / DoH** | 各设备默认解析器、EDNS/ECS 行为、查询 ID 随机化方式不同 | 默认仅路由器 DoH；LAN 53 接管需显式开启 `dns.redirect=1`。客户端 DoH 不受接管覆盖 |
| 13 | Flash Cookie | 已过时（Flash 停用） | 不适用 |

## 三、拓扑 / 主动 / 行为

| # | 方式 | 说明 | 本部署状态 |
|---|---|---|---|
| 14 | **IPv6 泄露** | 若客户端拿到全局 IPv6 地址，**绕过 NAT，每台设备地址直接暴露**，前面所有工作白做 | ✅ 已从结构上关闭：`autoverify-hardening ipv6` 默认开启，LAN 的 `ra` / `dhcpv6` 均为 `disabled`，客户端拿不到任何 IPv6 地址。实测地址生命周期单调递减、无任何续期 |
| 15 | 主动探测 | 由上游主动探测客户端（如 traceroute 到客户端、发低 TTL 包看是否被转发） | ⚠️ 未见校园网实战证据，理论存在 |
| 16 | MAC OUI 计数 | 统计同账号下的 MAC 数 | ✅ 不适用（STA + NAT，AP 只看到路由器自己的 MAC） |
| 17 | 路由器自身指纹 | 路由器自己的 DHCP 客户端指纹、出站 UA 等 | ✅ 已处理：出站 UA 换成普通 Chrome（`tuning.user_agent`）；DHCP 三个字段换掉（`autoverify-hardening dhcp`：主机名、client-id、厂商号），DHCPv6 的 Client-FQDN 也关掉。⚠️ 但**内核的 DHCP 客户端实现本身**仍与 Windows 不同（参数请求列表、报文时序等），只是不再主动报出身份 |
| 18 | **单 IP 并发连接数 / 流量形态** | "一个账号大量并发"这个特征**任何方案都藏不住** | ❌ 无法处理 |

## 四、厂商方案（宣传口径）

| 厂商 | 声称的能力 |
|---|---|
| 深信服 AC | 共享接入管理，可设单 IP / 单用户最大终端数，超限冻结 |
| 锐捷 | DPI 共享设备检测（专利 `CN106411644A`） |

---

## 核心认知：架构 > 逐个打补丁

来自重庆大学的实战记录（OpenWrt + ua3f）：

> ua3f 是个 SOCKS5 终结点：它关闭客户端 TCP，用路由器自己的协议栈重新发起一条连接。
> 凡是**进了代理**的流量，对外的 L3/L4 指纹（TTL、IP-ID、TCP options/时间戳、源端口行为）
> 统一成路由器这一台，再叠加 HTTP UA 改写，对外等效"一台主机"。
>
> **检测能抓到的，只有漏出代理的流量。**

所以加固的本质是：**让尽量多流量进代理 + 抑制进不去的流量**，而不是一项项打补丁。
本部署目前是“打补丁”路线（TTL + NTP），属于部分覆盖。

> **更新**：ua3f 已有继任者 **[UA-Mask](https://github.com/Zesuy/UA-Mask)**（GPL-3.0，Go）。
> 它保留了“全流量进代理 + L3/L4 指纹统一”的思路，并用动态 `ipset`/`nfset` 卸载
> 非 HTTP 流量，把硬路由上的性能代价压了下来。**若要转“架构”路线，它是目前的现实选择。**
>
> ⚠️ 但它**仍只改明文 HTTP 的 UA**，HTTPS 里的 UA 改不了（不做中间人解密）。

---

## 跨层一致性：一个容易被忽略的反面信号

来自 eBPF 那个项目的文档：

> 即使浏览器的 TLS 指纹被完美伪装，**应用层和 TCP/IP 栈不一致**
> （例如 Windows 的 TLS 签名跑在 Linux 的 TCP 栈上）本身就是高熵信号。

这条会影响“TTL 该设多少”这个决策：

- 不管设成 64 还是 128，都必然与**某类**设备的 UA 不一致（家里同时有 Windows 和手机）。
- 纯数 TTL 的检测器 → 归一化就赢（已消掉“多个 TTL 值”）。
- 做跨层关联的检测器 → 反而多了一个新特征，需要连 UA 一起统一（即 ua3f）。

**结论**：TTL 值取“与你主力设备一致”的那个更稳（主力是 Windows 就用 128）。
但跨层关联属于进阶场景，本项目未将它的存在当作前提。

## 五、各措施的代价与残留

| 措施 | 代价 | 残留 |
|---|---|---|
| 统一 TTL | 对外 traceroute/mtr 只剩第一跳 | 需先关 flow offloading，否则静默失效 |
| 统一 UA | 站点按 UA 分发内容会出错（手机拿到桌面版）；**默认值 `FFF` 是占位符，不换成真实主流 UA 反而更显眼** | HTTPS 里的 UA 改不了（除非中间人解密） |
| 全流量代理（UA-Mask） | 需额外常驻进程 + 一套 nft 规则；默认绕过 22/443，其余 TCP 进代理；其入站链为 `priority dstnat - 1`，优先于本项目的 DNAT 规则（只影响 `tcp/53` 指向外部解析器的情况，UDP 不受影响） | 明文 HTTP 的 UA 才改得动；JA3/JA4 不变 |
| 清除 TCP 时间戳 | 需用户态代理 | 直连流量仍泄露 |
| IPID 改写 | 需编译内核模块 `kmod-rkp-ipid`，要重编固件 | — |
| NTP 收敛 | 路由器时钟不准则全体不准；路由器离线时上游同步停止 | — |
| DNS / DoH | 默认允许客户端自选解析器；可选接管可能干扰 Clash | 默认不统一 LAN DNS；接管不覆盖客户端 DoH |
| 封 QUIC | 浏览器回落 TCP（`reject` 比 `drop` 回落快） | — |
| Clash/代理加密 | 需要自己的解密服务器 | 全部流量走代理，弱硬件吃不消 |

### 路由器侧改不掉的

- **HTTPS/443 的 UA、JA3/JA4** —— 不做中间人解密就改不了。做中间人的代价是把 CA 证书装到每台客户端，并**破坏证书固定**（银行 App、微信、部分游戏、Play 商店更新会直接失败）。
- **并发连接数 / 账号行为** —— 藏不住。

---

## 六、关键坑（都是别人踩过的）

### 1. 不关 flow offloading，TTL 改写是假的

OpenWrt 默认可能开软件/硬件流量卸载。被卸载的连接走 fastpath，
**直接跳过 netfilter 的 postrouting hook** —— `ip ttl set 64` 对它们根本不执行。

这是很多人"配了 TTL 还是被检测"的根因。`autoverify-hardening status` 会检测并告警。

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall && /etc/init.d/firewall restart
```

### 2. UA 伪装值本身别穿帮

统一成一个**不存在或已过时**的 UA 组合，本身就是显眼特征。
必须用真实、当前主流的 UA 串。

### 3. 代理拦截规则里不要排除 `10.0.0.0/8`

校园网内网和认证服务器就是 `10.x`，排除了它们就漏出去了。

### 4. IPv6 优先级最高

代理/改写规则通常只处理 IPv4。客户端一旦拿到全局 IPv6，就绕过一切。
**如果学校上了 IPv6，这件事要第一个处理。**

### 5. 弱硬件不要全量代理

实测：关掉 offload + 几乎全部 TCP 进用户态代理，MT7621 这类双核 mipsel 上
单核负载直接上 1.1（≈满载），高带宽场景明显降速、延迟抖动。

⚠️ **但这条对 [UA-Mask](https://github.com/Zesuy/UA-Mask) 不完全适用** —— 它用
“流量卸载”（把判定为非 HTTP 的 `ip:port` 加进 `ipset`/`nfset`，由防火墙层直接 RETURN）
正面处理了这个问题。官方在 MIPS 硬路由上实测 iperf3 上/下行约 **97 / 78 Mbps**，
并称对 P2P / Steam / 加密代理等重流量可降 80%+ CPU。这是它相对早期 ua3f / UA2F 的
关键改进。（该数据为官方自述，非本环境实测。）

不过仍有上限：受限于设备本身，且对**持续的原生 HTTPS 流量**（既不命中卸载、
也不命中 UA 白名单）仍然全程走用户态。

---

## 七、自检清单

### 路由器侧

```sh
# 1. conntrack 里有没有被卸载的连接(>0 就说明 offload 开着, TTL 规则会漏)
grep -ci offload /proc/net/nf_conntrack

# 2. ruleset 里有没有 flowtable
nft list ruleset | grep -i flowtable

# 3. 有没有 IPv6 全局地址/默认路由(有就危险)
ip -6 addr show br-lan | grep "scope global"
ip -6 route | grep default

# 4. 客户端 NTP 是否被收敛
grep 'dport=123' /proc/net/nf_conntrack

# 5. TTL 规则是否在跑、计数多少
nft list chain inet fw4 ttl_normalize

# 6. 本机 NTP 服务是否在听
netstat -lnu | grep ':123'
```

### 客户端侧

用**不同 UA、不同端口**请求一个回显服务，看服务器实际收到什么 —— 这能定位还有哪一维在漏。
测的时候**必须关掉客户端自己的代理软件**，否则流量绕过路由器，结果不可信。

### 判定"是不是被检测了"

看掉线规律：

- **每次认证后固定时长掉线** → 会话超时策略，不是检测
- **不规律、且集中在有流量时掉** → 才像 NAT/指纹检测
- **认证直接失败并提示"检测到共享/请勿使用代理"** → 检测已生效

---

## 与本项目的关系

| 组件 | 覆盖 |
|---|---|
| `autoverify` | 门户认证与会话保活 |
| `autoverify-hardening ttl` | 第一节 #1（TTL） |
| `autoverify-hardening ntp` | 第二节 #10（NTP） |
| `autoverify-hardening dns` | 第二节 #12（DNS） |
| [UA-Mask](https://github.com/Zesuy/UA-Mask)（外部项目，GPL-3.0） | 第二节 #6（HTTP UA），并把 L3/L4 指纹统一到路由器 |
| 其余 | **未覆盖**，见上文状态表 |

再次强调：**当前这所学校的检测只是"账号并发会话数"（按 IP 记账，NAT 后即已解决），
上面其余方式都没有证据表明在启用。** 这份文档的价值在于出问题时能快速定位。

---

## 现实提醒（研究里挖到的）

这几条比任何技术手段都值得先知道：

**1. 检测会突然升级，不给你准备时间。** 有记录是路由器用了一年都没事，某天早上
突然被冻结 30 分钟，去贴吧才发现是学校刚加的。SunBK201 那边也是类似。
所以不要因为“用了一段时间没事”就认为不会有事。

**2. 虚拟机 / 安卓模拟器会被误判成多设备。** 如果你跑 VM 或模拟器，某次被封可能
根本不是路由器的问题。排查时先想到这一点。

**3. 规避不一定成功。** 有记录（JNU）：试过 MAC 伪装和调整心跳间隔，
仍然大约每半个月被封一次（约 2 小时），自动重连脚本也失败。
**这类对抗没有必胜方案**，封禁窗口内只能等。

**4. 升级路径真实存在。** 有学校从 MAC 计数（容易被 MAC 克隆绕过）升级到
华为设备做终端数限制（3 台 → 2 台），并改成了大约 30 分钟的封禁。

## 参考来源

- SunBK201《关于某大学校园网共享上网检测机制的研究与解决方案》— https://blog.sunbk201.site/posts/crack-campus-network
- SunBK201/UA3F — https://github.com/SunBK201/UA3F
- Zesuy/UA-Mask（ua3f 继任者，Go + 动态流量卸载）— https://github.com/Zesuy/UA-Mask
- 《校园网防止多设备检测指北》（褐瞳）— https://www.hetong-re4per.com/posts/multi-device-detection/
- 《重庆大学校园网多设备检测对抗实战（OpenWrt + ua3f）》— https://lucky-z.fun/p/1e43e556.html
- un-nf/404 eBPF TCP/IP Fingerprint Editor — https://deepwiki.com/un-nf/404/6-ebpf-tcpip-fingerprint-editor
- Zxilly/UA2F — https://github.com/Zxilly/UA2F
- CHN-beta/rkp-ipid — https://github.com/CHN-beta/rkp-ipid
- 专利：`CN106411644A`（基于 DPI 的网络共享设备检测）、`CN104836700A`（基于 IPID 和概率统计模型的 NAT 主机个数检测）、`CN111970173A`（基于时钟偏移的加密流量共享检测）
- "Remote physical device fingerprinting"（Kohno et al.）— https://homes.cs.washington.edu/~yoshi/papers/PDF/KoBrCl2005PDF-Extended-lowres.pdf
