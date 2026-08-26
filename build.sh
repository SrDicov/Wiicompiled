#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BUILD_DIR="${BUILD_DIR:-native-build}"
TOOLCHAIN_DIR="${LLVM_MINGW_DIR:-$(pwd)/.toolchain/llvm-mingw}"
CPPWINRT_DIR="${CPPWINRT_DIR:-$(pwd)/.toolchain/cppwinrt}"
PROJECT_MANIFEST="projects/mkwii/recomp.yml"
TRANSLATOR_DLL="translator/src/Translator.Cli/bin/Release/net8.0/Translator.Cli.dll"

# Pass --retro (or RETRO=1) to additionally build the Retro Rewind product.
# RETRO_ROOT must contain:
#   Binaries/Code.pul   the Kamek-compiled patch binary (not part of a normal
#                       consumer SD-card install; built/obtained separately)
#   xml/RetroRewind6.xml    the Riivolution descriptor, path fixed relative
#                           to RETRO_ROOT
#   the disc file overlay (Race/, Language/, ...), either directly under
#   RETRO_ROOT or nested under RETRO_ROOT/files/ - both are checked
# Defaults to PulsarPacks/completed/RetroRewind/RetroRewind6 under the repo;
# point RETRO_ROOT at an existing install elsewhere instead of moving it.
RETRO="${RETRO:-0}"
RETRO_SKIP_WFC="${RETRO_SKIP_WFC:-0}"
# Pass --package (or PACKAGE=1) to also assemble a self-contained, movable
# copy under dist/ (exe+DLLs+DATA, and RetroRewind6 too when --retro) and
# zip it, useful for end users who want to understand what files to keep
# around for a portable install.
PACKAGE="${PACKAGE:-0}"
for arg in "$@"; do
    case "$arg" in
        --retro) RETRO=1 ;;
        --retro-skip-wfc) RETRO=1; RETRO_SKIP_WFC=1 ;;
        --package) PACKAGE=1 ;;
    esac
done
RETRO_ROOT="${RETRO_ROOT:-$(pwd)/PulsarPacks/completed/RetroRewind/RetroRewind6}"
RETRO_OUT="build/mods/retro_rewind_full_cpp"

EXPECTED_DOL_SHA256="80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05"
EXPECTED_REL_SHA256="16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d"

