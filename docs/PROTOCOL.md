# Protocolo TabDisplay v1

Un solo socket TCP (puerto por defecto **47800**), `TCP_NODELAY` en ambos extremos. La **tablet es el cliente**, la **Mac es el servidor**. Todos los enteros son **big-endian**. Los `f32` son IEEE-754 big-endian.

## Encabezado (16 bytes, en todos los paquetes)

| Offset | Tipo | Campo | Descripción |
|---|---|---|---|
| 0 | u8 | `type` | Tipo de mensaje (tabla abajo) |
| 1 | u8 | `flags` | Depende del tipo |
| 2 | u16 | `reserved` | 0 |
| 4 | u32 | `length` | Bytes de payload que siguen |
| 8 | u64 | `timestampUs` | Reloj monotónico del emisor, en microsegundos |

Payload máximo: 8 MiB. Un `length` mayor = error de protocolo → cerrar conexión.

Relojes usados:
- Mac: reloj de host (`mach_absolute_time` / `CLOCK_UPTIME_RAW`), el mismo que usan los `CMSampleBuffer` de ScreenCaptureKit.
- Tablet: `System.nanoTime() / 1000`.

Un `type` desconocido se **ignora** (se lee y descarta su payload); así se pueden agregar mensajes opcionales sin romper compatibilidad.

## Tipos de mensaje

| type | Nombre | Dirección | Payload |
|---|---|---|---|
| 0x01 | HELLO | Tablet → Mac | JSON UTF-8 |
| 0x02 | HELLO_ACK | Mac → Tablet | JSON UTF-8 |
| 0x03 | CODEC_CONFIG | Mac → Tablet | Annex B: SPS + PPS (+ VPS en HEVC) |
| 0x04 | VIDEO_FRAME | Mac → Tablet | Annex B, una access unit completa |
| 0x10 | TOUCH | Tablet → Mac | Binario (ver abajo) |
| 0x11 | SCROLL | Tablet → Mac | Binario (ver abajo) |
| 0x20 | KEYFRAME_REQUEST | Tablet → Mac | vacío |
| 0x30 | PING | ambos | vacío (usa `timestampUs`) |
| 0x31 | PONG | ambos | u64 `echoTimestampUs` (el del PING recibido) |
| 0x40 | STATS | Tablet → Mac | JSON UTF-8 (ver abajo) |
| 0x7F | BYE | ambos | u8 código de motivo (ver abajo) |

### HELLO (tablet → Mac)
```json
{
  "protocolVersion": 1,
  "deviceName": "Galaxy Tab S8+",
  "widthPx": 2800,
  "heightPx": 1752,
  "densityDpi": 266,
  "refreshRates": [60, 120],
  "codecs": [
    {"mime": "video/avc",  "lowLatency": true, "max60": true, "max120": false},
    {"mime": "video/hevc", "lowLatency": true, "max60": true, "max120": true}
  ],
  "transport": "usb",
  "token": null
}
```
- `widthPx`/`heightPx`: tamaño físico del panel **en horizontal** (ancho ≥ alto).
- `transport` es informativo. **La Mac decide el transporte por la dirección remota**: una conexión desde loopback (`127.0.0.1`/`::1`, que es lo que entrega `adb reverse`) es USB; cualquier otra es Wi-Fi.
- `token` es `null` por USB y obligatorio por Wi-Fi (base64 de 32 bytes, recibido antes en `HELLO_ACK.pairingToken`).

La tablet debe mandar `HELLO` como **primer** mensaje, en cuanto conecta. Si la Mac no lo recibe en 5 s, cierra. Por robustez, antes del `HELLO` la Mac responde `PING` con `PONG`, cierra con `BYE` e ignora cualquier otro mensaje.

### HELLO_ACK (Mac → tablet)
```json
{
  "protocolVersion": 1,
  "accepted": true,
  "codec": "video/avc",
  "streamWidthPx": 2800,
  "streamHeightPx": 1752,
  "fps": 60,
  "bitrate": 30000000,
  "pairingToken": "base64-32-bytes",
  "macName": "MacBook Pro de José"
}
```
- `pairingToken` solo se envía cuando la conexión es USB (emparejamiento). Nunca por Wi-Fi.
- `macName` (opcional): nombre legible de la Mac, para mostrar en la tablet.
- Si `accepted` es `false`, se agrega `"reason"` (texto para mostrar), la Mac manda `BYE` y cierra.

Tras `HELLO_ACK`, la Mac manda `CODEC_CONFIG` y luego un `VIDEO_FRAME` keyframe.

### CODEC_CONFIG
Se manda antes de **cada** keyframe (aunque no haya cambiado). La tablet compara los bytes con el último recibido: si son iguales lo ignora; si cambian, reconfigura el decodificador. El códec, la resolución del stream y los fps **no cambian dentro de una sesión**: si el usuario los cambia en la Mac, ésta manda `BYE` con motivo `6` y la tablet reconecta de inmediato.

### VIDEO_FRAME flags
- bit 0: keyframe (IDR)
- `timestampUs`: momento de captura en la Mac (del `CMSampleBuffer`), **no** el de envío. Sirve para calcular latencia.

