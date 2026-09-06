#!/usr/bin/env bash
# SwiftPM のユニバーサル dylib と公開モジュールを KaitoKit.framework にまとめる。
# 複数の --arch を同時に指定すると SwiftBuild 経由になり .swiftinterface が
# 出力されないため、各トリプルをネイティブの SwiftPM で個別にビルドして結合する。
# SwiftPM を介さない利用側では、ネストした KaitoKitCompat を解決するため
# `-I KaitoKit.framework/Modules` も指定する必要がある。
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
for build_triple in arm64-apple-macosx x86_64-apple-macosx; do
    run_swift build -c release --triple "$build_triple" \
        --product KaitoKitDynamic \
        -Xswiftc -enable-library-evolution \
        -Xswiftc -emit-module-interface
done

ARM64_BIN_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
X86_64_BIN_DIR="$ROOT_DIR/.build/x86_64-apple-macosx/release"
ARM64_DYLIB="$ARM64_BIN_DIR/libKaitoKitDynamic.dylib"
X86_64_DYLIB="$X86_64_BIN_DIR/libKaitoKitDynamic.dylib"

for dylib in "$ARM64_DYLIB" "$X86_64_DYLIB"; do
    if [[ ! -f "$dylib" ]]; then
        echo "error: dynamic library not found: $dylib" >&2
        exit 1
    fi
done

rm -rf "$FRAMEWORK"
MODULES_DIR="$FRAMEWORK/Versions/A/Modules"
RESOURCES_DIR="$FRAMEWORK/Versions/A/Resources"
mkdir -p "$MODULES_DIR" "$RESOURCES_DIR"
lipo -create "$X86_64_DYLIB" "$ARM64_DYLIB" -output "$EXECUTABLE"

if ! lipo -info "$EXECUTABLE" | grep -q 'arm64' || \
        ! lipo -info "$EXECUTABLE" | grep -q 'x86_64'; then
    echo "error: KaitoKit is not a universal arm64/x86_64 binary" >&2
    exit 1
fi

find_latest_interface() {
    local bin_dir="$1"
    local name="$2"
    local latest=""
    local candidate

    while IFS= read -r -d '' candidate; do
        if [[ -z "$latest" || "$candidate" -nt "$latest" ]]; then
            latest="$candidate"
        fi
    done < <(find "$bin_dir" -name "$name.swiftinterface" \
        -not -path '*ModuleCache*' -print0 2>/dev/null)

    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

install_arch_artifacts() {
    local name="$1"
    local build_triple="$2"
    local destination="$3"
    local arch="${build_triple%%-*}"
    local triple="$arch-apple-macos"
    local bin_dir="$ROOT_DIR/.build/$build_triple/release"
    local modules_dir="$bin_dir/Modules"
    local interface
    local extension

    for extension in swiftmodule swiftdoc; do
        if [[ ! -f "$modules_dir/$name.$extension" ]]; then
            echo "error: $name $arch $extension not found" >&2
            exit 1
        fi
        cp "$modules_dir/$name.$extension" \
            "$destination/$triple.$extension"
        cp "$destination/$triple.$extension" \
            "$destination/$build_triple.$extension"
    done

    if ! interface="$(find_latest_interface "$bin_dir" "$name")"; then
        echo "error: $name $arch swiftinterface not emitted" >&2
        exit 1
    fi
    cp "$interface" "$destination/$triple.swiftinterface"
    cp "$destination/$triple.swiftinterface" \
        "$destination/$build_triple.swiftinterface"
}

install_module() {
    local name="$1"
    local destination="$MODULES_DIR/$name.swiftmodule"
    mkdir -p "$destination"
    install_arch_artifacts "$name" arm64-apple-macosx "$destination"
    install_arch_artifacts "$name" x86_64-apple-macosx "$destination"
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
