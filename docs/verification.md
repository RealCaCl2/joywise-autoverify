# 实测记录

> 本文件区分本地验证与真实校园网 / OpenWrt 实测；本地结果不代表设备验收。
> 复现命令和验证范围见各条目自身。

## 2026-10-14：CI SDK 下载校验修复

- GitHub Actions run `38521337241` 在下载后解压阶段失败：所谓 SDK 仅 19,232 字节，
  zstd 报 `unsupported format`，尚未进入编译。本地已有 SDK 缓存未覆盖该路径。
- 构建脚本增加独立下载、SHA256 与 zstd 校验，以及镜像索引 / 下载 / 校验失败的
  官方源回退；解压完成才建立 SDK 缓存。CI 显式使用 OpenWrt 官方源。
- `python3 test/test_sdk_download.py` 五项离线回归通过，覆盖 HTTP 200 错误页、
  索引失败、校验和匹配但 zstd 无效、两个源均失败、官方源正常下载。
- 在全新 WSL 目录 `~/openwrt-apk-ci-check` 实际下载官方 25.12.5 ramips/mt7621
  SDK，通过 SHA256 / zstd 校验、解压与 APK 编译，产出 r17。
  `bash -n tools/build-apk.sh` 和 `git diff --check` 通过。
- 此修复只改构建流程，不修改路由器运行文件，不需要重新安装插件。

## 2026-10-14：r17 APK 构建与 OpenWrt 升级

- 复用 WSL OpenWrt 25.12.5 ramips/mt7621 SDK，`bash tools/build-apk.sh`
  构建成功；产物为 `dist/autoverify-1.0.0-r17.apk`（42,869 字节，noarch）。
  APK 元数据确认版本与五项依赖，上传前后 SHA256 一致：
  `29aa48c806fcb077a35f7c51fb4a062e513d7621e0b9b7aaeeb42924ba9bd6eb`。
- 用户授权通过已有密码环境变量连接路由器；使用已保存的 SSH 主机密钥验证身份。
  设备为 Xiaomi Mi Router 4A Gigabit Edition v2，OpenWrt 25.12.5 ramips/mt7621。
- 升级前将相关 UCI 配置及已有 DNS 备份保存在路由器本机，目录权限受 `umask 077`
  保护。备份路径由 `/root/autoverify-last-backup` 指向；没有下载账号或密码。
- `apk add --allow-untrusted /tmp/autoverify-1.0.0-r17.apk` 完成 r16 → r17 升级。
  修改运行模式前使用 `cmp` 确认原 `/etc/config/autoverify` 完整保留。
- 设置 `dns.enabled=1`、`dns.redirect=0`，应用配置、重启 autoverify 并重载 rpcd。
  13 个运行文件的 SHA256 与源码匹配（排除保留的配置和已执行的 uci-defaults）。
- 实机核验：UCI 和 nft 均没有插件 LAN DNS 重定向；所有 dnsmasq 实例使用
  `noresolv=1` 和 `127.0.0.1#5053`；代理 `force_dns=0`，自动 dnsmasq 更新关闭。
  本机 UDP 5053 监听存在，向 127.0.0.1 查询 example.com 返回 A / AAAA，
  autoverify 服务运行，`autoverify validate` 通过且无警告。
- 未执行：电脑私有 Clash 客户端连接、真实 LuCI 浏览器验收与出站抓包。
  DNS 查询成功不等于这些用户端项目已经验收；没有推送或发布。

## 2026-10-14：DoH 与 LAN DNS 接管拆分（本地验证）

- 默认 `dns.enabled=1`、`dns.redirect=0`；旧配置缺少接管开关时也按关闭处理。
  已关闭 DoH 的用户升级后保持关闭，需在 LuCI 单独开启“路由器使用 DoH”。
- WSL `python3 test/test_dns.py`：13 项通过。新增覆盖旧重定向清理、无关防火墙
  配置保留、显式接管规则、模式切换、关闭后恢复、代理失败、dnsmasq 缺失及
  无静态 LAN 地址场景。使用状态化 UCI / 服务 mock，没有修改真实设备配置。
- 纯 Linux PATH、清除代理变量后执行 `sh test/run.sh`：完整认证回归通过。
  初次使用混合 Windows PATH 的运行进度缓慢，已中断并重跑。
