#!/bin/bash
# 빌드해서 ~/Applications/Veil.app (베일) 으로 설치합니다.
# 사용법: ./build.sh        (빌드만)
#         ./build.sh --run  (빌드 후 실행)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Veil
# 식별자는 예전 이름(ScreenTranslator) 그대로 둬요. 바꾸면 화면 녹화 권한을 다시 줘야 해요.
BUNDLE_ID=local.ScreenTranslator
APP="$HOME/Applications/$APP_NAME.app"
# iCloud 폴더에 빌드 산출물이 동기화되지 않도록 캐시 폴더에서 빌드
BUILD_DIR="$HOME/Library/Caches/$APP_NAME-build"
SDK="$(xcode-select -p)/SDKs/MacOSX26.sdk"   # 27 SDK의 SwiftUI는 Xcode 전용 매크로가 필요해서 26 SDK 사용

mkdir -p "$BUILD_DIR"
# iCloud가 빌드 도중 소스 파일을 건드리면 swiftc가 실패해서, 복사본으로 빌드해요.
rm -rf "$BUILD_DIR/src"
cp -R Sources/ScreenTranslator "$BUILD_DIR/src"
xcrun swiftc -O \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4 \
    -swift-version 6 \
    -parse-as-library \
    -module-name "$APP_NAME" \
    "$BUILD_DIR"/src/*.swift \
    -o "$BUILD_DIR/$APP_NAME"

pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x ScreenTranslator 2>/dev/null || true          # 예전 이름으로 설치된 앱
rm -rf "$HOME/Applications/ScreenTranslator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 서명 순서: 애플 개발자 인증서 → 이 맥 전용 개인 인증서 → 임시(ad-hoc)
# 같은 인증서로 계속 서명해야 다시 빌드해도 화면 녹화 권한이 유지돼요.
# 개인 인증서는 처음 한 번 만들어 둔 것: "ScreenTranslator Local Signing" (로그인 키체인)
LOCAL_CERT="ScreenTranslator Local Signing"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
LABEL="$IDENTITY"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -p codesigning | awk -v name="\"$LOCAL_CERT\"" '$0 ~ name {print $2; exit}')
    LABEL="$LOCAL_CERT"
fi
codesign --force --sign "${IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "✅ 설치 완료: $APP (서명: ${LABEL:-ad-hoc})"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
