#!/bin/sh
#
# autoverify 运行状态摘要。
#
# 状态文件是本程序生成的数据文件，读取方必须按 key 读取，不能 source/eval。
# 只保存固定字段和脱敏后的 origin；写入失败不影响认证主流程。

AV_STATE_ENABLED=1
AV_STATE_DIR=/var/run/autoverify
AV_STATE_PERSIST_DIR=/var/lib/autoverify
AV_STATE_FILE=""
AV_STATE_LAST_FILE=""
AV_STATE_STARTED_AT=0
AV_STATE_SOURCE=manual
AV_STATE_OPERATION=once
AV_STATE_STAGE=idle
AV_STATE_ORIGIN=""
AV_STATE_HTTP_CODE=""
AV_STATE_ACTIVE=0

av_state_init() {
	AV_STATE_DIR="${AV_STATE_DIR:-/var/run/autoverify}"
	AV_STATE_PERSIST_DIR="${AV_STATE_PERSIST_DIR:-/var/lib/autoverify}"
	AV_STATE_FILE="$AV_STATE_DIR/status"
	AV_STATE_LAST_FILE="$AV_STATE_PERSIST_DIR/last-result"
}

av_state_now() {
	date +%s 2>/dev/null || printf '0\n'
}

av_state_safe() {
	# 状态值来自固定枚举或内部解析结果；过滤控制字符和换行，防止破坏 key=value 格式。
	printf '%s' "${1:-}" | tr -d '\r\n' | tr -c 'A-Za-z0-9_./:-' '_'
}

av_state_origin() {
	# 只保留 scheme + authority，不写完整查询串，也不保留 userinfo。
	_origin=$(printf '%s' "${1:-}" | sed -n 's#^\(https\{0,1\}://[^/?]*\).*#\1#p' | head -n 1)
	case "$_origin" in
		*@*) _origin=${_origin##*@} ;;
	esac
	av_state_safe "$_origin"
}