- `dash -n`（运行脚本）、ShellCheck（三个主脚本）、LuCI JS / Python 语法
  和 `git diff --check` 均通过；包修订号从 r16 增加到 r17。
- 未执行：APK 构建、OpenWrt 安装与升级、真实 LuCI 页面操作、私有 Clash 客户端
  连接及 DNS 抓包验证。本地测试通过不代表这些实机项目已验收。

## 2026-10-14：DNS DoH 与 LuCI 优化（本地验证）

- `python3 test/test_dns.py`：8 项通过，覆盖腾讯 / 阿里 / 自定义预设、连续切换、
  重复应用、原上游与服务状态恢复、非法配置、依赖缺失、代理失败与监听缺失。
- WSL 中使用纯 Linux PATH、清除代理变量运行 `sh test/run.sh`：完整认证回归通过，
  包括并发互斥和 stale lock 回收。保留 Windows PATH / 代理变量的首次 WSL 运行
  曾出现并发用例的时序失败；排除环境干扰后无需修改认证逻辑即可通过。
- `dash -n`、`node --check`、Python / JSON 解析与 `git diff --check` 通过。
- 当前电脑对腾讯 `https://doh.pub/dns-query` 的 RFC 8484 POST 返回 HTTP 200。
  阿里域名首次直连遇到 TLS 连接中断；使用其官方 `223.5.5.5` 节点并保留
  `dns.alidns.com` 的 SNI / 证书校验后，POST 返回 HTTP 200。两者 DNS 响应均包含答案。
- `test/ui-preview.html` 加载真实视图 JS、模拟 LuCI 数据及 RPC：验证预设摘要更新、
  自定义字段显隐、操作按钮互斥、结果弹窗、刷新后保留详情展开状态。
  390px 窄屏与亮/暗主题无页面水平溢出；预览图片见
  [桌面](ui-doh-preview.jpg) / [手机暗色](ui-doh-mobile-preview.jpg)。
- 未执行：SDK APK 构建、OpenWrt 实机、真实 LuCI / Argon 主题验收、校园网 DoH
  连通性与出站抓包。上述预览使用模拟数据，不包含真实账号或设备状态。

---

已在真实环境（校园网 / Xiaomi Mi Router 4A Gigabit v2 / OpenWrt 25.12.5，有线 WAN）跑通：

- 连通性探测、WAN 自动识别（`phy1-sta0` / `10.80.3.64`）
- 从 NAS 的 200 响应里解析出 `/zportal/login?...`，跨两跳拿到登录页
- 回填 7 个隐藏字段 + `qrCodeId` / `validCode`，提交认证并恢复上网
- `stop` 能被 SIGTERM 干净终止（不再靠 procd SIGKILL）
- `autoverify-hardening ttl`：用 `traceroute` 只剩第一跳作证；规则计数持续增长
- `autoverify-hardening ntp`：conntrack 证明回包确实来自路由器（`src=192.168.1.1`）
- `autoverify-hardening dns`：同上，且客户端解析与 HTTPS 访问均正常
- `autoverify-hardening dhcp`：**抓包看真实 DHCP 报文**，三个字段均已被替换
  （主机名 `LAPTOP-XXXXXXXX`、client-id `ether 58:ea:1f:31:04:bd`、vendor-class `MSFT 5.0`），
  且 `Requested-IP` 与租约 IP 一致 —— 换 client-id 没有导致换 IP。
  DHCPv6 侧：修好后 `(Client-FQDN)` 选项从报文中消失，报文长度 112 -> 98 字节
- `autoverify-hardening ipv6`：不只看配置 —— 若客户端地址的 `ValidLifetime`
  还在被 RA 续期，就说明没生效。实测 100 秒内减少 101 秒（单调递减、无续期）
- **出站 UA 不再自报家门**：用 `tcpdump` 抓真实探测报文，线上 `User-Agent` 已变为普通 Chrome，
  旧值里的 `OpenWrt` / `autoverify` 字样彻底消失（抓完即卸，不常驻）
- **`autoverify update-check` 退出码矩阵**：r3<r4 返 1（有新版）、r4=r4 返 0、
  r10>r4 返 0（不误报）、读不到版本与网络不通各返 2
- **apk 包**：`apk add --allow-untrusted` 安装成功，包内 14 个文件全部到位，
  与仓库源码 **MD5 逐个一致**；apk 的 conffile 机制正确保留了已有 UCI 配置（密码未丢）
