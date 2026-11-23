# Decisiones técnicas

Formato: fecha — decisión — motivo. Las más recientes al final.

## 2026-11-23 — Implementación inicial (fases 0–6 y parte de la 7)

### Protocolo
- **El transporte lo decide la Mac por la dirección remota**, no por el campo `transport` del HELLO. Loopback (`127.0.0.1`/`::1`) = USB (es lo que entrega `adb reverse`); cualquier otra dirección = Wi-Fi y exige token. Motivo: un cliente en la LAN no puede falsificar una dirección loopback, pero sí podría mentir en el JSON.
- **Un solo listener.** Sin Wi-Fi escucha solo en la interfaz loopback (`requiredInterfaceType = .loopback`); con Wi-Fi escucha en todas y se anuncia por Bonjour. Motivo: dos listeners en el mismo puerto (loopback + todas) chocan; uno solo es más simple.
- **Un cliente nuevo y válido reemplaza al anterior** (BYE 4). Motivo: al re-conectar el cable, el socket viejo puede tardar en morir; rechazar al nuevo dejaría la tablet sin imagen hasta el timeout.
- **SCROLL en píxeles del stream** (no "puntos" ambiguos). La Mac convierte a sus puntos. `momentum` con `dx = dy = 0` marca el fin de la inercia. Motivo: la tablet no conoce el preset de la Mac; así la conversión vive en un solo lugar.
- **Cambiar códec, fps, preset o modo = BYE 6 y renegociar**, en vez de un mensaje de reconfiguración. Motivo: la tablet ya reconecta en milisegundos; evita una máquina de estados extra en ambos lados.
- **Keepalive de 5 s en ambos lados** apoyado en el PING de 1 s. Tipos de mensaje desconocidos se ignoran (permite extensiones compatibles).
- Se agregaron vectores de prueba en `PROTOCOL.md`; Android (JUnit) y Mac (XCTest) los verifican.

### Mac
- **Monitor virtual:** los modos se registran primero en puntos; si macOS no ofrece el modo HiDPI (puntos = w, píxeles = 2w), se re-registran en píxeles. Luego se busca y activa explícitamente ese `CGDisplayMode`. Motivo: no está documentado cómo interpreta `CGVirtualDisplayMode` con `hiDPI = 1`; así funciona en ambos casos y el log dice cuál fue (verificación empírica pendiente en hardware real).
- Las clases privadas se declaran `weak_import` y se comprueban con `NSClassFromString`/`instancesRespond(to:)` antes de usarlas. Motivo: si macOS las elimina, la app arranca igual y muestra un error claro (el modo Duplicar sigue funcionando).
- **Modo Duplicar = capturar la pantalla principal**, no `CGConfigureDisplayMirrorOfDisplay`. Motivo: una pantalla en espejo puede no aparecer en `SCShareableContent`; capturar la principal siempre funciona. Si la proporción difiere, SCK agrega barras y la entrada se mapea al rectángulo de contenido.
- **`queueDepth = 4`** (el plan decía 3). Motivo: se retiene el último `CVPixelBuffer` para re-codificarlo como keyframe; con 3 el pool podría quedarse sin buffers.
- **Refresco de calidad:** si la pantalla queda quieta 250 ms, se re-codifica el último cuadro (máximo 2 veces). Motivo: con control de tasa de baja latencia el primer cuadro tras un cambio grande sale borroso; repetirlo lo afina y cuesta casi nada (SCK no manda cuadros si no hay cambios).
- **Keyframe bajo demanda inmediato:** además de marcar `ForceKeyFrame`, se re-codifica el último buffer. Motivo: con pantalla quieta no llegaría ningún cuadro nuevo.
- **H.264 Constrained High** (High sin B-frames) con fallback a High; CABAC; VUI BT.709; `DataRateLimits` = 1.5× el promedio por segundo. Motivo: compatibilidad máxima con el decodificador, colores correctos y ráfagas acotadas que no llenen el socket.
- Los PTS al codificador se fuerzan crecientes (`max(pts, último + 1 µs)`), porque una re-codificación puede llevar un tiempo posterior a la siguiente captura.
- **Gestos (resueltos en la Mac):** tap = clic en el punto donde bajó el dedo; arrastre si se mueve > 10 pt (empieza en el punto inicial, no se pierde precisión); mantener 0.5 s quieto = mantener el botón; doble clic por `mouseEventClickState` (0.5 s, 16 pt); tap de 2 dedos < 0.35 s sin scroll = clic derecho; 3 dedos no hace nada (la tablet lo usa para el overlay). S Pen: eventos inmediatos sin umbrales; botón lateral = botón derecho. Al bajar el primer dedo el cursor se mueve ahí, para que el scroll de 2 dedos vaya a la ventana correcta.
- **Scroll:** `CGEvent` en píxeles con fases (`scrollPhase`/`momentumPhase`) para que Safari y demás tengan rebote e inercia nativos; las fracciones de píxel se acumulan.
- **Presión del S Pen:** siempre en `mouseEventPressure`; el subtipo de tableta es opcional (ajuste experimental) porque sin eventos de proximidad algunas apps lo tratan raro.
- **Bitrate adaptativo en Wi-Fi:** empieza en 75 % del máximo; baja a 70 % si el socket se atrasa o el RTT pasa de max(2× base, base + 30 ms); sube 15 % tras 5 s estables. Mínimo 4 Mbps.
- **Token de emparejamiento en UserDefaults**, no en el Llavero. Motivo: uso personal; el Llavero pide confirmación cada vez que cambia la firma en desarrollo. Se compara en tiempo constante y se puede revocar desde el menú.
- **`adb` con salida a archivos temporales**, no a pipes. Motivo: cuando `adb devices` arranca el servidor de adb, el daemon podría heredar el pipe y la lectura no terminaría nunca.
- Swift 5 con concurrencia estricta mínima; el estado del servicio vive en una cola serial (`DisplayService.queue`), la UI en `@MainActor`.
- Las pruebas (XCTest) compilan `Protocol.swift` y `GestureResolver.swift` directamente, sin app anfitriona: no abren puertos ni crean monitores.

