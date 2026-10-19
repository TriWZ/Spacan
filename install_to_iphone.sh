#!/bin/bash
# One-shot installer: generate the Xcode project, build Spacan, and push it to the
# iPhone connected to this Mac (USB or Wi-Fi). Works with a free Apple ID (Personal Team,
# app expires after 7 days — just re-run) or a paid Developer Program team (1 year).
#
#   TEAM_ID=XXXXXXXXXX ./install_to_iphone.sh
#
# Find your Team ID in Xcode → Settings → Accounts → (your Apple ID) → Team, or at
# https://developer.apple.com/account (Membership details). Without TEAM_ID the script just
# generates the project and opens Xcode so you can pick the team and press ⌘R.
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-com.triphorium.spacan}"
SCHEME="Spacan"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null; then
  echo "需要先从 App Store 安装 Xcode，并打开一次完成组件安装。"; exit 1
fi
if ! command -v xcodegen >/dev/null; then
  if command -v brew >/dev/null; then brew install xcodegen
  else echo "需要 Homebrew（https://brew.sh）或手动安装 xcodegen。"; exit 1; fi
fi

echo "▶ 生成 Xcode 工程"
xcodegen generate >/dev/null

if [ -z "$TEAM_ID" ]; then
  echo "未设置 TEAM_ID，改为打开 Xcode：Signing & Capabilities 里选 Team，顶部选你的 iPhone，⌘R。"
  open "$SCHEME.xcodeproj"
  exit 0
fi

echo "▶ 查找已连接的 iPhone / iPad"
DEVICES_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
UDID="$(python3 - "$DEVICES_JSON" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit()
devs = [x for x in d.get("result", {}).get("devices", [])
        if x.get("hardwareProperties", {}).get("platform") in ("iOS", "iPadOS")]
devs.sort(key=lambda x: 0 if x.get("connectionProperties", {}).get("tunnelState") == "connected" else 1)
print(devs[0]["hardwareProperties"]["udid"] if devs else "")
EOF
)"
if [ -z "$UDID" ]; then
  echo "没找到设备。用数据线连上 iPhone，解锁并点「信任此电脑」，或在 Xcode → Window → Devices and Simulators 里开启 Wi-Fi 连接后重试。"
  exit 1
fi
echo "  设备 UDID: $UDID"

echo "▶ 编译并签名（第一次会自动注册设备、创建描述文件）"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build | grep -E "error:|warning: .*signing|BUILD" || true

APP="$(find build/Build/Products -type d -name "$SCHEME.app" -path "*iphoneos*" | head -1)"
if [ -z "$APP" ]; then
  echo "编译失败。常见原因：Xcode 里没登录这个 Team 的 Apple ID（Xcode → Settings → Accounts）；或 Bundle ID 被别的 Team 占用（改 BUNDLE_ID=com.yourname.spacan 重试）。"
  exit 1
fi

echo "▶ 安装到设备"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "▶ 启动"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" || true

cat <<EOF

完成。如果手机提示「不受信任的开发者」：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。
免费 Apple ID 签的包 7 天后失效，重新跑一次这个脚本即可（扫描数据保留）。
EOF
