#!/usr/bin/env python3
"""本地 mock 门户, 用于在不接触真实校园网的前提下验证 autoverify。

模拟 zportal 行为:
  GET  /probe                     未认证 -> 302 到登录页; 已授权 -> 204
  GET  /zportal/loginForWeb?...   返回带隐藏加密字段的登录页
  POST /zportal/login/do          返回 MOCK_RESP 指定的 JSON
  GET  /zportal/goToAuthResult    真正“授权”并置为在线 (模拟真实门户需要跟跳转)

注意: 置为在线发生在 goToAuthResult 被请求时, 而不是 POST 时。
真实门户就是这个行为 —— 只发 POST 会拿到 result=success 但会话并不通,
正是这个测试要卡住的回归点。

用法:
  python3 mock_portal.py [端口]        # 默认 18099
  MOCK_RESP='{"result":"fail","message":"密码错误"}' python3 mock_portal.py
  MOCK_PROBE_MODE=meta python3 mock_portal.py   # 未认证时回 200 + 页面内跳转
"""

import http.server
import os
import re
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18099
DEFAULT_RESP = '{"message":"","nextPage":"goToAuthResult","result":"success"}'
PID_FILE = os.environ.get("MOCK_PID_FILE", "")

if PID_FILE:
    with open(PID_FILE, "w", encoding="ascii") as pid_out:
        pid_out.write(str(os.getpid()))

STATE = {"online": False, "gets": [], "posts": 0}
SERVER = None

# 字段名与真实门户一致; 值仅用于校验脚本是否正确回填, 无实际含义。
# HYGXY / hyit.edu.cn 是抓包时的原始值(淮安大学 2026-02 改名前的旧缩写), 原样保留 ——
# 脚本本来就该把 NAS 给的值原样回填, 不猜不改。
LOGIN_PAGE = """<html><head><title>校园网认证</title></head><body>
<form id="login_form" action="login/do" method="post">
<input name="qrCodeId" id="qrCodeId" type="text" class="qrcode_login" value="请输入编号"/>
<input id="user_name" name="username" type="text" class="login_wbk_a" value="用户名"/>
<input id="tx" type="text" value="密码"/>
<input id="password" name="pwd" style="display:none;" type="password" value="密码" value=""/>
<input id="valid_code" name="validCode" type="text" class="login_wbk_c" value="验证码" onfocus="if (value =='验证码'){value =''}" onblur="if (value ==''){value='验证码'}" value=""/>
<input id="signin_validcode_flag" type="hidden" name="validCodeFlag">
<input id="ssid" name="ssid" type="hidden" value="d1010666092778db26b680f53a9018ca0b66008ed66337b5"/>
<input id="mac" name="mac" type="hidden" value="7e1883890d46a0282d9ac0995895d75c"/>
<input id="t" name="t" type="hidden" value="wireless-v2-plain"/>
<input id="wlanacname" name="wlanacname" type="hidden" value="13e2c992e520119c9124840643b7e37113dadb442e484c07"/>
<input id="url" name="url" type="hidden" value="82059655b3223e295cb9372bce37f5e884a55b4b74395ac1"/>
<input id="nasip" name="nasip" type="hidden" value="b901863f33db032eeb7b4095957c2a28"/>
<input id="wlanuserip" name="wlanuserip" type="hidden" value="87485323fa6a95e3b4c9e79ca0ad943e"/>
</form></body></html>"""

LOGIN_URL = (
    "http://127.0.0.1:{port}/zportal/loginForWeb"
    "?wlanuserip=10.80.3.64&wlanacname=HYGXY-CR16K-MC-1F&mac=AABB-CCDD-EEFF"
    "&nasip=10.82.66.9&ssid=iHuaiGong-Student&url=http%3A%2F%2Fwww.hyit.edu.cn"
).format(port=PORT)

# 实测这台 NAS 给的是 /zportal/login?... 而不是 loginForWeb, 且参数是完全百分号编码的
# (连 - 和 . 都被编码成 %2d / %2e)。该地址本身还会再 302 一次。
LOGIN_URL2 = (
    "http://127.0.0.1:{port}/zportal/login"
    "?wlanuserip=10.80.3.64&wlanacname=HYGXY%2dCR16K%2dMC%2d1F&mac=AABB-CCDD-EEFF"
    "&nasip=10%2e82%2e66%2e9&ssid=iHuaiGong%2dStudent&url=http%3a%2f%2fwww%2ehyit%2eedu%2ecn"
).format(port=PORT)

