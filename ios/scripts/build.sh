#!/usr/bin/env bash
#
# 在受限环境下构建并运行 iOS 版 SillyTavern。
#
# 为什么需要这个脚本：
#   本项目的开发环境禁止写入 ~/Library/Developer/Xcode/DerivedData 与
#   /var/folders/**/C，因此 xcodebuild 无法完成编译（clang 报
#   "unable to write module session file"）。
#   解决方案是直接用 swiftc 编译、手工组装 .app、adhoc 签名，再用 simctl 安装运行。
#   两个关键参数：
#     -disable-sandbox    允许宏展开（受限环境不允许嵌套沙箱）
#     -module-cache-path  把模块缓存指到可写目录
#   产物与 Xcode 构建等价，可用于真机外的全部验证。
#
#   若你在本地 Xcode GUI 中开发，直接打开 ios/SillyTavern.xcodeproj
#   按 ⌘R 即可，不需要本脚本。
#
# 用法：
#   ios/scripts/build.sh              # 编译 + 安装 + 启动
#   ios/scripts/build.sh --screenshot # 额外截图（验证 UI 是否真的渲染）
#   ios/scripts/build.sh --no-run     # 只编译出 .app
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${IOS_DIR}/.." && pwd)"

APP_NAME="SillyTavern"
BUNDLE_ID="app.sillytavern.ios"
SRC_DIR="${IOS_DIR}/${APP_NAME}"
BUILD_ROOT="${IOS_DIR}/build"
APP_BUNDLE="${BUILD_ROOT}/${APP_NAME}.app"
MODULE_CACHE="${BUILD_ROOT}/modulecache"
SDK_NAME="iphonesimulator"
DEVICE_NAME="${ST_SIM_DEVICE:-iPhone 17}"
DEPLOYMENT_TARGET="18.0"
ARCH="arm64"
LOG_FILE="${BUILD_ROOT}/build.log"

DO_RUN=1
DO_SCREENSHOT=0
for arg in "$@"; do
    case "$arg" in
        --no-run) DO_RUN=0 ;;
        --screenshot) DO_SCREENSHOT=1 ;;
        --clean) rm -rf "${BUILD_ROOT}" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "${BUILD_ROOT}" "${APP_BUNDLE}" "${MODULE_CACHE}"

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"

echo "==> 收集 Swift 源文件"
SOURCES=()
while IFS= read -r -d '' f; do
    SOURCES+=("$f")
done < <(find "${SRC_DIR}" -name '*.swift' -type f -print0 | sort -z)

if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "错误：在 ${SRC_DIR} 下没有找到任何 .swift 文件" >&2
    exit 1
fi
echo "    共 ${#SOURCES[@]} 个文件"

echo "==> 编译（target ${ARCH}-apple-ios${DEPLOYMENT_TARGET}-simulator）"
# 两个关键参数，缺一不可：
#   -disable-sandbox：swiftc 默认会用 sandbox-exec 给 swift-plugin-server 套一层沙箱，
#       而在受限环境里不允许嵌套沙箱，宏（@State / @StateObject / #Preview）就会展开失败。
#       这个参数禁用编译器自己那层沙箱，宏因此可以正常工作。
#   -module-cache-path：默认模块缓存目录在 /var/folders 下、不可写，指到仓库内即可。
set +e
xcrun --sdk "${SDK_NAME}" swiftc \
    -target "${ARCH}-apple-ios${DEPLOYMENT_TARGET}-simulator" \
    -sdk "${SDK_PATH}" \
    -disable-sandbox \
    -module-cache-path "${MODULE_CACHE}" \
    -swift-version 5 \
    -Onone \
    -g \
    -parse-as-library \
    -o "${APP_BUNDLE}/${APP_NAME}" \
    "${SOURCES[@]}" 2>&1 | tee "${LOG_FILE}"
STATUS=${PIPESTATUS[0]}
set -e

if [ "${STATUS}" -ne 0 ]; then
    echo ""
    echo "编译失败，完整日志：${LOG_FILE}" >&2
    echo "--- 错误摘要 ---" >&2
    grep -E "error:" "${LOG_FILE}" | head -30 >&2
    exit "${STATUS}"
fi
echo "    编译成功"

