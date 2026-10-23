#
# OpenWrt 包定义: autoverify
#
# 纯数据包 (PKGARCH:=all) —— 内容全是 shell 脚本 / JSON / JS, 没有任何编译产物,
# 所以不需要架构相关的 toolchain, 用任何 SDK 都能构建出通用的 .apk。
#
# 构建方式见 tools/build-apk.sh。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=autoverify
PKG_VERSION:=1.0.0
PKG_RELEASE:=19

PKG_LICENSE:=MIT
PKG_MAINTAINER:=CaCl2 <RealCaCl2@users.noreply.github.com>
PKG_URL:=https://github.com/RealCaCl2/joywise-autoverify

include $(INCLUDE_DIR)/package.mk

define Package/autoverify
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Joywise campus portal (zportal) auto authentication + anti-detection hardening
  DEPENDS:=+curl +luci-base +https-dns-proxy +ca-bundle
  PKGARCH:=all
endef

define Package/autoverify/description
  校园网门户 (zportal) 自动认证, 纯 POSIX sh 实现, 认证核心使用 curl。
  DNS DoH 上游需要 https-dns-proxy 与 ca-bundle, 由本包依赖自动安装。
  断线自动重认证, 出口接口 up 时立即认证, 失败按指数退避避免触发门户验证码。

  附带针对校园网多设备检测的反制措施(均可单独开关):
    - TTL 归一化
    - NTP 收敛
    - DNS 收敛
    - DHCP 伪装(主机名 / client-id / 厂商号 / DHCPv6 FQDN)
    - IPv6 防护(关掉 LAN 的 RA 与 DHCPv6, 防绕过 NAT)

  提供 LuCI 设置页面 (服务 -> 校园网自动认证)。
endef

define Build/Compile
endef

define Package/autoverify/conffiles
/etc/config/autoverify
endef

define Package/autoverify/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/usr/lib/autoverify
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view

	$(INSTALL_BIN)  ./files/usr/sbin/autoverify           $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/usr/sbin/autoverify-apply     $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/usr/sbin/autoverify-hardening $(1)/usr/sbin/
	$(INSTALL_DATA) ./files/usr/lib/autoverify/cfg.sh     $(1)/usr/lib/autoverify/
	$(INSTALL_DATA) ./files/usr/lib/autoverify/dns.sh     $(1)/usr/lib/autoverify/
	$(INSTALL_DATA) ./files/usr/lib/autoverify/lock.sh   $(1)/usr/lib/autoverify/
	$(INSTALL_DATA) ./files/usr/lib/autoverify/state.sh  $(1)/usr/lib/autoverify/
	$(INSTALL_BIN)  ./files/usr/lib/autoverify/refresh-luci-cache.sh $(1)/usr/lib/autoverify/

	$(INSTALL_BIN)  ./files/etc/init.d/autoverify                     $(1)/etc/init.d/
	$(INSTALL_BIN)  ./files/etc/hotplug.d/iface/99-autoverify         $(1)/etc/hotplug.d/iface/
	$(INSTALL_BIN)  ./files/etc/uci-defaults/90-autoverify-migrate    $(1)/etc/uci-defaults/
	$(INSTALL_CONF) ./files/etc/config/autoverify                     $(1)/etc/config/

	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-autoverify.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-autoverify.json  $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/autoverify.js   $(1)/www/luci-static/resources/view/

	# 配置里有账号密码, 收紧权限
	chmod 600 $(1)/etc/config/autoverify
endef

# 刷新 LuCI 视图的 mtime，否则升级后浏览器会继续用缓存的旧 JS。
#
# 具体逻辑和原因放在 files/usr/lib/autoverify/refresh-luci-cache.sh 里，
# 这里只负责调用它 —— 避免在 Makefile 里嵌 shell 变量，那样 $ 的转义层数
# 很容易写错，而且写错了很难看出来（生成的 scriptlet 在编译后被清掉了）。
define Package/autoverify/postinst
#!/bin/sh
/usr/lib/autoverify/refresh-luci-cache.sh
exit 0
endef

$(eval $(call BuildPackage,autoverify))
