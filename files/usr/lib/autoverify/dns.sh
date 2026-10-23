#!/bin/sh
# DNS 上游接管：备份一次、只走 DoH、关闭时恢复。目标为 BusyBox ash。
#
# dns.mode=always    - 服务启动/应用配置时就接管 dnsmasq 上游（旧行为）。
# dns.mode=post_auth - 认证前保留网络下发的明文 DNS，认证并验证在线后再切 DoH。
#                      多数校园网认证前只放行 HTTP，DoH 走 443 根本连不上；
#                      提前接管只会让门户探测拿到 HTTP 000，形成死锁。
DNS_DOH_STATE=${DNS_DOH_STATE:-/etc/autoverify-dns}
DNS_DOH_INIT=${DNS_DOH_INIT:-/etc/init.d/https-dns-proxy}
DNS_DOH_FAIL_MARK="$DNS_DOH_STATE/fail"
DNS_DOH_RETRY_SEC=${DNS_DOH_RETRY_SEC:-600}

dns_doh_mode() {
	case "$(av_cfg dns mode post_auth)" in
		always)    printf 'always\n' ;;
		*)
			# 未配置或拼写错误时按更安全的一侧处理：认证前不接管。
			printf 'post_auth\n'
			;;
	esac
}

# DoH 是否处于“已应用”状态。
#
# active 只是标记；最终以 dnsmasq 是否真的还指向本机 5053 为准。这样即使
# active 残留、而上游已经被手工改回明文，也不会误判为“DoH 已生效”而跳过
# 重新接管。
dns_doh_active() {
	[ -f "$DNS_DOH_STATE/active" ] || return 1
	dns_doh_plain_ready && return 1
	return 0
}

dns_restart_dnsmasq() {
	[ -x /etc/init.d/dnsmasq ] || return 0
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

# 认证后先确认 HTTPS 真的放行了，再动 dnsmasq。
# 有些校园网即使认证成功也只放行 HTTP，贸然切 DoH 会立刻断掉所有解析。
dns_https_ready() {
	dns_doh_url || return 1
	_code=$(curl -s -o /dev/null -m 5 -A "${USER_AGENT:-Mozilla/5.0}" \
		-w '%{http_code}' "$_doh_url" 2>/dev/null)
	case "$_code" in
		''|000) return 1 ;;
		*)      return 0 ;;
	esac
}

# 切换后真正查一次域名，确认 dnsmasq -> 5053 -> DoH 整条链路可用。
# 极简 BusyBox 可能没编译 nslookup，此时跳过这项检查，不因此禁用 DoH。
dns_query_ok() {
	command -v nslookup >/dev/null 2>&1 || return 0
	_out=$(nslookup www.baidu.com 127.0.0.1 2>/dev/null) || return 1
	printf '%s\n' "$_out" | grep -q 'Name:'
}

# 切换失败后冷却一段时间，避免守护进程每个周期都重启一次 dnsmasq。
dns_doh_retry_allowed() {
	[ -f "$DNS_DOH_FAIL_MARK" ] || return 0
	_mtime=$(date -r "$DNS_DOH_FAIL_MARK" +%s 2>/dev/null) || return 0
	_now=$(date +%s 2>/dev/null) || return 0
	[ $((_now - _mtime)) -ge "$DNS_DOH_RETRY_SEC" ]
}

dns_doh_mark_fail() {
	(umask 077; mkdir -p "$DNS_DOH_STATE" 2>/dev/null; : > "$DNS_DOH_FAIL_MARK") 2>/dev/null
	return 0
}

dnsmasq_sections() {
	uci -q show dhcp | sed -n 's/^\(dhcp\.[^.]*\)=dnsmasq$/\1/p'
}

# dnsmasq 当前是否已经是“认证前明文”形态：
#   - 没有 noresolv=1（否则不会读网络下发的 resolv 文件）
#   - 没有指向本机 DoH 代理的 server=127.0.0.1#5053/5054
# 只判断“有没有可用的明文上游”，不要求具体是哪个服务器。
dns_doh_plain_ready() {
	_found=0
	for _dm in $(dnsmasq_sections); do
		_found=1
		[ "$(uci -q get "$_dm.noresolv")" = 1 ] && return 1
		_servers=$(uci -q get "$_dm.server") || _servers=""
		for _srv in $_servers; do
			case "$_srv" in
				127.0.0.1#5053|127.0.0.1#5054|::1#5053|::1#5054) return 1 ;;
			esac
		done
	done
	[ "$_found" = 1 ]
}

