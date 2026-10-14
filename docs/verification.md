# 实测记录

> 本文件区分本地验证与真实校园网 / OpenWrt 实测；本地结果不代表设备验收。
> 复现命令和验证范围见各条目自身。

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