verify_sha256() {
    [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

have_assets() {
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256" && verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"
}

# Auto-extract main.dol/StaticR.rel from a local disc image if Assets/ doesn't
# already hold a verified clean PAL RMCP01 copy. Accepts whatever `wit` does
# (ISO, GCM, GCZ, CISO, WBFS, WIA, RVZ) sitting at the repo root, set
# GAME_IMAGE to pick one explicitly (path or name) when more than one exists
# or it lives elsewhere
if ! have_assets; then
    if [ -z "${GAME_IMAGE:-}" ]; then
        shopt -s nullglob nocaseglob
        candidates=(*.wbfs *.iso *.gcm *.gcz *.ciso *.wia *.rvz)
        shopt -u nullglob nocaseglob
        if [ "${#candidates[@]}" -eq 1 ]; then
            GAME_IMAGE="${candidates[0]}"
        elif [ "${#candidates[@]}" -gt 1 ]; then
            echo "error: multiple disc images found at the repo root; set GAME_IMAGE=path/to/image" >&2
            printf '  - %s\n' "${candidates[@]}" >&2
            exit 1
        fi
    fi

    if [ -n "${GAME_IMAGE:-}" ] && command -v wit >/dev/null 2>&1; then
        if ! verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" ||
           ! verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            echo "==> extracting $GAME_IMAGE (this only needs to happen once)"
            rm -rf extracted
            wit EXTRACT "$GAME_IMAGE" -D extracted
        fi
        if verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" &&
           verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            mkdir -p Assets
            cp -f extracted/DATA/sys/main.dol Assets/main.dol
            cp -f extracted/DATA/files/rel/StaticR.rel Assets/StaticR.rel
        else
            echo "error: $GAME_IMAGE did not produce a clean PAL RMCP01 main.dol/StaticR.rel (wrong region/revision?)" >&2
        fi
    fi
fi

# files that need to be dumped from PAL RMCP01 disc
if ! have_assets; then
    echo "error: missing game files under Assets/" >&2
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256"     || echo "  - Assets/main.dol     (expected sha256 $EXPECTED_DOL_SHA256)" >&2
    verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"  || echo "  - Assets/StaticR.rel  (expected sha256 $EXPECTED_REL_SHA256)" >&2
    echo "" >&2
    echo "place a clean PAL RMCP01 disc image (ISO/WBFS/RVZ/...) at the repo root and re-run" >&2
    echo "(needs the 'wit' package - Wiimms ISO Tools), or extract it yourself:" >&2
    echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
    echo "  or CLI:  wit EXTRACT your-game.iso -D ./extracted" >&2
    echo "then copy extracted/DATA/sys/main.dol and extracted/DATA/files/rel/StaticR.rel into Assets/" >&2
    echo "verify with: sha256sum Assets/main.dol Assets/StaticR.rel" >&2
    exit 1
fi

# Fetch llvm-mingw locally if it isn't already present
if [ ! -x "$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang++" ]; then
    echo "==> fetching llvm-mingw (not found at $TOOLCHAIN_DIR)"
    asset_url=$(curl -sL https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest \
        | jq -r '.assets[].browser_download_url' \
        | grep -E 'ucrt-ubuntu-[0-9.]+-x86_64\.tar\.xz$' \
        | head -n1)
    if [ -z "$asset_url" ]; then
        echo "error: could not find an llvm-mingw ucrt/ubuntu/x86_64 release asset" >&2
        exit 1
    fi
    tmp_archive="$(mktemp --suffix=.tar.xz)"
    tmp_extract="$(mktemp -d)"
    curl -sL -o "$tmp_archive" "$asset_url"
    tar -xf "$tmp_archive" -C "$tmp_extract"
    rm -f "$tmp_archive"
    mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
    rm -rf "$TOOLCHAIN_DIR"
    mv "$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)" "$TOOLCHAIN_DIR"
    rm -rf "$tmp_extract"
fi

# runtime/src/music_attenuation.cpp uses C++/WinRT (winrt/Windows.Media.Control.h)
# for the music-ducking feature. llvm-mingw doesn't ship the Windows SDK's
# generated WinRT projection headers, so fetch the community mingw-w64-cppwinrt
# project's prebuilt header set (github.com/alvinhochun/mingw-w64-cppwinrt)
if [ ! -f "$CPPWINRT_DIR/winrt/base.h" ]; then
    echo "==> fetching mingw-w64-cppwinrt headers (not found at $CPPWINRT_DIR)"
    # take the newest entry from the full release list
    asset_url=$(curl -sL https://api.github.com/repos/alvinhochun/mingw-w64-cppwinrt/releases \
        | jq -r '[.[] | select(.assets[].name | test("-headers\\.tar\\.gz$"))][0].assets[].browser_download_url' \
        | grep -E '\-headers\.tar\.gz$' \
        | head -n1)
    if [ -z "$asset_url" ]; then
        echo "error: could not find a mingw-w64-cppwinrt headers release asset" >&2
        exit 1
    fi
    tmp_archive="$(mktemp --suffix=.tar.gz)"
    tmp_extract="$(mktemp -d)"
    curl -sL -o "$tmp_archive" "$asset_url"
    tar -xzf "$tmp_archive" -C "$tmp_extract"
    rm -f "$tmp_archive"
    cppwinrt_src="$(dirname "$(dirname "$(find "$tmp_extract" -type f -path '*/winrt/base.h' | head -n1)")")"
    if [ -z "$cppwinrt_src" ] || [ ! -f "$cppwinrt_src/winrt/base.h" ]; then
        echo "error: mingw-w64-cppwinrt archive did not contain winrt/base.h" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$CPPWINRT_DIR")"
    rm -rf "$CPPWINRT_DIR"
    mv "$cppwinrt_src" "$CPPWINRT_DIR"
    rm -rf "$tmp_extract"
fi

# Build the translator CLI once if it hasn't been built yet.
if [ ! -f "$TRANSLATOR_DLL" ]; then
    echo "==> building translator"
    dotnet build translator/src/Translator.Cli/Translator.Cli.csproj -c Release
fi

PUL_SHA=""
if [ "$RETRO" = "1" ]; then
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        echo "==> $RETRO_ROOT is missing Binaries/Code.pul; downloading Retro Rewind from update.rwfc.net"
        tmp_archive="$(mktemp --suffix=.zip)"
        tmp_extract="$(mktemp -d)"
        curl -L -o "$tmp_archive" "https://update.rwfc.net/RetroRewind/zip/RetroRewind.zip"
        unzip -q "$tmp_archive" "RetroRewind6/*" -d "$tmp_extract"
        rm -f "$tmp_archive"
        if [ ! -f "$tmp_extract/RetroRewind6/Binaries/Code.pul" ]; then
            echo "error: downloaded Retro Rewind archive did not contain RetroRewind6/Binaries/Code.pul" >&2
            rm -rf "$tmp_extract"
            exit 1
        fi
        # Don't delete RETRO_ROOT if it already exists
        mkdir -p "$RETRO_ROOT"
        cp -rn "$tmp_extract/RetroRewind6/." "$RETRO_ROOT/"
        rm -rf "$tmp_extract"
    fi
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        echo "error: --retro needs a Retro Rewind install with Binaries/Code.pul" >&2
        echo "  place your RetroRewind6 folder at $RETRO_ROOT" >&2
        echo "  or point RETRO_ROOT at an existing one: RETRO_ROOT=/path/to/RetroRewind6 ./build.sh --retro" >&2
        exit 1
    fi
    # The project manifest's retro-rewind profile always reads Code.pul from
    # PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries
    STAGED_PUL="PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries/Code.pul"
    if [ "$(readlink -f "$RETRO_ROOT/Binaries/Code.pul")" != "$(readlink -f "$STAGED_PUL" 2>/dev/null || true)" ]; then
        mkdir -p "$(dirname "$STAGED_PUL")"
        cp -f "$RETRO_ROOT/Binaries/Code.pul" "$STAGED_PUL"
    fi
    PUL_SHA=$(sha256sum "$RETRO_ROOT/Binaries/Code.pul" | cut -d' ' -f1)
fi

# Translate the DOL/REL into generated/ if that hasn't been done yet, or (for
# a Retro Rewind build) if the existing translation predates this Code.pul.
NEED_BASE_TRANSLATE=0
if [ ! -f "generated/base_translation_output.json" ]; then
    NEED_BASE_TRANSLATE=1
elif [ "$RETRO" = "1" ] && ! grep -q "\"codePulSha256\":\"$PUL_SHA\"" generated/base_translation_output.json; then
    echo "==> base translation predates this Code.pul; retranslating"
    NEED_BASE_TRANSLATE=1
fi

if [ "$NEED_BASE_TRANSLATE" = "1" ]; then
    echo "==> translating Assets/main.dol"
    entry_addr=$(grep -A1 '^\s*entry_points:' "$PROJECT_MANIFEST" | tail -n1 | grep -oE '0x[0-9A-Fa-f]+')
    dotnet "$TRANSLATOR_DLL" translate-recursive "$entry_addr" --project "$PROJECT_MANIFEST" \
        --output-metadata generated/base_translation_output.json \
        --production-source-bundle generated/base_translation_sources.bin
fi

dotnet "$TRANSLATOR_DLL" generate-data-init --project "$PROJECT_MANIFEST"

if [ "$RETRO" = "1" ]; then
    mkdir -p build/base
    if [ ! -f "build/base/mkwii_base_manifest.json" ] || [ "$NEED_BASE_TRANSLATE" = "1" ]; then
        dotnet "$TRANSLATOR_DLL" emit-base-manifest --project "$PROJECT_MANIFEST"
    fi
    echo "==> translating Retro Rewind Code.pul"
    retro_mod_args=(translate-mod --project "$PROJECT_MANIFEST" --profile retro-rewind
        --base-manifest build/base/mkwii_base_manifest.json
        --base-translation-output-metadata generated/base_translation_output.json
        --code-pul "$RETRO_ROOT/Binaries/Code.pul" --mod-root "$RETRO_ROOT" --mod-name "Retro Rewind"
        --region P --out "$RETRO_OUT" --emit-cpp)
    if [ "$RETRO_SKIP_WFC" = "1" ]; then
        retro_mod_args+=(--skip-retro-wfc)
    fi
    dotnet "$TRANSLATOR_DLL" "${retro_mod_args[@]}"
fi

NEED_SHARDS=0
if [ ! -f "generated/build_shards/shards.cmake" ]; then
    NEED_SHARDS=1
elif [ "$RETRO" = "1" ] && ! grep -q "MKW_HAVE_RETRO_REWIND_SHARDS ON" generated/build_shards/shards.cmake; then
    NEED_SHARDS=1
fi

if [ "$NEED_SHARDS" = "1" ]; then
    shard_args=(emit-build-shards --project "$PROJECT_MANIFEST")
    if [ "$RETRO" = "1" ]; then
        shard_args+=(--resolved-profile "$RETRO_OUT/resolved_dispatch_profile.json" --retro-cpp-dir "$RETRO_OUT/cpp")
    fi
    dotnet "$TRANSLATOR_DLL" "${shard_args[@]}"
fi

cmake -S runtime -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-windres" \
    -DCMAKE_FIND_ROOT_PATH="$TOOLCHAIN_DIR/x86_64-w64-mingw32" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DAURORA_DAWN_PROVIDER=package \
    -DMKW_CPPWINRT_INCLUDE_DIR="$CPPWINRT_DIR"

cmake --build "$BUILD_DIR"

# Portable config, pre-filled with the paths this build already knows about.
# Only enabled (via portable.txt) for --package, without it, this
# just stages a Config.toml for --package to read below, and the exe here in
# $BUILD_DIR keeps using its normal (%LOCALAPPDATA%\WiiCompiled or Wine-prefix
# equivalent) config location instead of $BUILD_DIR/UserData
mkdir -p "$BUILD_DIR/UserData"
if [ "$PACKAGE" = "1" ]; then
    touch "$BUILD_DIR/portable.txt"
fi
CONFIG_FILE="$BUILD_DIR/UserData/Config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    dvd_root_line='# dvd_root = "D:/MarioKartWii/DATA"'
    if [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]; then
        dvd_root_line="dvd_root = \"$(realpath --relative-to="$BUILD_DIR/UserData" "extracted/DATA")\""
    fi
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# WiiCompiled user configuration (generated by build.sh; portable mode)
# Set paths.dvd_root to an extracted Mario Kart Wii DATA directory.

[video]
widescreen = true
resolution_multiplier = 1.0
frame_interpolation_fps = 0
display_mode = "windowed"
graphics_api = "auto"
skip_unready_pipelines = true
disable_copy_filter = true
show_fps = true
texture_replacements = false
texture_dumps = false

[audio]
volume = 1.0
music_volume = 1.0
sound_effects_volume = 1.0
ui_volume = 1.0
voices_volume = 1.0
muted = false
attenuate_music_when_media_plays = false
mix_worker = true

[network]
enabled = true

[paths]
$dvd_root_line
# nand_root = "D:/WiiNand"
# retro_rewind_root = "D:/RetroRewind/RetroRewind6"
# overlay_roots = ["D:/RetroRewind"]
EOF_CONFIG
    echo "==> wrote portable config: $CONFIG_FILE"
fi

if [ "$RETRO" = "1" ] && ! grep -q '^retro_rewind_root' "$CONFIG_FILE"; then
    retro_root_value="$(realpath --relative-to="$BUILD_DIR/UserData" "$RETRO_ROOT")"
    sed -i "/^\[paths\]/a retro_rewind_root = \"$retro_root_value\"" "$CONFIG_FILE"
    echo "==> set retro_rewind_root in $CONFIG_FILE"
fi

if [ "$PACKAGE" = "1" ]; then
    if [ ! -d "extracted/DATA/sys" ] || [ ! -d "extracted/DATA/files" ]; then
        echo "error: --package needs extracted/DATA (place a disc image at the repo root and re-run)" >&2
        exit 1
    fi
    PACKAGE_DIR="dist/WiiCompiled"
    echo ""
    echo "==> packaging a portable copy at $PACKAGE_DIR (this could takes a while)"
    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/UserData"
    cp -f "$BUILD_DIR"/*.exe "$BUILD_DIR"/*.dll "$BUILD_DIR/dsp_coef.bin" "$BUILD_DIR/initial_pipeline_cache.db" "$PACKAGE_DIR/"
    cp -r "$BUILD_DIR/wii_bootstrap" "$PACKAGE_DIR/wii_bootstrap"
    touch "$PACKAGE_DIR/portable.txt"
    cp -r "extracted/DATA" "$PACKAGE_DIR/DATA"

    package_paths=('dvd_root = "../DATA"')
    if [ "$RETRO" = "1" ]; then
        echo "==> copying RetroRewind6 ($(du -sh "$RETRO_ROOT" | cut -f1))"
        cp -r "$RETRO_ROOT" "$PACKAGE_DIR/RetroRewind6"
        package_paths+=('retro_rewind_root = "../RetroRewind6"')
    fi
    sed "/^\[paths\]/,\$d" "$CONFIG_FILE" > "$PACKAGE_DIR/UserData/Config.toml"
    { echo "[paths]"; printf '%s\n' "${package_paths[@]}"; } >> "$PACKAGE_DIR/UserData/Config.toml"

    echo "==> zipping $PACKAGE_DIR"
    rm -f "dist/WiiCompiled.zip"
    (cd dist && zip -rq -1 "WiiCompiled.zip" "WiiCompiled")
    rm -rf "$PACKAGE_DIR"
    echo "==> packaged: dist/WiiCompiled.zip ($(du -sh dist/WiiCompiled.zip | cut -f1))"
fi

echo "Build complete! Find it at $BUILD_DIR/WiiCompiled.exe"
if [ "$RETRO" = "1" ]; then
    echo "Retro Rewind build at $BUILD_DIR/RetroRewind.exe"
fi

if [ "$PACKAGE" != "1" ]; then
    echo ""
    echo "This exe will NOT work if moved on its own - it needs $BUILD_DIR/ (DLLs, wii_bootstrap/,"
    echo "dsp_coef.bin, initial_pipeline_cache.db, UserData/Config.toml) and the game data/mod"
    echo "folders Config.toml points at, all kept alongside it."
    echo "Re-run with --package for a single self-contained, movable copy instead."
fi