- **LuCI 菜单已注册**：LuCI 索引缓存里出现了 `"autoverify"` 与 `"luci-app-autoverify"`；
  视图 JS 可经 HTTP 取到（200 / 8811 字节）；JS 与两份 JSON 语法均校验通过
- **LuCI 的 ACL 已用真实会话验证**（登录 `/cgi-bin/luci/` 拿 sysauth 会话，再 POST 到
  `/ubus/` 调 `file.exec`）：四条授权命令均返回输出；
  `autoverify login` 与 `/bin/cat /etc/shadow` 都返回 `result:[6]`（权限拒绝）
- **apk 升级路径**：`apk add` r1 -> r2 成功，配置保留

当前检测强度：**只有“账号并发会话数”**，而且是按 IP 记账的，NAT 后已经解决。
其余检测方式（见 [detection.md](detection.md)）没有证据表明在启用。

---

## 2026-09-21：r13 -> r14（LuCI 界面改版）实机验证

设备：Xiaomi Mi Router 4A Gigabit v2 / OpenWrt 25.12.5（`r33051-f5dae5ece4`）/ ramips-mt7621 /
`luci-base 26.180.75667` / argon 主题。
构建：WSL Ubuntu 26.04 + OpenWrt SDK 25.12.5（ramips/mt7621），`bash tools/build-apk.sh`
产出 `autoverify-1.0.0-r14.apk`（38140 字节，md5 `dd922023d771cbef185377ef859e5ff5`）。

- **apk 升级 r13 -> r14**：`apk add --allow-untrusted` 返回 0，输出
  `Upgrading autoverify (1.0.0-r13 -> 1.0.0-r14)`。包内 14 个文件里 12 个与仓库工作区
  **MD5 逐个一致**；另两个差异均可解释且符合预期：`/etc/config/autoverify` 保留了设备上
  已有的真实配置（逐字节未变，包内默认值另存为 `autoverify.apk-new`），
  `/etc/uci-defaults/90-autoverify-migrate` 已在安装时执行并被删除。
- **升级未中断服务**：升级前后 procd 实例 PID 均为 7772，`/etc/init.d/autoverify status`
  为 running；`validate` / `status --json` / `check` 退出码均为 0，`validate` 结论为
  “配置有效 (0 个警告)”。
- **LuCI 视图文件**：经 HTTP 取到 200 / 26832 字节，md5 与仓库一致；包内 postinst
  已刷新 mtime，浏览器不会再拿到旧 JS（实测两个地址都可取到）。
- **新页面用到的 LuCI API 在该版本上确实存在**（不靠记忆假定）：`form.js` 含
  `SectionValue` / `subsection` / `taboption`；`luci.js` 注册了 `dom` / `poll` 类
  （该版本已无独立的 `poll.js` / `dom.js` 文件）、`Poll.add`、`L.resolveDefault`；
  `rpc.js` 含 `declare`；`ui.js` 自身就在调用 `dom.content`。
- **数据契约**：`status --json` 的全部字段（含新面板读取的 20 个）在设备上均存在。
- **argon 主题兼容性**（本次两个真实坑）：argon **不提供** LuCI 26 的设计 token
  （`--background-color-low` / `--text-color-high` 等出现 0 次），带 fallback 写死浅色会在
  暗色主题下变成一块突兑的浅色 —— 所以页面自定义样式只用边框、透明度和继承色；
  argon 支持选项卡（`.cbi-tabmenu` / `[data-tab-title]`）；并且无 `title` 的 option
  根本不会渲染标题列（`form.js` 里对 `typeof title === 'string' && title !== ''` 做了判断），
  所以不需要（也不应该）用 CSS 去“隐藏空标题列”。
- **实测到的既有缺陷（本次未修，已改写界面避开）**：`status --json` 的 `daemon_pid` /
  `daemon_count` 来自 `pidof autoverify`，而 busybox 的 `pidof` 按脚本名匹配，
  **会把发起查询的进程自身（及其子 shell）一起数进去** —— 实测设备上只有 1 个守护进程
  （PID 7772）时，`status --json` 报 `daemon_pid=24242`（即本次查询自己的 PID）、
  `daemon_count=3`。命令行的 daemon PID/数量因此不可信；LuCI 面板已改为读 procd 状态。

### 跟进：r15（同一界面的内边距修复）

