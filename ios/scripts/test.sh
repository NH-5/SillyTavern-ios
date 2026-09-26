#!/usr/bin/env bash
#
# 核心逻辑测试（无需模拟器）。
#
# 为什么需要这个脚本：
#   本项目的开发环境禁止嵌套沙箱，而 swift-plugin-server 必须用 sandbox-exec
#   启动，因此命令行**无法编译任何使用 SwiftUI 宏（@State / @Observable 等）的代码**。
#   好在最需要验证的部分——角色卡解析、世界书触发、Prompt 组装、SSE 分帧、
#   持久化格式——都是纯 Foundation 代码。这里把它们编成 macOS 命令行程序跑断言，
#   这样每次改动都能在几秒内确认「与 SillyTavern 的兼容性有没有被破坏」。
#
#   界面层（Views/）只能在 Xcode GUI 里编译，详见 ios/README.md。
#
# 用法：
#   ios/scripts/test.sh          # 跑全部测试
#   ios/scripts/test.sh --list   # 只列出测试用例
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${IOS_DIR}/.." && pwd)"

SRC_DIR="${IOS_DIR}/SillyTavern"
HARNESS_DIR="${IOS_DIR}/Tests"
BUILD_DIR="${IOS_DIR}/build/tests"
MODULE_CACHE="${IOS_DIR}/build/modulecache"
BINARY="${BUILD_DIR}/CoreTests"

mkdir -p "${BUILD_DIR}" "${MODULE_CACHE}"

echo "==> 收集纯逻辑源文件（排除依赖 SwiftUI 的部分）"

# 这些文件依赖 SwiftUI / UIKit，命令行环境编译不了，测试也不需要。
EXCLUDED=(
    "${SRC_DIR}/App/SillyTavernApp.swift"
    "${SRC_DIR}/App/RootView.swift"
    "${SRC_DIR}/Views"
)

is_excluded() {
    local file="$1"
    for pattern in "${EXCLUDED[@]}"; do
        case "${file}" in
            "${pattern}"|"${pattern}"/*) return 0 ;;
        esac
    done
    return 1
}

SOURCES=()
while IFS= read -r -d '' file; do
    if ! is_excluded "${file}"; then
        SOURCES+=("${file}")
    fi
done < <(find "${SRC_DIR}" -name '*.swift' -type f -print0 | sort -z)

while IFS= read -r -d '' file; do
    SOURCES+=("${file}")
done < <(find "${HARNESS_DIR}" -name '*.swift' -type f -print0 | sort -z)

if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "错误：没有找到任何源文件" >&2
    exit 1
fi
echo "    共 ${#SOURCES[@]} 个文件"

echo "==> 编译测试程序"
set +e
xcrun swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    -swift-version 5 \
    -Onone \
    -g \
    -parse-as-library \
    -o "${BINARY}" \
    "${SOURCES[@]}" 2>&1 | tee "${BUILD_DIR}/compile.log"
STATUS=${PIPESTATUS[0]}
set -e

if [ "${STATUS}" -ne 0 ]; then
    echo "" >&2
    echo "编译失败：" >&2
    grep -E "error:" "${BUILD_DIR}/compile.log" | head -20 >&2
    exit "${STATUS}"
fi

echo "==> 运行测试"
echo ""
set +e
ST_FIXTURES="${PROJECT_DIR}/default/content" "${BINARY}" "$@"
TEST_STATUS=$?
set -e

# ---------------------------------------------------------------------------
# 界面层类型检查
#
# Views/ 依赖 SwiftUI 宏（@State / @StateObject / #Preview）。
# swiftc 默认会用 sandbox-exec 给 swift-plugin-server 套一层沙箱，
# 受限环境里不允许嵌套沙箱，宏就会展开失败、界面层无法编译。
# `-disable-sandbox` 关掉编译器自己那层沙箱即可，于是界面层也能被真正
# 类型检查——而不是靠人读代码猜。这一步能抓出参数不匹配、API 用错等问题。
# ---------------------------------------------------------------------------
echo ""
echo "==> 界面层类型检查（iOS 模拟器目标）"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
UI_CACHE="${IOS_DIR}/build/ui-typecheck"

UI_SOURCES=()
while IFS= read -r -d '' file; do
    UI_SOURCES+=("${file}")
done < <(find "${SRC_DIR}" -name '*.swift' -type f -print0 | sort -z)

set +e
xcrun swiftc \
    -target arm64-apple-ios18.0-simulator \
    -sdk "${SDK_PATH}" \
    -disable-sandbox \
    -module-cache-path "${UI_CACHE}" \
    -swift-version 5 \
    -D DEBUG -D XCODE_BUILD \
    -typecheck \
    "${UI_SOURCES[@]}" 2>&1 | tee "${BUILD_DIR}/typecheck.log"
UI_STATUS=${PIPESTATUS[0]}
set -e

if [ "${UI_STATUS}" -ne 0 ]; then
    echo "" >&2
    echo "界面层类型检查失败：" >&2
    grep -E "error:" "${BUILD_DIR}/typecheck.log" | head -20 >&2
else
    echo "    通过（${#UI_SOURCES[@]} 个文件，含 Views/ 与 App/）"
fi

if [ "${TEST_STATUS}" -ne 0 ] || [ "${UI_STATUS}" -ne 0 ]; then
    exit 1
fi
