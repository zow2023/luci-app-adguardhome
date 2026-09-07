# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-adguardhome
LUCI_MAINTAINER:=Jackie264 <OneNAS-space>
PKG_LICENSE:=GPL-2.0-only
PKG_CPE_ID:=cpe:/a:Jackie264:luci-app-adguardhome

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_UNPACK:=$(CURDIR)/.prepare.sh $(PKG_NAME) $(CURDIR) $(PKG_BUILD_DIR)

define Package/luci-app-adguardhome/conffiles
/etc/adguardhome/adguardhome.yaml
/etc/config/adguardhome
endef

define Package/luci-app-adguardhome/postinst
#!/bin/sh
# 核心适配：ROOT 变量兼容 IPK(IPKG_INSTROOT) 与 APK(APK_ROOT)
# 固件编译期 ROOT 指向 target-rootfs 路径；设备运行期 ROOT 自动为空(即指向根目录 /)
ROOT="$${IPKG_INSTROOT:-$${APK_ROOT}}"

grep -q "^adguardhome:" "$${ROOT}/etc/group" 2>/dev/null || echo "adguardhome:x:853:" >> "$${ROOT}/etc/group"
grep -q "^adguardhome:" "$${ROOT}/etc/passwd" 2>/dev/null || echo "adguardhome:x:853:853:adguardhome:/var/run/adguardhome:/bin/false" >> "$${ROOT}/etc/passwd"
exit 0
endef

define Package/luci-app-adguardhome/prerm
#!/bin/sh
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
