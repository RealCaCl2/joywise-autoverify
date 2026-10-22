#!/bin/sh
#
# 端到端测试: 启动 mock 门户, 验证 autoverify 的探测 -> 抓页 -> 认证 -> 复核 全流程,
# 以及各种失败响应的处理。不接触真实校园网。
#
# 用法: sh test/run.sh          (需要 python3 和 curl)
#
set -u

PY="${PYTHON:-python3}"
# 默认随机端口: 避免上一轮残留的 mock 占着固定端口应答, 导致测试结果串味
PORT="${PORT:-$(( 20000 + ($$ % 20000) ))}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/files/usr/sbin/autoverify"

command -v "$PY" >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }
command -v curl  >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

export TUNING_PROBE_URLS="http://127.0.0.1:$PORT/probe"
export PORTAL_HOST=127.0.0.1
export PORTAL_PORT="$PORT"
export MAIN_USERNAME="20230001"
export MAIN_PASSWORD="p@ss w0rd&x=1"   # 故意带空格和 & , 验证编码
export TUNING_HTTP_TIMEOUT=5
# 登录延迟只影响实机节奏, 回归里关掉, 避免每个认证用例多等 1-2 秒。
export TUNING_LOGIN_DELAY=0
RUN_DIR=$(mktemp -d) || exit 1
export AUTOVERIFY_RUN_DIR="$RUN_DIR"
export AUTOVERIFY_STATE_DIR="$RUN_DIR/persist"

# 脚本现在从 /usr/lib/autoverify/cfg.sh 读配置; 本地跑要指到仓库里的那份。
# 没有 uci 命令时会自动退回同名环境变量 (上面那些就是 SECTION_OPTION 形式)。
export AV_LIB="$ROOT/files/usr/lib/autoverify/cfg.sh"

FAILED=0
MOCK_PID=""

start_mock() {
	# 端口必须空闲。Windows 上 SO_REUSEADDR 允许两个进程绑同一端口,
	# 若上一轮的 mock 还活着, 请求会被它接走, 而它带着上一轮的 MOCK_RESP。
	if curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null; then
		echo "错误: 端口 $PORT 已被占用 (很可能是上一轮测试残留的 mock 进程)"
		echo "      先结束残留进程, 或换端口: PORT=18123 sh test/run.sh"
		exit 1
	fi

	MOCK_RESP="$1" MOCK_POST_DELAY="${MOCK_POST_DELAY:-}" MOCK_NEXT_MODE="${MOCK_NEXT_MODE:-}" \
		MOCK_PID_FILE="$RUN_DIR/mock.pid" \
		"$PY" "$ROOT/test/mock_portal.py" "$PORT" > "$TMPOUT" 2>&1 &
	MOCK_PID=$!

	# 等启动完成: 既要有就绪日志, 也要端口真的能连上
	_i=0
	while [ "$_i" -lt 40 ]; do
		if grep -q "mock portal listening" "$TMPOUT" 2>/dev/null \
		   && curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null; then
			return 0
		fi
		sleep 0.2
		_i=$((_i + 1))
	done
	echo "mock 门户未能启动 (端口 $PORT):"
	sed 's/^/    /' "$TMPOUT"
	exit 1
}

stop_mock() {
	_mock_real_pid=""
	[ -f "$RUN_DIR/mock.pid" ] && _mock_real_pid=$(cat "$RUN_DIR/mock.pid" 2>/dev/null)
	_mock_windows=0
	if [ -n "$MOCK_PID" ]; then
		# 先让 mock 自己关闭 HTTPServer，避免 Windows 下杀包装进程后端口
		# 仍短暂占用，导致下一用例误报端口残留。
		curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/__shutdown" 2>/dev/null || true
		# Git Bash 下 $! 可能指向包装进程而不是 python 本身；taskkill /T
		# 只用于结束本测试启动的进程树，Linux 仍走 POSIX kill。
		if command -v taskkill >/dev/null 2>&1; then
			_mock_windows=1
			[ -n "$_mock_real_pid" ] || _mock_real_pid="$MOCK_PID"
			taskkill //PID "$_mock_real_pid" //T //F >/dev/null 2>&1 || true
		else
			[ -n "$_mock_real_pid" ] || _mock_real_pid="$MOCK_PID"
			kill "$_mock_real_pid" 2>/dev/null || true
		fi
	fi
	# Windows 的后台包装 shell 可能不会因子进程被 taskkill 而结束，等待它会让
	# 回归测试卡住；Linux 仍等待以回收子进程。
	[ "$_mock_windows" = "1" ] || wait "$MOCK_PID" 2>/dev/null
	MOCK_PID=""
	rm -f "$RUN_DIR/mock.pid"
	# 等端口真正释放, 否则下一次 start_mock 的占用检查会误报
	_i=0
	while [ "$_i" -lt 25 ]; do
		curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/probe" 2>/dev/null || break
		sleep 0.2
		_i=$((_i + 1))
	done
	return 0
}

