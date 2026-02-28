#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/zig-out"
APPDIR="${BUILD_DIR}/AppDir"

APP_ID="dev.productdevbook.portkiller.linux"
APP_NAME="PortKiller"
BIN_NAME="portkiller-linux"
ICON_SRC="${ROOT_DIR}/AppIcon.svg"
DESKTOP_SRC="${ROOT_DIR}/${APP_ID}.desktop"
APPIMAGETOOL_BIN="${APPIMAGETOOL:-appimagetool}"

if ! command -v "${APPIMAGETOOL_BIN}" >/dev/null 2>&1; then
  echo "error: appimagetool not found. Install it or set APPIMAGETOOL=/path/to/appimagetool" >&2
  exit 1
fi

if [ ! -x "${BUILD_DIR}/bin/${BIN_NAME}" ]; then
  echo "error: ${BUILD_DIR}/bin/${BIN_NAME} not found. Run 'zig build install' first." >&2
  exit 1
fi

if [ ! -f "${ICON_SRC}" ]; then
  echo "error: missing icon file: ${ICON_SRC}" >&2
  exit 1
fi

if [ ! -f "${DESKTOP_SRC}" ]; then
  echo "error: missing desktop file: ${DESKTOP_SRC}" >&2
  exit 1
fi

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/scalable/apps"

install -m 0755 "${BUILD_DIR}/bin/${BIN_NAME}" "${APPDIR}/usr/bin/${BIN_NAME}"
install -m 0644 "${DESKTOP_SRC}" "${APPDIR}/usr/share/applications/${APP_ID}.desktop"
install -m 0644 "${ICON_SRC}" "${APPDIR}/usr/share/icons/hicolor/scalable/apps/${APP_ID}.svg"

cp "${APPDIR}/usr/share/applications/${APP_ID}.desktop" "${APPDIR}/${APP_ID}.desktop"
cp "${APPDIR}/usr/share/icons/hicolor/scalable/apps/${APP_ID}.svg" "${APPDIR}/${APP_ID}.svg"

cat > "${APPDIR}/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "${HERE}/usr/bin/portkiller-linux" "$@"
EOF
chmod 0755 "${APPDIR}/AppRun"

ARCH="$(uname -m)"
OUTPUT_PATH="${BUILD_DIR}/${APP_NAME}-${ARCH}.AppImage"

ARCH="${ARCH}" "${APPIMAGETOOL_BIN}" "${APPDIR}" "${OUTPUT_PATH}"

echo "AppImage created: ${OUTPUT_PATH}"