av_state_write_file() {
	_target=$1
	_tmp="$_target.$$"
	_dir=${_target%/*}
	mkdir -p "$_dir" 2>/dev/null || return 1
	chmod 700 "$_dir" 2>/dev/null
	{
		printf 'version=1\n'
		printf 'state=%s\n' "$(av_state_safe "${AV_STATE_STAGE:-unknown}")"
		printf 'source=%s\n' "$(av_state_safe "${AV_STATE_SOURCE:-manual}")"
		printf 'operation=%s\n' "$(av_state_safe "${AV_STATE_OPERATION:-once}")"
		printf 'started_at=%s\n' "${AV_STATE_STARTED_AT:-0}"
		printf 'finished_at=%s\n' "${AV_STATE_FINISHED_AT:-0}"
		printf 'duration_ms=%s\n' "${AV_STATE_DURATION_MS:-0}"
		printf 'result=%s\n' "$(av_state_safe "${AV_STATE_RESULT:-unknown}")"
		printf 'error_code=%s\n' "$(av_state_safe "${AV_STATE_ERROR_CODE:-}")"
		printf 'error_stage=%s\n' "$(av_state_safe "${AV_STATE_ERROR_STAGE:-}")"
		printf 'http_code=%s\n' "$(av_state_safe "${AV_STATE_HTTP_CODE:-}")"
		printf 'portal_origin=%s\n' "$(av_state_origin "${AV_STATE_ORIGIN:-}")"
		printf 'next_retry_at=%s\n' "${AV_STATE_NEXT_RETRY_AT:-0}"
		printf 'lock_pid=%s\n' "${AV_STATE_LOCK_PID:-}"
	} >"$_tmp" 2>/dev/null || {
		rm -f "$_tmp"
		return 1
	}
	chmod 600 "$_tmp" 2>/dev/null
	mv "$_tmp" "$_target" 2>/dev/null || {
		rm -f "$_tmp"
		return 1
	}
	chmod 600 "$_target" 2>/dev/null
	return 0
}

av_state_commit() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	[ -n "${AV_STATE_FILE:-}" ] || av_state_init
	av_state_write_file "$AV_STATE_FILE" || return 0
	return 0
}

av_state_begin() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	AV_STATE_ACTIVE=1
	AV_STATE_SOURCE=${1:-manual}
	AV_STATE_OPERATION=${2:-once}
	AV_STATE_STARTED_AT=$(av_state_now)
	AV_STATE_FINISHED_AT=0
	AV_STATE_DURATION_MS=0
	AV_STATE_RESULT=running
	AV_STATE_ERROR_CODE=""
	AV_STATE_ERROR_STAGE=""
	AV_STATE_HTTP_CODE=""
	AV_STATE_ORIGIN=""
	AV_STATE_NEXT_RETRY_AT=0
	AV_STATE_LOCK_PID=$$
	AV_STATE_STAGE=${3:-checking}
	av_state_commit
}

av_state_phase() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	[ "${AV_STATE_ACTIVE:-0}" = "1" ] || return 0
	AV_STATE_STAGE=${1:-unknown}
	av_state_commit
}

av_state_finish() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	[ "${AV_STATE_ACTIVE:-0}" = "1" ] || return 0
	AV_STATE_STAGE=${1:-failed}
	AV_STATE_RESULT=${2:-failed}
	AV_STATE_ERROR_CODE=${3:-}
	AV_STATE_ERROR_STAGE=${4:-}
	AV_STATE_HTTP_CODE=${5:-${AV_STATE_HTTP_CODE:-}}
	AV_STATE_ORIGIN=${6:-${AV_STATE_ORIGIN:-}}
	AV_STATE_FINISHED_AT=$(av_state_now)
	case "${AV_STATE_STARTED_AT:-0}" in
		''|*[!0-9]*) AV_STATE_DURATION_MS=0 ;;
		*)
			case "$AV_STATE_FINISHED_AT" in
				''|*[!0-9]*) AV_STATE_DURATION_MS=0 ;;
				*) [ "$AV_STATE_FINISHED_AT" -ge "$AV_STATE_STARTED_AT" ] && \
					AV_STATE_DURATION_MS=$(( (AV_STATE_FINISHED_AT - AV_STATE_STARTED_AT) * 1000 )) || \
					AV_STATE_DURATION_MS=0 ;;
			esac
			;;
	esac
	AV_STATE_LOCK_PID=""
	av_state_commit
	# 仅在任务结束时写入闪存持久化摘要，避免每个阶段造成写放大。
	av_state_write_file "$AV_STATE_LAST_FILE" || true
	AV_STATE_ACTIVE=0
}

# 在线检查通过时刷新运行期状态。
#
# 只写 /var/run（tmpfs），不写 /var/lib 的持久化摘要：在线检查每 60 秒一次，
# 每次都写闪存会造成不必要的写放大。只有状态从非 success 变为 online 时才写，
# 因此不会每轮都产生 IO。
av_state_online() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	[ -n "${AV_STATE_FILE:-}" ] || av_state_init
	[ "$(av_state_get "$AV_STATE_FILE" result)" = success ] && return 0
	_now=$(av_state_now)
	AV_STATE_STAGE=online
	AV_STATE_SOURCE=${1:-daemon}
	AV_STATE_OPERATION=${2:-daemon}
	AV_STATE_STARTED_AT=$_now
	AV_STATE_FINISHED_AT=$_now
	AV_STATE_DURATION_MS=0
	AV_STATE_RESULT=success
	AV_STATE_ERROR_CODE=""
	AV_STATE_ERROR_STAGE=""
	AV_STATE_HTTP_CODE=${3:-}
	AV_STATE_ORIGIN=""
	AV_STATE_NEXT_RETRY_AT=0
	AV_STATE_LOCK_PID=""
	av_state_write_file "$AV_STATE_FILE"
}

av_state_set_retry() {
	[ "${AV_STATE_ENABLED:-1}" = "1" ] || return 0
	AV_STATE_NEXT_RETRY_AT=${1:-0}
	av_state_commit
}

av_state_get() {
	_file=$1
	_key=$2
	[ -r "$_file" ] || return 0
	sed -n "s/^${_key}=//p" "$_file" 2>/dev/null | head -n 1
}
