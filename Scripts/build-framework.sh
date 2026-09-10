#!/usr/bin/env bash
# SwiftPM の dylib と公開モジュールを KaitoKit.framework にまとめる。
# 複数の --arch を同時に指定すると SwiftBuild 経由になり .swiftinterface が
# 出力されないため、各トリプルを個別にビルドして結合する。
# SwiftPM を介さない利用側では、ネストした KaitoKitCompat を解決するため
# `-I KaitoKit.framework/Modules` も指定する必要がある。
set -euo pipefail

# 公開パッケージの利用者に非互換を持ち込まないよう、既定は universal のままにする。
# 必要な場合だけ KAITOKIT_ARCHS="arm64" などを空白区切りで指定する。
IFS=$' \t\n' read -r -d '' -a REQUESTED_ARCHS < <(
    printf '%s\0' "${KAITOKIT_ARCHS-arm64 x86_64}"
)
if [[ ${#REQUESTED_ARCHS[@]} -eq 0 ]]; then
    echo "error: KAITOKIT_ARCHS must not be empty; supported architectures: arm64 x86_64" >&2
    exit 1
fi
for arch in "${REQUESTED_ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "error: unsupported architecture '$arch' in KAITOKIT_ARCHS; supported architectures: arm64 x86_64" >&2
            exit 1
            ;;
    esac
done

# 重複を除き、指定順が違っても同じビルド設定として扱う。
ARCHS=()
for arch in arm64 x86_64; do
    if [[ " ${REQUESTED_ARCHS[*]} " == *" $arch "* ]]; then
        ARCHS+=("$arch")
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
FRAMEWORK="$FRAMEWORKS_DIR/KaitoKit.framework"
EXECUTABLE="$FRAMEWORK/Versions/A/KaitoKit"
STAMP_FILE="$FRAMEWORK/Versions/A/Resources/.swift-version"
ARCHS_STAMP_FILE="$FRAMEWORK/Versions/A/Resources/.archs"
CALLER_HOME="${HOME:-/var/empty}"
CALLER_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

verify_architectures() {
    local arch
    for arch in "${ARCHS[@]}"; do
        lipo "$EXECUTABLE" -verify_arch "$arch" || return 1
    done
}

# Xcode の Run Script から継承したビルド設定が SwiftPM に混ざらないようにする。
run_swift() {
    env -i \
        HOME="$CALLER_HOME" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_DIR="$CALLER_DEVELOPER_DIR" \
        swift "$@"
}

SWIFT_VERSION="$(run_swift --version 2>/dev/null | sed -n '1p')"

# ソース・ツールチェーン・要求アーキテクチャが同じ場合だけ既存成果物を使う。
if [[ -f "$EXECUTABLE" && -f "$STAMP_FILE" && -f "$ARCHS_STAMP_FILE" ]] && \
        [[ "$(<"$STAMP_FILE")" == "$SWIFT_VERSION" && \
           "$(<"$ARCHS_STAMP_FILE")" == "${ARCHS[*]}" ]] && \
        verify_architectures >/dev/null 2>&1; then
    if [[ -z "$(find "$ROOT_DIR/Sources" "$ROOT_DIR/Package.swift" \
            "$SCRIPT_DIR/build-framework.sh" \
            -type f -newer "$EXECUTABLE" -print -quit)" ]]; then
        echo "KaitoKit.framework is up to date."
        exit 0
    fi
fi

cd "$ROOT_DIR"
# library evolution を有効にし、異なる Swift コンパイラ用の interface も残す。
build_for_triple() {
    local build_triple="$1"
    shift
    # 新しい SwiftPM は出力先がトリプルに依存せず衝突するため、
    # スクラッチ領域を分けて両アーキテクチャの成果物を保持する。
    run_swift build -c release --triple "$build_triple" \
        --scratch-path "$ROOT_DIR/.build/$build_triple" \
        --product KaitoKitDynamic \
        -Xswiftc -enable-library-evolution \
        -Xswiftc -emit-module-interface "$@"
}

BIN_DIRS=()
DYLIBS=()
for arch in "${ARCHS[@]}"; do
    build_triple="$arch-apple-macosx"
    build_for_triple "$build_triple"

    # ビルド時と同じオプションで、SwiftPM が決めた出力先を取得する。
    bin_dir="$(build_for_triple "$build_triple" --show-bin-path)"
    dylib="$bin_dir/libKaitoKitDynamic.dylib"
    if [[ ! -f "$dylib" ]]; then
        echo "error: dynamic library not found: $dylib" >&2
        exit 1
    fi
    BIN_DIRS+=("$bin_dir")
    DYLIBS+=("$dylib")
done

rm -rf "$FRAMEWORK"
MODULES_DIR="$FRAMEWORK/Versions/A/Modules"
RESOURCES_DIR="$FRAMEWORK/Versions/A/Resources"
mkdir -p "$MODULES_DIR" "$RESOURCES_DIR"
if [[ ${#DYLIBS[@]} -eq 1 ]]; then
    cp "${DYLIBS[0]}" "$EXECUTABLE"
else
    lipo -create "${DYLIBS[@]}" -output "$EXECUTABLE"
fi

if ! verify_architectures; then
    echo "error: KaitoKit is missing requested architectures: ${ARCHS[*]}" >&2
    exit 1
fi

find_latest_interface() {
    local search_dir="$1"
    local name="$2"
    local latest=""
    local candidate

    while IFS= read -r -d '' candidate; do
        if [[ -z "$latest" || "$candidate" -nt "$latest" ]]; then
            latest="$candidate"
        fi
    done < <(find "$search_dir" -name "$name.swiftinterface" \
        -not -path '*ModuleCache*' -print0 2>/dev/null)

    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

install_arch_artifacts() {
    local name="$1"
    local build_triple="$2"
    local destination="$3"
    local bin_dir="$4"
    local arch="${build_triple%%-*}"
    local triple="$arch-apple-macos"
    local modules_dir="$bin_dir/$name.swiftmodule"
    local artifact
    local interface
    local extension

    for extension in swiftmodule swiftdoc; do
        if [[ -d "$modules_dir" ]]; then
            # 新レイアウトはモジュールのディレクトリ内にトリプル別のファイルを置く。
            artifact="$modules_dir/$triple.$extension"
            if [[ ! -f "$artifact" ]]; then
                artifact="$modules_dir/$build_triple.$extension"
            fi
        else
            # 旧レイアウトは Modules 内にモジュール名で平置きする。
            artifact="$bin_dir/Modules/$name.$extension"
        fi
        if [[ ! -f "$artifact" ]]; then
            echo "error: $name $arch $extension not found" >&2
            exit 1
        fi
        cp "$artifact" "$destination/$triple.$extension"
        cp "$destination/$triple.$extension" \
            "$destination/$build_triple.$extension"
    done

    # Products の外の中間生成物も、同じトリプルのスクラッチ領域内だけで探す。
    if ! interface="$(find_latest_interface "$ROOT_DIR/.build/$build_triple" "$name")"; then
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
    local index
    mkdir -p "$destination"
    for index in "${!ARCHS[@]}"; do
        install_arch_artifacts "$name" "${ARCHS[$index]}-apple-macosx" \
            "$destination" "${BIN_DIRS[$index]}"
    done
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
echo "${ARCHS[*]}" > "$ARCHS_STAMP_FILE"

ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/KaitoKit "$FRAMEWORK/KaitoKit"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

install_name_tool -id '@rpath/KaitoKit.framework/Versions/A/KaitoKit' "$EXECUTABLE"
codesign --force --sign - "$FRAMEWORK"
echo "Built $FRAMEWORK ($SWIFT_VERSION)"
