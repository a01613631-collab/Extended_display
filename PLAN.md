# PLAN — TabDisplay (Tab S8+ como segundo monitor de la Mac)

## 0. Objetivo y metas medibles

Extender el escritorio de la Mac a la Galaxy Tab S8+ como un monitor más (arrastrar ventanas, Mission Control, etc.), con control táctil y S Pen.

| Meta | Mínimo aceptable | Ideal |
|---|---|---|
| Resolución | 2800 × 1752 px nítidos (HiDPI, "parece 1400 × 876") | Presets con más espacio (escalado) |
| Fluidez | 60 fps estables al mover ventanas | 120 fps experimental |
| Latencia "vidrio a vidrio" (USB) | < 80 ms | ~40–50 ms |
| Latencia (Wi-Fi) | < 120 ms | < 70 ms |
| Conexión | Conectar cable → funciona en < 3 s, sin teclear comandos | Reconexión automática |
| Entrada | Tap = clic, arrastrar, scroll con dos dedos | S Pen con hover y botón lateral |

### Supuestos (ajusta si no aplican)
- Mac con Apple Silicon y macOS 14 o superior.
- La tablet tiene activadas las **Opciones de desarrollador** y la **Depuración USB**.
- Uso exclusivamente personal: la app de Mac se firma con tu "Personal Team" de Xcode y la de Android se instala por `adb`.

## 1. Decisión de conexión

| Opción | Ancho de banda real | Latencia / estabilidad | Veredicto |
|---|---|---|---|
| **USB-C + `adb reverse`** | Sobrado para 20–40 Mbps de video | La más baja y constante; sin interferencia; además carga la tablet | **Principal** |
| **Wi-Fi local (LAN)** | Suficiente (Wi-Fi 5/6/6E) | Buena, pero con picos (jitter) según router, interferencia y ahorro de energía | **Secundaria** (sin cable) |
| Wi-Fi Direct | Bueno | macOS no ofrece Wi-Fi Direct con Android de forma práctica | Descartada |
| Bluetooth | ~1–2 Mbps útiles | Insuficiente para video de 2800 × 1752 | **Descartada** |

Ambos transportes usan **exactamente el mismo protocolo TCP** (`docs/PROTOCOL.md`); solo cambia a qué dirección se conecta la tablet.

## 2. Arquitectura detallada

### Mac (emisor) — Swift
1. **VirtualDisplayManager** — crea la pantalla con `CGVirtualDisplay` (API privada; declarar `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode`, `CGVirtualDisplay` en un bridging header).
   - Descriptor: nombre "Tab S8+", `maxPixelsWide/High` ≥ resolución del preset más grande, `sizeInMillimeters` ≈ 267 × 167 (para que macOS elija bien la escala), `vendorID/productID/serialNum` fijos (para que macOS recuerde la posición del monitor).
   - Settings: `hiDPI = 1`, modos en **puntos**: 1400 × 876 @60 (nativo 2x). Presets extra: 1600 × 1000 y 1680 × 1050 (más espacio, se reescala al capturar). **Verificar empíricamente** que los modos se interpretan en puntos.
   - Destruir la pantalla al desconectar (con un periodo de gracia configurable, p. ej. 10 s, para reconexiones).