### Android
- **Sin AndroidX.** No hizo falta: `Activity`, `SurfaceView` y `WindowInsetsController` bastan con minSdk 31.
- **targetSdk 36 + `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY`.** Android 16 ignora la orientación fija en pantallas grandes para apps con targetSdk 36; esta propiedad (exclusión temporal) mantiene el modo horizontal. Si Google la retira, la app igual funciona en vertical (el video se ajusta con barras) hasta implementar el modo vertical de la Fase 7.
- **Render solo del último cuadro:** las salidas del decodificador se juntan en el hilo del Handler y un `drain` posterior renderiza la última y descarta las demás.
- **Claves de Qualcomm** (`vendor.qti-ext-dec-low-latency.enable`, `vendor.qti-ext-dec-picture-order.enable`) además de `KEY_LOW_LATENCY`, `KEY_PRIORITY = 0` y `KEY_OPERATING_RATE` máximo. Si `configure` falla con ellas, se reintenta con un formato mínimo.
- **Atraso del decodificador** = más de 6 cuadros entregados sin salir (medido por PTS, no con un contador que pueda desfasarse) o 100 ms sin buffer de entrada → flush, KEYFRAME_REQUEST y descartar hasta el siguiente keyframe.
- **Latencia por cuadro** con `OnFrameRenderedListener` (momento real en que se mostró), no al liberar el buffer.
- **Panel siempre a su tasa máxima** (`preferredDisplayModeId` + `Surface.setFrameRate`), aunque el stream sea de 60 fps. Motivo: a 120 Hz un cuadro espera como máximo 8 ms al vsync en lugar de 16 ms.
- **Rechazo de palma:** con el S Pen cerca (hover) o usado hace < 400 ms se ignoran los dedos.
- **Inercia en la tablet** con decaimiento 0.998 por ms (como iOS/macOS), integrada exactamente por intervalo para que no dependa de los fps.
- Prioridad conexión: USB (`127.0.0.1`) primero, luego Wi-Fi (NSD) si hay token. Reintento cada 500 ms; 3 s tras un rechazo.
- El token se guarda en `SharedPreferences`, excluido de respaldos y transferencias (`dataExtractionRules`).

## 2026-11-23 — Primera prueba en hardware: HELLO debe ir primero

