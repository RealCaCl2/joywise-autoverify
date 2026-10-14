# joywise-autoverify 开发计划

## 2026-10-14：DoH 与 LAN DNS 接管拆分

- 保留 `dns.enabled` 控制 DoH，新增 `dns.redirect` 控制 LAN 53 重定向，缺失时默认关闭。
- 应用时清理旧重定向，再按显式开关创建；关闭接管不恢复或停用 DoH。
- 先添加默认行为、旧规则清理、模式切换与失败路径回归，再修改运行时、LuCI 和说明。
- 本地验证 DNS/认证回归和脚本语法；实机与 APK 构建另行记录，不推送或发布。

> 本计划基于当前项目结构、已有实现和现有测试体系制定。
>
> 目标是提升认证可靠性、配置安全性、运行可观测性、网络暴露面审计能力，以及 OpenWrt 环境下的可维护性。
> 本计划不引入深层协议指纹改写、TLS/QUIC 代理或多套终端身份模拟。

## 执行版说明

本文件既是设计记录，也是本轮变更的验收清单。实施以“可回滚、可独立验证、一个阶段一个
提交”为硬约束；没有真实 OpenWrt 设备时，不把设备验收标记为完成。

当前基线：`main` 的 `v1.0.5`，本轮已先完成认证锁、运行状态、`validate` 和 `nextPage` 严格校验，
并在本阶段补充 `status`、`audit` 与机器可读输出；设备验收仍未完成。
现有 mock 回归测试是行为基线，任何阶段都必须保持通过。

执行顺序和状态：

| 阶段 | 交付物 | 状态 |
|---|---|---|
| 0 | `agent.md`、本计划、基线提交 | 已完成 |
| 1 | 认证互斥、stale lock、中断清理、并发测试 | 已实现；设备/CI 待验证 |
| 2 | 统一运行状态和稳定错误码 | 已实现；CI/设备待验证 |
| 3 | `validate` 配置/环境检查 | 已实现；CI/设备待验证 |
| 4 | 安全的 `nextPage` 校验与失败传播 | 已实现；CI/设备待验证 |
| 5 | `status`、`audit` 和只读 JSON 输出 | 已实现；CI/设备待验证 |
| 6 | LuCI 状态/诊断入口、最小权限 ACL | 已实现；真实 LuCI 待验证 |
| 7 | 门户解析异常覆盖、文档、CI/打包检查 | 代码、文档和 CI 检查已实现；SDK/CI/设备待验证 |

阶段 1 是本轮第一实现目标。若后续阶段需要真实设备、额外权限或会改变既有网络策略，
应暂停在前一阶段的提交点，并在验收记录中说明原因，而不是扩大修改范围。

## 原子提交规则

- 阶段 0 提交只包含协作指南和计划，不修改认证行为。
- 每个实现阶段完成后立即提交，提交前执行该阶段的静态检查和可用的本地回归。
- 测试、文档或打包修复若属于同一阶段，和该阶段一起提交；不把无关重构带入。
- 回滚优先使用 `git revert`；不删除运行期目录、不覆盖用户配置、不使用不可逆 Git 命令。
- `dist/`、SDK、真实 UCI 配置、日志和临时响应永不提交。

---

# 1. 项目目标

### 1.1 总体目标

在保持现有 zportal 认证流程和 UCI 配置兼容性的前提下，完成以下改进：

1. 防止多个入口并发发起认证请求；
2. 提高认证状态机和失败原因的可观测性；
3. 避免密码、Cookie 和临时认证数据不必要地暴露；
4. 增加只读配置检查和网络暴露面审计；
5. 让配置状态与系统实际生效状态可对照查看；
6. 改善 LuCI 状态展示和操作反馈；
7. 增强门户解析、异常网络和 OpenWrt BusyBox 环境下的测试覆盖；
8. 保持纯 POSIX `sh`、低依赖、可回滚和现有 APK 构建方式。

### 1.2 非目标

以下内容不纳入本期开发：

- IPID、TCP window、TCP timestamp 或 TCP option 的改写；
- TLS/JA3/JA4 指纹伪造；
- HTTP/2 或 QUIC 指纹伪造；
- 多套 User-Agent、DHCP 身份或 TTL 的随机切换；
- 模拟多个浏览器或多个终端行为；
- 将所有业务流量强制导入用户态代理；
- 修改现有 zportal 协议字段和提交顺序，除非已有兼容性测试证明需要调整。

---

# 2. 现状基线

### 2.1 主要源码

| 文件 | 职责 |
|---|---|
| `files/usr/sbin/autoverify` | 连通性检测、门户发现、登录、daemon、更新检查 |
| `files/usr/lib/autoverify/cfg.sh` | UCI、环境变量和默认值读取 |
| `files/usr/sbin/autoverify-apply` | TTL、NTP、DNS、DHCP、IPv6 配置落地 |
| `files/usr/sbin/autoverify-hardening` | 加固配置开关和状态查看 |
| `files/etc/init.d/autoverify` | procd 服务管理 |
| `files/etc/hotplug.d/iface/99-autoverify` | 接口上线触发认证 |
| `files/www/luci-static/resources/view/autoverify.js` | LuCI 设置页面 |
| `files/usr/share/rpcd/acl.d/luci-app-autoverify.json` | LuCI RPC 权限 |
| `test/run.sh` | 端到端回归测试入口 |
| `test/mock_portal.py` | 本地 mock zportal |
| `package/autoverify/Makefile` | OpenWrt 包定义 |
| `.github/workflows/ci.yml` | CI、语法检查、测试和构建 |

### 2.2 当前关键风险点

1. daemon、hotplug、LuCI 和手工命令可能同时发起认证；
2. `nextPage` 请求失败时的错误上下文不够完整；
3. 密码可能作为 `curl` 命令参数存在于进程列表中；
4. 配置值缺少统一的预检查和范围校验；
5. LuCI 主要是配置表单，缺少持续状态和历史结果展示；
6. 加固开关与系统实际 nftables、网络和服务状态需要更直观的对照；
7. 认证过程缺少统一阶段、耗时和失败分类；
8. 并发、超时、信号中断、过期锁等测试尚未覆盖完整；
9. `autoverify-apply` 对部分命令失败的处理需要区分“可继续”和“必须失败”；
10. 当前项目缺少统一的版本化运行状态数据结构。