dns_doh_have_markers() {
	for _dm in $(dnsmasq_sections); do
		[ "$(uci -q get "$_dm.av_doh_saved")" = 1 ] && return 0
	done
	return 1
}

dns_doh_url() {
	_doh_provider=$(av_cfg dns doh_provider tencent)
	case "$_doh_provider" in
		tencent)
			_doh_url='https://doh.pub/dns-query'
			# https-dns-proxy 2026.05.06 + c-ares 1.34 只给一个 bootstrap
			# 时会在 dns_poller.c 里直接 abort（需要的 IO handler 比 nameserver 多）。
			# 两个都是 DNSPod 公共 DNS，不是猜测的第三方地址。
			_doh_bootstrap='119.29.29.29,182.254.116.116'
			;;
		aliyun)
			_doh_url='https://dns.alidns.com/dns-query'
			_doh_bootstrap='223.5.5.5,223.6.6.6'
			;;
		custom)
			_doh_url=$(av_cfg dns doh_url '')
			_doh_bootstrap=$(av_cfg dns doh_bootstrap '119.29.29.29')
			;;
		*) return 1 ;;
	esac
	# 禁止凭据、空白和引号，避免生成 UCI 时注入；保持 TLS 验证。
	printf '%s\n' "$_doh_url" | awk '
		/^https:\/\/[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?\/[A-Za-z0-9_\/.~?&=%+:-]*$/ {
			split($0, p, "/"); split(p[3], h, ":");
			if (h[2]!="" && (h[2]<1 || h[2]>65535)) exit 1;
			if (h[1] ~ /^[0-9.]+$/) {
				if (split(h[1], a, ".")!=4) exit 1;
				for (i=1; i<=4; i++) if (a[i]=="" || a[i]>255) exit 1;
			}
			ok=1
		} END {exit !ok}' || return 1
	printf '%s\n' "$_doh_bootstrap" | awk '
		/^[0-9.,]+$/ {
			n=split($0, s, ",");
			for (j=1; j<=n; j++) {
				if (split(s[j], a, ".")!=4) exit 1;
				for (i=1; i<=4; i++) if (a[i]=="" || a[i]>255) exit 1;
			}
			ok=1
		} END {exit !ok}'
}

# 保存 autoverify 接管前的原始状态。
#
# proxy.uci / enabled / running 是“完整恢复”用的，只能在第一次接管时保存；
# 认证前暂停 DoH 时必须把它们留着，否则下一次只能把 autoverify 自己的 DoH
# 配置当成“原始配置”，完整恢复就回不到用户原来的状态了。
dns_doh_save_original() {
	[ -f "$DNS_DOH_STATE/proxy.uci" ] && return 0
	_dm_sections=$(dnsmasq_sections)
	[ -n "$_dm_sections" ] || { log '找不到 dnsmasq UCI 配置'; return 1; }
	(umask 077; mkdir -p "$DNS_DOH_STATE") || return 1
	"$DNS_DOH_INIT" enabled && touch "$DNS_DOH_STATE/enabled"
	"$DNS_DOH_INIT" status >/dev/null 2>&1 && touch "$DNS_DOH_STATE/running"
	# 先停原服务，让它把手里的 dnsmasq 配置还回来，再快照。
	"$DNS_DOH_INIT" stop || return 1
	(umask 077; uci export https-dns-proxy > "$DNS_DOH_STATE/proxy.uci.tmp") || return 1
	mv "$DNS_DOH_STATE/proxy.uci.tmp" "$DNS_DOH_STATE/proxy.uci" || return 1
	for _dm in $_dm_sections; do
		if [ "$(uci -q get "$_dm.av_doh_saved")" != 1 ]; then
			for _opt in noresolv server serversfile; do
				if _old=$(uci -q get "$_dm.$_opt"); then
					uci set "$_dm.av_doh_${_opt}_present=1" || return 1
					if [ "$_opt" = server ]; then
						for _srv in $_old; do uci add_list "$_dm.av_doh_server=$_srv" || return 1; done
					else
						uci set "$_dm.av_doh_$_opt=$_old" || return 1
					fi
				fi
			done
			uci set "$_dm.av_doh_saved=1" || return 1
		fi
	done
	uci commit dhcp || return 1
	return 0
}

