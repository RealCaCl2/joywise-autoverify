'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require dom';
'require poll';
'require rpc';

/*
 * 校园网自动认证 - 设置页面
 *
 * 页面分三块:
 *   1. 运行状态概览: 只读, 周期性调用 `autoverify status --json`, 不发起网络探测;
 *   2. 配置表单: 直接绑定 UCI /etc/config/autoverify, 按用途分成四个选项卡;
 *   3. 操作区: 调用路由器上的只读诊断/认证命令, 输出与退出码弹窗显示。
 *
 * 点"保存并应用"后:
 *   uci commit autoverify -> procd 的 reload trigger 触发
 *   /etc/init.d/autoverify reload -> 重新落地加固配置 + 重启认证进程
 * 因此页面里不需要自己做"应用", 也不用 exec 任何脚本。
 *
 * 表单用 form.SectionValue 把 portal / tuning / network / 五个 hardening 段
 * 嵌进同一个容器 section 的选项卡里 —— 这样九个 UCI section 不再纵向堆成一条
 * 长页面, 而各 section 自己的标题、描述和 depends 关系保持不变。
 */

var BIN = '/usr/sbin/autoverify';
var HARDENING_BIN = '/usr/sbin/autoverify-hardening';
var STATUS_INTERVAL = 10;

/* procd 的实例状态是判断“守护进程是否在跑”的权威来源。
 *
 * 不能用 status --json 里的 daemon_count / daemon_pid: 它们来自 pidof autoverify,
 * 而 pidof 按脚本名匹配, 会把发起本次查询的进程自身(及其子 shell)一起数进去 ——
 * 实测在守护进程已停的情况下也会得到非零值, 据此判断存活会永远显示“运行中”。 */
var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

/* 页面私有样式。全部以 av- 前缀限定, 不影响 LuCI 其它页面。
 *
 * 只用边框、透明度与继承色, 不写死背景色, 也不引用 LuCI 26 的设计 token
 * (--background-color-low 之类): 第三方主题(实测 argon)没有这些 token,
 * 带 fallback 写死浅色会在暗色主题下变成一块突兑的浅色。
 * 状态色用饱和填充 + 白字, 在亮/暗两种主题下都保持对比度。 */
var STYLE = [
	'.av-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:.75em;margin:.75em 0}',
	'.av-card{border:1px solid rgba(127,127,127,.3);border-radius:8px;padding:.8em 1em;min-width:0}',
	'.av-card-label{font-size:.8em;opacity:.7;margin-bottom:.2em}',
	'.av-card-value{font-size:1em;line-height:1.5;word-break:break-word}',
	'.av-badge{display:inline-block;padding:.05em .5em;border-radius:10px;font-size:.85em;color:#fff;white-space:nowrap}',
	'.av-ok{background:#2e7d32}.av-bad{background:#c62828}.av-warn{background:#b26a00}.av-idle{background:#616161}',
	'.av-hint{font-size:.85em;opacity:.75;margin:.3em 0}',
	/* argon 等主题会把 .cbi-section 的 padding 清零, 页面留白是靠表单行
	 * (.cbi-value{padding:0 1rem}) 撑出来的。所以自定义面板的内容块要自己留边距,
	 * 否则卡片与按钮会紧贴左右两边。数值跟随主题自己的表单行。 */
	'.av-body{padding:0 1rem}',
	'.av-header{display:flex;align-items:center;justify-content:space-between;gap:1em;padding:.8em 1rem;flex-wrap:wrap}',
	'.av-header h3{margin:0}.av-header p{margin:.25em 0 0}',
	'.av-details{margin:.9em 0;border-top:1px solid rgba(127,127,127,.25);padding-top:.7em}',
	'.av-details summary{cursor:pointer;font-weight:600;padding:.25em 0}',
	'.av-notice{border-left:3px solid #4488aa;padding:.75em 1em;line-height:1.65;margin:.5em 0}',
	'.av-route{display:flex;align-items:center;flex-wrap:wrap;gap:.5em;margin:.6em 0}',
	'.av-route span{border:1px solid rgba(127,127,127,.3);border-radius:6px;padding:.25em .65em}',
	'.av-dns-summary{line-height:1.7;overflow-wrap:anywhere}.av-dns-summary strong{display:block}',
	'.av-actions .av-row{margin:.5em 0 1em}.av-actions button{min-height:2.5em}',
	'.av-page .cbi-tabmenu{display:flex;flex-wrap:wrap;gap:.25em}',
	'.av-actions button:disabled{opacity:.55;cursor:wait}',
	'.av-page details>summary:focus-visible,.av-page button:focus-visible{outline:2px solid #4488aa;outline-offset:3px}',
	'@media(max-width:600px){.av-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.av-card{padding:.65em}.av-actions .av-row{display:grid;grid-template-columns:1fr}.av-actions button{width:100%}}',
	'.av-group{font-weight:600;font-size:.9em;opacity:.8;margin:.9em 0 .35em}',
	'.av-row{display:flex;flex-wrap:wrap;gap:.5em;align-items:center}',
	'.av-out{white-space:pre-wrap;word-break:break-all;max-height:60vh;overflow:auto;',
	'border:1px solid rgba(127,127,127,.35);border-radius:4px;padding:.5em;margin-top:.6em}'
].join('');