---

# 3. 总体实施策略

### 3.1 实施顺序

按以下顺序开发：

1. 认证互斥和生命周期控制；
2. 配置校验和认证状态模型；
3. 敏感数据处理和 nextPage 错误处理；
4. `status`、`validate`、`audit` 命令；
5. LuCI 状态区和诊断入口；
6. 门户解析和异常网络兼容性增强；
7. 测试、文档、打包和设备验证。

### 3.2 兼容性原则

- 保持现有 UCI section 和 option 名称不变；
- 新配置项必须提供默认值；
- 旧配置不迁移时也能正常运行；
- 不改变 `check`、`once`、`daemon` 的现有退出码语义；
- 不依赖 Bash、Python、Node 或大型运行时；
- 运行时继续以 BusyBox `ash`、`curl`、`uci`、`ip`、`nft` 等 OpenWrt 工具为基础；
- 生成文件继续由源配置和脚本生成，不直接维护构建产物；
- 每项行为变化都必须可以通过配置关闭或回滚。

---

# 4. 阶段一：认证互斥与生命周期控制

## 4.1 目标

确保任意时刻最多只有一个认证任务执行，避免 daemon、hotplug、LuCI 和手工命令重复提交。

## 4.2 设计

新增统一的认证锁机制，所有会调用认证流程的入口都经过同一个 helper。

建议锁位置：

```text
/var/run/autoverify/auth.lock
```

锁内容建议包含：

```text
pid=<进程号>
started_at=<时间>
source=<daemon|hotplug|luci|manual>
operation=<once|login>
```

锁机制要求：

- 使用 OpenWrt 可用的原子创建方式；
- 获取锁失败时返回明确的“已有认证任务运行”状态；
- 检查锁内 PID 是否仍存在；
- 发现旧 PID 不存在时清理 stale lock；
- 认证结束时清理锁；
- 收到 `TERM`、`INT` 时执行清理；
- 清理操作必须幂等；
- 锁失败不能阻塞 daemon 的主循环；
- `debug`、`check`、`status`、`audit` 不应获取认证锁。

## 4.3 需要修改的文件

- `files/usr/sbin/autoverify`
  - 增加锁 helper；
  - 在 `login`、`once`、daemon 内部认证入口统一加锁；
  - 让 `run_once` 和 daemon 使用相同的认证函数；
  - 增加触发来源变量；
  - 在所有退出路径释放锁。
- `files/etc/hotplug.d/iface/99-autoverify`
  - 传递触发来源；
  - 不再自行形成另一套认证控制逻辑。
- `files/www/luci-static/resources/view/autoverify.js`
  - 对认证按钮增加执行中的 UI 状态；
  - 二次点击时给出明确提示。
- `test/run.sh`
  - 增加并发测试。
- `test/mock_portal.py`
  - 支持延迟 POST 响应，用于模拟认证占用锁。

## 4.4 验收标准

- 两个同时执行的 `once` 中只有一个会提交 POST；
- hotplug 与 daemon 同时触发时只有一个认证请求；
- 认证被 SIGTERM 中断后锁会清理；
- 旧 PID 锁不会永久阻塞认证；
- 锁文件中的密码、Cookie 和认证字段不得出现；
- 认证结束后 `/var/run/autoverify/auth.lock` 不残留；
- 现有 10 个回归测试继续通过。

---

# 5. 阶段二：统一认证状态模型

## 5.1 目标

让命令行、daemon 和 LuCI 能够查看一致的当前状态和最近一次执行结果。

## 5.2 状态文件

建议新增运行时状态文件：

```text
/var/run/autoverify/status
```

必要时增加持久化摘要：

```text
/var/lib/autoverify/last-result
```

运行时状态与持久化状态必须区分：

- `/var/run`：当前进程、锁、当前阶段；
- `/var/lib`：最近一次成功或失败摘要，不保存密码和完整认证字段。

建议字段：

```text
state=offline|checking|discovering|fetching|submitting|following|verifying|online|failed
source=daemon|hotplug|luci|manual
started_at=<时间>
finished_at=<时间>
duration_ms=<耗时>
last_result=success|online|failed|skipped|busy
last_error_code=<稳定的内部错误码>
last_error_stage=<阶段>
last_http_code=<状态码>
last_portal_origin=<脱敏后的 origin>
next_retry_at=<时间>
```

不得记录：

- 密码；
- Cookie；
- 完整认证 URL 参数；
- 完整响应体；
- 完整隐藏字段。

## 5.3 错误分类

建议建立稳定的错误码，例如：

| 错误码 | 含义 |
|---|---|
| `E_CONFIG` | 配置无效 |
| `E_DEPENDENCY` | 依赖命令缺失 |
| `E_PROBE_TIMEOUT` | 探测超时 |
| `E_PORTAL_NOT_FOUND` | 未发现门户地址 |
| `E_LOGIN_PAGE` | 登录页获取失败 |
| `E_LOGIN_FIELDS` | 登录页字段缺失 |
| `E_LOGIN_REQUEST` | 登录请求失败 |
| `E_LOGIN_RESPONSE` | 登录响应无法解析 |
| `E_NEXT_PAGE` | nextPage 请求失败 |
| `E_VERIFY_OFFLINE` | 认证后仍无法联网 |
| `E_BUSY` | 已有认证任务运行 |
| `E_INTERRUPTED` | 任务被中断 |

## 5.4 需要修改的文件

- `files/usr/sbin/autoverify`
- `files/usr/lib/autoverify/cfg.sh`
- `files/etc/init.d/autoverify`
- `files/www/luci-static/resources/view/autoverify.js`
- `files/usr/share/rpcd/acl.d/luci-app-autoverify.json`
- 新增：`files/usr/lib/autoverify/state.sh`，如确认不会增加过度抽象

## 5.5 验收标准

- `status`、LuCI 和 daemon 使用相同状态字段；
- 当前状态在进程退出后不会遗留为运行中；
- 状态更新失败不会阻断认证主流程；
- 认证中断后能区分 `E_INTERRUPTED` 和普通网络失败；
- 状态文件权限不低于配置文件的安全要求；
- 状态文件不包含密码、Cookie 或完整隐藏字段。

