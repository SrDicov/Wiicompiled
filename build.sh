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
for arg in "$@"; do
    case "$arg" in
        --retro) RETRO=1 ;;
        --retro-skip-wfc) RETRO=1; RETRO_SKIP_WFC=1 ;;
    esac
done
RETRO_ROOT="${RETRO_ROOT:-$(pwd)/PulsarPacks/completed/RetroRewind/RetroRewind6}"
RETRO_OUT="build/mods/retro_rewind_full_cpp"

# files that need to be dumped from PAL RMCP01 disc
if [ ! -f "Assets/main.dol" ] || [ ! -f "Assets/StaticR.rel" ]; then
    echo "error: missing game files under Assets/" >&2
    [ -f "Assets/main.dol" ]     || echo "  - Assets/main.dol     (expected sha256 80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05)" >&2
    [ -f "Assets/StaticR.rel" ]  || echo "  - Assets/StaticR.rel  (expected sha256 16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d)" >&2
    echo "" >&2
    echo "extract them from your own clean PAL RMCP01 disc image (ISO/WBFS/RVZ/...):" >&2
    echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
    echo "  or CLI:  wit EXTRACT your-game.iso ./extracted" >&2
    echo "then copy sys/main.dol and files/rel/StaticR.rel from the extracted tree into Assets/" >&2
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
# project's prebuilt header set (github.com/alvinhochun/mingw-w64-cppwinrt).
if [ ! -f "$CPPWINRT_DIR/winrt/base.h" ]; then
    echo "==> fetching mingw-w64-cppwinrt headers (not found at $CPPWINRT_DIR)"
    # This project has no non-prerelease build, so GitHub's /releases/latest
    # (which only ever resolves to a non-prerelease) 404s; take the newest
    # entry from the full release list instead.
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

echo "Build complete! Find it at $BUILD_DIR/WiiCompiled.exe"
if [ "$RETRO" = "1" ]; then
    echo "Retro Rewind build at $BUILD_DIR/RetroRewind.exe"
fi
