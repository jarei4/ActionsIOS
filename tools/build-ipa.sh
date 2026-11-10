#!/usr/bin/env bash
# tools/build-ipa.sh — 在 macOS（本机或 CI）上产出「未签名 IPA」
#
# 为什么默认不签名：
#   签名材料（证书 + 描述文件）属于私密资产，不该进仓库、不该进 CI 缓存。
#   先产出结构完整的未签名包，再在 Windows 侧用 tools/resign.ps1 用当前有效的
#   描述文件重签 —— 描述文件到期只要换一份重签，二进制不用重新编译。
#
# 用法：
#   tools/build-ipa.sh                                  # 未签名
#   API_BASE_URL=http://192.168.1.20:8787 tools/build-ipa.sh
#   TEAM_ID=ABCDE12345 tools/build-ipa.sh --signed      # 走 Xcode 导出（需已装证书与描述文件）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="ios/AuroraApp.xcodeproj"
SCHEME="AuroraApp"
CONFIG="Release"

VERSION="$(node -e "process.stdout.write(require('./version.json').version)")"
BUILD="$(node -e "process.stdout.write(String(require('./version.json').build))")"
BUNDLE_ID="$(node -e "process.stdout.write(require('./version.json').bundleId)")"
API_BASE_URL="${API_BASE_URL:-http://192.168.1.10:8787}"

SIGNED=0
[[ "${1:-}" == "--signed" ]] && SIGNED=1

BUILD_DIR="build"
DIST_DIR="dist"
APP_NAME="AuroraApp"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo ""
echo "  Aurora 构建  v$VERSION ($BUILD)"
echo "  ──────────────────────────────────────────────────────"
echo "  服务端地址   $API_BASE_URL"
echo "  Bundle ID    $BUNDLE_ID"
echo "  Xcode        $(xcodebuild -version | head -n1)"
echo ""

COMMON_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination "generic/platform=iOS"
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive"
  -derivedDataPath "$BUILD_DIR/DerivedData"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD"
  API_BASE_URL="$API_BASE_URL"
)

if [[ $SIGNED -eq 1 ]]; then
  : "${TEAM_ID:?--signed 需要 TEAM_ID；并确保本机钥匙串里有对应证书}"
  : "${PROFILE_NAME:?--signed 需要 PROFILE_NAME（描述文件名称或 UUID）}"
  EXPORT_METHOD="${EXPORT_METHOD:-ad-hoc}"

  echo "  签名方式     Xcode 导出 ($EXPORT_METHOD)"
  xcodebuild archive "${COMMON_ARGS[@]}" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
    CODE_SIGN_IDENTITY="iPhone Distribution"

  EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>$EXPORT_METHOD</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>manual</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key><string>$PROFILE_NAME</string>
	</dict>
	<key>compileBitcode</key><false/>
	<key>stripSwiftSymbols</key><true/>
	<key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates

  OUT="$DIST_DIR/Aurora-$VERSION-$BUILD-signed.ipa"
  cp "$BUILD_DIR/export/$APP_NAME.ipa" "$OUT"
else
  echo "  签名方式     未签名（结构完整，交给 tools/resign.ps1 重签）"
  xcodebuild archive "${COMMON_ARGS[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS=""

  APP_PATH="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "  ✗ 归档里找不到 $APP_NAME.app" >&2
    exit 1
  fi

  rm -rf "$BUILD_DIR/Payload"
  mkdir -p "$BUILD_DIR/Payload"
  cp -R "$APP_PATH" "$BUILD_DIR/Payload/"

  OUT="$DIST_DIR/Aurora-$VERSION-$BUILD-unsigned.ipa"
  rm -f "$OUT"
  ( cd "$BUILD_DIR" && zip -qry "$ROOT/$OUT" Payload )

  # 校验条目名必须是正斜杠，否则 iOS 装不上
  if command -v unzip >/dev/null 2>&1; then
    if unzip -l "$OUT" | grep -q 'Payload/'; then
      :
    else
      echo "  ✗ 包内路径异常" >&2
      exit 1
    fi
  fi
fi

SIZE="$(du -h "$OUT" | cut -f1)"
echo ""
echo "  ✓ 产出 $OUT  ($SIZE)"
echo ""
echo "  下一步（Windows）："
echo "    powershell -NoProfile -File tools/resign.ps1 -Ipa $OUT \\"
echo "      -P12 signing/dev.p12 -PasswordFile signing/pass.txt \\"
echo "      -Profile signing/Aurora_AdHoc.mobileprovision"
echo ""