---

# 6. 阶段三：配置校验

## 6.1 目标

在启动、保存应用和手工执行前，尽早发现无效配置，减少运行时才失败的情况。

## 6.2 新增命令

```sh
autoverify validate
```

约定：

- `0`：配置有效；
- `1`：配置存在错误；
- `2`：校验环境不完整或命令缺失；
- 默认只读，不修改配置；
- 支持 `-v` 输出更多检查细节。

## 6.3 校验项目

### 配置值

- `main.enabled` 是否为布尔值；
- 用户名和密码是否配置；
- `portal.port` 是否为 `1..65535`；
- `expect_code` 是否为合法 HTTP 状态码；
- 所有 timeout 和 interval 是否为正整数；
- `retry_interval <= max_retry_interval`；
- TTL 是否在 `1..255`；
- `probe_urls` 是否非空；
- URL 是否包含支持的 scheme；
- `portal.url` 使用 `%WANIP%` 时格式是否合理；
- User-Agent 是否为空。

### 系统环境

- `curl`、`ip`、`uci` 是否存在；
- `WAN_IF` 是否存在或能从默认路由推断；
- `lan_dev` 是否存在；
- `hotplug_if` 是否在网络配置中存在；
- `dnsmasq` 是否存在；
- 启用 DNS 收敛时本地 53 端口是否监听；
- 启用 NTP 收敛时本地 123 端口是否监听；
- 配置文件权限是否为 `600`；
- 相关脚本是否具有执行权限。

### 组合关系

- 开启 TTL 时检查 nft 是否存在；
- 开启 DNS/NTP 时检查 firewall 配置能力；
- 开启 DHCP 伪装时检查 WAN 接口；
- 开启 IPv6 防护时检查 `dhcp.lan` section；
- 检测 flowtable 并给出警告，而不是直接阻断；
- 新增配置项缺失时使用兼容默认值并标记为默认值。

## 6.4 LuCI 集成

保存配置前增加前端基础校验；保存后由后端再次执行完整校验。

建议行为：

- 错误：阻止应用；
- 警告：允许应用，但显示具体说明；
- 信息：显示使用的默认值。

## 6.5 验收标准

- 任何非法数值都能在认证前被发现；
- 校验输出不包含密码；
- 校验命令在没有真实校园网的情况下可以运行；
- 旧配置缺少新增 section 时不报无法识别；
- CI 覆盖有效配置、缺失配置和非法配置。

---

# 7. 阶段四：认证安全和 nextPage 处理

## 7.1 避免密码出现在进程参数

当前认证参数通过 `curl --data-urlencode` 传递。计划评估以下实现，优先选择 OpenWrt 可用且不增加新依赖的方案：

1. 使用 curl 的标准输入或临时配置文件；
2. 使用权限严格的临时请求文件；
3. 临时文件使用 `umask 077`；
4. 请求完成后立即删除；
5. 不把密码写入状态文件、日志或 debug 输出。

实现前需要在真实目标设备上确认当前 curl 版本支持的安全传参方式。

## 7.2 临时文件安全

- 创建临时目录前设置严格 umask；
- cookie 文件权限设为 `600`；
- 页面、响应、表单字段文件只在认证期间存在；
- `EXIT`、`TERM`、`INT` 路径都清理临时数据；
- 清理失败时记录文件类型而不记录内容；
- 不改变现有调试信息的脱敏策略。

## 7.3 nextPage 严格处理

`follow_next_page()` 计划改为：

- 缺少 `nextPage` 时记录可区分的警告；
- 相对路径按照当前门户 origin 解析；
- 绝对 URL 只允许与当前门户 origin 相同；
- 拒绝非 HTTP/HTTPS URL；
- 限制最大 URL 长度；
- 捕获 curl 退出码；
- 记录 HTTP 状态码；
- 请求失败时返回失败状态；
- 即使请求成功，仍然必须执行最终连通性验证；
- 日志中不输出完整查询参数。

## 7.4 验收标准

- `nextPage` 正常时仍通过现有 mock 测试；
- 缺少 `nextPage` 时有明确诊断；
- 外部 origin 的 URL 不会被访问；
- nextPage 网络失败不会被记录为完整认证成功；
- 最终连通性失败仍返回 `E_VERIFY_OFFLINE`；
- 失败路径上的临时文件都被删除。

---

# 8. 阶段五：新增 `status`、`audit` 和诊断能力

## 8.1 `status`

新增：

```sh
autoverify status
```

输出内容：

```text
== 服务 ==
  enabled
  daemon PID
  daemon 是否运行
  重复进程数量

== 认证状态 ==
  当前阶段
  当前触发来源
  最近一次结果
  最近一次耗时
  最近一次错误阶段
  下次重试时间

== 网络 ==
  WAN 接口
  WAN IPv4
  WAN MAC（必要时脱敏）
  当前在线状态
```

`status` 只读，不触发探测之外的修改，不发送认证请求。

## 8.2 `audit`

新增：

```sh
autoverify audit
```

审计报告分为四组。

### 认证服务

- daemon 是否运行；
- 是否存在重复 daemon；
- 锁文件是否正常；
- 最近一次成功、失败和跳过记录；
- 是否存在异常 stale lock。

### 网络路径

- 默认路由和 WAN 接口；
- LAN bridge 是否存在；
- 是否存在 IPv6 全局地址；
- 是否存在 IPv6 默认路由；
- 是否存在额外 WAN、VPN 或代理接口；
- 是否存在旁路接口配置。

### 防火墙与服务实际状态

- TTL 规则文件是否存在；
- TTL 规则是否被 `inet fw4` 加载；
- TTL 规则计数；
- 是否存在 flowtable；
- DNS UDP/TCP redirect 是否加载；
- NTP redirect 是否加载；
- dnsmasq 是否监听 53；
- sysntpd 是否监听 123；
- LAN RA/DHCPv6 实际配置。

### 未覆盖的网络特征

以明确的只读信息展示：

- DoH 不受 DNS redirect 覆盖；
- HTTPS/TLS 层信息不由本项目处理；
- QUIC 不由本项目处理；
- 并发连接和流量行为不由本项目处理；
- flow offloading 可能使 TTL 规则覆盖不完整。

