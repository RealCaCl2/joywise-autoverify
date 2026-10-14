# joywise-autoverify 运维手册

项目展示名是 joywise-autoverify，设备上的命令、包名和 UCI 命名空间仍是
autoverify，这样升级不会丢失已有配置。

## 1. 安装后检查

安装包后先确认运行时文件和权限：

~~~sh
command -v curl
ls -l /usr/sbin/autoverify /usr/lib/autoverify/{cfg.sh,lock.sh,state.sh}
stat -c '%a' /etc/config/autoverify
/usr/sbin/autoverify validate
~~~

配置文件应为 600。不要把真实账号、密码、Cookie、完整门户查询串或状态文件复制到
工单、日志和代码仓库。

## 2. 配置与启动

推荐通过 LuCI 保存配置；命令行修改后提交并重载：

~~~sh
uci set autoverify.main.username='你的账号'
uci set autoverify.main.password='你的密码'
uci commit autoverify
/etc/init.d/autoverify reload
~~~

启动守护进程并查看日志：

~~~sh
/etc/init.d/autoverify enable
/etc/init.d/autoverify start
logread -e autoverify
~~~

## 3. 只读诊断路径

按以下顺序执行，不会强制认证：

~~~sh
/usr/sbin/autoverify validate
/usr/sbin/autoverify status
/usr/sbin/autoverify audit
/usr/sbin/autoverify check
~~~

status 默认不探测网络；需要一次显式探测时使用：

~~~sh
/usr/sbin/autoverify status --probe
~~~

机器采集使用固定字段的 JSON：

~~~sh
/usr/sbin/autoverify check --json
/usr/sbin/autoverify status --json
/usr/sbin/autoverify audit --json
~~~

状态字段只保存脱敏后的门户 origin，不保存密码、Cookie 或完整认证字段。缺少
ip、nft、netstat 等可选命令时，审计会保留其余结果并标记 unknown。

## 4. 认证失败排查

先看错误阶段和 HTTP 摘要：

~~~sh
/usr/sbin/autoverify -v once
sed -n '1,40p' /var/run/autoverify/status
logread -e autoverify
~~~

常见阶段：

- discovering：探测响应中没有可识别的 zportal 地址；
- fetching / page：登录页无法获取或字段结构发生变化；
- submitting：认证请求失败或门户返回失败；
- following / nextpage：nextPage 缺失、越界、跨 origin 或请求失败；
- verifying：门户返回成功，但最终连通性仍未恢复。

门户要求验证码或修改初始密码时，应先在浏览器完成一次人工处理，再重新执行
once。不要通过关闭严格校验来绕过外部 nextPage，除非已经确认门户行为且接受风险。

## 5. daemon、hotplug 和锁

守护进程由 procd 管理，出口接口上线时 hotplug 也可能触发一次认证：

~~~sh
/etc/init.d/autoverify status
pidof autoverify
/usr/sbin/autoverify status
ls -la /var/run/autoverify
~~~

认证锁是 /var/run/autoverify/auth.lock.d。并发调用返回退出码 3，不会排队。

> 注意：`status` 输出里的 `daemon_pid` / `daemon_count` 是 `pidof autoverify` 的结果，
> 而 busybox 的 `pidof` 按脚本名匹配，**会把发起本次查询的进程自身（及其子 shell）
> 一起数进去**。所以在命令行下这两个值不可信（守护进程已停时计数也不为 0）“某接口
> 已在线”之类的判断不要拿它们做依据；要看真实存活请用
> `ubus call service list '{"name":"autoverify"}'`（LuCI 页面顶部的状态面板就是这幺做的）。
正常情况下锁会在进程结束时释放；stale lock 会根据 PID、/proc 命令行和最大年龄回收。
不要手工删除正在运行任务的锁；如果确认进程已不存在，再先保存 owner 文件内容供排障。

## 6. TTL、DNS、NTP、DHCP 和 IPv6

VPN/Clash 兼容模式：启用 `autoverify.dns.enabled=1`，设置
`autoverify.dns.redirect=0`，提交后运行 `autoverify-apply`。
这会保留路由器 DoH 并清理旧 LAN 53 重定向。旧配置缺少 `redirect` 也按关闭处理。
LuCI 对应“路由器使用 DoH”开启、“强制接管局域网 DNS”关闭。

查看配置开关与系统实际状态：

~~~sh
/usr/sbin/autoverify-hardening status
nft list ruleset | grep -E 'ttl|ntp-converge|dns-converge|flowtable'
netstat -lnu | grep -E ':53[[:space:]]|:123[[:space:]]'
~~~

关闭某项后重新应用并确认实际状态：

~~~sh
uci set autoverify.ttl.enabled='0'
uci set autoverify.ntp.enabled='0'
uci set autoverify.dns.enabled='0'
uci commit autoverify
/usr/sbin/autoverify-apply
/usr/sbin/autoverify-hardening status
~~~

IPv6 防护会关闭 LAN 的 RA/DHCPv6，可能影响局域网 IPv6；关闭前确认上游网络和使用场景。
flowtable 可能绕过部分 TTL hook，审计报告会明确提示，不会自动修改流量卸载策略。

## 7. 回滚

本项目的新增认证锁、状态记录和 nextPage 严格校验都有独立配置开关：

~~~sh
uci set autoverify.tuning.lock_enabled='0'
uci set autoverify.tuning.state_enabled='0'
uci set autoverify.tuning.nextpage_strict='0'
uci commit autoverify
/etc/init.d/autoverify reload
~~~

回滚代码优先使用 Git 的 git revert <commit>，不要使用不可逆的 reset 或覆盖用户配置。
关闭加固项使用 autoverify-hardening <ttl|ntp|dns|dhcp|ipv6> off，再检查实际状态。

## 8. 升级与配置保留

升级前保存 UCI 配置（保存位置应受保护）：

~~~sh
umask 077
uci export autoverify > /tmp/autoverify.uci
apk add --allow-untrusted /tmp/autoverify.apk
/etc/init.d/autoverify reload
/usr/sbin/autoverify validate
~~~

/etc/config/autoverify 是 conffile；升级不应覆盖已有账号密码。升级后应重新检查
LuCI 页面、status、audit 和 daemon 自启。确认无误后再删除临时备份：

~~~sh
rm -f /tmp/autoverify.uci /tmp/autoverify.apk
~~~

如果安装器提示 conffile 冲突，保留现有配置，先不要用包内默认文件覆盖它。

### 8.1 升级后 ACL 需要重载

本包在 `/usr/share/rpcd/acl.d/luci-app-autoverify.json` 里授予了 LuCI 所需的只读命令权限。
升级后若页面顶部的运行状态显示“读取失败：Permission denied”，说明 rpcd 还在用旧的
ACL 缓存，执行以下命令后刷新页面即可（不需要重启路由器）：

~~~sh
/etc/init.d/rpcd reload
~~~

这会让 LuCI 登录会话失效，需要重新登录一次。
