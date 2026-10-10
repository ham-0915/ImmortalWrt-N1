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
# 克隆 所需要的插件
# ============================================================
log "克隆官方源码"
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git package/passwall2
git clone --depth=1 https://github.com/ophub/luci-app-amlogic package/amlogic
git clone --depth=1 -b v5 https://github.com/sbwml/luci-app-mosdns package/mosdns
git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 package/openlist2
git clone --depth=1 https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone --depth=1 https://github.com/timsaya/openwrt-bandix package/openwrt-bandix
git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/lucky
# ----------------------------------------------------------------------------------
git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki package/nikki
# 设置为：启用 FullCone NAT 不打勾（首次开机时写入，覆盖其它来源的默认值）
log "设置默认关闭 FullCone NAT"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/zzzz-fullcone-off <<'EOF'
#!/bin/sh
# 旁路由不需要 FullCone；它会让 nikki 的 UDP 53 DNS 劫持失效
uci -q set firewall.@defaults[0].fullcone='0'
uci -q set firewall.@defaults[0].fullcone6='0'
uci -q commit firewall
# 如果装了 TurboACC，它会在启动时重新写入 FullCone，一并关掉
uci -q get turboacc.config.fullcone_nat >/dev/null 2>&1 && {
  uci -q set turboacc.config.fullcone_nat='0'
  uci -q commit turboacc
}
exit 0
EOF
chmod +x files/etc/uci-defaults/zzzz-fullcone-off
[ -x files/etc/uci-defaults/zzzz-fullcone-off ] && log "设置成功 ✓" || { log "失败"; exit 1; }
# ----------------------------------------------------------------------------------------
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
# ----------------------------------------------------------------------------------------
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

# ── apk 配置（仅 25.12）─────────
# customfeeds.list 是 apk 包自带的文件，不能在 base-files 里再放一个同名文件
# （会在 package/install 阶段报 "trying to overwrite ... owned by apk-openssl" 导致编译失败）。
# 所以直接在 apk 包的源文件末尾追加，保留原有注释头；路径变了则退回到首次开机追加。
[ "$VERSION" = "25.12" ] && {
  log "25.12 软件源配置"
  APK_LIST=package/system/apk/files/customfeeds.list
  APK_FEED_URL="https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_cortex-a53/packages.adb"

  if [ -f "$APK_LIST" ]; then
    if ! grep -qxF "$APK_FEED_URL" "$APK_LIST"; then
      [ -z "$(tail -c1 "$APK_LIST")" ] || echo >> "$APK_LIST"    # 末尾无换行则补一个
      echo "$APK_FEED_URL" >> "$APK_LIST"
    fi
  else
    log "未找到 $APK_LIST，改用 uci-defaults 在首次开机时追加"
    mkdir -p package/base-files/files/etc/uci-defaults
    cat > package/base-files/files/etc/uci-defaults/98-apk-customfeeds << EOF
#!/bin/sh
f=/etc/apk/repositories.d/customfeeds.list
grep -qxF '${APK_FEED_URL}' "\$f" 2>/dev/null || echo '${APK_FEED_URL}' >> "\$f"
exit 0
EOF
    chmod +x package/base-files/files/etc/uci-defaults/98-apk-customfeeds
  fi
}

# ============================================================
log "完成 ✓"