TMPOUT=$(mktemp) || exit 1
trap 'stop_mock; rm -f "$TMPOUT"; rm -rf "$RUN_DIR"' EXIT INT TERM

check() {
	_name="$1"; _expect_rc="$2"; _expect_text="$3"
	_out=$(sh "$SCRIPT" once 2>&1)
	_rc=$?
	printf -- '--- %s\n' "$_name"
	printf '%s\n' "$_out" | sed 's/^/    /'
	if [ "$_rc" != "$_expect_rc" ]; then
		echo "    [FAIL] 退出码 $_rc, 期望 $_expect_rc"
		FAILED=1
		return
	fi
	if [ -n "$_expect_text" ]; then
		case "$_out" in
			*"$_expect_text"*) ;;
			*) echo "    [FAIL] 输出中未出现: $_expect_text"; FAILED=1; return ;;
		esac
	fi
	echo "    [OK]"
}

echo "=========== 0. 配置校验 ==========="
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
printf '%s\n' "$_validate_out" | sed 's/^/    /'
if [ "$_validate_rc" = "0" ] && ! printf '%s\n' "$_validate_out" | grep -qF "$MAIN_PASSWORD"; then
	echo "    [OK] 有效配置通过且不输出密码"
else
	echo "    [FAIL] 有效配置校验失败或泄露密码"; FAILED=1
fi

_port_save="$PORTAL_PORT"
PORTAL_PORT=65536
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
PORTAL_PORT="$_port_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'portal.port'; then
	echo "    [OK] 非法端口被拒绝"
else
	echo "    [FAIL] 非法端口未被拒绝"; FAILED=1
fi

_ttl_save="${TTL_TTL:-64}"
export TTL_TTL=0
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
export TTL_TTL="$_ttl_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'ttl.ttl'; then
	echo "    [OK] 非法 TTL 被拒绝"
else
	echo "    [FAIL] 非法 TTL 未被拒绝"; FAILED=1
fi

_username_save="$MAIN_USERNAME"
export MAIN_USERNAME=
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
export MAIN_USERNAME="$_username_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'main.username'; then
	echo "    [OK] 空账号被拒绝"
else
	echo "    [FAIL] 空账号未被拒绝"; FAILED=1
fi

_password_save="$MAIN_PASSWORD"
export MAIN_PASSWORD=
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
export MAIN_PASSWORD="$_password_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'main.password'; then
	echo "    [OK] 空密码被拒绝"
else
	echo "    [FAIL] 空密码未被拒绝"; FAILED=1
fi

_timeout_save="$TUNING_HTTP_TIMEOUT"
export TUNING_HTTP_TIMEOUT=0
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
export TUNING_HTTP_TIMEOUT="$_timeout_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'http_timeout'; then
	echo "    [OK] 零 HTTP timeout 被拒绝"
else
	echo "    [FAIL] 零 HTTP timeout 未被拒绝"; FAILED=1
fi

_url_save="${PORTAL_URL:-}"
export PORTAL_URL='ftp://invalid.example/login'
_validate_out=$(sh "$SCRIPT" validate 2>&1)
_validate_rc=$?
export PORTAL_URL="$_url_save"
if [ "$_validate_rc" = "1" ] && printf '%s\n' "$_validate_out" | grep -q 'portal.url'; then
	echo "    [OK] 非 HTTP(S) 门户地址被拒绝"
else
	echo "    [FAIL] 非 HTTP(S) 门户地址未被拒绝"; FAILED=1
fi

