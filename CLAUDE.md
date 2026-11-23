# TabDisplay — contexto para Claude Code

Proyecto personal (uso interno, un solo usuario): usar una **Samsung Galaxy Tab S8+** como **segundo monitor extendido** de una **Mac con Apple Silicon**, con la menor latencia posible.

Lee siempre `PLAN.md` (fases y criterios de aceptación) y `docs/PROTOCOL.md` (protocolo binario) antes de tocar código. Trabaja **una fase a la vez** y no avances a la siguiente hasta cumplir los criterios de aceptación de la actual.

## Hardware objetivo

| | Valor |
|---|---|
| Tablet | Galaxy Tab S8+ (SM-X800), Snapdragon 8 Gen 1, Android 14+ |
| Panel | 12.4", 2800 × 1752 px, 16:10, hasta 120 Hz, Super AMOLED (~267 × 167 mm) |
| Conectividad tablet | USB-C 3.2, Wi-Fi 6E, Bluetooth 5.2, S Pen |
| Mac | Apple Silicon, macOS 14 o superior |

## Arquitectura (resumen)

```
MAC (emisor, Swift)                                   TABLET (receptor, Kotlin)
CGVirtualDisplay  ──► ScreenCaptureKit ──► VideoToolbox ──► TCP ──► MediaCodec ──► SurfaceView
(macOS cree que hay        (captura solo esa      (H.264 low-latency,      (USB vía adb reverse     (low-latency,     (pantalla
 un monitor real)           pantalla, 420v)        sin B-frames)            o Wi-Fi LAN)             render inmediato)  completa)
CGEvent (mouse/scroll) ◄────────────────────── TCP ◄────────────────────── eventos táctiles / S Pen
```

- **Transporte principal: cable USB-C** con `adb reverse tcp:47800 tcp:47800`. La tablet se conecta a `127.0.0.1:47800` y adb lo tuneliza por USB hasta la Mac.
- **Transporte secundario: Wi-Fi local** (mismo protocolo, descubrimiento por Bonjour/NSD, token de emparejamiento).
- **Bluetooth: descartado** (ancho de banda insuficiente para video de esta resolución).

## Reglas del proyecto

- **Sin dependencias de terceros** en el código de la app salvo AndroidX en Android. Nada de FFmpeg, WebRTC, etc. Solo frameworks del sistema.
- **Mac:** Swift + SwiftUI (`MenuBarExtra`), app **sin sandbox** (usa API privada, Accesibilidad y lanza `adb`). Proyecto generado con **XcodeGen** (`mac/project.yml`) y compilado con `xcodebuild` desde terminal; no dependas de clics en Xcode.
- **Android:** Kotlin, una sola `Activity` a pantalla completa, `SurfaceView` (no `TextureView`), Gradle wrapper, `minSdk 31`, `targetSdk` el más reciente disponible. Se instala con `./gradlew installDebug` (no va a Play Store).
- **API privada:** `CGVirtualDisplay` no es pública. Aíslala en un único archivo (`VirtualDisplayManager.swift` + bridging header) para que, si una actualización de macOS la rompe, solo haya que arreglar ese módulo.
- **Protocolo primero:** cualquier cambio de mensajes se refleja primero en `docs/PROTOCOL.md` y luego en ambos lados. Incrementa `protocolVersion` si rompes compatibilidad.
- **Latencia ante todo:** nunca metas buffers "por si acaso". Ninguna cola debe crecer sin límite; si hay atraso, se descartan cuadros y se pide keyframe.
- Código claro y legible. Identificadores en inglés, comentarios en español. Nada de abstracciones innecesarias.
- Registra decisiones técnicas no obvias en `docs/DECISIONS.md` (fecha, decisión, motivo).
- Proyectos de referencia para **estudiar ideas** (no copiar código; respeta sus licencias): `Stengo/DeskPad` (pantalla virtual), `peetzweg/opendisplay` (mismo concepto pero para iPad: CGVirtualDisplay + ScreenCaptureKit + VideoToolbox por TCP), `Genymobile/scrcpy` (decodificación de baja latencia en el lado que recibe video, framing).

## Comandos útiles

```bash
# Mac
cd mac && xcodegen generate && xcodebuild -scheme TabDisplayMac -configuration Debug build
scripts/build-mac.sh [--test | --install]      # lo mismo + pruebas XCTest / instalar en /Applications
log stream --predicate 'subsystem == "dev.jose.tabdisplay.mac"'
# Android
cd android && ./gradlew installDebug
cd android && ./gradlew testDebugUnitTest lintDebug
adb reverse tcp:47800 tcp:47800
adb shell am start -n dev.jose.tabdisplay/.MainActivity
adb logcat -s TabDisplay
# Probar un lado sin el otro
python3 scripts/mock_tablet.py --seconds 15     # tablet simulada contra la app de Mac
python3 scripts/mock_mac.py test.h264 --loop     # Mac simulada para la app de Android
```

## Estructura esperada

```
tabdisplay/
├── CLAUDE.md
├── PLAN.md
├── docs/
│   ├── PROTOCOL.md
│   └── DECISIONS.md
├── mac/
│   ├── project.yml
│   └── TabDisplayMac/
│       ├── App/            (MenuBarExtra, ajustes)
│       ├── Display/        (VirtualDisplayManager + bridging header)
│       ├── Capture/        (ScreenCaptureKit)
│       ├── Encode/         (VideoToolbox → Annex B)
│       ├── Net/            (servidor TCP, framing, Bonjour)
│       ├── Input/          (inyección de eventos CGEvent)
│       └── Device/         (detección de la tablet vía adb)
├── android/
│   └── app/src/main/java/dev/jose/tabdisplay/
│       ├── MainActivity.kt
│       ├── net/            (cliente TCP, framing)
│       ├── video/          (MediaCodec)
│       └── input/          (touch / S Pen → mensajes)
└── scripts/
    ├── usb-connect.sh
    ├── build-mac.sh / install-android.sh
    ├── mock_tablet.py / mock_mac.py / tdproto.py   (simuladores del protocolo, solo stdlib)
    └── measure-latency.md
```

Estado y uso: ver `README.md`. El código cubre las fases 0–6 y parte de la 7; los criterios de
aceptación que requieren hardware (Mac + tablet) están como checklist en el README.