这部分只做状态和范围说明，不自动修改流量策略。

## 8.3 输出格式

当前同时支持人类可读文本和固定字段 JSON：

```sh
autoverify check --json
autoverify status --json
autoverify audit --json
```

JSON 输出必须使用固定字段名，便于 LuCI 或外部监控读取。

## 8.4 验收标准

- 没有 `nft`、`ip` 或某个可选服务时仍能输出部分报告；
- 缺失信息显示为 `unknown` 或明确的不可用状态；
- audit 不修改 UCI、防火墙或网络接口；
- 输出中不包含密码、Cookie 和完整认证字段；
- JSON 输出可以被严格解析。

---

# 9. 阶段六：LuCI 状态页面

## 9.1 目标

在保留当前表单的基础上，增加运行状态、审计结果和操作反馈。

## 9.2 页面结构

建议增加以下区域：

### 当前状态

- 在线/离线/认证中；
- daemon 状态；
- 当前认证锁状态；
- 最近一次认证结果；
- 最近一次认证耗时；
- 最近一次失败原因。

### 网络状态

- WAN 接口和 IPv4；
- 当前默认路由；
- IPv6 泄露提示；
- flowtable 提示；
- DNS/NTP 监听状态。

### 加固实际状态

每一项显示两列：

```text
配置开关 | 系统实际状态
```

项目包括：

- TTL；
- NTP；
- DNS；
- DHCP；
- IPv6。

### 操作

保留现有按钮，并增加：

- 查看运行状态；
- 校验配置；
- 执行只读审计；
- 刷新状态。

## 9.3 RPC 权限

更新 ACL 时遵循最小权限：

- 允许 `status`、`validate`、`audit` 只读执行；
- 不开放强制登录命令；
- 不开放任意 shell；
- 不允许通过页面读取敏感文件；
- 仅保留当前必要的 UCI 读写和 apply 权限。

## 9.4 验收标准

- 页面加载失败时给出明确通知；
- 命令无输出时仍显示退出码和状态；
- [x] 执行期间按钮不会无限重复提交；
- [x] 状态显示与命令行输出一致；
- [x] JSON 和 JavaScript 语法检查通过；
- 在真实 LuCI 浏览器环境中完成一次手工验证。

---

# 10. 阶段七：门户解析和网络异常增强

## 10.1 门户发现

保持现有三种发现方式，同时增加：

- 记录完整重定向链的摘要；
- 处理 Location 前后空白；
- 对相对 Location 做规范化；
- 限制重定向跳数和 URL 长度；
- 区分“没有重定向”和“重定向不是 zportal”；
- 区分响应头发现和响应体发现；
- 失败时输出最后一次探测的状态码、响应头摘要和响应体摘要。

## 10.2 登录页字段解析

保持当前 `field()` 兼容逻辑，并增加测试覆盖：

- 单引号属性；
- 双引号属性；
- 属性顺序变化；
- 属性跨行；
- 重复 `value` 属性；
- HTML 注释和无关同名字段；
- 字段缺失；
- 空字段；
- 页面编码变化。

如果继续使用 POSIX 工具，必须优先保证 BusyBox 版本可运行，不直接引入大型 HTML 解析依赖。

## 10.3 JSON 解析

评估以下优先级：

1. 使用 OpenWrt 已有的 `jsonfilter`；
2. 在没有 `jsonfilter` 时保留当前纯文本 fallback；
3. 对转义字符和字段顺序增加测试；
4. 无法解析时保留响应摘要和 HTTP 状态码。

## 10.4 网络失败分类

将 curl 失败区分为：

- DNS 解析失败；
- 连接超时；
- TLS/协议错误；
- 对端关闭连接；
- 超过重定向上限；
- 响应体写入失败。

若 curl 版本无法可靠区分某些错误，至少保留退出码和执行阶段，不伪造更具体的原因。

## 10.5 验收标准

- [x] 现有 mock 用例保持兼容；
- [x] 新增的两跳、相对路径、单引号属性、跨行属性用例通过；
- [x] 每个失败分支都有可区分的日志阶段名；
- [x] 无法解析时不丢失 HTTP 状态码与响应摘要；
- [x] 解析逻辑使用 BusyBox 可用的 `awk` / `sed` / `grep`（不使用 GNU 扩展）。

---

# 11. 阶段八：测试计划

## 11.1 Shell 静态检查

继续在 CI 执行：

```sh
dash -n ...
shellcheck -s sh ...
```

新增脚本后必须加入检查列表。

## 11.2 认证并发测试

在 `test/run.sh` 增加：

- 两个 `once` 同时运行；
- daemon 与 once 并行；
- hotplug 与 once 并行；
- mock POST 延迟时第二次调用；
- 锁中 PID 有效；
- 锁中 PID 无效；
- 锁文件损坏；
- 认证进程被终止；
- 锁清理失败。

## 11.3 配置校验测试

覆盖：

- 正常默认配置；
- 空账号；
- 空密码；
- 非法端口；
- 非法 TTL；
- 零 timeout；
- 负数 interval；
- 空 probe URL；
- 无效 URL；
- 缺失 section；
- 旧版配置；
- 环境变量 fallback；
- UCI 优先级。

## 11.4 认证流程测试

覆盖：

- 正常 success；
- online；
- fail；
- 非 JSON；
- 缺少 result；
- 缺少 nextPage；
- 外部 nextPage；
- nextPage 请求失败；
- 最终 check 失败；
- 多跳重定向；
- Location 头；
- 页面内跳转；
- 相对路径；
- 页面字段缺失；
- 重复 HTML 属性。

## 11.5 状态和审计测试

- 命令退出码正确；
- 输出不泄露密码；
- 缺失可选系统命令时仍可部分输出；
- JSON 输出合法；
- 状态文件正确创建、更新和清理；
- stale 状态不会显示为运行中。

## 11.6 OpenWrt 设备验证

在真实 OpenWrt 设备上验证：

- BusyBox ash；
- 旧版 curl；
- UCI 配置读写；
- procd stop/restart；
- hotplug ifup；
- nftables 规则加载；
- DNS/NTP 服务重启；
- DHCP 参数更新；
- IPv6 配置回滚；
- LuCI 页面渲染；
- 长时间 daemon 运行。

