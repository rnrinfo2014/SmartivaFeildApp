#!/usr/bin/env bash
# Install a JDK 17+ and Android SDK first; see ANDROID_TESTING.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" build apk --no-pub --debug --target-platform android-arm,android-arm64
mkdir -p dist
app_version="$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)"
test -n "$app_version"
apk_name="smartiva-fieldops-${app_version}-test.apk"
cp build/app/outputs/flutter-apk/app-debug.apk "dist/$apk_name"
(cd dist && sha256sum "$apk_name" > "$apk_name.sha256")
printf 'Test APK: %s\n' "$PWD/dist/$apk_name"
