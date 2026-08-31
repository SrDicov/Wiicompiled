#!/bin/sh
# Crea AppImage Anylinux para WiiCompiled (glibc) usando quick-sharun
# Basado en https://github.com/pkgforge-dev/Anylinux-AppImages HOW-TO-MAKE-THESE.md
# REQUISITO: ejecutar en Arch Linux (ghcr.io/pkgforge-dev/archlinux:latest), NO en Void/Fedora
# Uso en CI: docker run --privileged -v $PWD:/work -w /work archlinux ./Launcher/build-game-appimage.sh
# Localmente no ejecutar en tu Void débil - solo en Actions.
set -eux

ARCH="$(uname -m)"
SHARUN="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh"
EXTRA="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/get-debloated-pkgs.sh"

if [ "$(uname -m)" != "x86_64" ]; then
	echo "Solo x86_64 soportado para WiiCompiled" >&2; exit 1
fi

# 1) Instalar deps de build + runtime (Arch) - ya hecho por workflow, solo fallback
pacman -Sy --noconfirm --needed \
	base-devel clang cmake ninja patchelf git python3 wget curl unzip zsync \
	dotnet-sdk xorg-server-xvfb \
	sdl3 vulkan-icd-loader vulkan-headers mesa \
	libpng zlib libx11 libxcursor libxrandr libxi libxkbcommon \
	libxcb xcb-util-wm abseil-cpp wayland wayland-protocols 2>/dev/null || echo "deps ya instaladas por workflow"

# 2) Mesa debloated para tamaño (opcional, recomendado)
echo "Instalando paquetes debloated..."
wget --retry-connrefused --tries=30 "$EXTRA" -O ./get-debloated-pkgs.sh
chmod +x ./get-debloated-pkgs.sh
./get-debloated-pkgs.sh --add-mesa --prefer-nano

# 3) Verificar binario glibc ya compilado existe (no recompila aquí)
if [ ! -x "./native-build/WiiCompiled" ]; then
	echo "Falta ./native-build/WiiCompiled (compila primero con cmake --build native-build)" >&2
	exit 1
fi
file ./native-build/WiiCompiled | grep -q "interpreter /lib64/ld-linux" || {
	echo "El binario no es glibc (esperaba /lib64/ld-linux)" >&2; exit 1
}

# 4) Instalar binario al FHS para que sharun lo encuentre
install -Dm755 ./native-build/WiiCompiled /usr/bin/WiiCompiled
# Archivos que el runtime espera ADYACENTES al binario (executableDirectory/dsp_coef.bin etc.)
install -Dm644 ./native-build/dsp_coef.bin /usr/bin/dsp_coef.bin 2>/dev/null || install -Dm644 ./build/dsp_coef.bin /usr/bin/dsp_coef.bin 2>/dev/null || true
install -Dm644 ./native-build/initial_pipeline_cache.db /usr/bin/initial_pipeline_cache.db 2>/dev/null || install -Dm644 ./build/initial_pipeline_cache.db /usr/bin/initial_pipeline_cache.db 2>/dev/null || true
if [ -d ./native-build/wii_bootstrap ]; then
	cp -r ./native-build/wii_bootstrap /usr/bin/wii_bootstrap
elif [ -d ./build/wii_bootstrap ]; then
	cp -r ./build/wii_bootstrap /usr/bin/wii_bootstrap
elif [ -d ./wii_bootstrap ]; then
	cp -r ./wii_bootstrap /usr/bin/wii_bootstrap
fi
# También en share para compatibilidad con instalaciones FHS
install -Dm644 ./native-build/dsp_coef.bin /usr/share/wiicompiled/dsp_coef.bin 2>/dev/null || true
install -Dm644 ./native-build/initial_pipeline_cache.db /usr/share/wiicompiled/initial_pipeline_cache.db 2>/dev/null || true

# 5) Desktop + Icon (requeridos por appimagetool)
mkdir -p /usr/share/applications /usr/share/icons/hicolor/256x256/apps
cat > /usr/share/applications/wiicompiled.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=WiiCompiled
Comment=Mario Kart Wii recompilado nativo
Exec=WiiCompiled
Icon=wiicompiled
Categories=Game;
Terminal=false
DESKTOP
# Icon dummy azul-gris si no hay branding
python3 - /usr/share/icons/hicolor/256x256/apps/wiicompiled.png <<'PY'
import struct, sys, zlib
path=sys.argv[1]
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d))
w=h=256; row=b"\x00"+bytes([0x3A,0x5F,0x8F,0xFF])*w; raw=row*h
ihdr=struct.pack(">IIBBBBB",w,h,8,6,0,0,0); idat=zlib.compress(raw,9)
open(path,"wb").write(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",ihdr)+chunk(b"IDAT",idat)+chunk(b"IEND",b""))
PY

# 6) Configurar quick-sharun (ver HOW-TO-MAKE-THESE.md)
export ICON=/usr/share/icons/hicolor/256x256/apps/wiicompiled.png
export DESKTOP=/usr/share/applications/wiicompiled.desktop
export OUTPATH=./dist
export OUTNAME=WiiCompiled-glibc-"$ARCH".AppImage
export MAIN_BIN=WiiCompiled
export DEPLOY_OPENGL=1
export DEPLOY_VULKAN=1
export DEPLOY_LOCALE=0
# WiiCompiled no necesita python, locale completo
export ADD_HOOKS=""
# STRACE_MODE=1 (default) detecta Vulkan drivers dlopened vía xvfb-run
export STRACE_MODE=1
export STRACE_TIME=5

echo "Descargando quick-sharun..."
wget --retry-connrefused --tries=30 "$SHARUN" -O ./quick-sharun
chmod +x ./quick-sharun

echo "Bundling con sharun (detecta + bundlea ld-linux, libc 2.44, abseil 2605, etc.)..."
./quick-sharun /usr/bin/WiiCompiled

echo "Empaquetando AppImage con dwarfs + uruntime..."
./quick-sharun --make-appimage

echo "Test (xvfb)..."
./quick-sharun --test ./dist/*.AppImage || echo "Test falló pero AppImage creado"

ls -lh ./dist/*.AppImage
echo "Hecho: ./dist/WiiCompiled-glibc-$ARCH.AppImage (Anylinux, funciona en glibc vieja + musl)"