---

# 12. 阶段九：文档和发布

## 12.1 README 更新

增加：

- 新命令 `status`、`validate`、`audit`；
- 状态文件位置和字段说明；
- 认证锁行为；
- 失败错误码；
- nextPage 处理逻辑；
- 配置校验流程；
- 加固项“配置状态/实际状态”的区别；
- 诊断命令示例；
- 回滚步骤。

## 12.2 新增文档

建议新增：

```text
docs/operations.md
```

内容包括：

- 安装后检查；
- 配置校验；
- 认证失败排查；
- daemon 和 hotplug 排查；
- DNS、NTP、TTL、IPv6 状态检查；
- 日志和状态文件；
- 配置回滚；
- 升级注意事项。

## 12.3 版本和迁移

- 新增 UCI 配置项必须提供默认值；
- 必要时扩展 `90-autoverify-migrate`；
- 包版本增加 release 号；
- 不覆盖用户已有账号密码；
- APK 升级后验证 LuCI JS 缓存刷新逻辑；
- 在 release notes 中列出新命令和行为变化。

---

# 13. 阶段十：构建和发布验收

## 13.1 CI 检查项

CI 必须包括：

1. POSIX shell 语法检查；
2. ShellCheck；
3. Node JavaScript 语法检查；
4. JSON 解析；
5. mock 门户回归测试；
6. 并发和状态测试；
7. 配置校验测试；
8. OpenWrt SDK 构建；
9. APK 文件存在性检查；
10. 包内文件清单检查。

## 13.2 APK 验收

确认：

- 所有脚本进入 APK；
- 新增文件权限正确；
- `/etc/config/autoverify` 是 conffile；
- LuCI 菜单和 ACL 文件存在；
- postinst 不在构建主机上执行真实系统操作；
- 安装、升级、保留已有配置均正常。

## 13.3 设备验收

安装后依次执行：

```sh
/usr/sbin/autoverify validate
/usr/sbin/autoverify status
/usr/sbin/autoverify audit
/usr/sbin/autoverify check
/etc/init.d/autoverify restart
logread -e autoverify
```

然后验证：

- 配置保存并应用；
- LuCI 页面刷新；
- 接口 ifup 触发；
- 认证失败重试；
- 认证中停止服务；
- 重启后状态恢复；
- 升级后配置保留。

---

# 14. 建议的提交拆分

为降低回归风险，建议按以下提交拆分：

1. `feat: add authentication lock and stale lock recovery`
2. `feat: add runtime authentication state`
3. `feat: add configuration validation command`
4. `fix: harden nextPage handling and error reporting`
5. `fix: reduce credential exposure in curl invocation`
6. `feat: add status and audit commands`
7. `feat: show runtime status in LuCI`
8. `test: cover concurrent authentication and invalid configuration`
9. `test: add OpenWrt compatibility smoke checks`
10. `docs: document operations, diagnostics and rollback`
11. `build: include new files and CI checks`

每个提交都应保持可独立检查，避免把认证逻辑、LuCI、打包和大规模格式化混在同一个提交中。

---

# 15. 完成定义

当以下条件全部满足时，认为本计划完成：

- 认证入口具备统一互斥控制；
- stale lock 和中断清理经过测试；
- `status`、`validate`、`audit` 可用；
- 状态、日志和 LuCI 不泄露密码、Cookie 或完整认证字段；
- nextPage 错误可区分并且不会被误报为完整成功；
- 配置错误可在启动前发现；
- 配置开关和系统实际状态可以对照查看；
- LuCI 能展示核心运行状态；
- 并发、异常网络、信号、配置和门户响应测试覆盖；
- 现有 10 个 mock 门户用例继续通过；
- POSIX shell、JSON、JavaScript 和 APK 构建检查通过；
- 至少在一台真实 OpenWrt 设备上完成安装、启动、认证、停止、升级和回滚验证；
- README 和运维文档同步更新；
- 工作区 diff 中不包含无关文件和构建缓存。

---

# 16. 推荐首个开发任务

首个实现迭代建议只做以下三项：

1. 认证互斥锁；
2. stale lock 清理和 SIGTERM 清理；
3. 并发认证 mock 测试。

理由：这三项影响认证稳定性最大、改动范围相对可控，而且完成后可以为后续状态管理和 LuCI 展示提供可靠基础。

---

# 17. 详细设计：认证锁

## 17.1 目录与文件

```
/var/run/autoverify/          0700   运行期状态（tmpfs，重启自动清空）
  auth.lock.d/                0700   锁目录，存在即代表已占用
    owner                     0600   pid / started_at / source / operation
  status                      0600   当前运行状态
/var/lib/autoverify/          0700   跨重启保留
  last-result                 0600   最近一次认证结果摘要
```

`/var/run` 是 tmpfs，重启后自动清空，因此不需要额外的开机清理逻辑；代价是重启后运行期状态丢失，这是可接受的（`/var/lib/last-result` 保留结论）。

## 17.2 获取锁的算法

原子性用 **目录创建** 而不是文件创建：`mkdir` 在 POSIX 下是原子的，且不依赖 `flock`（BusyBox 不保证编入该 applet）。

```sh
LOCK_DIR=/var/run/autoverify
LOCK=$LOCK_DIR/auth.lock.d

acquire_auth_lock() {
	mkdir -p "$LOCK_DIR" || return 1
	chmod 700 "$LOCK_DIR" 2>/dev/null
	umask 077
	if mkdir "$LOCK" 2>/dev/null; then
		write_lock_owner "$$" "$SOURCE"          # > "$LOCK/owner"
		LOCK_HELD=1
		return 0
	fi
	if lock_is_stale; then
		reap_stale_lock                            # rm -rf "$LOCK"
		mkdir "$LOCK" 2>/dev/null && { write_lock_owner "$$" "$SOURCE"; LOCK_HELD=1; return 0; }
	fi
	return 3                                       # busy
}
```

## 17.3 stale 判定规则

按顺序判定，任一命中即认为锁已失效：