# 把 dnsmasq 的上游恢复成接管前保存的状态。
#   keep: 保留 av_doh_* 标记（认证前暂停用，之后还要再次接管）
#   drop: 删除标记（完整恢复/关闭 DoH 时用）
dns_doh_restore_dnsmasq() {
	_drop=${1:-drop}
	_any=0
	for _dm in $(dnsmasq_sections); do
		[ "$(uci -q get "$_dm.av_doh_saved")" = 1 ] || continue
		_any=1
		for _opt in noresolv server serversfile; do
			uci -q delete "$_dm.$_opt"
			if [ "$(uci -q get "$_dm.av_doh_${_opt}_present")" = 1 ]; then
				_old=$(uci -q get "$_dm.av_doh_$_opt")
				if [ "$_opt" = server ]; then
					for _srv in $_old; do uci add_list "$_dm.server=$_srv" || return 1; done
				else
					uci set "$_dm.$_opt=$_old" || return 1
				fi
			fi
			if [ "$_drop" = drop ]; then
				uci -q delete "$_dm.av_doh_$_opt"
				uci -q delete "$_dm.av_doh_${_opt}_present"
			fi
		done
		if [ "$_drop" = drop ]; then
			uci -q delete "$_dm.av_doh_saved"
		fi
	done
	[ "$_any" = 1 ] && uci commit dhcp
	return 0
}

dns_doh_restore() {
	_have_proxy=0
	[ -f "$DNS_DOH_STATE/proxy.uci" ] && _have_proxy=1
	_saved=0
	dns_doh_have_markers && _saved=1
	# 没有备份也没有接管标记时什么都不做。
	# 但只剩 dnsmasq 标记（proxy.uci 被手工删掉）也要恢复，否则上游永远停在
	# 127.0.0.1#5053，而代理根本没在跑。
	[ "$_have_proxy" = 1 ] || [ "$_saved" = 1 ] || [ -f "$DNS_DOH_STATE/active" ] || return 0
	if [ -x "$DNS_DOH_INIT" ]; then
		"$DNS_DOH_INIT" stop || return 1
	fi
	rm -f "$DNS_DOH_STATE/active"
	dns_doh_restore_dnsmasq drop || return 1
	if [ "$_have_proxy" = 1 ]; then
		uci import https-dns-proxy < "$DNS_DOH_STATE/proxy.uci" || return 1
		uci commit https-dns-proxy || return 1
		if [ -f "$DNS_DOH_STATE/enabled" ]; then
			"$DNS_DOH_INIT" enable || return 1
		else
			"$DNS_DOH_INIT" disable || return 1
		fi
		if [ -f "$DNS_DOH_STATE/running" ]; then
			"$DNS_DOH_INIT" start || return 1
		fi
	fi
	rm -f "$DNS_DOH_STATE/proxy.uci" "$DNS_DOH_STATE/enabled" "$DNS_DOH_STATE/running"
	rm -f "$DNS_DOH_STATE/fail"
}

dns_doh_apply() {
	dns_doh_url || { log 'DoH 预设、自定义 HTTPS URL 或 bootstrap IPv4 列表无效'; return 1; }
	[ -x "$DNS_DOH_INIT" ] || { log '缺少 https-dns-proxy，请安装套件依赖'; return 1; }
	_dm_sections=$(dnsmasq_sections)
	[ -n "$_dm_sections" ] || { log '找不到 dnsmasq UCI 配置'; return 1; }
	rm -f "$DNS_DOH_STATE/active"
	dns_doh_save_original || return 1
	for _dm in $_dm_sections; do
		uci set "$_dm.noresolv=1" || return 1
		uci -q delete "$_dm.server"
		uci -q delete "$_dm.serversfile"
		uci add_list "$_dm.server=127.0.0.1#5053" || return 1
	done
	uci commit dhcp || return 1
	# 不让代理的 init 脚本再次修改 dnsmasq 或扩大到 853 端口的控制范围。
	uci import https-dns-proxy <<EOF || return 1
package https-dns-proxy
config main 'config'
	option dnsmasq_config_update '-'
	option force_dns '0'
	option notrack_dns '0'
config https-dns-proxy 'autoverify'
	option resolver_url '$_doh_url'
	option listen_addr '127.0.0.1'
	option listen_port '5053'
	option bootstrap_dns '$_doh_bootstrap'
	option force_ip_family 'ipv4'
EOF
	uci commit https-dns-proxy || return 1
	"$DNS_DOH_INIT" enable || return 1
	"$DNS_DOH_INIT" restart || { log 'DoH 代理启动失败'; return 1; }
	_doh_wait=0
	while [ "$_doh_wait" -lt 5 ]; do
		if netstat -lnu 2>/dev/null | grep -qE '127\.0\.0\.1:5053[[:space:]]'; then
			: > "$DNS_DOH_STATE/active"
			return 0
		fi
		sleep 1
		_doh_wait=$((_doh_wait + 1))
	done
	log 'DoH 代理没有监听 127.0.0.1:5053'
	return 1
}

