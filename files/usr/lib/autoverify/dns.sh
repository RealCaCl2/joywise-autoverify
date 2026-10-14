#!/bin/sh
# DNS 上游接管：备份一次、只走 DoH、关闭时恢复。目标为 BusyBox ash。
DNS_DOH_STATE=${DNS_DOH_STATE:-/etc/autoverify-dns}
DNS_DOH_INIT=${DNS_DOH_INIT:-/etc/init.d/https-dns-proxy}

dnsmasq_sections() {
	uci -q show dhcp | sed -n 's/^\(dhcp\.[^.]*\)=dnsmasq$/\1/p'
}

dns_doh_url() {
	_doh_provider=$(av_cfg dns doh_provider tencent)
	case "$_doh_provider" in
		tencent)
			_doh_url='https://doh.pub/dns-query'
			_doh_bootstrap='119.29.29.29'
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

dns_doh_restore() {
	[ -f "$DNS_DOH_STATE/proxy.uci" ] || return 0
	"$DNS_DOH_INIT" stop || return 1
	for _dm in $(dnsmasq_sections); do
		[ "$(uci -q get "$_dm.av_doh_saved")" = 1 ] || continue
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
			uci -q delete "$_dm.av_doh_$_opt"
			uci -q delete "$_dm.av_doh_${_opt}_present"
		done
		uci -q delete "$_dm.av_doh_saved"
	done
	uci commit dhcp || return 1
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
	rm -f "$DNS_DOH_STATE/proxy.uci" "$DNS_DOH_STATE/enabled" "$DNS_DOH_STATE/running"
}

dns_doh_apply() {
	dns_doh_url || { log 'DoH 预设、自定义 HTTPS URL 或 bootstrap IPv4 列表无效'; return 1; }
	[ -x "$DNS_DOH_INIT" ] || { log '缺少 https-dns-proxy，请安装套件依赖'; return 1; }
	_dm_sections=$(dnsmasq_sections)
	[ -n "$_dm_sections" ] || { log '找不到 dnsmasq UCI 配置'; return 1; }
	if [ ! -f "$DNS_DOH_STATE/proxy.uci" ]; then
		# 先停止原服务，让它恢复自身保存的 dnsmasq 配置，再保存接管前状态。
		(umask 077; mkdir -p "$DNS_DOH_STATE") || return 1
		"$DNS_DOH_INIT" enabled && touch "$DNS_DOH_STATE/enabled"
		"$DNS_DOH_INIT" status >/dev/null 2>&1 && touch "$DNS_DOH_STATE/running"
		"$DNS_DOH_INIT" stop || return 1
		(umask 077; uci export https-dns-proxy > "$DNS_DOH_STATE/proxy.uci.tmp") || return 1
		mv "$DNS_DOH_STATE/proxy.uci.tmp" "$DNS_DOH_STATE/proxy.uci" || return 1
	fi
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
			uci commit dhcp || return 1
		fi
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
	"$DNS_DOH_INIT" restart || { log 'DoH 代理启动失败；保留严格上游配置，不回退明文 DNS'; return 1; }
	_doh_wait=0
	while [ "$_doh_wait" -lt 5 ]; do
		netstat -lnu 2>/dev/null | grep -qE '127\.0\.0\.1:5053[[:space:]]' && return 0
		sleep 1
		_doh_wait=$((_doh_wait + 1))
	done
	log 'DoH 代理没有监听 127.0.0.1:5053；保留严格上游配置，不回退明文 DNS'
	return 1
}