echo "=========== 1. 认证成功 ==========="
start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "probe 302 -> 抓登录页 -> 提交 -> 跟随 nextPage -> 204 复核" 0 "认证后连通性验证通过"
if [ -f "$AUTOVERIFY_RUN_DIR/status" ] && \
	grep -q '^result=success$' "$AUTOVERIFY_RUN_DIR/status" && \
	grep -q '^state=online$' "$AUTOVERIFY_RUN_DIR/status"; then
	echo "    [OK]   运行状态已记录认证结论"
else
	echo "    [FAIL] 运行状态缺失或结论错误"; FAILED=1
fi
if grep -qE 'p@ss|JSESSIONID|wlanuserip=' "$AUTOVERIFY_RUN_DIR/status" 2>/dev/null; then
	echo "    [FAIL] 运行状态包含敏感认证数据"; FAILED=1
else
	echo "    [OK]   运行状态未泄露密码、Cookie 或完整认证字段"
fi
_status_json=$(sh "$SCRIPT" status --json 2>&1)
_status_rc=$?
if [ "$_status_rc" = "0" ] && printf '%s\n' "$_status_json" | "$PY" -c 'import json, sys; x=json.load(sys.stdin); assert x["version"] == 1; assert x["result"] == "success"; assert x["service_enabled"] in (0, 1)' && ! printf '%s\n' "$_status_json" | grep -qF "$MAIN_PASSWORD"; then
	echo "    [OK]   status --json 可严格解析且字段类型正确"
else
	echo "    [FAIL] status --json 无法严格解析或泄露敏感信息"; FAILED=1
fi
_status_probe_json=$(sh "$SCRIPT" status --probe --json 2>&1)
_status_probe_rc=$?
if [ "$_status_probe_rc" = "0" ] && printf '%s\n' "$_status_probe_json" | "$PY" -c 'import json, sys; assert json.load(sys.stdin)["probe"] in ("online", "offline")'; then
	echo "    [OK]   status --probe --json 组合选项生效"
else
	echo "    [FAIL] status --probe --json 组合选项未生效"; FAILED=1
fi
_audit_json=$(sh "$SCRIPT" audit --json 2>&1)
_audit_rc=$?
if [ "$_audit_rc" = "0" ] && printf '%s\n' "$_audit_json" | "$PY" -c 'import json, sys; x=json.load(sys.stdin); assert x["version"] == 1; assert isinstance(x["checks"], list); assert isinstance(x["coverage"], list)' && ! printf '%s\n' "$_audit_json" | grep -qF "$MAIN_PASSWORD"; then
	echo "    [OK]   audit --json 可严格解析且无敏感信息"
else
	echo "    [FAIL] audit --json 无法严格解析或泄露敏感信息"; FAILED=1
fi
if grep -q "HDR GET /probe.*AL='zh-CN" "$TMPOUT" 2>/dev/null && \
	grep -q "HDR GET /zportal/loginForWeb.*AL='zh-CN.*SF='cross-site'" "$TMPOUT" 2>/dev/null && \
	grep -q "HDR POST /zportal/login/do.*AL='zh-CN.*SF='same-origin'" "$TMPOUT" 2>/dev/null; then
	echo "    [OK]   探测/登录请求带浏览器请求头"
else
	echo "    [FAIL] 探测或登录请求缺少 Accept-Language/Sec-Fetch 头"; FAILED=1
fi
mkdir -p "$AUTOVERIFY_RUN_DIR/auth.lock.d"
{
	echo 'pid=999999'
	echo 'started_at=1'
	echo 'source=test'
	echo 'operation=once'
} > "$AUTOVERIFY_RUN_DIR/auth.lock.d/owner"
_stale_json=$(sh "$SCRIPT" status --json 2>&1)
if printf '%s\n' "$_stale_json" | "$PY" -c 'import json, sys; assert json.load(sys.stdin)["lock_state"] == "stale"'; then
	echo "    [OK]   status 能识别 stale lock"
else
	echo "    [FAIL] status 未识别 stale lock"; FAILED=1
fi
rm -rf "$AUTOVERIFY_RUN_DIR/auth.lock.d"
echo "    mock 收到的请求:"
sed 's/^/      /' "$TMPOUT"

