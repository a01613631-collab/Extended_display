#!/usr/bin/env bash
# Conexión USB manual (la app de Mac lo hace sola cada 2 s; esto es para depurar).
# Verifica la tablet en `adb devices`, hace `adb reverse` del puerto y abre la app de Android.
set -euo pipefail

PORT="${PORT:-47800}"
ACTIVITY="dev.jose.tabdisplay/.MainActivity"
ADB="${ADB:-$(command -v adb || true)}"
if [[ -z "$ADB" ]]; then
  for candidate in /opt/homebrew/bin/adb /usr/local/bin/adb "$HOME/Library/Android/sdk/platform-tools/adb"; do
    [[ -x "$candidate" ]] && ADB="$candidate" && break
  done
fi
if [[ -z "$ADB" || ! -x "$ADB" ]]; then
  echo "✗ No se encontró adb. Instálalo con: brew install android-platform-tools" >&2
  exit 1
fi

devices_output="$("$ADB" devices)"
ready=$(awk 'NR>1 && $2=="device" {print $1}' <<<"$devices_output")
unauthorized=$(awk 'NR>1 && $2=="unauthorized" {print $1}' <<<"$devices_output")

if [[ -n "$unauthorized" ]]; then
  echo "! Tablet sin autorizar ($unauthorized): acepta \"¿Permitir depuración USB?\" en la tablet."
fi
if [[ -z "$ready" ]]; then
  echo "✗ No hay tablets listas. Revisa el cable (debe ser de datos) y que la Depuración USB esté activa." >&2
  exit 1
fi

for serial in $ready; do
  model=$("$ADB" -s "$serial" shell getprop ro.product.model | tr -d '\r')
  "$ADB" -s "$serial" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
  echo "✓ $model ($serial): adb reverse tcp:$PORT activo"
  if "$ADB" -s "$serial" shell am start -n "$ACTIVITY" 2>&1 | grep -q "Error"; then
    echo "! No se pudo abrir la app. ¿Está instalada? (cd android && ./gradlew installDebug)"
  else
    echo "✓ App abierta en la tablet"
  fi
done