ScreenCaptureKit no entrega cuadros si la pantalla no cambia, así que puede haber segundos sin `VIDEO_FRAME`. La Mac puede re-codificar el último cuadro (un "refresco de calidad") con `timestampUs` = momento del re-codificado.

### TOUCH (20 bytes)
| Tipo | Campo | Valores |
|---|---|---|
| u8 | action | 0 down, 1 move, 2 up, 3 cancel, 4 hover_move, 5 hover_exit |
| u8 | pointerId | id del dedo / S Pen |
| u8 | toolType | 0 dedo, 1 stylus, 2 borrador |
| u8 | buttons | bit 0: botón lateral del S Pen |
| f32 | x | 0.0–1.0 (relativo al ancho del stream) |
| f32 | y | 0.0–1.0 |
| f32 | pressure | 0.0–1.0 |
| u32 | reserved | 0 |

- Se manda un `down`/`up` por cada dedo que entra/sale (Android `ACTION_POINTER_DOWN/UP` incluidos).
- `move` solo se manda mientras hay **un** dedo (con dos o más dedos el gesto es scroll o clic derecho y la posición no se usa).
- Los gestos (tap, doble clic, arrastre, clic derecho con 2 dedos) se **resuelven en la Mac** a partir de la secuencia de TOUCH, excepto el scroll, que la tablet ya manda como SCROLL.

### SCROLL (9 bytes)
| Tipo | Campo |
|---|---|
| f32 | dx |
| f32 | dy |
| u8 | phase: 0 began, 1 changed, 2 ended, 3 momentum |

- `dx`, `dy` están en **píxeles del stream** (el mismo espacio que `x × streamWidthPx`). La Mac los convierte a puntos de su pantalla: `puntos = px × anchoPantallaPuntos / streamWidthPx`.
- Signo: positivo = el contenido se mueve hacia la derecha/abajo (el dedo se movió hacia la derecha/abajo), como en una pantalla táctil.
- La inercia la calcula la tablet y la manda con fase `3`. Un `momentum` con `dx = dy = 0` marca **el fin** de la inercia. Si llega un `began` mientras hay inercia, la inercia terminó.

### STATS (tablet → Mac, cada 1 s)
```json
{"fpsReceived": 60.0, "fpsRendered": 59.8, "mbps": 21.4, "rttMs": 2.1, "latencyMs": 38.5, "droppedFrames": 0, "decoder": "c2.qti.avc.decoder"}
```
Todos los campos son opcionales; la Mac solo los muestra (y usa `rttMs` para ajustar el bitrate en Wi-Fi).

### BYE — códigos de motivo
| Código | Motivo |
|---|---|
| 0 | Cierre normal (la app se cerró) |
| 1 | Error de protocolo / parseo |
| 2 | Versión de protocolo incompatible |
| 3 | No autorizado (token inválido o ausente por Wi-Fi) |
| 4 | Reemplazado por otra conexión |
| 5 | La Mac se está apagando / desactivó el servicio |
| 6 | Reconfiguración: reconectar de inmediato |

## Medición de latencia
1. La tablet manda PING cada 1 s; la Mac responde PONG con `echoTimestampUs` (y su propio reloj en `timestampUs`).
2. RTT = ahora − echo. Offset de reloj ≈ `timestampUs(PONG) − (echo + RTT/2)`. Como el PONG comparte el socket con el video y puede llegar tarde (retraso asimétrico), se usa el offset de la muestra con **menor RTT** de las últimas 30 (como NTP), no la mediana.
3. Latencia por cuadro (captura → render) = `renderTimeTablet − (frame.timestampUs − offset)`.

## Reglas de robustez
- Cualquier error de parseo → BYE (1) y cerrar; el cliente reintenta.
- Keepalive: si un lado no recibe **ningún** byte en 5 s, cierra. (La tablet hace PING cada 1 s y la Mac responde PONG, así que ambos lados siempre reciben algo.)
- Si la tablet detecta corrupción o atraso del decodificador → KEYFRAME_REQUEST y descartar VIDEO_FRAME hasta el siguiente con bit keyframe.
- Si la Mac tiene > 2 cuadros sin enviar en el socket → descartar cuadros no-keyframe hasta poder enviar un keyframe nuevo.
- Un solo cliente a la vez. Si llega un cliente válido mientras hay otro, la Mac manda BYE (4) al anterior y se queda con el nuevo (un cable re-conectado suele dejar un socket viejo a medio morir).

## Vectores de prueba
Ambos lados tienen pruebas unitarias contra estos bytes (hex).

Encabezado de `KEYFRAME_REQUEST` con `timestampUs = 0x0102030405060708`:
```
20 00 0000 00000000 0102030405060708
```

`TOUCH` (sin encabezado): action=0 down, pointerId=1, toolType=1 stylus, buttons=1, x=0.5, y=0.25, pressure=1.0:
```
00 01 01 01 3F000000 3E800000 3F800000 00000000
```

`SCROLL` (sin encabezado): dx=-2.5, dy=10.0, phase=1 changed:
```
C0200000 41200000 01
```

`PONG` completo con `timestampUs = 1000`, `echoTimestampUs = 999`:
```
31 00 0000 00000008 00000000000003E8 00000000000003E7
```
