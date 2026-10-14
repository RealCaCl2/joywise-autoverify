"""Offline SDK download tests using real SHA256, zstd and tar validation."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


@unittest.skipUnless(all(shutil.which(tool) for tool in ('bash', 'zstd', 'tar', 'sha256sum')),
                     'requires Linux SDK download tools')
class SdkDownloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / 'build'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        archive = self.root / 'sdk.tar'
        with tarfile.open(archive, 'w') as tar:
            info = tarfile.TarInfo('openwrt-sdk/Makefile')
            content = b'# offline fixture\n'
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
        self.compressed = self.root / 'fixture.zst'
        subprocess.run(['zstd', '-q', '-o', str(self.compressed), str(archive)], check=True)
        mock = self.bin / 'curl'
        mock.write_text('''#!/usr/bin/env python3
import hashlib, os, pathlib, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
path = pathlib.Path(args[args.index('-o') + 1])
with open(os.environ['SDK_TEST_CALLS'], 'a') as log:
    log.write(url + '\\n')
mode = os.environ['SDK_TEST_MODE']
mirror = 'mirror.example' in url
name = 'openwrt-sdk-test.tar.zst'
valid = pathlib.Path(os.environ['SDK_TEST_ARCHIVE']).read_bytes()
html = b'<html>HTTP 200 verification page</html>'
if mirror and mode == 'index_failure' and url.endswith('/'):
    sys.exit(22)
if url.endswith('/'):
    data = ('<a href="' + name + '">' + name + '</a>').encode()
elif url.endswith('sha256sums'):
    payload = html if mode == 'invalid_zstd' and mirror else valid
    data = (hashlib.sha256(payload).hexdigest() + '  ' + name + '\\n').encode()
else:
    data = html if mode == 'all_failure' or (mirror and mode in ('html', 'invalid_zstd')) else valid
path.write_bytes(data)
''', encoding='utf-8')
        mock.chmod(0o755)
        script = Path(__file__).resolve().parents[1] / 'tools/build-apk.sh'
        self.bootstrap = script.read_text(encoding='utf-8').split('# --- 2.', 1)[0]

    def run_download(self, mode, mirror='https://mirror.example'):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   WORK=str(self.work), MIRROR=mirror, SDK_TEST_MODE=mode,
                   SDK_TEST_ARCHIVE=str(self.compressed), SDK_TEST_CALLS=str(self.root / 'calls'))
        return subprocess.run(['bash', '-c', self.bootstrap], cwd=self.root, env=env,
                              capture_output=True, text=True)

    def assert_fallback_succeeds(self, mode):
        result = self.run_download(mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / 'sdk/Makefile').is_file())
        self.assertEqual((self.work / 'sdk.tar.zst').read_bytes(), self.compressed.read_bytes())
        self.assertIn('https://downloads.openwrt.org/', (self.root / 'calls').read_text())

    def test_http_200_html_falls_back(self):
        self.assert_fallback_succeeds('html')

    def test_index_failure_falls_back(self):
        self.assert_fallback_succeeds('index_failure')

    def test_matching_checksum_but_invalid_zstd_falls_back(self):
        self.assert_fallback_succeeds('invalid_zstd')

    def test_both_sources_fail_without_sdk_cache(self):
        result = self.run_download('all_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'sdk').exists())

    def test_official_source_success(self):
        result = self.run_download('valid', 'https://downloads.openwrt.org')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / 'sdk/Makefile').is_file())
        self.assertNotIn('mirror.example', (self.root / 'calls').read_text())


if __name__ == '__main__':
    unittest.main()