1. `owner` 文件不存在或不可读；
2. `pid` 字段不是纯数字；
3. `/proc/<pid>` 不存在；
4. `/proc/<pid>/cmdline` 中不含 `autoverify` —— 防止 **PID 复用** 误判；
5. `now - started_at` 超过 `tuning.lock_max_age`（默认 300 秒）。

第 3、4 条依赖 `/proc`，OpenWrt 默认挂载，存在；若判定过程本身出错（例如 `started_at` 非数字），一律按“不可判定”处理并回退到第 5 条的时间上限，避免因为读数失败而永久锁死。

## 17.4 释放锁

```sh
release_auth_lock() {
	[ "$LOCK_HELD" = "1" ] || return 0
	_owner_pid=$(sed -n 's/^pid=//p' "$LOCK/owner" 2>/dev/null)
	[ "$_owner_pid" = "$$" ] || return 0        # 只删自己的锁
	rm -rf "$LOCK"
	LOCK_HELD=0
	return 0
}
trap 'release_auth_lock' EXIT INT TERM
```

`release_auth_lock` 必须幂等：目录已不存在时仍然返回 0。只删自己的锁，避免第二个进程误删正在运行者的锁。

## 17.5 明确不做的事

- 不使用 `flock`：BusyBox 不保证编入；
- 不排队等待：第二个请求立即返回 busy（退出码 3），不 sleep 等锁，避免 hotplug 堆积；
- `check` / `debug` / `status` / `validate` / `audit` 不加锁；
- 不在 `login` 与 `once` 之间做“谁优先”的仲裁，先到先得。

## 17.6 触发来源传递

通过环境变量 `AUTOVERIFY_SOURCE` 传递，取值 `daemon|hotplug|luci|manual`：

- daemon 内部调用时设为 `daemon`；
- hotplug 脚本显式传 `hotplug`；
- LuCI 通过 `fs.exec` 的 `env` 传 `luci`；
- 手工执行时默认 `manual`。

该变量只用于日志与状态记录，不参与权限或行为分支。

---

# 18. 详细设计：状态与错误码落地

## 18.1 写入方式

- 先写同目录临时文件，再用 `mv` 覆盖（原子替换），读者不会读到半截内容；
- 每次写整个文件，不做行内更新；
- 写入失败只记日志，**不改变认证结果与退出码**。

## 18.2 字段契约

| 字段 | 类型 | 示例 | 出现时机 |
|---|---|---|---|
| `state` | enum | `online` | 每次状态变更 |
| `source` | enum | `hotplug` | 任务开始 |
| `operation` | enum | `once` | 任务开始 |
| `started_at` | epoch | `1788704520` | 任务开始 |
| `finished_at` | epoch | `1788704523` | 任务结束 |
| `duration_ms` | int | `2840` | 任务结束 |
| `attempt` | int | `3` | daemon 重试计数 |
| `result` | enum | `success` | 任务结束 |
| `error_code` | string | `E_LOGIN_FIELDS` | 失败时 |
| `error_stage` | enum | `submit` | 失败时 |
| `http_code` | int | `200` | 有 HTTP 交互时 |
| `portal_origin` | string | `http://10.82.66.10:9090` | 定位到门户后 |
| `next_retry_at` | epoch | `1788704820` | daemon 退避时 |
| `lock_pid` | int | `4821` | 持锁期间 |
| `version` | string | `1.0.0-r13` | 始终 |

## 18.3 读取约定

只读消费者使用 `sed -n 's/^key=//p' "$1"` 取值，**不使用 `source` / `eval`** —— 状态文件虽然由本程序生成，但读取方不得执行其内容。

## 18.4 错误码到退出码的映射

| 错误码 | 退出码 | 说明 |
|---|---|---|
| 认证成功 / `result=online` | 0 | 正常 |
| `E_CONFIG`、`E_LOGIN_REQUEST`、`E_LOGIN_RESPONSE`、`E_LOGIN_FIELDS`、`E_LOGIN_PAGE`、`E_PORTAL_NOT_FOUND`、`E_VERIFY_OFFLINE` | 1 | 认证未成功 |
| `E_BUSY` | 3 | 已有认证任务运行 |
| `E_DEPENDENCY`、`E_INTERRUPTED` | 1 | 与普通失败同在 1，靠 `error_code` 区分 |
| `status` / `audit` 内部错误 | 2 | 与认证结果无关 |
| `validate` 配置错误 | 1 | 见 6.2 |
| `validate` 环境不完整 | 2 | 见 6.2 |

本期退出码的唯一扩展是新增 `3`（busy），且只影响 `once` 与 `login`。`check` 的 `0/1` 语义保持不变。

## 18.5 与现有实现的关系

保留现有 `log()` / `logv()` / `die()`；错误码作为日志的附加字段追加，**不改变现有日志文案**，避免破坏已经形成的排障习惯与文档描述。

---

# 19. 命令接口规范

## 19.1 退出码矩阵

| 命令 | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `check` | 在线 | 离线 | — | — |
| `login` | 成功或 online | 失败 | — | 已有任务 |
| `once` | 成功（含本来就在线） | 失败 | — | 已有任务 |
| `daemon` | 收到 SIGTERM 正常退出 | 启动失败 | — | — |
| `debug` | 产出报告 | 探测或解析失败 | — | — |
| `update-check` | 已是最新 | 有新版本 | 查询失败 | — |
| `status` | 始终 | — | 内部错误 | — |
| `validate` | 配置有效 | 配置有错误 | 环境不完整 | — |
| `audit` | 始终 | — | 内部错误 | — |

## 19.2 选项

- `-v` / `--verbose`：详细日志，语义与现状一致，必须作为参数传入（UCI 是唯一事实来源）；
- `--json`：仅 `status`、`audit`、`check` 支持，输出机器可读结果；
- `--probe`：仅 `status` 支持，显式允许其触发一次连通性探测（默认不探测，保持只读）；
- `AUTOVERIFY_SOURCE`：内部环境变量，见 17.6。

## 19.3 JSON 契约