r14 装上后由使用者在浏览器里发现：**状态面板与操作区的内容紧贴左右两边**。
根因就在 argon 的 CSS 里 —— 它有一条全局规则把 `.cbi-section` 的内边距清零
（`.cbi-section, ... { padding: 0; border: 0; border-radius: .25rem; ... }`），
页面留白实际是靠表单行 `.cbi-value{padding:0 1rem}` 撑出来的。
而这两块面板里层是自定义的 `.av-grid` / `.av-row`，都不带内边距，于是贴边。

修法：把自定义内容块包一层 `.av-body{padding:0 1rem}`（数值跟随主题自己的表单行），
不去修改主题的 `.cbi-section`。该修复随 r15 重新构建、重新安装到实机。

仍是推测、没单独验证过的：

- ⚠️ **LuCI 页面的实际渲染效果**：本次已在设备上核实了 API 存在、文件可经 HTTP 取到、
  数据字段齐备，但**没有在浏览器里真正看过**这个新页面（无浏览器环境），
  选项卡切换、按钮与弹窗、暗色模式仍需人工看一眼（F12 控制台有无报错）。
- **开机自启**：`S95autoverify` 软链已建，但没重启过路由器验证。
- **hotplug 钩子**：出口接口 up 时立即认证这一条没单独触发过。
- **daemon 无人值守循环**：与手动 `once` 走同一套函数，但没在真实掉线时
  完整观察过它自己恢复。另外手动跑 `once` 时日志只进终端（`log()` 写 stderr），
  不进 syslog；只有 daemon 的日志会被 procd 转发到 syslog。
- **回滚路径**：本次只用过文件级“还原 HEAD 版本”来回退中间状态，没有用 `apk` 真正
  降级过一次版本。

### 跟进：r18（DoH 改为认证成功后启用）

实机定位到 `E_PORTAL_NOT_FOUND` 的完整因果链：认证前 443 被拦截 → DoH 无法建立 →
dnsmasq 仍被强制指向 `127.0.0.1#5053` → 所有探测 HTTP 000。另发现
`https-dns-proxy 2026.05.06-r1 + c-ares 1.34.8` 在只有一个 bootstrap 时于
`dns_poller.c` 直接 abort，tencent 预设恰好只写了一个地址。

本地回归：

- `python test/test_dns.py`：20 项通过，新增 post_auth 切换、HTTPS 未放行跳过、
  解析失败回退、冷却期、always 兼容、备份丢失恢复、post_auth 应用时保留明文上游。
- `PYTHON=python sh test/run.sh`：完整认证回归全部通过。
- `sh -n` 四个脚本、`node --check` LuCI 视图通过。

实机（OpenWrt 25.12.5 / ramips-mt7621）：

- 部署新脚本并 `uci set autoverify.dns.mode=post_auth` 后执行 `autoverify-apply`：
  dnsmasq 从 `noresolv + 127.0.0.1#5053` 恢复为 WAN 下发的 `10.82.66.1`，
  `nslookup` 正常。
- `autoverify reload`：04:06:27 认证成功，04:06:47 日志“已切换到 DoH 上游”，
  5053 监听存在，`nslookup www.baidu.com 127.0.0.1` 正常，状态 `online/success`。
- 手工执行 `dns_doh_before_auth` → 明文上游、DNS 正常；再 `dns_doh_after_auth` →
  重新接管、DNS 正常，证明掉线重认证路径可逆。
- 再次 reload（模拟开机）：先在 apply 阶段恢复明文，守护进程检测到已在线后
  自动补切 DoH，DNS 全程可用。

未验证：

- ⚠️ APK r18 的 SDK 构建与 `apk` 升级流程；本次是直接覆盖脚本验证。
- ⚠️ LuCI 页面在浏览器里的实际渲染（仅做了 `node --check`）。
- ⚠️ 真实“会话被校园网踢下线”后的完整守护进程循环；已验证同一组函数的切换/回退。

### 跟进：r18（探测/登录 L7 伪装与节拍）

- 探测默认地址改为 Chrome 的 `http://www.gstatic.com/generate_204`，与 Windows/Chrome 人设一致。
- `probe()`、登录页 GET、登录 POST、nextPage 补 `Accept` / `Accept-Language` /
  `Sec-Fetch-*` / `Connection`；统一加 `--compressed`（路由器 curl 只支持 gzip/deflate）。