# ------------------------------------------------- 认证前后的时机切换 -------
#
# post_auth 模式的两个入口:
#   dns_doh_before_auth - 需要认证时先恢复网络下发的明文 DNS，否则门户探测
#                         无法解析域名，只能拿到 HTTP 000。
#   dns_doh_after_auth  - 认证并验证在线后切到 DoH；切换失败或解析测试不过
#                         就立即回退，避免把整台路由器的 DNS 弄死。

# 认证前把 DNS 真正拉回明文。
#
# 不能直接复用 dns_doh_restore：它恢复的是“接管前”的 https-dns-proxy 配置。
# 如果用户原本就装着一套 force_dns=1 / dnsmasq_config_update='*' 的 DoH
# （例如 Cloudflare/Google），restore 会把这套配置和代理一起启动，dnsmasq
# 又被拉回 127.0.0.1#5053/5054，认证探测继续 HTTP 000，形成死循环。
#
# 认证前只做三件事：停代理、保留原始快照、把 dnsmasq 的本地 DoH 上游清掉。
dns_doh_pause() {
	dns_doh_save_original || return 1
	if [ -x "$DNS_DOH_INIT" ]; then
		"$DNS_DOH_INIT" stop || return 1
		"$DNS_DOH_INIT" disable || return 1
	fi
	rm -f "$DNS_DOH_STATE/active"
	_changed=0
	if dns_doh_have_markers; then
		dns_doh_restore_dnsmasq keep || return 1
		_changed=1
	fi
	for _dm in $(dnsmasq_sections); do
		if [ "$(uci -q get "$_dm.noresolv")" = 1 ]; then
			uci -q delete "$_dm.noresolv" || return 1
			_changed=1
		fi
		_servers=$(uci -q get "$_dm.server") || _servers=""
		_kept=""
		_removed=0
		for _srv in $_servers; do
			case "$_srv" in
				127.0.0.1#5053|127.0.0.1#5054|::1#5053|::1#5054) _removed=1 ;;
				*) _kept="$_kept $_srv" ;;
			esac
		done
		if [ "$_removed" = 1 ]; then
			uci -q delete "$_dm.server" || return 1
			for _srv in $_kept; do uci add_list "$_dm.server=$_srv" || return 1; done
			_changed=1
		fi
	done
	if [ "$_changed" = 1 ]; then
		uci commit dhcp || return 1
		dns_restart_dnsmasq
	fi
	return 0
}

dns_doh_before_auth() {
	[ "$(av_cfg_bool dns enabled 0)" = "1" ] || return 0
	[ "$(dns_doh_mode)" = "post_auth" ] || return 0
	# 已经是明文上游时不要反复 stop/restart，认证重试可能每几十秒一次。
	dns_doh_plain_ready && return 0
	if dns_doh_pause; then
		log '需要认证, 已恢复明文 DNS 上游'
		return 0
	fi
	log '恢复明文 DNS 上游失败, 认证探测可能受影响'
	return 1
}

dns_doh_after_auth() {
	[ "$(av_cfg_bool dns enabled 0)" = "1" ] || return 0
	[ "$(dns_doh_mode)" = "post_auth" ] || return 0
	dns_doh_active && return 0
	[ -x "$DNS_DOH_INIT" ] || return 0
	dns_doh_retry_allowed || { logv 'DoH 切换仍在冷却期, 保持明文上游'; return 1; }
	dns_https_ready || { logv '认证后 HTTPS 仍不可用, 暂不切换 DoH'; return 1; }

	if ! dns_doh_apply; then
		log '认证后启用 DoH 失败, 已回退明文上游'
		dns_doh_pause || log '回退明文 DNS 失败'
		dns_doh_mark_fail
		return 1
	fi
	dns_restart_dnsmasq
	sleep 1
	if ! dns_query_ok; then
		log 'DoH 已启动但解析测试失败, 已回退明文上游'
		dns_doh_pause || log '回退明文 DNS 失败'
		dns_doh_mark_fail
		return 1
	fi
	rm -f "$DNS_DOH_FAIL_MARK"
	log '已切换到 DoH 上游'
	return 0
}