2. **CaptureEngine** — `ScreenCaptureKit`:
   - Buscar el `SCDisplay` cuyo `displayID` coincida con el de la pantalla virtual.
   - `SCStreamConfiguration`: `width/height` en **píxeles** de la tablet (2800 × 1752), `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (evita conversiones), `minimumFrameInterval = 1/60`, `queueDepth = 3`, `showsCursor = true`, sin audio.
   - Ignorar cuadros cuyo `SCFrameStatus` no sea `.complete`. ScreenCaptureKit no manda cuadros si nada cambia: está bien, ahorra ancho de banda.
   - Guardar siempre el **último `CVPixelBuffer`** para poder re-codificarlo como keyframe cuando la tablet lo pida.
3. **VideoEncoder** — `VTCompressionSession`:
   - Empezar con **H.264** + `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` + `RequireHardwareAcceleratedVideoEncoder = true`.
   - Propiedades: `RealTime = true`, `AllowFrameReordering = false`, `ProfileLevel = H264_High_AutoLevel`, `ExpectedFrameRate = 60`, `AverageBitRate` (USB: 30 Mbps; Wi-Fi: 15–20 Mbps), `MaxKeyFrameIntervalDuration` grande (p. ej. 10 s; los keyframes se piden bajo demanda), `PrioritizeEncodingSpeedOverQuality = true` si está disponible.
   - Convertir la salida AVCC (longitud + NAL) a **Annex B** (start codes `00 00 00 01`). Extraer SPS/PPS del `CMFormatDescription` y mandarlos como `CODEC_CONFIG` cada vez que cambien y antes de cada keyframe.
   - **HEVC como experimento** (fase 3): intentar con low-latency; si `VTCompressionSessionCreate` falla (p. ej. -12902) reintentar sin esa bandera; si aun así no conviene, quedarse en H.264.
   - Nota de niveles: 2800 × 1752 @60 en H.264 requiere nivel 5.2; @120 excede 5.2 → 120 Hz probablemente requiera HEVC o menor resolución. La tablet reporta sus capacidades en el `HELLO`.
4. **Server** — `Network.framework` (`NWListener`/`NWConnection`), TCP con `noDelay = true`.
   - Modo USB: escuchar solo en `127.0.0.1:47800`.
   - Modo Wi-Fi: escuchar en la LAN y anunciar `_tabdisplay._tcp` por Bonjour; aceptar solo clientes con el token de emparejamiento.
   - Un solo cliente a la vez. Si el socket se atrasa (bytes pendientes > umbral), descartar cuadros P hasta el siguiente keyframe.
5. **InputInjector** — recibe toques normalizados (0..1), los mapea con `CGDisplayBounds(displayID)` y publica `CGEvent` (`leftMouseDown/Dragged/Up`, `mouseMoved`, `rightMouseDown/Up`, `scrollWheelEvent2` con unidades en píxeles). Requiere permiso de **Accesibilidad** (`AXIsProcessTrustedWithOptions`).
6. **DeviceWatcher** — cada 2 s ejecuta `adb devices` (ruta de `adb` configurable; por defecto la de Homebrew). Al detectar la tablet: `adb reverse tcp:47800 tcp:47800` y `adb shell am start -n dev.jose.tabdisplay/.MainActivity`.
7. **UI** — `MenuBarExtra` con: estado (desconectado / USB / Wi-Fi), preset de resolución, fps, bitrate, latencia medida, botón "Reconectar", interruptor "Wi-Fi", "Abrir al iniciar sesión".

### Tablet (receptor) — Kotlin
1. **MainActivity** — pantalla completa inmersiva, orientación horizontal fija, `FLAG_KEEP_SCREEN_ON`, sin animaciones. Pedir la tasa de refresco más alta (`preferredDisplayModeId` / `Surface.setFrameRate`).
2. **Connection** — hilo dedicado con prioridad alta. USB: conectar a `127.0.0.1:47800` y reintentar cada 500 ms. Wi-Fi: descubrir con `NsdManager` y conectar con token. En Wi-Fi mantener `WifiManager.WifiLock` en modo `WIFI_MODE_FULL_LOW_LATENCY`. `tcpNoDelay = true`.
3. **Handshake** — mandar `HELLO` con tamaño real en píxeles, densidad, tasas de refresco y, por cada códec (`video/avc`, `video/hevc`): si el decodificador soporta `FEATURE_LowLatency` y si `areSizeAndRateSupported(2800, 1752, 60/120)`.
4. **VideoDecoder** — `MediaCodec` en modo asíncrono, salida directa al `Surface` del `SurfaceView`.
   - `KEY_LOW_LATENCY = 1` (si se soporta), `KEY_PRIORITY = 0` (tiempo real), `KEY_OPERATING_RATE` alto.
   - Alimentar cada `VIDEO_FRAME` en cuanto llega; `CODEC_CONFIG` con `BUFFER_FLAG_CODEC_CONFIG`.
   - Renderizar cada salida en cuanto sale (`releaseOutputBuffer(index, true)`); si salen varias juntas, renderizar solo la última.
   - Si el decodificador se atrasa o hay error: vaciar, pedir `KEYFRAME_REQUEST` e ignorar todo hasta el siguiente keyframe.
5. **InputCapture** — `onTouchEvent` / `onGenericMotionEvent` (hover del S Pen) → mensajes `TOUCH` y `SCROLL`:
   - 1 dedo: tap = clic, arrastrar = arrastre.
   - 2 dedos deslizando = scroll (deltas en puntos); tap con 2 dedos = clic derecho.
   - S Pen: hover = mover cursor; botón lateral + tap = clic derecho; presión se envía aunque al principio la Mac la ignore.
6. **Overlay de depuración** (activable con 3 dedos): fps recibidos, fps renderizados, Mbps, RTT y latencia estimada.

## 3. Fases

Cada fase termina con: código compilando en ambos lados, criterios cumplidos, `docs/DECISIONS.md` actualizado y un commit de git.

### Fase 0 — Preparación y pruebas de concepto
- Crear la estructura del repo, `git init`, `.gitignore` (Xcode, Gradle, `local.properties`).
- `mac/project.yml` (XcodeGen), app sin sandbox, bridging header vacío, `Info.plist` con `LSUIElement = YES`.
- Proyecto Android mínimo que abre una pantalla negra a pantalla completa.
- `scripts/usb-connect.sh`: verifica `adb devices`, hace `adb reverse` y lanza la app.
- **Spike A:** crear la pantalla virtual 1400 × 876 HiDPI y confirmar que aparece en Ajustes del Sistema → Pantallas y que se le pueden arrastrar ventanas.
- **Aceptación:** ambas apps compilan desde terminal; el monitor virtual aparece y desaparece al abrir/cerrar la app.

### Fase 1 — Captura y codificación local (sin red)
- CaptureEngine + VideoEncoder sobre la pantalla virtual.
- Modo de prueba que escribe Annex B a `~/Desktop/test.h264` durante 10 s.
- **Aceptación:** `ffplay test.h264` (o QuickTime tras empaquetarlo) muestra la pantalla virtual nítida a 2800 × 1752; el log muestra ~60 fps al mover una ventana y tiempo de codificación por cuadro < 8 ms.

### Fase 2 — Primer video extremo a extremo por USB
- Implementar `docs/PROTOCOL.md` (framing, HELLO/HELLO_ACK, CODEC_CONFIG, VIDEO_FRAME, KEYFRAME_REQUEST) en ambos lados.
- Server en la Mac (127.0.0.1), cliente + MediaCodec en Android.
- **Aceptación:** con el cable conectado y `scripts/usb-connect.sh`, la tablet muestra el escritorio extendido; arrastrar una ventana a la tablet se ve fluido; desconectar y reconectar el cable recupera la imagen sin reiniciar apps.

### Fase 3 — Afinar latencia y fluidez
- PING/PONG para RTT y estimación de offset de reloj; con eso, la tablet calcula latencia captura→render por cuadro (timestamp del cuadro + offset).
- Overlay de depuración.
- Descarte de cuadros atrasados en ambos lados; keyframe bajo demanda usando el último `CVPixelBuffer`.
- Experimentos (documentar resultados en DECISIONS.md): bitrate 15/30/50 Mbps; H.264 vs HEVC; 120 Hz (modo virtual @120, `minimumFrameInterval = 1/120`, tablet en 120 Hz).
- Medición manual: ver `scripts/measure-latency.md` (grabar en cámara lenta un cronómetro en milisegundos visible en ambas pantallas).
- **Aceptación:** latencia vidrio a vidrio por USB < 80 ms medida con el método manual; sin acumulación de retraso tras 10 min de uso.

### Fase 4 — Entrada táctil y S Pen
- InputCapture (Android) + InputInjector (Mac). Pedir permiso de Accesibilidad con un mensaje claro en el menú.
- Gestos: tap, arrastre, scroll de 2 dedos (con inercia básica), clic derecho (2 dedos o botón del S Pen), hover del S Pen.
- **Aceptación:** se puede mover una ventana, hacer scroll en Safari y abrir un menú contextual solo desde la tablet; el cursor sigue al S Pen en hover.

### Fase 5 — Experiencia "conectar y listo"
- DeviceWatcher: detección automática del cable, `adb reverse` y lanzamiento de la app.
- MenuBarExtra completa, presets de resolución, recordar ajustes, "Abrir al iniciar sesión" (`SMAppService`).
- La app Android reintenta sola y muestra un mensaje simple mientras espera ("Esperando a la Mac…").
- **Aceptación:** desde cero (apps cerradas), conectar el cable → el escritorio aparece en la tablet en < 3 s sin tocar la terminal.

### Fase 6 — Modo Wi-Fi
- Emparejamiento una sola vez por USB: la Mac genera un token aleatorio y lo manda en `HELLO_ACK`; la tablet lo guarda.
- Bonjour (`_tabdisplay._tcp`) en la Mac, `NsdManager` en Android; conexión con token; WifiLock de baja latencia.
- Bitrate por defecto más bajo y ajuste simple: si el RTT sube o el socket se atrasa, bajar bitrate; si se estabiliza, subirlo poco a poco.
- **Aceptación:** sin cable, en la misma red, funciona con < 120 ms y sin cortes de más de 1 s en 10 min. Un dispositivo sin token es rechazado.

### Fase 7 — Opcional / pulido
- Modo vertical (pantalla virtual 876 × 1400).
- Presión del S Pen como evento de tableta en macOS.
- Atajo para alternar "extender" ↔ "espejo".
- Mensaje claro si la API privada falla tras una actualización de macOS.

## 4. Riesgos y cómo mitigarlos

| Riesgo | Mitigación |
|---|---|
| `CGVirtualDisplay` es privada y una actualización de macOS puede romperla | Aislada en un solo módulo; comprobar al arrancar que las clases y selectores existen y mostrar error claro. Revisar DeskPad/OpenDisplay si algo cambia. |
| Permisos de Grabación de pantalla y Accesibilidad se "pierden" al recompilar | Firmar siempre con la misma identidad (Personal Team), mismo bundle ID; nunca firma ad-hoc cambiante. |
| HEVC low-latency no disponible | H.264 low-latency es la base; HEVC solo si mejora medido. |
| 120 Hz excede el nivel H.264 o el decodificador | Tratarlo como experimento; 60 Hz es la meta firme. |
| Jitter en Wi-Fi | USB como modo principal; en Wi-Fi usar 5/6 GHz, Mac de preferencia por cable Ethernet al router, WifiLock de baja latencia. |
| Cable USB solo de carga o USB 2 lento | Usar un cable USB-C de datos de calidad; `adb devices` debe listar la tablet. |

## 5. Cómo trabajar con Claude Code

1. Crea la carpeta `tabdisplay/` con `CLAUDE.md`, `PLAN.md` y `docs/PROTOCOL.md`.
2. Instala requisitos: Xcode, Android Studio (para el SDK y JDK), `brew install android-platform-tools xcodegen ffmpeg`.
3. En la tablet: Ajustes → Acerca de la tablet → Información de software → toca 7 veces "Número de compilación" → Opciones de desarrollador → activa **Depuración USB**. Conecta el cable y acepta la huella RSA.
4. En la carpeta, abre Claude Code y pide: *"Lee CLAUDE.md, PLAN.md y docs/PROTOCOL.md. Haz un plan detallado solo para la Fase 0 y espera mi aprobación."* (usa el modo plan).
5. Al terminar cada fase: prueba tú los criterios de aceptación, haz commit y pide la siguiente fase.
