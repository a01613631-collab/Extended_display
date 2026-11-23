#!/usr/bin/env bash
# Compila e instala la app en la tablet conectada por USB y la abre.
set -euo pipefail
cd "$(dirname "$0")/../android"
./gradlew --quiet installDebug
adb shell am start -n dev.jose.tabdisplay/.MainActivity >/dev/null
echo "✓ TabDisplay instalada y abierta en la tablet"
