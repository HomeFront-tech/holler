#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# ./build.sh            build + sign into build/Holler.app
# ./build.sh --test     ... and run the self-tests
# ./build.sh --install  ... and replace ~/Applications/Holler.app (quits a running copy)
# ./build.sh --open     ... install and launch it
case "${1:-}" in
  ''|--test|--install|--open) ;;
  *) echo 'Usage: ./build.sh [--test|--install|--open]' >&2; exit 2 ;;
esac
version="$(cat VERSION)"
repo="${HOLLER_REPO:-HomeFront-tech/holler}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION' >&2; exit 1; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid HOLLER_REPO (expected owner/name)' >&2; exit 1; }
mkdir -p build/module-cache build/Holler.app/Contents/MacOS
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path build/module-cache Sources/*.swift Tests/*.swift \
  -o build/Holler.app/Contents/MacOS/Holler -framework AppKit -framework Speech \
  -framework AVFoundation -framework CoreAudio -framework ApplicationServices -framework ServiceManagement -framework Security
cat > build/Holler.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.github.homefront-tech.holler</string>
<key>CFBundleName</key><string>Holler</string>
<key>CFBundleDisplayName</key><string>Holler</string>
<key>CFBundleExecutable</key><string>Holler</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>HollerUpdateRepo</key><string>$repo</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>Holler listens only while you hold Fn, and turns what you say into text on this Mac.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Holler uses Apple's on-device dictation to type what you say.</string>
</dict></plist>
PLIST
cat > build/entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
# BACK UP .signing/: losing this identity means published updates can no longer be verified by existing installs.
stable_sign() (
  umask 077
  mkdir -p .signing || exit 1
  kc="$PWD/.signing/holler.keychain-db"
  openssl_bin="$(command -v openssl)"
  if [[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then openssl_bin=/opt/homebrew/opt/openssl@3/bin/openssl; fi
  # Homebrew OpenSSL 3 needs -legacy; macOS LibreSSL already emits the older PKCS#12 format.
  legacy=""
  if "$openssl_bin" version | /usr/bin/grep -q '^OpenSSL 3'; then legacy="-legacy"; fi
  if [[ ! -f .signing/local.crt || ! -f .signing/local.key ]]; then
    "$openssl_bin" req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj '/CN=Holler Local Signing' -addext 'basicConstraints=critical,CA:false' \
      -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=critical,codeSigning' \
      -keyout .signing/local.key -out .signing/local.crt || exit 1
  fi
  if [[ ! -f .signing/local.p12 ]]; then
    "$openssl_bin" pkcs12 -export ${legacy:+"$legacy"} -inkey .signing/local.key -in .signing/local.crt \
      -out .signing/local.p12 -passout pass:holler || exit 1
  fi
  if [[ ! -f "$kc" ]]; then
    /usr/bin/security create-keychain -p holler "$kc" || exit 1
  fi
  /usr/bin/security unlock-keychain -p holler "$kc" || exit 1
  if [[ ! -f .signing/imported ]]; then
    /usr/bin/security import .signing/local.p12 -k "$kc" -P holler -T /usr/bin/codesign || exit 1
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k holler "$kc" >/dev/null || exit 1
    touch .signing/imported || exit 1
  fi
  /usr/bin/codesign --force --options runtime --entitlements build/entitlements.plist \
    --keychain "$kc" --sign 'Holler Local Signing' build/Holler.app || exit 1
)
# Do not modify the user's keychain search list or login keychain.
if (set -e; stable_sign) >build/signing.log 2>&1; then
  echo 'Signed with Holler Local Signing (stable identity).'
else
  echo 'WARNING: private-keychain signing failed; using ad-hoc signing. Accessibility may need reapproval. See build/signing.log.' >&2
  codesign --force --options runtime --entitlements build/entitlements.plist --sign - build/Holler.app
fi
codesign --verify --strict build/Holler.app
echo 'Built build/Holler.app.'
if [[ "${1:-}" == --test ]]; then build/Holler.app/Contents/MacOS/Holler --selftest; fi
if [[ "${1:-}" == --install || "${1:-}" == --open ]]; then
  build/Holler.app/Contents/MacOS/Holler --selftest >/dev/null || { echo 'self-tests failed; not installing' >&2; exit 1; }
  # SIGTERM lets Holler clean up (unmute, resume media, restore clipboard) before it exits; force only if stuck.
  if pkill -TERM -x Holler 2>/dev/null; then
    for _ in {1..50}; do pgrep -x Holler >/dev/null || break; sleep 0.1; done
    pkill -KILL -x Holler 2>/dev/null || true
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Holler.app"
  /usr/bin/ditto build/Holler.app "$HOME/Applications/Holler.app"
  echo "Installed $HOME/Applications/Holler.app"
  if [[ "${1:-}" == --open ]]; then open "$HOME/Applications/Holler.app"; fi
fi