# 对齐浏览器 #login_form.serialize(): 字段名、顺序、占位文字、Origin 头
assert_post() {
	_name="$1"; shift
	for _want in "$@"; do
		if grep -qF "$_want" "$TMPOUT"; then
			echo "    [OK]   $_name: $_want"
		else
			echo "    [FAIL] $_name: 未找到 $_want"; FAILED=1
		fi
	done
}
echo "    --- 与浏览器报文的逐项对比 ---"
# 占位文字涉及非 ASCII 字节。Windows/MSYS 下本地 curl 会把 argv 从 UTF-8
# 重新编码成当前代码页(GBK), 因此这里只断言“字段存在且非空”。
# 路由器上的 curl 是原生 Linux 二进制, argv 是裸字节, 无此问题。
assert_post_nonempty() {
	if grep -qE "^  $2=.+" "$TMPOUT"; then
		echo "    [OK]   $1"
	else
		echo "    [FAIL] $1: 字段缺失或为空"; FAILED=1
	fi
}
assert_post "Origin 头"        'Origin: http://127.0.0.1:'"$PORT"
assert_post "Content-Type"     'Content-Type: application/x-www-form-urlencoded; charset=UTF-8'
assert_post "validCodeFlag"    'validCodeFlag=false'
assert_post "跟随 nextPage"    'GET /zportal/goToAuthResult'
assert_post_nonempty "qrCodeId 已原样回填(占位文字)" qrCodeId
assert_post_nonempty "validCode 已原样回填(占位文字)" validCode

_seq=$(grep -oE '^  [A-Za-z]+=' "$TMPOUT" | sed 's/^  //' | tr -d '=' | tr '\n' ' ' | sed 's/ $//')
_want="qrCodeId username pwd validCode validCodeFlag ssid mac t wlanacname url nasip wlanuserip"
if [ "$_seq" = "$_want" ]; then
	echo "    [OK]   字段顺序与浏览器一致"
else
	echo "    [FAIL] 字段顺序不一致:"
	echo "           实际: $_seq"
	echo "           期望: $_want"
	FAILED=1
fi
stop_mock

echo "=========== 2. 密码错误 ==========="
start_mock '{"message":"您输入的帐号或密码有误","nextPage":"","result":"fail"}'
check "认证失败应返回非 0 并报出门户提示" 1 "您输入的帐号或密码有误"
stop_mock

echo "=========== 3. 重复认证 ==========="
start_mock '{"message":"该帐号已在线, 请勿重复认证","nextPage":"","result":"online"}'
check "result=online 视为已在线" 0 "已在线"
stop_mock

echo "=========== 4. 门户要求验证码 ==========="
start_mock '{"message":"请输入验证码","nextPage":"","result":"fail"}'
check "应提示需先在浏览器认证" 1 "门户要求输入验证码"
stop_mock

echo "=========== 5. 返回非 JSON ==========="
start_mock '<html>502 Bad Gateway</html>'
check "应报出无法解析并带原始响应" 1 "认证响应无法解析"
stop_mock

echo "=========== 5a. 缺少 nextPage ==========="
start_mock '{"message":"","result":"success"}'
check "严格模式下缺少 nextPage 应失败" 1 "nextPage"
stop_mock

echo "=========== 5b. 外部 nextPage ==========="
start_mock '{"message":"","nextPage":"http://example.com/notice","result":"success"}'
check "严格模式下外部 nextPage 不应访问" 1 "外部门户"
stop_mock

echo "=========== 5c. nextPage 请求失败 ==========="
MOCK_NEXT_MODE=fail start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "nextPage HTTP 失败应传播为认证失败" 1 "nextPage 请求失败"
stop_mock

# 下面两个用例对应真实 NAS 的形态。实测这台 NAS 未认证时回 200 而不是 302,
# 最初的实现只认 302, 导致“未发现门户重定向, 无法定位认证页”。
echo "=========== 6. 未认证回 200 + 页面内 JS 跳转 (真实形态) ==========="
MOCK_PROBE_MODE=meta start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能从页面内跳转里找到门户地址" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 7. 未认证回 200 + Location 头 ==========="
MOCK_PROBE_MODE=location200 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能从 200 响应的 Location 头找到门户地址" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 8. 完全找不到门户地址 ==========="
start_mock '{"message":"","result":"success"}'
# 把探测指向只回 404 的路径, 模拟“NAS 回了 200/其它但内容里没有门户地址”
PROBE_SAVE="$TUNING_PROBE_URLS"
export TUNING_PROBE_URLS="http://127.0.0.1:$PORT/nothing"
check "应报错并把响应头/响应体打进日志" 1 "未发现门户重定向"
export TUNING_PROBE_URLS="$PROBE_SAVE"
stop_mock

