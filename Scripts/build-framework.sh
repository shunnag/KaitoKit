#!/usr/bin/env bash
# SwiftPM のユニバーサル dylib と公開モジュールを KaitoKit.framework にまとめる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
FRAMEWORK="$FRAMEWORKS_DIR/KaitoKit.framework"
EXECUTABLE="$FRAMEWORK/Versions/A/KaitoKit"
STAMP_FILE="$FRAMEWORK/Versions/A/Resources/.swift-version"
CALLER_HOME="${HOME:-/var/empty}"
CALLER_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

# Xcode の Run Script から継承したビルド設定が SwiftPM に混ざらないようにする。
run_swift() {
    env -i \
        HOME="$CALLER_HOME" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_DIR="$CALLER_DEVELOPER_DIR" \
        swift "$@"
}

SWIFT_VERSION="$(run_swift --version 2>/dev/null | sed -n '1p')"

# ソースとツールチェーンが変わっていなければ既存成果物を使う。
if [[ -f "$EXECUTABLE" && -f "$STAMP_FILE" ]] && \
        [[ "$(<"$STAMP_FILE")" == "$SWIFT_VERSION" ]]; then
    if [[ -z "$(find "$ROOT_DIR/Sources" "$ROOT_DIR/Package.swift" \
            "$SCRIPT_DIR/build-framework.sh" \
            -type f -newer "$EXECUTABLE" -print -quit)" ]]; then
        echo "KaitoKit.framework is up to date."
        exit 0
    fi
fi

cd "$ROOT_DIR"
# library evolution を有効にし、異なる Swift コンパイラ用の interface も残す。
run_swift build -c release --product KaitoKitDynamic \
    --arch arm64 --arch x86_64 \
    -Xswiftc -enable-library-evolution \
    -Xswiftc -emit-module-interface
BIN_DIR="$(run_swift build -c release --arch arm64 --arch x86_64 \
    --show-bin-path | tail -n 1)"
DYLIB="$BIN_DIR/libKaitoKitDynamic.dylib"

if [[ ! -f "$DYLIB" ]]; then
    echo "error: dynamic library not found: $DYLIB" >&2
    exit 1
fi
if ! lipo -info "$DYLIB" | grep -q 'arm64' || \
        ! lipo -info "$DYLIB" | grep -q 'x86_64'; then
    echo "error: KaitoKitDynamic is not a universal arm64/x86_64 binary" >&2
    exit 1
fi

rm -rf "$FRAMEWORK"
MODULES_DIR="$FRAMEWORK/Versions/A/Modules"
RESOURCES_DIR="$FRAMEWORK/Versions/A/Resources"
mkdir -p "$MODULES_DIR" "$RESOURCES_DIR"
cp "$DYLIB" "$EXECUTABLE"

copy_first() {
    local destination="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            cp "$candidate" "$destination"
            return 0
        fi
    done
    return 1
}

install_arch_artifacts() {
    local name="$1"
    local arch="$2"
    local destination="$3"
    local triple="$arch-apple-macos"
    local triple_x="$arch-apple-macosx"
    local legacy="$ROOT_DIR/.build/$triple_x/release/Modules"
    local intermediates="$ROOT_DIR/.build/out/Intermediates.noindex/KaitoKit.build/Release/${name}-t.build/Objects-normal/$arch"

    copy_first "$destination/$triple.swiftmodule" \
        "$BIN_DIR/$name.swiftmodule/$triple.swiftmodule" \
        "$BIN_DIR/$name.swiftmodule/$triple_x.swiftmodule" \
        "$intermediates/$name.swiftmodule" \
        "$legacy/$name.swiftmodule" || {
            echo "error: $name $arch swiftmodule not found" >&2
            exit 1
        }
    cp "$destination/$triple.swiftmodule" \
        "$destination/$triple_x.swiftmodule"

    if copy_first "$destination/$triple.swiftdoc" \
            "$BIN_DIR/$name.swiftmodule/$triple.swiftdoc" \
            "$BIN_DIR/$name.swiftmodule/$triple_x.swiftdoc" \
            "$intermediates/$name.swiftdoc" \
            "$legacy/$name.swiftdoc"; then
        cp "$destination/$triple.swiftdoc" "$destination/$triple_x.swiftdoc"
    fi

    copy_first "$destination/$triple.swiftinterface" \
        "$BIN_DIR/$name.swiftmodule/$triple.swiftinterface" \
        "$BIN_DIR/$name.swiftmodule/$triple_x.swiftinterface" \
        "$intermediates/$name.swiftinterface" \
        "$legacy/$name.swiftinterface" || {
            echo "error: $name $arch swiftinterface not emitted" >&2
            exit 1
        }
    cp "$destination/$triple.swiftinterface" \
        "$destination/$triple_x.swiftinterface"

    if copy_first "$destination/$triple.abi.json" \
            "$BIN_DIR/$name.swiftmodule/$triple.abi.json" \
            "$BIN_DIR/$name.swiftmodule/$triple_x.abi.json" \
            "$intermediates/$name.abi.json" \
            "$legacy/$name.abi.json"; then
        cp "$destination/$triple.abi.json" "$destination/$triple_x.abi.json"
    fi
}

install_module() {
    local name="$1"
    local destination="$MODULES_DIR/$name.swiftmodule"
    mkdir -p "$destination"
    install_arch_artifacts "$name" arm64 "$destination"
    install_arch_artifacts "$name" x86_64 "$destination"
}

# Compat の interface が import KaitoKit を含むため両モジュールが必要。
install_module KaitoKit
install_module KaitoKitCompat

cat > "$RESOURCES_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>KaitoKit</string>
	<key>CFBundleIdentifier</key>
	<string>com.shunnag.KaitoKit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>KaitoKit</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
</dict>
</plist>
PLIST
echo "$SWIFT_VERSION" > "$STAMP_FILE"

ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/KaitoKit "$FRAMEWORK/KaitoKit"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

install_name_tool -id '@rpath/KaitoKit.framework/Versions/A/KaitoKit' "$EXECUTABLE"
codesign --force --sign - "$FRAMEWORK"
echo "Built $FRAMEWORK ($SWIFT_VERSION)"