echo "==> 组装 app bundle"
# App 图标：直接生成各尺寸 PNG 放进 bundle，并手写 Info.plist 的图标键。
#
# 为什么不只用 actool：actool 的产物（Assets.car + CFBundleIcons）在 iOS 27
# 模拟器上不会渲染出图标，需要 .icon（Icon Composer 格式）才行，而 Icon Composer
# 只有 GUI、没有命令行接口。这里改用 iOS 长期支持的传统方式：
# 把 PNG 放在 bundle 根目录并写全套 CFBundleIconFiles，这样图标一定能显示。
# Assets.xcassets 仍然保留，供在 Xcode GUI 里构建/上架时使用。
ASSETS_DIR="${SRC_DIR}/Assets.xcassets"
ICON_SOURCE="${ASSETS_DIR}/AppIcon.appiconset/AppIcon-1024.png"
if [ -f "${ICON_SOURCE}" ]; then
    # iPhone: 20@2x 40, 20@3x 60, 29@2x 58, 29@3x 87, 40@2x 80, 40@3x 120,
    #          60@2x 120, 60@3x 180 ; iPad: 20@1x 20, 20@2x 40, 29@1x 29,
    #          29@2x 58, 40@1x 40, 40@2x 80, 76@1x 76, 76@2x 152, 83.5@2x 167
    ICON_SIZES="40 58 60 76 80 87 120 152 167 180"
    for size in ${ICON_SIZES}; do
        sips -z "${size}" "${size}" "${ICON_SOURCE}" \
            --out "${APP_BUNDLE}/AppIcon${size}.png" >/dev/null 2>&1 || true
    done
    # 1x 的 20/29/40/76 也放一份，覆盖 iPad 老尺寸。
    for size in 20 29 40 76; do
        sips -z "${size}" "${size}" "${ICON_SOURCE}" \
            --out "${APP_BUNDLE}/AppIcon${size}.png" >/dev/null 2>&1 || true
    done
    ICON_FILES="AppIcon60 AppIcon120 AppIcon180 AppIcon80 AppIcon40 AppIcon58 AppIcon87 AppIcon76 AppIcon152 AppIcon167 AppIcon20 AppIcon29"
    ICON_PNGS="1"
fi

cat > "${APP_BUNDLE}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>SillyTavern</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>MinimumOSVersion</key><string>${DEPLOYMENT_TARGET}</string>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UILaunchScreen</key><dict/>
	<key>UIApplicationSceneManifest</key>
	<dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>用于从相册选择角色卡图片进行导入。</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>用于导入与导出角色卡、聊天记录文件。</string>
	<!-- 让 Documents 目录出现在「文件」App 里，方便与桌面版 SillyTavern 互传数据。 -->
	<key>UIFileSharingEnabled</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<!-- 支持 sillytavern://chat/<会话UUID> 深链，可从「快捷指令」等入口直达会话。 -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>app.sillytavern.ios</string>
			<key>CFBundleURLSchemes</key>
			<array><string>sillytavern</string></array>
		</dict>
	</array>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60</string>
				<string>AppIcon120</string>
				<string>AppIcon180</string>
				<string>AppIcon80</string>
				<string>AppIcon40</string>
				<string>AppIcon58</string>
				<string>AppIcon87</string>
				<string>AppIcon20</string>
				<string>AppIcon29</string>
			</array>
			<key>CFBundleIconName</key><string>AppIcon</string>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon76</string>
				<string>AppIcon152</string>
				<string>AppIcon167</string>
				<string>AppIcon40</string>
				<string>AppIcon80</string>
				<string>AppIcon20</string>
				<string>AppIcon29</string>
				<string>AppIcon58</string>
			</array>
			<key>CFBundleIconName</key><string>AppIcon</string>
		</dict>
	</dict>
</dict>
</plist>
PLIST

echo "==> adhoc 签名"
codesign --force --sign - "${APP_BUNDLE}" >/dev/null 2>&1

if [ "${DO_RUN}" -eq 0 ]; then
    echo "已生成：${APP_BUNDLE}"
    exit 0
fi

echo "==> 准备模拟器：${DEVICE_NAME}"
UDID="$(xcrun simctl list devices available | grep -F "${DEVICE_NAME} (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [ -z "${UDID}" ]; then
    echo "错误：找不到可用模拟器「${DEVICE_NAME}」。可用列表：" >&2
    xcrun simctl list devices available | grep -E "iOS|--" >&2
    exit 1
fi

# 若未启动则启动并等待完成 boot
if ! xcrun simctl list devices | grep -F "${UDID}" | grep -q "Booted"; then
    xcrun simctl boot "${UDID}" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "${UDID}" -b >/dev/null 2>&1 || true
fi

echo "==> 安装并启动"
xcrun simctl install "${UDID}" "${APP_BUNDLE}"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
xcrun simctl launch "${UDID}" "${BUNDLE_ID}"

if [ "${DO_SCREENSHOT}" -eq 1 ]; then
    sleep 5
    SHOT="${BUILD_ROOT}/screenshot.png"
    xcrun simctl io "${UDID}" screenshot "${SHOT}" >/dev/null 2>&1
    echo "截图：${SHOT}"
fi

echo "完成。"
