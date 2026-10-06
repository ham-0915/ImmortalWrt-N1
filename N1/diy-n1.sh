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
git clone --depth=1 https://github.com/sbwml/luci-app-quickfile package/luci-app-quickfile
git clone --depth=1 https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone --depth=1 https://github.com/timsaya/openwrt-bandix package/openwrt-bandix
# git clone --depth=1 https://github.com/vernesong/OpenClash package/openclash
# git clone --depth=1 https://github.com/kenzok8/openwrt-clashoo.git package/openwrt-clashoo

# --------------------------------------------------------------------------------------------------------
git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki package/nikki
# ── nikki 自定义三处设置为‘不修改’ ─────────────────────────────
log "nikki: 清除默认值 log_level/ui_url/tun_stack"
sed -i "/option 'log_level' 'warning'/d" package/nikki/nikki/files/nikki.conf
sed -i "\#option 'ui_url' 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip'#d" package/nikki/nikki/files/nikki.conf
sed -i "/option 'tun_stack' 'mixed'/d" package/nikki/nikki/files/nikki.conf

# ── mihomo-meta 自动升级到 mihomo 最新稳定版 ─────────────────────
# 规则：
#   1. 查 MetaCubeX/mihomo 的最新稳定 tag（只认 vX.Y.Z，不含 Alpha/预发布）。
#   2. 只在它【比 nikki 官方 Makefile 里的版本更新】时才升级，不会降级。
#   3. PKG_MIRROR_HASH 用 OpenWrt 自带的 scripts/dl_github_archive.py 现算（故意传错哈希，
#      从它的报错里取真实 sha256），与正式下载走同一套代码，保留完整性校验。
#   4. 任何一步失败（网络/API 限流/算不出哈希）都保留 nikki 官方版本，不会让编译中断。
# 手动指定版本：运行脚本前设置环境变量 MIHOMO_VERSION=1.19.32（会跳过“只升不降”的判断）。
MIHOMO_MK=package/nikki/mihomo-meta/Makefile
if [ -f "$MIHOMO_MK" ]; then
  MIHOMO_CUR=$(sed -n 's/^PKG_VERSION:=//p' "$MIHOMO_MK" | head -n1)
  MIHOMO_NEW="${MIHOMO_VERSION:-}"
  if [ -z "$MIHOMO_NEW" ]; then
    MIHOMO_NEW=$(git ls-remote --tags --refs https://github.com/MetaCubeX/mihomo.git 'v*' 2>/dev/null \
      | sed -n 's#.*refs/tags/v\([0-9]\+\.[0-9]\+\.[0-9]\+\)$#\1#p' | sort -V | tail -n1) || true
  fi
  MIHOMO_OK=0
  if [ -n "$MIHOMO_NEW" ] && [ -n "$MIHOMO_CUR" ] && [ "$MIHOMO_NEW" != "$MIHOMO_CUR" ]; then
    if [ -n "${MIHOMO_VERSION:-}" ] || [ "$(printf '%s\n%s\n' "$MIHOMO_CUR" "$MIHOMO_NEW" | sort -V | tail -n1)" = "$MIHOMO_NEW" ]; then
      MIHOMO_OK=1
    fi
  fi
  if [ "$MIHOMO_OK" = 1 ]; then
    log "nikki: mihomo-meta $MIHOMO_CUR → $MIHOMO_NEW，计算源码包哈希..."
    MIHOMO_TMP=$(mktemp -d)
    MIHOMO_OUT=$(python3 scripts/dl_github_archive.py \
      --dl-dir="$MIHOMO_TMP" \
      --url="https://github.com/MetaCubeX/mihomo.git" \
      --version="v$MIHOMO_NEW" \
      --subdir="mihomo-meta-$MIHOMO_NEW" \
      --source="mihomo-meta-$MIHOMO_NEW.tar.gz" \
      --hash=0000000000000000000000000000000000000000000000000000000000000000 \
      --submodules 2>&1) || true
    rm -rf "$MIHOMO_TMP"
    MIHOMO_HASH=$(printf '%s\n' "$MIHOMO_OUT" | sed -n 's/.*, got \([0-9a-f]\{64\}\).*/\1/p' | head -n1)
    if [ -n "$MIHOMO_HASH" ]; then
      sed -i \
        -e "s/^PKG_VERSION:=.*/PKG_VERSION:=$MIHOMO_NEW/" \
        -e "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=v$MIHOMO_NEW/" \
        -e "s/^PKG_BUILD_VERSION:=.*/PKG_BUILD_VERSION:=v$MIHOMO_NEW/" \
        -e "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=$MIHOMO_HASH/" \
        "$MIHOMO_MK"
      log "nikki: mihomo-meta 已升级到 v$MIHOMO_NEW (hash $MIHOMO_HASH)"
    else
      log "nikki: 无法计算 v$MIHOMO_NEW 的哈希，保留官方 $MIHOMO_CUR。原因: $(printf '%s' "$MIHOMO_OUT" | tail -n 2 | tr '\n' ' ')"
    fi
  else
    log "nikki: mihomo-meta 保持官方版本 ${MIHOMO_CUR:-未知}（最新稳定版: ${MIHOMO_NEW:-查询失败}）"
  fi
else
  log "nikki: 未找到 mihomo-meta/Makefile，跳过升级"
fi

# ── nikki 界面：TUN「栈」下拉框增加 Mips ──────────────────────────
# mihomo 从 v1.19.31 起支持 tun stack: mips，但 luci-app-nikki 的下拉框是写死的，只有 System/gVisor/Mixed。
# 后端 (mixin.uc) 直接透传 tun_stack，没有白名单，所以只需给界面加一个选项。已有则不重复添加。
NIKKI_MIXIN_JS=package/nikki/luci-app-nikki/htdocs/luci-static/resources/view/nikki/mixin.js
if [ -f "$NIKKI_MIXIN_JS" ] && ! grep -q "o.value('mips'" "$NIKKI_MIXIN_JS" \
   && grep -q "o.value('mixed', 'Mixed');" "$NIKKI_MIXIN_JS"; then
  log "nikki: TUN 栈增加 Mips 选项"
  sed -i "/o.value('mixed', 'Mixed');/a\\        o.value('mips', 'Mips');" "$NIKKI_MIXIN_JS"
else
  log "nikki: 跳过 Mips 选项（已存在或界面文件结构已变）"
fi

# --------------------------------------------------------------------------------------------------------

git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/lucky
# ── lucky v3 适配 ─────────────────────────────────────────────
# v3 的界面已改为 JS 视图，经 rpcd 调用 /usr/libexec/lucky-call，
# 不再有 luasrc/controller/lucky.lua（旧的 luci.sys.exec 补丁已不适用，会导致 sed 报错中断编译）。
# 这里只在 lucky-call 里加一行 ulimit 作为保险；找不到文件就跳过，避免上游再改结构时编译失败。
LUCKY_CALL=package/lucky/lucky/files/lucky-call
if [ -f "$LUCKY_CALL" ]; then
  log "lucky: 在 lucky-call 中解除 ulimit -v（保险）"
  sed -i '/^PROG=/i ulimit -v unlimited 2>/dev/null || true' "$LUCKY_CALL"
else
  log "lucky: 未找到 lucky-call，跳过 ulimit 补丁"
fi

# ============================================================
# 注入软件源配置文件（仅 24.10）
# ============================================================

# ── opkg 配置（仅 24.10）───────────────────────────────────
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
src/gz openwrt_kiddin9 https://dl.openwrt.ai/latest/packages/aarch64_cortex-a53/kiddin9
EOF
}

# ============================================================
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
# ============================================================

log "完成 ✓"