echo "=========== 9. 两跳: 200 + JS 跳 /zportal/login, 该地址再 302 到 loginForWeb ==========="
# 完整复现真实 NAS 的行为。第一版实现只认 302 (报“未发现门户重定向”),
# 第二版不跟随登录页那一跳 (报“无法获取认证页面”)。
MOCK_PROBE_MODE=login302 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "应能跨两跳拿到登录页并完成认证" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 9a. 相对 Location ==========="
MOCK_PROBE_MODE=relative start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "相对 Location 应按探测地址补全并完成认证" 0 "认证后连通性验证通过"
stop_mock

echo "=========== 9b. 单引号 + 跨行 HTML 属性 ==========="
MOCK_PAGE_MODE=single-crossline start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "单引号和跨行属性应能解析并完成认证" 0 "认证后连通性验证通过"
stop_mock
unset MOCK_PAGE_MODE

echo "=========== 10. 空 portal.host (开源后的默认配置) ==========="
# 包里默认 host 为空, 门户地址靠响应里的 /zportal/ 自动识别。
# 这里同时卡住一个真 bug: case 的 *""* 能匹配任意字符串, host 为空时会把
# 任何地址都判成门户 —— 下面的 10b 就是这个回归点。
HOST_SAVE="$PORTAL_HOST"
PORTAL_HOST=""

MOCK_PROBE_MODE=login302 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
check "空 portal.host 时应能认出 /zportal/ 并完成认证" 0 "认证后连通性验证通过"
stop_mock

echo "--- 空 host 时, 与门户无关的跳转不能被当成门户"
# 旧实现下 is_portal_url 会匹配任意串, 于是拿公告页当登录页去请求,
# 报的是“无法获取认证页面”而不是“未发现门户重定向”。
MOCK_PROBE_MODE=other302 start_mock '{"message":"","result":"success"}'
check "应报未发现门户重定向" 1 "未发现门户重定向"
stop_mock

echo "=========== 11. 并发认证互斥 =========="
MOCK_POST_DELAY=2 start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
OUT1=$(mktemp)
OUT2=$(mktemp)
sh "$SCRIPT" once >"$OUT1" 2>&1 &
PID1=$!
_i=0
while [ "$_i" -lt 40 ] && ! grep -q '^POST /zportal/login/do' "$TMPOUT" 2>/dev/null; do
	sleep 0.1
	_i=$((_i + 1))
done
sh "$SCRIPT" once >"$OUT2" 2>&1
RC2=$?
wait "$PID1"
RC1=$?
POSTS=$(grep -c '^POST /zportal/login/do' "$TMPOUT" 2>/dev/null || true)
printf '    first rc=%s second rc=%s POST 数=%s\n' "$RC1" "$RC2" "$POSTS"
if [ "$RC2" = "3" ] && [ "$POSTS" = "1" ]; then
	echo "    [OK] 并发调用只有一个提交, 第二个立即返回 busy"
else
	echo "    [FAIL] 并发互斥未生效"
	cat "$OUT1" "$OUT2" | sed 's/^/      /'
	FAILED=1
fi
rm -f "$OUT1" "$OUT2"
stop_mock

echo "=========== 12. stale lock 回收 =========="
start_mock '{"message":"","nextPage":"goToAuthResult","result":"success"}'
mkdir -p "$AUTOVERIFY_RUN_DIR/auth.lock.d"
{
	echo 'pid=999999'
	echo 'started_at=1'
	echo 'source=test'
	echo 'operation=once'
} > "$AUTOVERIFY_RUN_DIR/auth.lock.d/owner"
check "无效 PID 的 stale lock 应被回收" 0 "认证后连通性验证通过"
if [ -d "$AUTOVERIFY_RUN_DIR/auth.lock.d" ]; then
	echo "    [FAIL] stale lock 未清理"; FAILED=1
else
	echo "    [OK] stale lock 已回收"
fi
stop_mock

PORTAL_HOST="$HOST_SAVE"

echo
if [ "$FAILED" = "0" ]; then
	echo "全部通过"
else
	echo "存在失败用例"
fi
exit "$FAILED"
