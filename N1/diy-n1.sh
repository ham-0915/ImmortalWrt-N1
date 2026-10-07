#!/bin/bash
# diy-n1.sh — Phicomm N1 DIY 脚本
# 用法: diy-n1.sh [24.10|25.12]（不传则自动检测）
set -euo pipefail

# ── 版本检测 ─────────────────────────────────────────────────
VERSION="${1:-}"
[ -z "$VERSION" ] && { grep -q 'openwrt-25.12' feeds.conf.default 2>/dev/null && VERSION="25.12" || VERSION="24.10"; }
log() { echo ">>> [$VERSION] $*"; }

# ============================================================
# 基础设置（IP / 主机名）
# ============================================================
log "设置默认 IP 与主机名"
sed -i 's/192.168.1.1/192.168.123.2/g' package/base-files/files/bin/config_generate
sed -i 's/ImmortalWrt/OpenWrt/g' package/base-files/files/bin/config_generate

# ============================================================
# Golang + lang rust
# ============================================================
log "替换 Golang → 27.x"
rm -rf feeds/packages/lang/golang
git clone --depth=1 -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang

log "修复 lang-rust 出现404的问题"
rm -rf feeds/packages/lang/rust
git clone https://github.com/sbwml/packages_lang_rust feeds/packages/lang/rust

# ============================================================
# 清理 feeds 冲突包
# ============================================================
log "清理冲突包"
PASSWALL_PKGS=(chinadns-ng dns2socks geoview hysteria ipt2socks microsocks naiveproxy \
  shadow-tls shadowsocks-libev shadowsocks-rust shadowsocksr-libev simple-obfs sing-box \
  tcping trojan-plus tuic-client v2ray-geodata v2ray-plugin xray-core xray-plugin)
for pkg in "${PASSWALL_PKGS[@]}"; do rm -rf "feeds/packages/net/$pkg"; done
rm -rf feeds/luci/applications/luci-app-{lucky,mosdns,nikki,openclash,openlist,openlist2,passwall,passwall2} \
  feeds/packages/net/{mosdns,openlist}

# 如果 25.12 或 24.10 去除 dockerman  （代码示例）
[ "$VERSION" = "25.12" ] && sed -i '/CONFIG_PACKAGE_luci-app-dockerman/d' .config
[ "$VERSION" = "24.10" ] && sed -i '/CONFIG_PACKAGE_luci-app-dockerman/d' .config

#  ============================================================
# 克隆 Passwall 2
# ============================================================
log "克隆 Passwall 2"
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git package/passwall2

# ============================================================
# 克隆第三方插件
# ============================================================
log "克隆第三方插件"
git clone --depth=1 https://github.com/ophub/luci-app-amlogic package/amlogic
git clone --depth=1 -b v5 https://github.com/sbwml/luci-app-mosdns package/mosdns
git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 package/openlist2
git clone --depth=1 https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone --depth=1 https://github.com/timsaya/openwrt-bandix package/openwrt-bandix
git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/lucky
git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki package/nikki
git clone --depth=1 https://github.com/sbwml/luci-app-quickfile package/luci-app-quickfile
log "注入 Nginx Quickfile 修复"
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-fix-nginx-quickfile << 'EOF'
#!/bin/sh
uci set nginx.global.uci_enable='true'
uci del nginx._lan; uci del nginx._redirect2ssl
uci add nginx server; uci rename nginx.@server[0]='_lan'
uci set nginx._lan.server_name='_lan'
uci add_list nginx._lan.listen='80 default_server'
uci add_list nginx._lan.listen='[::]:80 default_server'
uci add_list nginx._lan.include='conf.d/*.locations'
uci set nginx._lan.access_log='off'
uci commit nginx
/etc/init.d/nginx restart
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-fix-nginx-quickfile

# git clone --depth=1 https://github.com/vernesong/OpenClash package/openclash
# git clone --depth=1 https://github.com/kenzok8/openwrt-clashoo.git package/openwrt-clashoo

# ============================================================
# 注入软件源配置文件
# ============================================================

# ── opkg 配置（仅 24.10）─────────
[ "$VERSION" = "24.10" ] && {
  log "24.10 软件源配置"
  mkdir -p package/base-files/files/etc/opkg
  
  cat > package/base-files/files/etc/opkg.conf << 'EOF'
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
# option check_signature
arch all 100
arch aarch64_generic 200
arch aarch64_cortex-a53 300
EOF

  cat > package/base-files/files/etc/opkg/customfeeds.conf << 'EOF'
# add your custom package feeds here
#
# src/gz example_feed_name http://www.example.com/path/to/files
# src/gz openwrt_kiddin9 https://dl.openwrt.ai/latest/packages/aarch64_cortex-a53/kiddin9
src/gz dllkids https://down.dllkids.xyz/openwrt-feed/24.10/aarch64_cortex-a53
EOF
}

# ============================================================
log "完成 ✓"
