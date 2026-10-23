# 检测加固改进清单

记录 2026-10-22 的审计结论，供后续按优先级实施。

**已明确不做的两项**（用户决策，2026-10-22）：

- 不关闭 `firewall.@defaults[0].flow_offloading`。TTL 归一化只覆盖未卸载的连接，作为已知残留。
- 不启用 `autoverify.dns.redirect`（LAN DNS 强制接管）。客户端可以继续使用自己的解析器/DoH。

以下清单不包含这两项。

## 一、探测与登录流量的 L7 伪装

- [x] **1. 探测地址改成人设一致的端点**（P1）
  - 现状：MIUI + 华为 + vivo 三家手机厂商的 `generate_204`，配 Windows Chrome UA。
  - 已改为 `http://www.gstatic.com/generate_204`（Chrome 自己的探测地址，实测 204）。
  - 可选未做：`http://www.msftconnecttest.com/connecttest.txt` + 正文匹配 `Microsoft Connect Test`。
- [x] **2. 给 `probe()` 补浏览器请求头**（P1）
  - `Accept: */*`、`Accept-Language: zh-CN,zh;q=0.9,en;q=0.8`、`Connection: keep-alive`。
  - `--compressed`（路由器 curl 只支持 gzip/deflate，不写 br/zstd）。
- [x] **3. 给登录 GET / POST / nextPage 补请求头**（P1）
  - GET：`Accept` HTML 列表、`Accept-Language`、`Upgrade-Insecure-Requests`、`Sec-Fetch-Mode: navigate`、`Sec-Fetch-Dest: document`、`Sec-Fetch-Site: cross-site`。
  - POST：`Accept: */*`、`Accept-Language`、`Sec-Fetch-Site: same-origin`、`Sec-Fetch-Mode: cors`、`Sec-Fetch-Dest: empty`。
  - nextPage：同 GET 的导航头，`Sec-Fetch-Site: same-origin`。
- [x] **4. 登录 POST 前加随机延迟**（P1）
  - `tuning.login_delay`（秒，0 关闭，默认 2）；实际在 1..该值之间随机。
- [x] **5. 轮询/退避抖动与探测顺序随机化**（P1）
  - 在线检查 `60s ± 15%`；失败退避 `±20%`（不超过 `max_retry_interval`）。
  - 探测 URL 每次随机顺序；`check_online` 不再固定从第一个地址开始。
  - 未做：`check_online` 串行多地址、每个 8s，离线最坏 24s；可后续并行或缩短超时
    （默认已收敛为单地址，当前最坏 8s）。

## 二、DHCP 与人设

- [ ] **6. 对齐 DHCP option 55（PRL）**（P1）
  - `network.wan.defaultreqopts=0` + `reqopts='1 3 6 15 31 33 43 44 46 47 119 121 249 252'`。
  - 先抓 Windows 笔记本的 DHCP Request，按实际列表和顺序填；`classlessroute=0` 并把 121 放进 reqopts。
- [ ] **7. 检查 option 57（Max Message Size）**（P2）
  - 抓包对比 Windows 与 udhcpc；不一致时用 `network.wan.sendopts` 补。
- [ ] **8. TTL 人设一致性**（P3）
  - 当前 TTL=64，主机名/UA 是 Windows。offload 保留时 TTL 本来就部分覆盖；改 128 需同时加 output 链，收益有限。

## 三、IPv6

- [ ] **9. 修 `ipv6_global` 误报**（P1）
  - `autoverify` 第 1093 行把 br-lan 的 ULA `fd16::/60` 当成全局地址。
  - 只统计 WAN 上的 `2000::/3` 全局单播。
- [ ] **10. 给 TTL/NTP/DNS 补 IPv6 版本**（P2）
  - 仅在打开 LAN IPv6 时需要；`ip6 hoplimit`、`meta nfproto ipv6` 的 123/53 DNAT。
- [ ] **11. 可选关闭 `wan6`**（P2）
  - 当前 `wan6` down；如果确定不用 IPv6，减少路由器自身 RS/DHCPv6 流量。

