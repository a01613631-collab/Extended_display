#!/usr/bin/env bash
# Compila e instala la app en la tablet conectada por USB y la abre.
# Busca solo el JDK (17+) y el SDK de Android si JAVA_HOME / ANDROID_HOME no sirven.
set -euo pipefail
cd "$(dirname "$0")/../android"

# --- Java (JDK 17 o más nuevo) ---
java_ok() { [[ -n "${1:-}" && -x "$1/bin/java" ]]; }

if ! java_ok "${JAVA_HOME:-}"; then
  JAVA_HOME=""
  for candidate in \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home" \
    "$HOME/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home" \
    "$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)" \
    "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"; do
    if java_ok "$candidate"; then JAVA_HOME="$candidate"; break; fi
  done
fi
if [[ -z "${JAVA_HOME:-}" ]]; then
  echo "✗ No encontré un JDK 17 o más nuevo." >&2
  echo "  Opción A: instala Android Studio (trae su JDK): https://developer.android.com/studio" >&2
  echo "  Opción B: brew install openjdk@21" >&2
  exit 1
fi
export JAVA_HOME
echo "✓ Java: $JAVA_HOME"

# --- SDK de Android ---
sdk_ok() { [[ -n "${1:-}" && -d "$1" ]]; }

SDK=""
for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" \
  "/opt/homebrew/share/android-commandlinetools" "/usr/local/share/android-commandlinetools"; do
  if sdk_ok "$candidate"; then SDK="$candidate"; break; fi
done
if [[ -z "$SDK" ]]; then
  echo "✗ No encontré el SDK de Android." >&2
  echo "  Opción A: abre Android Studio una vez; descarga el SDK en ~/Library/Android/sdk." >&2
  echo "  Opción B: brew install --cask android-commandlinetools" >&2
  exit 1
fi
export ANDROID_HOME="$SDK"
echo "sdk.dir=$SDK" > local.properties
echo "✓ SDK de Android: $SDK"

# Gradle descarga solo las plataformas que falten, pero necesita las licencias aceptadas.
if [[ ! -f "$SDK/licenses/android-sdk-license" ]]; then
  sdkmanager=""
  for candidate in "$SDK/cmdline-tools/latest/bin/sdkmanager" "$SDK/cmdline-tools/bin/sdkmanager" "$(command -v sdkmanager || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && sdkmanager="$candidate" && break
  done
  if [[ -n "$sdkmanager" ]]; then
    echo "→ Aceptando licencias del SDK…"
    yes | "$sdkmanager" --sdk_root="$SDK" --licenses >/dev/null || true
  else
    echo "! Faltan las licencias del SDK y no encontré sdkmanager. Si la compilación falla por licencias,"
    echo "  abre Android Studio → Settings → Languages & Frameworks → Android SDK y acepta las licencias."
  fi
fi

# --- adb y tablet ---
ADB="$SDK/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
if [[ -z "$ADB" ]]; then
  echo "✗ No encontré adb: brew install android-platform-tools" >&2
  exit 1
fi
if ! "$ADB" devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'; then
  echo "✗ No hay ninguna tablet lista en 'adb devices'." >&2
  echo "  Conecta el cable (de datos), activa la Depuración USB y acepta \"¿Permitir depuración USB?\"." >&2
  exit 1
fi

./gradlew --quiet installDebug
"$ADB" shell am start -n dev.jose.tabdisplay/.MainActivity >/dev/null
echo "✓ TabDisplay instalada y abierta en la tablet"