RELATIVE_LOGIN_URL = (
    "/zportal/loginForWeb"
    "?wlanuserip=10.80.3.64&wlanacname=HYGXY%2dCR16K%2dMC-1F&mac=AABB-CCDD-EEFF"
    "&nasip=10%2e82%2e66%2e9&ssid=iHuaiGong%2dStudent&url=http%3a%2f%2fwww%2ehyit%2eedu%2ecn"
)


def login_page():
    page = LOGIN_PAGE
    if os.environ.get("MOCK_PAGE_MODE") == "single-crossline":
        # 模拟部分 NAS 的格式差异：属性使用单引号，并跨行排列。
        page = re.sub(r'([A-Za-z][A-Za-z0-9_-]*)="([^"]*)"', r"\1='\2'", page)
        page = page.replace(" ", "\n ")
    return page


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"", extra=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html;charset=UTF-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        STATE["gets"].append(self.path)
        print("GET %s" % self.path, flush=True)
        print("HDR GET %s AL=%r SF=%r" % (self.path.split("?")[0],
                                          self.headers.get("Accept-Language"),
                                          self.headers.get("Sec-Fetch-Site")), flush=True)
        if self.path.startswith("/__shutdown"):
            self._send(200, "shutting down")
            threading.Thread(target=SERVER.shutdown, daemon=True).start()
        elif self.path.startswith("/probe"):
            if STATE["online"]:
                self._send(204)
                return
            # 未认证时 NAS 怎么把客户端引到门户:
            #   302        = 标准重定向 (假定的)
            #   meta       = 200 + 页面内 JS 跳转 (实测这台 NAS 的实际形态)
            #   location200= 200 但带 Location 头
            #   login302   = 200 + JS 跳到 /zportal/login?..., 该地址再 302 到 loginForWeb
            #                (完整复现真实 NAS 的两跳行为)
            #   other302   = 302 到一个跟门户无关的地址 (例如运营商公告页)。
            #                用来卡住 "portal.host 为空时把任意地址都判成门户" 的回归。
            mode = os.environ.get("MOCK_PROBE_MODE", "302")
            if mode == "meta":
                self._send(200, "<html><head><script>window.location.href='%s';</script>"
                                "</head></html>" % LOGIN_URL)
            elif mode == "login302":
                self._send(200, "<html><head><script>window.location.href='%s';</script>"
                                "</head></html>" % LOGIN_URL2)
            elif mode == "location200":
                self._send(200, "", extra=[("Location", LOGIN_URL)])
            elif mode == "relative":
                self._send(302, extra=[("Location", RELATIVE_LOGIN_URL)])
            elif mode == "other302":
                self._send(302, extra=[("Location", "http://portal.example.com/notice")])
            else:
                self._send(302, extra=[("Location", LOGIN_URL)])
        elif self.path.startswith("/zportal/login?"):
            # NAS 给的地址本身还会再跳一次; 不跟随跳转就只能拿到空 body
            self._send(302, extra=[("Location", LOGIN_URL)])
        elif self.path.startswith("/zportal/loginForWeb"):
            self._send(200, login_page(), extra=[("Set-Cookie", "JSESSIONID=MOCK; Path=/zportal/")])
        elif self.path.startswith("/zportal/goToAuthResult"):
            if os.environ.get("MOCK_NEXT_MODE", "") == "fail":
                self._send(503, "认证结果页暂不可用")
                return
            STATE["online"] = True
            self._send(200, "<html>认证结果页</html>")
        else:
            self._send(404, "not found")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        STATE["posts"] += 1
        print("POST %s" % self.path, flush=True)
        print("HDR POST %s AL=%r SF=%r" % (self.path,
                                           self.headers.get("Accept-Language"),
                                           self.headers.get("Sec-Fetch-Site")), flush=True)
        print("  Origin: %s" % self.headers.get("Origin"), flush=True)
        print("  Content-Type: %s" % self.headers.get("Content-Type"), flush=True)
        for pair in body.split("&"):
            print("  %s" % pair, flush=True)
        delay = os.environ.get("MOCK_POST_DELAY", "")
        if delay:
            time.sleep(float(delay))
        response = os.environ.get("MOCK_RESP", DEFAULT_RESP)
        if '"result":"online"' in response:
            # 已在线的门户响应本身表示 NAS 已有有效会话，不依赖 nextPage。
            STATE["online"] = True
        self._send(200, response)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer.allow_reuse_address = True
    print("mock portal listening on 127.0.0.1:%d" % PORT, flush=True)
    SERVER = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    SERVER.serve_forever()
