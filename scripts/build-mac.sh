#!/usr/bin/env bash
# Genera el proyecto con XcodeGen y compila la app de Mac desde terminal.
#   scripts/build-mac.sh            → compila (Debug)
#   scripts/build-mac.sh --test     → corre las pruebas unitarias
#   scripts/build-mac.sh --install  → compila Release, copia a /Applications y la abre
#
# Instalar siempre en /Applications con la misma firma evita que macOS pida otra vez
# los permisos de Grabación de pantalla y Accesibilidad.
set -euo pipefail
cd "$(dirname "$0")/../mac"

command -v xcodegen >/dev/null || { echo "✗ Falta XcodeGen: brew install xcodegen" >&2; exit 1; }

SIGNING_OVERRIDES=()
if [[ ! -f Config/Signing.xcconfig ]]; then
  echo "! No existe mac/Config/Signing.xcconfig: se firma ad-hoc."
  echo "  Los permisos se perderán en cada compilación. Copia Config/Signing.xcconfig.example"
  echo "  a Config/Signing.xcconfig y pon tu Team ID para evitarlo."
  SIGNING_OVERRIDES=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
elif grep -q "ABCDE12345" Config/Signing.xcconfig; then
  echo "✗ mac/Config/Signing.xcconfig todavía tiene el Team ID de ejemplo (ABCDE12345)." >&2
  echo "  Tu Team ID es el valor OU= de:" >&2
  echo "    security find-certificate -c \"Apple Development\" -p | openssl x509 -noout -subject" >&2
  echo "  Si dice que no encuentra el certificado: Xcode → Settings → Accounts → tu Apple ID →" >&2
  echo "  Manage Certificates… → + → Apple Development. O borra Signing.xcconfig para firmar ad-hoc." >&2
  exit 1
fi

# Evita el aviso de "multiple matching destinations" en Macs con Apple Silicon.
DESTINATION=(-destination "platform=macOS,arch=$(uname -m)")

xcodegen generate --quiet

pretty() {
  if command -v xcbeautify >/dev/null; then xcbeautify --quiet; else grep -E "error|warning: .*TabDisplay|BUILD|Test Suite|Executed|passed|failed" || true; fi
}

case "${1:-}" in
  --test)
    set -o pipefail
    xcodebuild -project TabDisplayMac.xcodeproj -scheme TabDisplayMac "${DESTINATION[@]}" -derivedDataPath build \
      ${SIGNING_OVERRIDES[@]+"${SIGNING_OVERRIDES[@]}"} test | pretty
    ;;
  --install)
    set -o pipefail
    xcodebuild -project TabDisplayMac.xcodeproj -scheme TabDisplayMac "${DESTINATION[@]}" -configuration Release \
      -derivedDataPath build -allowProvisioningUpdates ${SIGNING_OVERRIDES[@]+"${SIGNING_OVERRIDES[@]}"} build | pretty
    APP="build/Build/Products/Release/TabDisplay.app"
    pkill -x TabDisplay 2>/dev/null && sleep 1 || true
    rm -rf /Applications/TabDisplay.app
    cp -R "$APP" /Applications/
    echo "✓ Instalada en /Applications/TabDisplay.app"
    open /Applications/TabDisplay.app
    ;;
  *)
    set -o pipefail
    xcodebuild -project TabDisplayMac.xcodeproj -scheme TabDisplayMac "${DESTINATION[@]}" -configuration Debug \
      -derivedDataPath build -allowProvisioningUpdates ${SIGNING_OVERRIDES[@]+"${SIGNING_OVERRIDES[@]}"} build | pretty
    echo "✓ build/Build/Products/Debug/TabDisplay.app"
    ;;
esac