```json
{
  "version": "1.0.0-r13",
  "state": "online",
  "source": "daemon",
  "started_at": 1788704520,
  "duration_ms": 2840,
  "result": "success",
  "error_code": null,
  "error_stage": null,
  "http_code": 200,
  "portal_origin": "http://10.82.66.10:9090",
  "lock_pid": null,
  "next_retry_at": null,
  "checks": [ { "name": "ttl", "configured": true, "effective": true, "count": 18422 } ]
}
```

约束：

- 字段名固定，**只增不减**；
- 缺失值用 `null`，不用空字符串；
- 数值字段不用字符串包裹；
- 不输出密码、Cookie、完整认证字段；
- 不引入 `jq` 生成，由脚本按固定模板 `printf` 输出，避免转义差异。

---

# 20. 新增与修改文件清单

## 20.1 新增

| 文件 | 权限 | 说明 |
|---|---|---|
| `files/usr/lib/autoverify/lock.sh` | 0644 | 锁 helper；若最终不足约 80 行则并入主脚本 |
| `files/usr/lib/autoverify/state.sh` | 0644 | 状态读写 helper |
| `docs/operations.md` | — | 运维与排障文档 |

## 20.2 修改

| 文件 | 改动要点 |
|---|---|
| `files/usr/sbin/autoverify` | 锁、状态、错误码、`status`/`validate`/`audit`、nextPage 严格化、临时文件安全 |
| `files/etc/hotplug.d/iface/99-autoverify` | 传 `AUTOVERIFY_SOURCE=hotplug`；按退避结果处理 busy |
| `files/etc/init.d/autoverify` | 启动时清理残留运行期状态；日志补充 |
| `files/www/luci-static/resources/view/autoverify.js` | 状态区、校验入口、按钮防重 |
| `files/usr/share/rpcd/acl.d/luci-app-autoverify.json` | 增加 `status`/`validate`/`audit` 只读 exec |
| `package/autoverify/Makefile` | **新增文件的 install 行**（漏了就不进包） |
| `test/run.sh` | 并发、配置、状态、nextPage 用例 |
| `test/mock_portal.py` | 可配置 POST 延迟、外部 origin 跳转、非法页面结构 |
| `README.md` | 新命令、错误码、回滚 |
| `.github/workflows/ci.yml` | 新增脚本纳入语法与 shellcheck 检查 |

最容易遗漏的是 `Makefile` 的 install 行：脚本在源码树里存在但没进包，只有装到设备上才会发现。CI 需要一条“包内文件清单”检查来兜住这件事。

---

# 21. 新增 UCI 配置项

全部挂在现有 `tuning` 段下，不新增 section，把迁移面压到最小。

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `tuning.lock_enabled` | bool | `1` | 关闭后恢复本期之前的行为，用于快速回滚 |
| `tuning.lock_max_age` | int | `300` | stale 判定的时间上限（秒） |
| `tuning.nextpage_strict` | bool | `1` | 关闭后 nextPage 只做最小校验，用于门户兼容性回滚 |
| `tuning.state_enabled` | bool | `1` | 关闭后不写运行期状态 |

规则：

- 每一项都必须有默认值，旧配置缺失时按默认值工作；
- 新增项**不写入** `files/etc/config/autoverify` 的默认配置里也可以（走代码默认），但建议写进去以便用户在 LuCI 中看到；
- 写入默认配置时不能覆盖已有 conffile。

---

# 22. 日志规范

- 现有 `log()` 写 stderr，由 procd 转发到 syslog，保持不变；
- 阶段名固定为 `probe` / `portal` / `page` / `submit` / `nextpage` / `verify`，出现在日志行首，便于 `logread | grep` 定位；
- 失败日志必须同时带错误码与阶段；
- 禁止输出：密码、`pwd`、Cookie、完整查询串、完整响应体、完整隐藏字段；
- `debug` 子命令沿用同一套脱敏规则，密码固定打印为 `***`；
- 不引入日志级别体系，保留 `-v` 二值开关。

---

# 23. 回滚方案

| 阶段 | 回滚方式 | 系统副作用 |
|---|---|---|
| 一（锁） | `uci set autoverify.tuning.lock_enabled=0` + `reload` | 无残留；`/var/run/autoverify` 可直接 `rm -rf` |
| 二（状态） | `uci set autoverify.tuning.state_enabled=0` + `reload` | 无；删除 `/var/run/autoverify`、`/var/lib/autoverify` 即可 |
| 三（validate） | 纯新增命令，不调用即无影响 | 无 |
| 四（nextPage） | `uci set autoverify.tuning.nextpage_strict=0` + `reload` | 无 |
| 五（status/audit） | 纯只读命令，不调用即无影响 | 无 |
| 六（LuCI） | 还原 JS 与 ACL 文件即回到原页面 | 无 |
| 七（解析） | 与阶段四同一开关路径 | 无 |
| 八~十 | 代码与文档级改动 | 无 |

现有加固五项的回滚方式不变（`autoverify-hardening <项> off`），本期不改动其语义。

降级注意：APK 降级不保证配置兼容。新版本写入的新 UCI 项在降级后会被旧脚本忽略（因为旧脚本不读它们），属于安全方向；但**已应用的加固规则不会因降级而自动撤回**，需要显式 `off`。

---

# 24. 风险、假设与依赖

## 24.1 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| PID 复用导致误判锁为有效 | 认证被永久阻塞 | 校验 `/proc/<pid>/cmdline` + 时间上限 |
| 误清他人持有的锁 | 两个认证并发 | 释放时校验 owner pid |
| 状态文件写入失败（只读/满） | 无状态可读 | 只记日志，不影响认证结果与退出码 |
| nextPage 严格化导致门户不兼容 | 认证回归 | 开关回滚 + mock 覆盖 + 真实设备验证 |
| BusyBox 缺少所需 applet | 脚本直接失败 | 只用 `mkdir`/`sed`/`awk`/`grep`/`date +%s`；CI 用 `dash` 检查；避免 `flock`/`od`/GNU 扩展 |
| UCI 并发写（apply 与 LuCI 同时提交） | 配置错乱 | 保持单一落地路径；本期不新增并发写入口 |
| procd respawn 与 reload 竞态 | 两个 daemon | 锁兜底；`STOP` 顺序已由现有实现处理 |
| hotplug 风暴 | 短时间内大量触发 | busy 直接返回，不排队；退避由 daemon 负责 |
| 退出码 `3` 影响既有调用方 | 脚本判断错误 | 仅用于 `once`/`login`；文档明确；LuCI 提示文案同步 |