## 四、其他可选维度

- [ ] **12. QUIC**（P2）
  - `reject` LAN→WAN UDP 443，迫使浏览器回落 TCP；但“没有 QUIC”本身也可能是特征。
- [ ] **13. DSCP/ECN 归一化**（P2）
  - `ip dscp set 0`；低风险低收益，可能影响校园网 QoS。
- [ ] **14. UAmask `proxy_host=1`**（P2）
  - 让路由器自身 HTTP 也走 UAmask；多一跳，收益不如直接补请求头。
- [ ] **15. NTP 时钟偏差检查**（P3）
  - 路由器时间不准会传染所有客户端。

## 五、观测与可靠性

- [x] **16. 修 `daemon_count` / `daemon_pid`**（P1）
  - 已完成 r19：按 `/proc/<pid>/cmdline` 只统计第二个参数为 `daemon` 的进程，
    `autoverify status` 自身不再计入。
- [ ] **17. `status --json` / `audit` 补字段**（P1）
  - `dns_mode`、`doh_active`、`offload`、TTL 规则计数、`dhcp.reqopts` 实际值。
- [ ] **18. UAmask 与 autoverify 的 UA 一致性检查**（P1）
  - 在 `autoverify-hardening status` 中对比 `UAmask.main.ua` 与 `tuning.user_agent`。
- [ ] **19. UAmask + `firewall restart` 兼容问题**（P1）
  - 实测 `firewall restart` 会让 fw4 渲染失败并清空 NAT；文档/脚本统一用 `fw4 reload`，或在 status 中提示。
- [ ] **20. 新增 `hardening-check` 自检命令**（P2）
  - 汇总 offload/flowtable、TTL 计数、DHCP PRL、UA 同步、IPv6 真全局、DNS 接管、DoH 状态。

## 六、发布与验证

- [x] **21. 构建 r19 APK**（P1）
  - 已用 WSL OpenWrt 25.12.5 ramips/mt7621 SDK 构建并升级路由器；
    `dist/autoverify-1.0.0-r19.apk`，原有配置保留。
- [ ] **22. LuCI 页面浏览器验收**（P2）
  - 新增的“启用时机”和“登录提交延迟”需要真实浏览器确认渲染/保存。
- [ ] **23. 抓包验证**（P2）
  - 探测请求头、登录 GET/POST 头、DHCP option 55/57、offload 下 TTL 实际覆盖。

## 七、DNS 认证前恢复（r19 后续）

- [ ] **24. 认证前确认 https-dns-proxy 不再运行/启用**（P2）
  - `dns_doh_before_auth` 在 dnsmasq 已是明文时直接返回；如果
    https-dns-proxy 之后才启动并再次抢 dnsmasq，仍可能断 DNS。可在 pause
    中按监听 / rc.d 状态无条件 stop + disable。
- [ ] **25. pause 时处理 `serversfile`**（P3）
  - 当前只清 `server=` 和 `noresolv`；若原配置用 `serversfile` 指向本机 DoH，
    认证前仍可能拿到坏上游。需要解析文件或临时移除。
- [ ] **26. 卸载时恢复 DNS**（P2）
  - 增加 prerm：卸载 autoverify 时若处于暂停 / 接管状态，调用
    `dns_doh_restore`，恢复用户原始 https-dns-proxy 配置。
- [ ] **27. 日志级别分级**（P3）
  - 正常状态切换目前也写 `daemon.err`；可拆成 notice / err，减少 syslog 噪声。

## 不建议做

- IPID 改写（分片数据损坏风险）。
- TCP window/MSS 改写（流控字段，改错会限速/丢包）。
- TCP 时间戳（nftables 改不了，需用户态代理）。
- TLS 中间人（破坏证书固定）。
- 改 MAC OUI（影响校园网按 MAC 绑定的会话）。
- `update-check` 的 UA（请求走 HTTPS，校园看不到；改了只是给 GitHub 看）。
