#!/bin/bash
#
# 在 WSL 里用 OpenWrt SDK 构建 autoverify 的 .apk
#
# 为什么要 SDK: OpenWrt 25.12 的 apk 包是 apk-tools 3.x 的 ADB 二进制格式
# (文件头 "ADBd"), schema 只松散定义、实际取决于 apk-tools 的 C 源码,
# 无法手工拼装。必须用 OpenWrt 的构建系统产出。
#
# 用法 (在 WSL 里跑):
#   bash tools/build-apk.sh            # 默认 25.12.5 / ramips/mt7621
#   VER=25.12.5 TARGET=ramips SUBTARGET=mt7621 bash tools/build-apk.sh
#
set -euo pipefail

VER="${VER:-25.12.5}"
TARGET="${TARGET:-ramips}"
SUBTARGET="${SUBTARGET:-mt7621}"
# SDK 下载源。downloads.openwrt.org 在国内经常只有 100KB/s 量级,
# 换国内镜像快一个数量级。用 MIRROR=... 可覆盖。
MIRROR="${MIRROR:-https://mirrors.ustc.edu.cn/openwrt}"
WORK="${WORK:-$HOME/openwrt-apk-build}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

OFFICIAL="https://downloads.openwrt.org"

# 镜像可能返回 HTTP 200 的 HTML 验证页，不能把 curl 成功当作下载成功。
# 每个源单独获取索引、校验和及归档，避免跨源续传混入错误内容。
fetch_sdk_from() {
	local base="$1/releases/${VER}/targets/${TARGET}/${SUBTARGET}/"
	local actual expected
	echo "==> 查询 SDK: $base"
	curl -fsSL --connect-timeout 20 --max-time 120 "${base}" -o sdk.index || return 1
	actual=$(grep -oE 'openwrt-sdk-[A-Za-z0-9_.+-]+\.tar\.zst' sdk.index | sed -n '1p')
	[ -n "$actual" ] || { echo '!! 目录索引中没有 SDK' >&2; return 1; }
	curl -fsSL --connect-timeout 20 --max-time 120 "${base}sha256sums" -o sdk.sha256sums || return 1
	expected=$(awk -v name="$actual" '$2 == name || $2 == "*" name {print $1; exit}' sdk.sha256sums)
	[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { echo '!! 找不到 SDK SHA256' >&2; return 1; }
	echo "==> 下载 $actual"
	curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o sdk.tar.zst.part "${base}${actual}" || return 1
	printf '%s  sdk.tar.zst.part\n' "$expected" | sha256sum -c - || return 1
	zstd -tq sdk.tar.zst.part || return 1
	mv sdk.tar.zst.part sdk.tar.zst
}

echo "==> 仓库: $REPO"
echo "==> 版本: $VER  目标: $TARGET/$SUBTARGET"
echo "==> 镜像: $MIRROR"
echo "==> 构建目录: $WORK"

mkdir -p "$WORK"
cd "$WORK"

# --- 1. 下载并解压 SDK -------------------------------------------------------
if [ ! -d sdk ]; then
	if ! fetch_sdk_from "${MIRROR%/}"; then
		if [ "${MIRROR%/}" = "$OFFICIAL" ]; then
			echo '!! 官方源 SDK 下载或校验失败' >&2
			exit 1
		fi
		echo '!! 镜像下载或校验失败，切换到 OpenWrt 官方源' >&2
		fetch_sdk_from "$OFFICIAL" || { echo '!! 所有 SDK 下载源均失败' >&2; exit 1; }
	fi
	echo "==> 解压 SDK"
	_unpack=$(mktemp -d "$WORK/sdk-unpack.XXXXXX")
	tar --zstd -xf sdk.tar.zst -C "$_unpack" --strip-components=1
	test -f "$_unpack/Makefile"
	mv "$_unpack" sdk
fi

# --- 2. 放入包源码 -----------------------------------------------------------
echo "==> 拷贝包源码到 SDK"
rm -rf "$WORK/sdk/package/autoverify"
mkdir -p "$WORK/sdk/package/autoverify"
cp "$REPO/package/autoverify/Makefile" "$WORK/sdk/package/autoverify/"
cp -r "$REPO/files" "$WORK/sdk/package/autoverify/files"
# 保证脚本有可执行位 (Windows 上拷过来可能丢)
chmod +x "$WORK/sdk/package/autoverify/files/usr/sbin/"* \
         "$WORK/sdk/package/autoverify/files/etc/init.d/"* \
         "$WORK/sdk/package/autoverify/files/etc/hotplug.d/iface/"* \
         "$WORK/sdk/package/autoverify/files/etc/uci-defaults/"*

cd "$WORK/sdk"

# --- 3. 构建 -----------------------------------------------------------------
# 必须先生成 .config: SDK 解压后没有 .config, 直接 make package/.../compile
# 会让 OpenWrt 启动 menuconfig 交互界面并在无人值守时卡死。
if [ ! -f .config ]; then
	echo "==> 生成 .config (make defconfig)"
	make defconfig
fi

echo "==> 编译"
make package/autoverify/compile V=s

# --- 4. 收集产物 -------------------------------------------------------------
echo "==> 产物"
find bin -name 'autoverify*.apk' -o -name 'autoverify*.ipk' | while read -r f; do
	echo "    $f"
done
OUT="$REPO/dist"
mkdir -p "$OUT"
find bin \( -name 'autoverify*.apk' -o -name 'autoverify*.ipk' \) -exec cp {} "$OUT/" \;
if ! find "$OUT" -maxdepth 1 -type f \( -name 'autoverify*.apk' -o -name 'autoverify*.ipk' \) | grep -q .; then
	echo "!! 构建没有产出 autoverify APK/IPK" >&2
	exit 1
fi
ls -la "$OUT"