- 新增 `tuning.login_delay`（默认 2，0 关闭），实际在 1..上限之间随机。
- 在线检查 ±15%、失败退避 ±20% 抖动；探测地址用 Fisher-Yates 随机顺序
  （`awk` 实现，seed 取 `$RANDOM`）。

本地验证：

- `sh -n`、`node --check`、`py_compile` 通过。
- `test/run.sh` 全部通过；新增断言验证 mock 门户收到的头：
  - 探测 GET：`Accept-Language: zh-CN,...`；
  - 登录 GET：`Sec-Fetch-Site: cross-site`；
  - 登录 POST：`Sec-Fetch-Site: same-origin`；
  - nextPage：`Sec-Fetch-Site: same-origin`。
- 单独用 `TUNING_LOGIN_DELAY=2` 跑一次 mock 认证：日志出现
  “登录前随机延迟 1s”，认证成功。
- 抖动/乱序单独验证：60s 得到 52–68s，300s 上限得到 247–300s，乱序每次不同。

实机（OpenWrt 25.12.5 / ramips-mt7621）：

- `http://www.gstatic.com/generate_204` 经路由器返回 204；
  `autoverify -v check` 输出 `探测 ... -> 204`。
- `uci set autoverify.tuning.login_delay=2` 后 reload：守护进程日志变为
  “在线检查间隔 60s±15%”，并自动重新接管 DoH，状态 `online/success`。
- 新探测地址下 PC 正常上网，DoH 5053 监听、`nslookup` 正常。

未验证：

- ⚠️ 真实校园门户上的登录请求头/延迟（路由器当前在线，没有主动登出）。
- ⚠️ 实机抓包确认请求头顺序；目前只验证了头存在。

## 2026-10-23：r19 修复 post_auth 认证前误启动原 DoH 配置

- 现场 `E_PORTAL_NOT_FOUND / portal`：dnsmasq 被 `https-dns-proxy` 的原始配置
  （Cloudflare + Google，`force_dns=1`、`dnsmasq_config_update='*'`）接管；
  `post_auth` 认证前调用 `dns_doh_restore`，把这份原始配置连同代理一起恢复/启动，
  dnsmasq 又回到 `127.0.0.1#5053/5054`，探测拿不到域名解析，HTTP 000。
- 修复：`dns.sh` 拆出 `dns_doh_save_original` / `dns_doh_pause` / 完整
  `dns_doh_restore`。认证前暂停只停代理、保留原始快照、把 dnsmasq 拉回明文；
  DoH apply 失败的回退也改用 pause，不再 full restore 启动原代理。
  `autoverify-apply` 的 `post_auth` 启动路径改用 `dns_doh_before_auth`。
- 附带：在线轮询通过 `av_state_online` 刷新运行期状态（只写 `/var/run`，不写闪存）；
  `status` 的 daemon PID/数量只统计 `autoverify daemon`，不再把 status 命令算进去。
- 本地：`python3 test/test_dns.py` 22 项通过，新增“原始配置本身抢占 dnsmasq”
  与“认证前暂停/再次接管/完整恢复”回归；`dash -n` 全部脚本通过；
  `sh test/run.sh` 在 WSL ext4、清除 `http_proxy/https_proxy` 后全部通过
  （未清代理时仅并发互斥用例因时序失败）。
- 构建：WSL OpenWrt 25.12.5 ramips/mt7621 SDK，`dist/autoverify-1.0.0-r19.apk`
  （48,977 字节，noarch），SHA256
  `ad76bebe505fcc438065a537c7a583cdbf87c0d8f21aef0d715725f43e7d1ec8`。
- 实机：r17 → r19，`/etc/config/autoverify` 保留（新默认配置在
  `autoverify.apk-new`）；DoH 上游为 `https://doh.pub/dns-query`，dnsmasq
  `no-resolv` + `127.0.0.1#5053`，`/etc/autoverify-dns/active` 存在；
  `gstatic` 204，`autoverify check` 返回 0，`status` 为 `online`，daemon 数量 1。
- 备份：`/root/autoverify-r17-backup-20261023-151200`（r17 脚本/配置）、
  `/root/autoverify-dnsfix-20261023-143239`（DNS 修复前配置）、
  `/tmp/autoverify-1.0.0-r17.apk`（回滚包）。
- 未验证：真实校园网会话过期后的完整认证循环；后续优化见
  `docs/hardening-backlog.md` 第七节。
