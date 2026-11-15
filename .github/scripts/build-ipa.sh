#!/usr/bin/env bash
# ==============================================================================
# TÊN SCRIPT: build-ipa.sh (Phiên bản tối ưu hóa cấp độ tối cao)
# MỤC ĐÍCH: Build và đóng gói IPA ad-hoc chuẩn chỉnh cho GestaltX kèm ShareExtension
# ==============================================================================
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mkdir -p "${1:-$root/build/ipa}" && cd "${1:-$root/build/ipa}" && pwd)"
cd "$root"

# Lấy phiên bản Marketing Version
version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' GestaltX.xcodeproj/project.pbxproj | sort -u)"
if [[ -z "$version" || "$(wc -l <<< "$version")" -ne 1 ]]; then
  echo "Error: expected one MARKETING_VERSION, found: ${version:-none}" >&2
  exit 1
fi
echo "==> Building GestaltX $version"

if [[ -n "${BUILD_DATE:-}" ]]; then
  printf '%s' "$BUILD_DATE" > GestaltX/BuildDate.txt
fi

# Biên dịch tệp JSON ngôn ngữ nếu có
if [[ -f scripts/generate_localization.py ]]; then
  python3 scripts/generate_localization.py
fi

# Dọn dẹp build cũ để tránh xung đột cache
echo "==> Cleaning previous build artifacts..."
rm -rf "$root/build/Release-iphoneos/GestaltX.app"

# THỰC THI BUILD: Đã loại bỏ cờ -quiet để CI nhả toàn bộ log lỗi nếu có sự cố
echo "==> Starting xcodebuild compile process..."
set +e
xcodebuild \
  -project GestaltX.xcodeproj \
  -target GestaltX \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$root/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build
BUILD_EXIT_CODE=$?
set -e

if [ $BUILD_EXIT_CODE -ne 0 ]; then
  echo "==> CRITICAL ERROR: xcodebuild failed with exit code $BUILD_EXIT_CODE" >&2
  echo "==> Kiểm tra lại mã nguồn Swift hoặc cấu hình Entitlements." >&2
  exit $BUILD_EXIT_CODE
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" "$out"

# Kiểm tra xem app đã build ra chưa
APP_PATH="$root/build/Release-iphoneos/GestaltX.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: GestaltX.app not found at expected path: $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$stage/Payload/"
app="$stage/Payload/GestaltX.app"
appex="$app/PlugIns/GestaltXShare.appex"

echo "==> Signing with entitlements (Ad-hoc)"
# Ký các framework và dylib bên trong trước
while IFS= read -r -d '' item; do
  codesign -f -s - "$item"
done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)

bundles=()
if [[ -d "$appex" ]]; then
  codesign -f -s - --entitlements ShareExtension/GestaltXShare.entitlements "$appex"
  bundles+=("$appex")
fi
codesign -f -s - --entitlements GestaltX/GestaltX.entitlements "$app"
bundles+=("$app")

# Kiểm tra chữ ký và entitlements bằng Python
python3 - "${bundles[@]}" <<'VERIFY_ENTITLEMENTS'
import plistlib, subprocess, sys
common = None
for bundle in sys.argv[1:]:
    subprocess.run(["codesign", "--verify", "--strict", bundle], check=True)
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", bundle], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    groups = entitlements.get("com.apple.security.application-groups", [])
    if not isinstance(groups, list) or not groups or not all(isinstance(group, str) and group for group in groups):
        raise SystemExit(f"Missing usable App Group entitlements in signed bundle: {bundle}")
    if entitlements.get("com.apple.developer.team-identifier"):
        raise SystemExit(f"A developer Team ID must not be embedded in ad-hoc package: {bundle}")
    metadata = subprocess.run(["codesign", "-dvv", bundle], capture_output=True, text=True, check=True).stderr
    if "Signature=adhoc" not in metadata or "TeamIdentifier=not set" not in metadata:
        raise SystemExit(f"Expected ad-hoc signature without developer identity for: {bundle}")
    common = set(groups) if common is None else common.intersection(groups)
if not common:
    raise SystemExit("The app and share extension do not have a common App Group")
print("SUCCESS: App and embedded extensions retain common App Groups with ad-hoc signatures.")
VERIFY_ENTITLEMENTS

ipa="$out/GestaltX_$version.ipa"
(cd "$stage" && zip -qry "$stage/GestaltX_$version.ipa" Payload)
mv -f "$stage/GestaltX_$version.ipa" "$ipa"
echo "==> Wrote IPA successfully to: $ipa"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "ipa=$ipa"
  } >> "$GITHUB_OUTPUT"
fi