function intval(value) {
	var n = parseInt(value, 10);
	return isNaN(n) ? 0 : n;
}

function fmtTime(ts) {
	ts = intval(ts);
	if (ts <= 0)
		return '-';
	return new Date(ts * 1000).toLocaleString();
}

function fmtText(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return String(value);
}

function badge(cls, text) {
	return E('span', { 'class': 'av-badge ' + cls }, text);
}

/* 返回 { count, pid } 或 null。null 表示读不到 procd 状态(权限/版本), 与
 * “确实没在运行”(count=0) 是两回事, 界面上不能混为一谈。 */
function daemonState(serviceList) {
	var instances = serviceList && serviceList.autoverify && serviceList.autoverify.instances;
	if (!instances)
		return null;

	var count = 0, pid = null;
	for (var id in instances) {
		if (instances[id] && instances[id].running) {
			count++;
			if (pid == null)
				pid = instances[id].pid;
		}
	}
	return { count: count, pid: pid };
}

function card(label, value) {
	return E('div', { 'class': 'av-card' }, [
		E('div', { 'class': 'av-card-label' }, label),
		E('div', { 'class': 'av-card-value' }, value)
	]);
}

/* result / state 都来自 status --json 的固定枚举, 未知值一律按"未知"处理,
 * 不猜测含义。 */
function resultBadge(result) {
	switch (result) {
	case 'success': return badge('av-ok', _('成功'));
	case 'failed':  return badge('av-bad', _('失败'));
	case 'running': return badge('av-warn', _('进行中'));
	default:        return badge('av-idle', _('未知'));
	}
}

function lockBadge(state) {
	switch (state) {
	case 'free':  return badge('av-ok', _('空闲'));
	case 'busy':  return badge('av-warn', _('认证中'));
	case 'stale': return badge('av-bad', _('残留(可回收)'));
	default:      return badge('av-idle', _('未知'));
	}
}