- **Bug:** el hilo emisor de Android mandaba un PING al arrancar, antes que el HELLO; la Mac lo trataba como error de protocolo (BYE 1) y la tablet reintentaba sin fin. Los simuladores no lo detectaron porque `mock_tablet.py` sí manda HELLO primero.
- **Arreglo:** la tablet escribe el HELLO directamente en el socket antes de arrancar el hilo emisor. La Mac, por robustez, antes del HELLO responde PING, cierra con BYE e ignora lo demás (documentado en PROTOCOL.md; no rompe compatibilidad).

## 2026-11-23 — Sin fila en el codificador

- **Observado:** HEVC a 120 Hz con 2800 × 1752 dio 51 ms de "codificación" por cuadro, 82 fps y retraso notable con el S Pen. El codificador recibía más cuadros de los que procesa y se formaba una fila.
- **Decisión:** como máximo 2 cuadros dentro del codificador. Si llega una captura con el codificador lleno, se guarda solo la más reciente y se codifica en cuanto sale un cuadro; las intermedias se descartan (cuentan en "Descartados"). El menú indica si el códec no aceptó el modo de baja latencia.
- **Recomendación vigente:** H.264 a 60 Hz como configuración por defecto; HEVC/120 Hz siguen siendo experimentos.

## 2026-11-23 — Entregar cada cuadro sin esperar al siguiente

- **Observado:** con H.264 a 60 Hz la "codificación" medía ~14 ms, casi un intervalo de cuadro (16.7 ms): señal de que VideoToolbox retenía cada cuadro hasta recibir el siguiente.
- **Decisión:** `VTCompressionSessionCompleteFrames(hasta el PTS del cuadro)` después de cada envío al codificador. Bloquea la cola de captura solo lo que tarda el hardware y garantiza que el último cuadro de un movimiento salga de inmediato.

## 2026-11-23 — Renderizar con la hora de la tablet, no con el PTS

- **Observado (log):** en `OnFrameRenderedListener`, `renderUs` era idéntico al PTS. `releaseOutputBuffer(index, true)` usa el PTS como hora de presentación deseada, y nuestro PTS es el reloj de la Mac (~6.8 días "en el futuro" para la tablet). La latencia calculada salía absurda y se descartaba ("—"), y SurfaceFlinger recibía horas de presentación sin sentido.
- **Decisión:** `releaseOutputBuffer(index, System.nanoTime())`: presentar en el siguiente vsync. El PTS sigue viajando por el decodificador solo para medir la latencia.

## 2026-11-23 — Offset de reloj por mínimo RTT

- **Observado (log):** el offset estimado saltaba ~200 ms entre muestras y la latencia aparecía en 306 ms un segundo y en 10 ms otro. El PONG comparte el socket con el video; con cuadros en camino llega tarde y sesga el offset (hasta RTT/2).
- **Decisión:** usar el offset de la muestra con menor RTT de las últimas 30 (como NTP), no la mediana de 10. Actualizado en PROTOCOL.md, la tablet y `mock_tablet.py`.

## Resultados de experimentos (Fase 3)

Mediciones en hardware real. La columna "vidrio a vidrio" se mide con cámara (`scripts/measure-latency.md`).

| Fecha | Transporte | Códec | fps | Bitrate | Vidrio a vidrio (mediana) | Captura → pantalla (overlay) | Notas |
|---|---|---|---|---|---|---|---|
| 2026-11-22 | USB | HEVC | 120 | 50 Mbps | — | — (medición aún rota) | Codificación 51 ms/cuadro, 82 fps enviados, 221 descartados; retraso notable con el S Pen. Antes de limitar la fila del codificador. |
| 2026-11-22 | USB | H.264 | 60 | 30 Mbps | pendiente | 12–18 ms típicos, picos ~55 ms | 58 fps enviados/mostrados, RTT ~3–4 ms, codificación de pocos ms con picos en cambios grandes. Gestos y S Pen OK. Configuración recomendada. |
| | USB | H.264 | 60 | 15 Mbps | | | |
| | USB | H.264 | 60 | 50 Mbps | | | |
| | USB | HEVC | 60 | 30 Mbps | | | |
| | Wi-Fi | H.264 | 60 | auto | | | |
