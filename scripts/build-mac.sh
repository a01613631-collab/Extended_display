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

# --- Firma ---
# Usa el Team ID de Config/Signing.xcconfig. Si falta o no es válido (p. ej. sigue el de ejemplo),
# lo detecta del certificado "Apple Development" del Llavero y reescribe el archivo.
# Sin certificado, firma ad-hoc (funciona, pero macOS vuelve a pedir permisos tras cada compilación).
SIGNING_FILE=Config/Signing.xcconfig
detect_team() {
  security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1
}
current_team=""
if [[ -f "$SIGNING_FILE" ]]; then
  current_team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' "$SIGNING_FILE" | head -n 1)
fi

SIGNING_OVERRIDES=()
if [[ ! "$current_team" =~ ^[A-Z0-9]{10}$ || "$current_team" == "ABCDE12345" ]]; then
  team=$(detect_team || true)
  if [[ -n "$team" ]]; then
    echo "DEVELOPMENT_TEAM = $team" > "$SIGNING_FILE"
    echo "✓ Team ID detectado del certificado Apple Development: $team (guardado en mac/$SIGNING_FILE)"
  else
    rm -f "$SIGNING_FILE"
    echo "! No hay certificado \"Apple Development\" en el Llavero: se firma ad-hoc."
    echo "  Funciona, pero macOS pedirá otra vez los permisos tras cada compilación. Para evitarlo:"
    echo "  Xcode → Settings → Accounts → tu Apple ID → Manage Certificates… → + → Apple Development,"
    echo "  y vuelve a correr este script."
    SIGNING_OVERRIDES=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
  fi
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