## 24.2 假设

- 目标设备挂载 `/proc`，且 `/var/run` 可写并支持 `mkdir` 原子性；
- 目标设备 `curl` 支持现有全部选项（如需改用标准输入传参，需先确认版本）；
- 现有 10 个 mock 用例是可依赖的回归基线；
- UCI 仍是唯一事实来源，环境变量仅在无 `uci` 时回退。

## 24.3 依赖

- 目标为 **不新增任何运行时依赖**（`jq`、`python`、`bash`、`flock` 一律不引入）；
- 构建依赖不变（OpenWrt SDK）。

---

# 25. 兼容性矩阵

| 维度 | 目标 | 说明 |
|---|---|---|
| OpenWrt 24.10 | opkg/ipk | 脚本层无差异；包定义需额外处理 |
| OpenWrt 25.x | apk | 当前主要目标 |
| Shell | POSIX `sh`（ash / dash） | CI 用 `dash -n` 校验 |
| BusyBox applet | `mkdir` `rm` `sed` `awk` `grep` `tr` `date` `printf` `cat` `head` `tail` `mktemp` `kill` `netstat` | 不使用 `flock` `od` `jq` `timeout` |
| curl | 现有已用选项集合 | 新方案须先确认版本 |
| nftables | `fw4` 存在时 | 缺 `nft` 时 audit 降级为部分输出 |
| LuCI | 无额外 JS 依赖 | 仅 `require view/form/uci/fs/ui` |
| 架构 | 与架构无关 | 纯数据包 `PKGARCH:=all` |

---

# 26. 里程碑与工作量估算

估算为粗估，用于排序而非承诺。

| 里程碑 | 覆盖阶段 | 交付物 | 估算 |
|---|---|---|---|
| M1 认证互斥 | 一、二 | 锁 + 状态 + 并发测试 | 2~3 人日 |
| M2 校验与安全 | 三、四 | `validate` + nextPage 严格化 + 传参安全 | 2~3 人日 |
| M3 可观测性 | 五、六 | `status` / `audit` + LuCI 状态区 | 3~4 人日 |
| M4 解析与测试 | 七、八 | 解析增强 + 全套用例 | 2~3 人日 |
| M5 文档与发布 | 九、十 | `docs/operations.md` + CI + APK + 设备验收 | 2 人日 |
| 合计 | — | — | 约 11~15 人日 |

依赖顺序：M1 → M2 → M3 → M4 → M5。M2 与 M3 之间无硬依赖，可在 M1 完成后并行。

---

# 27. 未决问题

1. **hotplug 去抖**：接口反复 up/down 时是否需要合并 N 秒内的重复触发？倾向在阶段一之后单独评估，本期先靠 busy 返回。
2. **`status` 是否触发探测**：默认不触发（保持只读），需要时用 `--probe`。
3. **`login` 是否继续在 ACL 中禁用**：保持禁用，现状即如此。
4. **历史保留**：是否需要 `/var/lib` 轮转保留最近 N 次结果？倾向只保留最近一次，避免闪存写入放大。
5. **JSON 兼容承诺**：是否公开承诺“字段只增不减”？倾向承诺，但仅限 `--json` 输出。
6. **版本号统一**：当前 tag（`v1.0.2`）与包版本（`1.0.0-r7`）不对应，是否需要统一编号体系？
7. **opkg 包**：是否需要为 24.10 用户额外提供 ipk 定义？

---

# 28. 待办候选（本期不做）

- 门户协议适配层（把 zportal 解析拆成可替换模块，为 srun / Dr.COM 等留出接口）；
- LuCI 一键导出/导入 UCI 配置；
- 结构化指标导出，供外部监控采集；
- 认证成功率与耗时统计；
- 用 `jsonfilter` 完整替代文本解析；
- 各阶段耗时分解（探测 / 抓页 / 提交 / 跟随）；
- 24.10 的 ipk 包定义。

这些项目与本期目标正交，列入此处以免遗忘，不在本期实施。

---

# 29. 验收清单（可勾选）

## 29.1 功能

- [ ] 两个并发 `once` 只有一个提交 POST；
- [ ] hotplug 与 daemon 并发时只有一个认证请求；
- [ ] stale lock（假 PID / 真 PID 非本程序 / 超时）能被回收；
- [ ] SIGTERM 中断后锁不残留；
- [x] `status` 输出当前阶段、最近结果、错误码、重试时间；
- [x] `validate` 对非法端口 / TTL / 超时 / 空账号报错并返回 1；
- [x] `audit` 在缺少 `nft` 时仍能输出其余部分；
- [ ] nextPage 指向外部 origin 时被拒且不发起请求；
- [x] `--json` 输出可被严格解析。

## 29.2 安全

- [ ] 密码不出现在进程参数（`ps` 不可见）；
- [ ] 锁文件、状态文件、cookie 文件权限为 `600`；
- [ ] 状态与日志不含密码、Cookie、完整认证字段；
- [ ] 临时目录在 `EXIT` / `TERM` / `INT` 路径都被清理；
- [ ] ACL 未开放 `login` 与任意 shell。

## 29.3 回归

- [ ] 现有 10 个 mock 用例通过；
- [x] 新增并发、配置、状态、nextPage 用例已加入回归套件；
- [ ] `dash -n` 与 shellcheck 无新增错误；
- [ ] JS 与 JSON 语法检查通过；
- [ ] APK 构建成功且包内文件清单与源码一致。

## 29.4 设备

- [ ] 真实设备上 `validate` / `status` / `audit` 可执行；
- [ ] 认证中执行 `stop` 能干净退出；
- [ ] 重启后 daemon 自启、状态恢复正常；
- [ ] APK 升级后配置保留、LuCI 页面不取旧缓存；
- [ ] 五项加固开关与系统实际状态一致；
- [ ] TTL / DNS / NTP 关闭后系统状态随之回滚。

## 29.5 文档

- [x] README 覆盖新命令、退出码、回滚；
- [x] `docs/operations.md` 覆盖排障路径；
- [ ] release notes 列出行为变化与不兼容点。