return view.extend({
	load: function() {
		return uci.load('autoverify');
	},

	/*
	 * 读取运行状态。只读: status 默认不发起网络探测, 也不会改任何配置。
	 *
	 * 失败分两种, 必须区分显示:
	 *   - exec 被 rpcd 拒绝(ACL 未生效) -> 提示 reload rpcd;
	 *   - 命令本身失败/输出不是 JSON   -> 原样提示, 不假装有数据。
	 */
	pollStatus: function(node) {
		var self = this;
		var status = fs.exec(BIN, [ 'status', '--json' ]).then(function(res) {
			var out = (res.stdout || '').trim();
			if (res.code !== 0 || !out)
				throw new Error(_('命令退出码 %d').format(res.code));
			return JSON.parse(out);
		});
		/* procd 查询失败不应连带整个面板失败, 退回“未知”。 */
		var service = L.resolveDefault(callServiceList('autoverify'), null);

		return Promise.all([ status, service ]).then(function(r) {
			var details = node.querySelector('.av-details');
			if (details)
				self._detailsOpen = details.open;
			dom.content(node, self.renderStatus(r[0], r[1]));
		}).catch(function(err) {
			dom.content(node, self.renderStatusError(err));
		});
	},

	renderStatus: function(d, serviceList) {
		var serviceEnabled = intval(d.service_enabled) === 1;
		var daemon = daemonState(serviceList);
		var daemonNode, probeNode, errText, wanText, portalText, lastText, ipv6Text;

		if (daemon == null)
			daemonNode = badge('av-idle', _('未知'));
		else if (daemon.count > 0)
			daemonNode = badge('av-ok', daemon.pid != null
				? _('运行中 (PID %d)').format(daemon.pid) : _('运行中'));
		else
			daemonNode = badge(serviceEnabled ? 'av-bad' : 'av-idle', _('未运行'));

		switch (d.probe) {
		case 'online':  probeNode = badge('av-ok', _('在线')); break;
		case 'offline': probeNode = badge('av-bad', _('离线')); break;
		default:        probeNode = E('span', {}, _('未探测'));
		}

		errText = fmtText(d.error_code);
		if (d.error_code && d.error_stage)
			errText = '%s / %s'.format(d.error_code, d.error_stage);

		/* 相关字段合并成一行, 避免卡片数量过多、版面碎散。 */
		wanText = fmtText(d.wan_interface);
		if (d.wan_ipv4)
			wanText += ' · ' + d.wan_ipv4;

		portalText = fmtText(d.portal_origin);
		if (d.http_code)
			portalText += ' · HTTP %s'.format(d.http_code);

		lastText = _('%d ms').format(intval(d.duration_ms));
		if (intval(d.finished_at) > 0)
			lastText += ' · ' + fmtTime(d.finished_at);

		ipv6Text = _('全局 %s · 默认路由 %s').format(
			fmtText(d.ipv6_global), fmtText(d.ipv6_default_route));

		var cards = [
			card(_('服务开关'), serviceEnabled
				? badge('av-ok', _('已启用')) : badge('av-idle', _('已禁用'))),
			card(_('守护进程'), daemonNode),
			card(_('最近任务'), resultBadge(d.result)),
			card(_('WAN'), wanText)
		];
		var details = [
			card(_('任务阶段'), fmtText(d.state)),
			card(_('最近错误'), errText),
			card(_('触发来源'), '%s · %s'.format(fmtText(d.source), fmtText(d.operation))),
			card(_('认证锁'), lockBadge(d.lock_state)),
			card(_('本次连通性'), probeNode),
			card(_('门户'), portalText),
			card(_('最近一次'), lastText),
			card(_('下次重试'), fmtTime(d.next_retry_at)),
			card(_('IPv6'), ipv6Text)
		];

		return [
			E('div', { 'class': 'av-grid' }, cards),
			E('details', { 'class': 'av-details', 'open': this._detailsOpen ? '' : null }, [
				E('summary', {}, _('连接与任务详情')),
				E('div', { 'class': 'av-grid' }, details)
			]),
			E('div', { 'class': 'av-hint' },
				_('每 %d 秒自动刷新。此处不主动探测网络；需要确认在线状态时，请点击“检测连通性”。')
					.format(STATUS_INTERVAL)),
			daemon == null ? E('div', { 'class': 'av-hint' },
				_('读不到 procd 的实例状态，守护进程一栏显示为未知。')) : E([])
		];
	},

	renderStatusError: function(err) {
		var msg = (err && err.message) ? err.message : String(err);
		return [
			E('div', { 'class': 'av-card' }, [
				E('div', { 'class': 'av-card-label' }, _('运行状态')),
				E('div', { 'class': 'av-card-value' }, badge('av-idle', _('读取失败')))
			]),
			E('div', { 'class': 'av-hint' },
				_('无法读取运行状态：%s').format(msg)),
			E('div', { 'class': 'av-hint' },
				_('若提示权限被拒，通常是升级后 rpcd 还在用旧的 ACL 缓存，' +
				  '在路由器上执行 /etc/init.d/rpcd reload 后刷新本页即可。'))
		];
	},

	handleRefresh: function(node) {
		return this.pollStatus(node);
	},

	/*
	 * 执行路由上的命令并弹窗显示结果。
	 *
	 * 必须把退出码也显示出来: autoverify check / once 正常情况下本来就不产生输出,
	 * 只看 stdout 会得到一个空弹窗, 分不清是成功、离线、还是权限被拒。
	 * hint 用来解释退出码的含义。
	 */
	handleAction: function(cmd, args, title, hint) {
		if (this._actionBusy) {
			ui.addNotification(null, E('p', _('已有操作正在执行，请等待结果返回。')), 'warning');
			return Promise.resolve();
		}

		this._actionBusy = true;
		var self = this;
		(this._actionButtons || []).forEach(function(button) { button.disabled = true; });
		return fs.exec(cmd, args).then(function(res) {
			var out = ((res.stdout || '') + (res.stderr || '')).replace(/\s+$/, '');
			var body = out || _('(命令没有产生输出)');

			ui.showModal(title || cmd, [
				E('div', {}, [
					E('span', { 'style': 'margin-right:.5em' }, _('退出码:')),
					res.code === 0 ? badge('av-ok', String(res.code)) : badge('av-warn', String(res.code))
				]),
				hint ? E('div', { 'class': 'av-hint' }, hint) : E([]),
				E('pre', { 'class': 'av-out', 'tabindex': '0', 'aria-label': _('命令输出') }, body),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('关闭'))
				])
			]);
		}).catch(function(err) {
			ui.addNotification(null,
				E('p', _('执行失败: %s').format(err && err.message ? err.message : err)), 'error');
		}).then(function() {
			self._actionBusy = false;
			(self._actionButtons || []).forEach(function(button) { button.disabled = false; });
			if (self._statusBody)
				return self.pollStatus(self._statusBody);
		});
	},

	/* 操作区里的一个按钮。集中构造, 避免每个按钮重复一大段属性。 */
	actionButton: function(label, style, cmd, args, title, hint) {
		var button = E('button', {
			'class': 'btn cbi-button ' + style,
			'type': 'button',
			'click': ui.createHandlerFn(this, 'handleAction', cmd, args, title, hint)
		}, label);
		(this._actionButtons || (this._actionButtons = [])).push(button);
		return button;
	},

	renderDnsSummary: function(provider, section) {
		var presets = {
			tencent: [ _('腾讯云 DNSPod'), 'https://doh.pub/dns-query', '119.29.29.29' ],
			aliyun: [ _('阿里云公共 DNS'), 'https://dns.alidns.com/dns-query', '223.5.5.5,223.6.6.6' ]
		};
		var preset = presets[provider];
		if (!preset) {
			var url = section.formvalue('dns', 'doh_url') || uci.get('autoverify', 'dns', 'doh_url');
			// URL 可能含服务令牌，摘要只显示 host，完整值保留在输入框中。
			var host = /^https:\/\/([^/]+)/.exec(url || '');
			return [ E('strong', {}, _('自定义 DoH 服务')),
				E('div', {}, host ? host[1] : _('请填写下方的 HTTPS 地址和 Bootstrap DNS。')) ];
		}
		return [ E('strong', {}, preset[0]), E('div', {}, preset[1]),
			E('div', { 'class': 'av-hint' }, _('Bootstrap：%s（仅解析服务域名）').format(preset[2])) ];
	},

	render: function() {
		var self = this, m, s, o, ss;
		this._actionButtons = [];

		/* ------------------------------------------------------ 状态概览 --- */
		/* statusBody 的 class 不会被 dom.content 改掉(它只换子节点), 所以内边距放它身上。 */
		var statusBody = E('div', { 'class': 'av-body' }, E('em', {}, _('正在读取运行状态…')));
		var statusPanel = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'av-header' }, [
				E('div', {}, [ E('h3', _('运行概览')), E('p', { 'class': 'av-hint' }, _('服务、最近任务与出口接口')) ]),
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'type': 'button',
					'click': ui.createHandlerFn(this, 'handleRefresh', statusBody) }, _('刷新状态'))
			]),
			statusBody,
		]);

		/* -------------------------------------------------------- 配置表单 --- */
		m = new form.Map('autoverify', _('校园网自动认证'),
			_('zportal 门户自动认证，以及针对校园网多设备检测的反制措施。' +
			  '改完点“保存并应用”，配置会落盘并自动重启认证进程。'));

		s = m.section(form.NamedSection, 'main', 'autoverify');
		s.addremove = false;
		s.anonymous = true;

		s.tab('basic', _('账号与门户'),
			_('账号和门户地址。多数 zportal 学校只需要填账号密码，门户地址留空自动识别。'));
		s.tab('dns', _('DNS 与 DoH'),
			_('汇聚 LAN 的 DNS 查询，统一由路由器通过 HTTPS 解析。默认使用腾讯云，也可选择阿里云或自定义服务。'));
		s.tab('probe', _('探测与轮询'),
			_('决定“何时认为掉线”以及失败后的重试节奏。' +
			  '本节末尾还有认证互斥、状态记录和 nextPage 严格校验，保持默认即可。'));
		s.tab('iface', _('接口'),
			_('出口与 LAN 接口。注意 netdev 名和 netifd 接口名不是同一个命名空间。'));
		s.tab('hardening', _('反检测加固'),
			_('针对校园网多设备检测的反制措施，均可单独开关。' +
			  '这些措施可能违反所在学校的网络使用规定，启用前请自行确认。'));

		/* --------------------------------------------------------- 账号 --- */
		o = s.taboption('basic', form.Flag, 'enabled', _('启用'),
			_('关闭后不启动认证守护进程，也不再自动认证'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'username', _('账号'), _('通常是学号'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value ? true : _('账号不能为空');
		};

		o = s.taboption('basic', form.Value, 'password', _('密码'));
		o.password = true;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return value ? true : _('密码不能为空');
		};

		/* --------------------------------------------------------- 门户 --- */
		o = s.taboption('basic', form.SectionValue, '_portal', form.NamedSection,
			'portal', 'autoverify', _('门户'),
			_('未认证时程序会从 NAS 的响应里自动识别 /zportal/ 登录页，通常三项全部留空即可。'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Value, 'host', _('门户地址'),
			_('认证服务器 IP。留空 = 由响应中的 /zportal/ 自动识别（推荐）。' +
			  '只有门户返回相对路径、需要补全主机名时才必须填。'));
		o.datatype = 'ip4addr';
		o.placeholder = _('留空自动识别');
		o.rmempty = true;

		o = ss.option(form.Value, 'port', _('门户端口'));
		o.default = '9090';
		o.datatype = 'port';
		o.rmempty = false;

		o = ss.option(form.Value, 'url', _('登录页地址（覆盖）'),
			_('通常留空。未认证时程序会自动从 NAS 的响应里解析登录页地址，' +
			  'wlanuserip / mac / nasip / wlanacname / ssid 都会自动跟随网络变化。' +
			  '仅当自动探测失败时，才把浏览器地址栏里的 loginForWeb 地址粘到这里，' +
			  '其中会变化的客户端 IP 用 %WANIP% 占位。'));
		o.placeholder = 'http://10.82.66.10:9090/zportal/loginForWeb?wlanuserip=%WANIP%&...';

		/* ---------------------------------------------------- 探测与轮询 --- */
		o = s.taboption('probe', form.SectionValue, '_tuning', form.NamedSection,
			'tuning', 'autoverify', _('探测与轮询'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.DynamicList, 'probe_urls', _('连通性探测地址'),
			_('未认证时这些地址会被 NAS 劫持并引导到门户。' +
			  '判定"在线" = 状态码等于下面的期望值，且没有被重定向。'));
		o.placeholder = 'http://connect.rom.miui.com/generate_204';
		o.rmempty = false;

		o = ss.option(form.Value, 'user_agent', _('请求 User-Agent'),
			_('发出所有 HTTP 请求时带的 UA。探测走明文 HTTP，校园网直接看得见，' +
			  '所以不能填任何带 OpenWrt 或本项目名字的串，也不要填虚构/过时的 UA。' +
			  '建议与 UA-Mask 的 UA 保持一致 —— 两边不同，等于告诉对方这里住着两种浏览器。'));
		o.default = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
			'(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';
		o.rmempty = false;

		o = ss.option(form.Value, 'expect_code', _('期望状态码'), _('generate_204 类地址填 204'));
		o.default = '204';
		o.datatype = 'range(100,599)';

		o = ss.option(form.Value, 'http_timeout', _('单次 HTTP 超时'), _('秒'));
		o.default = '8';
		o.datatype = 'and(uinteger,min(1))';

		o = ss.option(form.Value, 'check_interval', _('在线检查间隔'), _('秒'));
		o.default = '60';
		o.datatype = 'and(uinteger,min(1))';

		o = ss.option(form.Value, 'retry_interval', _('失败重试间隔'), _('秒，之后逐次翻倍'));
		o.default = '20';
		o.datatype = 'and(uinteger,min(1))';

		o = ss.option(form.Value, 'max_retry_interval', _('重试间隔上限'),
			_('秒。限制退避的上限，避免高频失败把门户的失败计数打满而强制要求验证码。' +
			  '不能小于上面的失败重试间隔。'));
		o.default = '300';
		o.datatype = 'and(uinteger,min(1))';
		o.validate = function(section_id, value) {
			var base = this.section.formvalue(section_id, 'retry_interval');
			if (value && base && +value < +base)
				return _('重试间隔上限不能小于失败重试间隔');
			return true;
		};

		o = ss.option(form.Flag, 'verbose', _('详细日志'),
			_('每次探测都写日志，排障用。也可以临时执行 autoverify -v once。'));
		o.default = '0';
		o.rmempty = false;

		/* 以下几项以前只能用命令行改 (见 docs/operations.md 的回滚一节)。
		 * 放到界面上是为了排障时能看到当前值; 它们与上面的选项同属 tuning 段,
		 * 因此挂在同一个子 section 里 —— 同一个 UCI section 不重复实例化。 */
		o = ss.option(form.Flag, 'lock_enabled', _('认证互斥锁（高级）'),
			_('防止 daemon、hotplug 和手动操作同时提交认证。关闭后并发请求会一起打到门户。' +
			  '保持默认开启。'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.Value, 'lock_max_age', _('锁最大存活时间（高级）'),
			_('秒。超过该时长且持锁进程已不存在时，锁会被判定为残留并回收。'));
		o.default = '300';
		o.datatype = 'and(uinteger,min(1))';
		o.depends('lock_enabled', '1');

		o = ss.option(form.Flag, 'state_enabled', _('记录运行状态（高级）'),
			_('把认证阶段和结果写入 /var/run/autoverify/status（只保存脱敏结论）。' +
			  '关闭后页面顶部的运行状态将没有数据。'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.Flag, 'nextpage_strict', _('nextPage 严格校验（高级）'),
			_('只允许门户返回本站 origin 的 HTTP(S) 跳转，并把该请求的失败视为认证失败。' +
			  '关闭后认证成功的响应可能把路由器带到第三方地址。'));
		o.default = '1';
		o.rmempty = false;

		/* --------------------------------------------------------- 接口 --- */
		o = s.taboption('iface', form.SectionValue, '_network', form.NamedSection,
			'network', 'autoverify', _('接口'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Value, 'wan_if', _('出口 netdev'),
			_('如 phy1-sta0。留空则自动取默认路由接口。'));
		o.placeholder = _('自动');

		o = ss.option(form.Value, 'hotplug_if', _('触发认证的 netifd 接口'),
			_('如 wwan（无线 STA）或 wan（有线）。' +
			  '注意这与上面的 netdev 名不是同一个命名空间。'));
		o.default = 'wwan';

		o = ss.option(form.Value, 'lan_dev', _('LAN 接口'),
			_('TTL 归一化作用的接口，通常是 br-lan。'));
		o.default = 'br-lan';

		/* ----------------------------------------------------- TTL 归一化 --- */
		o = s.taboption('hardening', form.SectionValue, '_ttl', form.NamedSection,
			'ttl', 'hardening', _('TTL 归一化'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 转发出去的 IPv4 包 TTL 统一。' +
			  '不同系统初始 TTL 不同（Windows 128、Linux/Android 64），' +
			  'NAT 后出现离散值就会被判定为多设备。'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.ListValue, 'ttl', _('TTL 值'),
			_('取与你主力设备一致的值。跨层一致性也有意义：' +
			  '如果你的浏览器 UA 是 Windows 而 TTL 是 64，某些检测会认为两者不匹配。'));
		o.value('64', _('64 — Linux / Android / iOS'));
		o.value('128', _('128 — Windows'));
		o.default = '64';
		o.depends('enabled', '1');

		/* --------------------------------------------------------- NTP --- */
		o = s.taboption('hardening', form.SectionValue, '_ntp', form.NamedSection,
			'ntp', 'hardening', _('NTP 收敛'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 的 udp/123 重定向到路由器，并让路由器作为 NTP 服务器。' +
			  '不同设备的默认 NTP 服务器和对时频率都不一样，直接出去就是多设备特征。'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.DynamicList, 'server', _('上游 NTP 服务器'),
			_('路由器自己向这些服务器对时；客户端则统一由路由器应答。'));
		o.placeholder = 'ntp.aliyun.com';
		o.depends('enabled', '1');

		/* --------------------------------------------------------- DNS --- */
		o = s.taboption('dns', form.SectionValue, '_dns', form.NamedSection,
			'dns', 'hardening', _('DNS 汇聚与加密上游'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Flag, 'enabled', _('启用'),
			_('把 LAN 的 udp/tcp 53 重定向到路由器的 dnsmasq。' +
			  'dnsmasq 的上游统一通过本机 https-dns-proxy 使用 DoH，不回退明文 DNS。' +
			  '注意：浏览器启用 DoH 时走 443，本项覆盖不到。'));
		o.default = '1';
		o.rmempty = false;

		var dnsSection = ss;
		var dnsSummary = E('div', { 'class': 'av-notice av-dns-summary', 'role': 'status', 'aria-live': 'polite' });
		o = ss.option(form.DummyValue, '_dns_summary', _('上游预览'));
		o.depends('enabled', '1');
		o.renderWidget = function() {
			dom.content(dnsSummary, self.renderDnsSummary(uci.get('autoverify', 'dns', 'doh_provider') || 'tencent', dnsSection));
			return E('div', {}, [
				dnsSummary,
				E('div', { 'class': 'av-route', 'aria-label': _('DNS 解析链路') }, [
					E('span', {}, _('客户端 DNS')), '→', E('span', {}, 'dnsmasq'), '→', E('span', {}, _('DoH 上游'))
				]),
				E('div', { 'class': 'av-hint' }, _('DoH 失败时不回退明文 DNS。修改后点击“保存并应用”生效。'))
			]);
		};

		o = ss.option(form.ListValue, 'doh_provider', _('DoH 上游'));
		o.value('tencent', _('腾讯云 DNSPod（doh.pub）'));
		o.value('aliyun', _('阿里云公共 DNS（dns.alidns.com）'));
		o.value('custom', _('自定义'));
		o.default = 'tencent';
		o.rmempty = false;
		o.depends('enabled', '1');
		o.onchange = function(ev, section_id, value) {
			dom.content(dnsSummary, self.renderDnsSummary(value, dnsSection));
		};

		o = ss.option(form.Value, 'doh_url', _('自定义 DoH URL'),
			_('填写支持 RFC 8484 的 HTTPS 地址，使用域名进行 TLS 证书验证。'));
		o.placeholder = 'https://resolver.example/dns-query';
		o.rmempty = false;
		o.retain = true;
		o.depends({ enabled: '1', doh_provider: 'custom' });
		o.onchange = function() {
			dom.content(dnsSummary, self.renderDnsSummary('custom', dnsSection));
		};
		o.validate = function(section_id, value) {
			var match = /^https:\/\/([A-Za-z0-9][A-Za-z0-9.-]*)(?::(\d+))?\/[A-Za-z0-9_\/.~?&=%+:-]*$/.exec(value);
			if (!match || (match[2] && (Number(match[2]) < 1 || Number(match[2]) > 65535)))
				return _('请输入有效的 HTTPS DoH URL');
			if (/^[0-9.]+$/.test(match[1]) && !/^(\d+\.){3}\d+$/.test(match[1]))
				return _('IPv4 地址无效');
			return !/^[0-9.]+$/.test(match[1]) || match[1].split('.').every(function(n) { return Number(n) <= 255; })
				? true : _('IPv4 地址无效');
		};

		o = ss.option(form.Value, 'doh_bootstrap', _('Bootstrap DNS'),
			_('仅用于解析 DoH 服务域名，使用明文 DNS；填写 IPv4 地址，以逗号分隔。普通查询不回退到这里。'));
		o.default = '119.29.29.29';
		o.rmempty = false;
		o.retain = true;
		o.depends({ enabled: '1', doh_provider: 'custom' });
		o.validate = function(section_id, value) {
			return value.split(',').every(function(ip) {
				return /^(\d+\.){3}\d+$/.test(ip) && ip.split('.').every(function(n) { return Number(n) <= 255; });
			}) ? true : _('请输入逗号分隔的 IPv4 地址');
		};

		/* -------------------------------------------------------- DHCP --- */
		o = s.taboption('hardening', form.SectionValue, '_dhcp', form.NamedSection,
			'dhcp', 'hardening', _('DHCP 伪装'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Flag, 'enabled', _('启用'),
			_('校园网的 DHCP 服务器会记录三个字段，而 OpenWrt 的默认值等于直接自报家门：' +
			  '主机名 "OpenWrt"、client-id 是一串 DUID、厂商号 "udhcp <版本号>"（连 DHCP 客户端实现都报出去了）。' +
			  '本项把它们换成普通终端的样子。' +
			  '注意：改 client-id 有可能让 DHCP 服务器重新分配地址，会短暂断网（本项目会自动重新认证）。'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.Value, 'hostname', _('伪装主机名'),
			_('留空则首次应用时随机生成一个 LAPTOP-XXXXXXXX（Windows 默认命名风格）并写回配置，' +
			  '之后保持不变。不要填带 OpenWrt 字样的名字。'));
		o.placeholder = 'LAPTOP-AB12CD34';
		o.depends('enabled', '1');

		o = ss.option(form.Value, 'vendorid', _('伪装厂商号'),
			_('Windows 客户端发的是 MSFT 5.0。留空会退回 OpenWrt 默认值，不建议。'));
		o.placeholder = 'MSFT 5.0';
		o.depends('enabled', '1');

		/* -------------------------------------------------------- IPv6 --- */
		o = s.taboption('hardening', form.SectionValue, '_ipv6', form.NamedSection,
			'ipv6', 'hardening', _('IPv6 防护'));
		ss = o.subsection;
		ss.addremove = false;
		ss.anonymous = true;

		o = ss.option(form.Flag, 'enabled', _('启用'),
			_('关掉 LAN 的 RA 与 DHCPv6。本项目所有措施的前提是「设备藏在 NAT 后面」，' +
			  '而 IPv6 不做 NAT —— 一旦上游下发全局前缀且 LAN 还在发 RA，每台客户端会直接拿到' +
			  '可路由地址，绕过本机全部出站检查。代价：局域网内也没有 IPv6 了。'));
		o.default = '1';
		o.rmempty = false;

		/* --------------------------------------------------------- 操作 --- */
		/* 自己用 .av-row 排版, 不借用表单的 .cbi-value: 那个类在不同主题下的
		 * 缩进、行高按表单字段调过, 拿来装按钮会跟着变。 */
		var actions = E('div', { 'class': 'cbi-section av-actions' }, [
			E('div', { 'class': 'av-header' }, [ E('h3', _('认证与诊断')), E('span', { 'class': 'av-hint' }, _('结果以弹窗显示')) ]),
			E('div', { 'class': 'av-body' }, [
				E('div', { 'class': 'cbi-section-descr' },
					_('手动认证、连通性检测和只读诊断。操作期间按钮会暂时禁用，完成后刷新运行状态。')),

				E('div', { 'class': 'av-group' }, _('认证')),
				E('div', { 'class': 'av-row' }, [
					this.actionButton(_('立即认证一次'), 'cbi-button-action',
						BIN, [ '-v', 'once' ], _('立即认证一次'),
						_('已在线时不会重复认证 —— 在线状态下强行认证会顶掉自己已有的会话。' +
						  '退出码 0 = 已在线或认证成功，1 = 失败，3 = 已有认证任务在跑。')),
					this.actionButton(_('检测连通性'), 'cbi-button-neutral',
						BIN, [ '-v', 'check' ], _('检测连通性'),
						_('退出码 0 = 在线，1 = 离线。'))
				]),

				E('div', { 'class': 'av-group' }, _('只读诊断')),
				E('div', { 'class': 'av-row' }, [
					this.actionButton(_('运行状态'), '', BIN, [ 'status' ],
						_('查看运行状态'),
						_('只读，不发起网络探测；如需探测请使用“检测连通性”。')),
					this.actionButton(_('网络与防火墙审计'), '', BIN, [ 'audit' ],
						_('网络与防火墙审计'),
						_('只读，缺少可选系统命令时仍会输出部分结果。')),
					this.actionButton(_('校验配置'), '', BIN, [ 'validate' ],
						_('校验配置'),
						_('只读，不访问门户、不修改 UCI 或防火墙。' +
						  '退出码 0 = 配置有效，1 = 配置错误，2 = 环境不完整。')),
					this.actionButton(_('加固状态'), '', HARDENING_BIN, [ 'status' ],
						_('查看加固状态'),
						_('对比 UCI 开关与系统里实际生效的规则、监听和接口参数。')),
					this.actionButton(_('将要提交的认证字段'), '', BIN, [ 'debug' ],
						_('将要提交的认证字段 (只读)'),
						_('只读，不会提交认证。密码已脱敏。' +
						  ' 未认证时才能看到完整的登录页字段；在线时会提示“未发现门户重定向”，这是正常的。'))
				]),

				E('div', { 'class': 'av-group' }, _('维护')),
				E('div', { 'class': 'av-row' }, [
					this.actionButton(_('检查更新'), '', BIN, [ 'update-check' ],
						_('检查更新'),
						_('退出码 0 = 已是最新，1 = 有新版本，2 = 查询失败。' +
						  '查询 GitHub Releases，只读，不会自动安装。'))
				]),

				E('div', { 'class': 'cbi-section-descr' },
					_('提示：手动执行时的日志只进终端，不进 syslog；' +
					  '只有守护进程自己的日志会被 procd 转发到系统日志。'))
			])
		]);

		return m.render().then(function(mapEl) {
			self.pollStatus(statusBody);
			poll.add(function() {
				return self.pollStatus(statusBody);
			}, STATUS_INTERVAL);

			self._statusBody = statusBody;
			return E('div', { 'class': 'av-page' }, [
				E('style', { 'type': 'text/css' }, STYLE),
				statusPanel,
				mapEl,
				actions
			]);
		});
	}
});
