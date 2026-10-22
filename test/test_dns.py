"""Exercise POSIX DNS apply/restore with a stateful UCI and init-service mock."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


def mock_uci(args):
    path = Path(os.environ['DNS_TEST_DB'])
    db = json.loads(path.read_text())
    args = [a for a in args if a != '-q']
    cmd, key = args[:2]
    if cmd == 'get':
        if key not in db:
            return 1
        value = db[key]
        print(' '.join(value) if isinstance(value, list) else value)
    elif cmd == 'show':
        for k, v in db.items():
            if k.startswith(key + '.') and isinstance(v, str):
                print(k + '=' + v)
    elif cmd in ('set', 'add_list'):
        key, value = key.split('=', 1)
        if cmd == 'set':
            db[key] = value
        else:
            db.setdefault(key, []).append(value)
    elif cmd == 'delete':
        if key not in db:
            return 1
        db = {k: v for k, v in db.items() if k != key and not k.startswith(key + '.')}
    elif cmd == 'export':
        print(json.dumps({k: v for k, v in db.items() if k.startswith(key + '.')}))
    elif cmd == 'import':
        content = sys.stdin.read()
        db = {k: v for k, v in db.items() if not k.startswith(key + '.')}
        if content.lstrip().startswith('{'):
            db.update(json.loads(content))
        else:
            section = None
            for line in content.splitlines():
                parts = shlex.split(line)
                if not parts:
                    continue
                if parts[0] == 'config':
                    section = key + '.' + parts[2]
                    db[section] = parts[1]
                elif parts[0] == 'option':
                    db[section + '.' + parts[1]] = parts[2]
    elif cmd != 'commit':
        raise ValueError(args)
    path.write_text(json.dumps(db))
    return 0


class DnsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db_path = self.root / 'uci.json'
        self.initial = {
            'dhcp.@dnsmasq[0]': 'dnsmasq',
            'dhcp.@dnsmasq[0].server': ['8.8.8.8#53', '/campus/10.0.0.1'],
            'dhcp.@dnsmasq[0].serversfile': '/etc/custom-servers',
            'dhcp.other': 'dnsmasq',
            'dhcp.other.noresolv': '0',
            'dhcp.lan': 'dhcp',
            'https-dns-proxy.config': 'main',
            'https-dns-proxy.config.force_dns': '1',
            'https-dns-proxy.old': 'https-dns-proxy',
            'https-dns-proxy.old.resolver_url': 'https://example.org/dns-query',
        }
        self.db_path.write_text(json.dumps(self.initial))
        self.service = self.root / 'proxy'
        self.service.write_text('''#!/bin/sh
echo "$1" >> "$DNS_TEST_CALLS"
case "$1" in
enabled|status) [ "$DNS_TEST_ORIGINAL_RUNNING" = 1 ] ;;
restart) [ "$DNS_TEST_FAIL" != 1 ] ;;
*) exit 0 ;;
esac
''')
        self.service.chmod(0o755)
        self.env = dict(os.environ, DNS_TEST_DB=str(self.db_path),
                        DNS_DOH_STATE=str(self.root / 'state'),
                        DNS_DOH_INIT=str(self.service),
                        DNS_TEST_CALLS=str(self.root / 'calls'),
                        DNS_TEST_ORIGINAL_RUNNING='1', DNS_TEST_FAIL='0', DNS_TEST_LISTEN='1',
                        DNS_TEST_DNSMASQ='1', DNS_TEST_LAN_IP='192.168.1.1',
                        DNS_TEST_HTTPS='200', DNS_TEST_QUERY='1')

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, command, url='', provider='tencent', bootstrap='119.29.29.29',
                  mode='post_auth', enabled='1'):
        helper = Path(__file__).resolve().parents[1] / 'files/usr/lib/autoverify/dns.sh'
        quote = lambda p: shlex.quote(str(p).replace('\\', '/'))
        script = (f'uci() {{ {quote(sys.executable)} {quote(Path(__file__).resolve())} uci "$@"; }}\n'
                  'av_cfg() { case "$2" in\n'
                  f'doh_provider) printf "%s\\n" {shlex.quote(provider)} ;;\n'
                  f'doh_url) printf "%s\\n" {shlex.quote(url)} ;;\n'
                  f'doh_bootstrap) printf "%s\\n" {shlex.quote(bootstrap)} ;;\n'
                  f'mode) printf "%s\\n" {shlex.quote(mode)} ;;\n'
                  f'enabled) printf "%s\\n" {shlex.quote(enabled)} ;;\n'
                  'esac; }\n'
                  'av_cfg_bool() { _v=$(av_cfg "$1" "$2" "$3"); '
                  '[ "$_v" = 1 ] && echo 1 || echo 0; }\n'
                  'log() { echo "$*" >&2; }\n'
                  'curl() { printf "%s\\n" "${DNS_TEST_HTTPS:-200}"; }\n'
                  'nslookup() { [ "$DNS_TEST_QUERY" = 1 ] && '
                  'printf "Name: www.baidu.com\\nAddress 1: 1.2.3.4\\n"; }\n'
                  'netstat() {\n'
                  '[ "$DNS_TEST_DNSMASQ" = 1 ] && echo "udp 0 0 0.0.0.0:53 0.0.0.0:*";\n'
                  '[ "$DNS_TEST_LISTEN" = 1 ] && echo "udp 0 0 127.0.0.1:5053 0.0.0.0:*"; }\n'
                  'sleep() { :; }\n'
                  f'. {quote(helper)}\n{command}')
        shell = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else '/bin/sh'
        return subprocess.run([shell, '-c', script], env=self.env, capture_output=True,
                              text=True, encoding='utf-8')

    def db(self):
        return json.loads(self.db_path.read_text())

    def run_apply(self, enabled='1', redirect=None, mode='always'):
        db = self.db()
        db['autoverify.dns.enabled'] = enabled
        db.pop('autoverify.dns.redirect', None)
        if redirect is not None:
            db['autoverify.dns.redirect'] = redirect
        self.db_path.write_text(json.dumps(db))
        self.env['DNS_TEST_MODE'] = mode
        source = (Path(__file__).resolve().parents[1] / 'files/usr/sbin/autoverify-apply').read_text(encoding='utf-8')
        function = source.split('apply_dns() {', 1)[1].split('# --------------------------------------------------------------- DHCP', 1)[0]
        return self.run_shell('''
av_cfg() { case "$2" in
mode) printf '%s\\n' "$DNS_TEST_MODE" ;;
doh_provider) printf '%s\\n' tencent ;;
esac; }
av_cfg_bool() { uci -q get "autoverify.$1.$2" || printf '%s\\n' "$3"; }
lan_ip() { [ -n "$DNS_TEST_LAN_IP" ] && echo "$DNS_TEST_LAN_IP"; }
DNS_SEC_UDP=dns_converge_udp
DNS_SEC_TCP=dns_converge_tcp
apply_dns() {''' + function + '\napply_dns')

    def assert_no_redirect(self):
        self.assertFalse(any(k.startswith('firewall.dns_converge_') for k in self.db()))

    def test_default_doh_without_redirect_removes_old_rules(self):
        db = self.db()
        for proto in ('udp', 'tcp'):
            db['firewall.dns_converge_' + proto] = 'redirect'
            db['firewall.dns_converge_' + proto + '.src_dport'] = '53'
        db['firewall.unrelated'] = 'rule'
        self.db_path.write_text(json.dumps(db))
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_redirect()
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assertEqual(self.db()['firewall.unrelated'], 'rule')

    def test_redirect_mode_switch_and_disable_restore(self):
        result = self.run_apply(redirect='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        for proto in ('udp', 'tcp'):
            prefix = 'firewall.dns_converge_' + proto
            for option, expected in (('src', 'lan'), ('proto', proto), ('src_dport', '53'),
                                     ('dest_ip', '192.168.1.1'), ('dest_port', '53'), ('target', 'DNAT')):
                self.assertEqual(self.db()[prefix + '.' + option], expected)
        result = self.run_apply(redirect='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_redirect()
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assertEqual(self.run_apply(enabled='0', redirect='1').returncode, 0)
        self.assert_no_redirect()
        restored = {k: v for k, v in self.db().items() if not k.startswith('autoverify.')}
        self.assertEqual(restored, self.initial)

    def test_redirect_removed_even_if_proxy_fails(self):
        self.assertEqual(self.run_apply(redirect='1').returncode, 0)
        self.env['DNS_TEST_FAIL'] = '1'
        self.assertNotEqual(self.run_apply(redirect='0').returncode, 0)
        self.assert_no_redirect()

    def test_missing_dnsmasq_removes_old_redirect(self):
        self.assertEqual(self.run_apply(redirect='1').returncode, 0)
        self.env['DNS_TEST_DNSMASQ'] = '0'
        self.assertNotEqual(self.run_apply(redirect='1').returncode, 0)
        self.assert_no_redirect()

    def test_doh_without_static_lan_address(self):
        self.env['DNS_TEST_LAN_IP'] = ''
        result = self.run_apply(redirect='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assert_no_redirect()
        self.assertNotEqual(self.run_apply(redirect='1').returncode, 0)
        self.assert_no_redirect()
        self.assertEqual(self.run_apply(enabled='0').returncode, 0)

    def test_apply_repeat_restore(self):
        for _ in range(2):
            result = self.run_shell('dns_doh_apply')
            self.assertEqual(result.returncode, 0, result.stderr)
            db = self.db()
            for section in ('dhcp.@dnsmasq[0]', 'dhcp.other'):
                self.assertEqual(db[section + '.server'], ['127.0.0.1#5053'])
                self.assertEqual(db[section + '.noresolv'], '1')
                self.assertNotIn(section + '.serversfile', db)
            self.assertEqual(db['https-dns-proxy.config.dnsmasq_config_update'], '-')
            self.assertEqual(db['https-dns-proxy.config.force_dns'], '0')
            self.assertEqual(db['https-dns-proxy.autoverify.resolver_url'], 'https://doh.pub/dns-query')
            self.assertEqual(db['https-dns-proxy.autoverify.bootstrap_dns'],
                             '119.29.29.29,182.254.116.116')
        result = self.run_shell('dns_doh_restore; dns_doh_restore')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db(), self.initial)

    def test_disabled_original_stays_disabled(self):
        self.env['DNS_TEST_ORIGINAL_RUNNING'] = '0'
        result = self.run_shell('dns_doh_apply && dns_doh_restore')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(calls[-1], 'disable')
        self.assertNotIn('start', calls)

    def test_failure_never_falls_back(self):
        self.env['DNS_TEST_FAIL'] = '1'
        self.assertNotEqual(self.run_shell('dns_doh_apply').returncode, 0)
        self.assertEqual(self.db()['dhcp.@dnsmasq[0].server'], ['127.0.0.1#5053'])
        self.assertEqual(self.run_shell('dns_doh_restore').returncode, 0)
        self.assertEqual(self.db(), self.initial)

    def test_reject_invalid_custom_url(self):
        for url in ('http://resolver.example/dns-query', 'https://user:pass@resolver.example/dns-query',
                    'https://999.1.1.1/dns-query', "https://resolver.example/dns-query'", '',
                    'https://resolver.example:70000/dns-query'):
            self.assertNotEqual(self.run_shell('dns_doh_apply', url, 'custom').returncode, 0, url)
            self.assertEqual(self.db(), self.initial)

    def test_presets_and_custom_switching(self):
        for provider, url, bootstrap, expected in (
            ('aliyun', 'ignored', 'ignored', 'https://dns.alidns.com/dns-query'),
            ('custom', 'https://resolver.example:8443/dns-query?key=abc', '9.9.9.9,149.112.112.112',
             'https://resolver.example:8443/dns-query?key=abc'),
            ('tencent', '', '', 'https://doh.pub/dns-query'),
        ):
            result = self.run_shell('dns_doh_apply', url, provider, bootstrap)
            self.assertEqual(result.returncode, 0, result.stderr)
            db = self.db()
            self.assertEqual(db['https-dns-proxy.autoverify.resolver_url'], expected)
            expected_bootstrap = {'aliyun': '223.5.5.5,223.6.6.6',
                                  'tencent': '119.29.29.29,182.254.116.116'}.get(provider, bootstrap)
            self.assertEqual(db['https-dns-proxy.autoverify.bootstrap_dns'], expected_bootstrap)
            self.assertEqual(db['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assertEqual(self.run_shell('dns_doh_restore').returncode, 0)
        self.assertEqual(self.db(), self.initial)

    def test_invalid_provider_and_bootstrap(self):
        self.assertNotEqual(self.run_shell('dns_doh_apply', provider='unknown').returncode, 0)
        for bootstrap in ('', '999.1.1.1', '1.1.1.1,', 'dns.example', '1.1.1.1 8.8.8.8'):
            self.assertNotEqual(self.run_shell('dns_doh_apply', 'https://resolver.example/dns-query',
                                             'custom', bootstrap).returncode, 0)
            self.assertEqual(self.db(), self.initial)

    def test_no_listener_never_falls_back(self):
        self.env['DNS_TEST_LISTEN'] = '0'
        self.assertNotEqual(self.run_shell('dns_doh_apply').returncode, 0)
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])

    def test_missing_dependency_changes_nothing(self):
        self.env['DNS_DOH_INIT'] = str(self.root / 'missing')
        self.assertNotEqual(self.run_shell('dns_doh_apply').returncode, 0)
        self.assertEqual(self.db(), self.initial)

    def test_post_auth_switches_after_auth_and_restores_before_auth(self):
        # 认证前: 明文上游。认证成功后切 DoH；再次认证前恢复。
        self.assertEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assertTrue((self.root / 'state/proxy.uci').exists())
        # 幂等: 已接管时不再重复 apply / restart。
        self.assertEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.assertEqual(self.run_shell('dns_doh_before_auth').returncode, 0)
        self.assertEqual(self.db(), self.initial)
        self.assertFalse((self.root / 'state/proxy.uci').exists())

    def test_post_auth_skips_when_https_blocked(self):
        self.env['DNS_TEST_HTTPS'] = '000'
        self.assertNotEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.assertEqual(self.db(), self.initial)
        self.assertFalse((self.root / 'state/proxy.uci').exists())

    def test_post_auth_rolls_back_when_dns_query_fails(self):
        self.env['DNS_TEST_QUERY'] = '0'
        self.assertNotEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.assertEqual(self.db(), self.initial)
        self.assertFalse((self.root / 'state/proxy.uci').exists())
        self.assertTrue((self.root / 'state/fail').exists())
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertIn('stop', calls)

    def test_post_auth_cooldown_skips_retry(self):
        self.env['DNS_TEST_QUERY'] = '0'
        self.assertNotEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.env['DNS_TEST_QUERY'] = '1'
        self.env['DNS_TEST_HTTPS'] = '200'
        # 失败标记在冷却期内，即使条件恢复也不再重启 dnsmasq。
        self.assertNotEqual(self.run_shell('dns_doh_after_auth').returncode, 0)
        self.assertEqual(self.db(), self.initial)

    def test_always_mode_never_defers(self):
        self.assertEqual(self.run_shell('dns_doh_after_auth', mode='always').returncode, 0)
        self.assertFalse((self.root / 'state/proxy.uci').exists())
        self.assertEqual(self.db(), self.initial)

    def test_restore_recovers_without_proxy_backup(self):
        self.assertEqual(self.run_shell('dns_doh_apply').returncode, 0)
        # proxy.uci 丢失（手工清理/升级残留）时, 仍要把 dnsmasq 从 5053 拉回来。
        (self.root / 'state/proxy.uci').unlink()
        self.assertEqual(self.run_shell('dns_doh_restore').returncode, 0)
        db = self.db()
        for key, value in self.initial.items():
            if key.startswith('dhcp.'):
                self.assertEqual(db.get(key), value, key)
        for key in ('dhcp.@dnsmasq[0].noresolv', 'dhcp.other.av_doh_saved'):
            self.assertNotIn(key, db)
        self.assertFalse((self.root / 'state/proxy.uci').exists())

    def test_post_auth_apply_keeps_plain_dns(self):
        # 先按 always 接管, 再切到 post_auth 应用配置: 必须恢复明文上游。
        self.assertEqual(self.run_apply(mode='always').returncode, 0)
        self.assertEqual(self.db()['dhcp.other.server'], ['127.0.0.1#5053'])
        self.assertEqual(self.run_apply(mode='post_auth').returncode, 0)
        restored = {k: v for k, v in self.db().items() if not k.startswith('autoverify.')}
        self.assertEqual(restored, self.initial)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'uci':
        sys.exit(mock_uci(sys.argv[2:]))
    unittest.main()
