# Medir la latencia "vidrio a vidrio"

La latencia que muestra el overlay (3 dedos) y el menú de la Mac es **captura → render**
(del `CMSampleBuffer` de ScreenCaptureKit al momento en que SurfaceFlinger muestra el cuadro),
calculada con el offset de reloj de PING/PONG. No incluye lo que pasa antes de la captura
(composición de macOS, hasta ~1 cuadro) ni el tiempo de respuesta del panel de la tablet.
Para la cifra real se mide con una cámara.

## Método (cámara lenta)

1. Abre un cronómetro con milisegundos en un navegador, por ejemplo
   `https://www.google.com/search?q=stopwatch` o cualquier página de cronómetro en ms.
2. Pon TabDisplay en modo **Duplicar**: así el mismo cronómetro se ve a la vez en la Mac y en la tablet.
   (Duplicar captura la pantalla principal con el mismo pipeline que Extender, así que la cifra vale para ambos.)
3. Pon la tablet junto a la pantalla de la Mac, a la misma altura.
4. Graba con el celular en **cámara lenta** (240 fps si se puede) unos 10 s, encuadrando ambas pantallas.
5. Pausa el video en 10 momentos distintos y anota `t_mac − t_tablet` en cada uno.
   Descarta los cuadros donde algún número esté borroso (a mitad de un cambio).
6. La latencia es la **mediana** de las 10 diferencias.

Hazlo por USB y por Wi-Fi, con 60 Hz y (si lo pruebas) con 120 Hz.

## Registrar resultados

Anótalos en `docs/DECISIONS.md` con fecha, transporte, códec, fps, bitrate y la mediana, por ejemplo:

| Fecha | Transporte | Códec | fps | Bitrate | Mediana | Overlay (captura→render) |
|---|---|---|---|---|---|---|
| | USB | H.264 | 60 | 30 Mbps | | |

## Acumulación de retraso (criterio de la Fase 3)

Deja el escritorio extendido 10 minutos moviendo ventanas de vez en cuando y mira en el overlay que
"latencia" no crezca con el tiempo. Si crece, revisa "descartados" (la Mac descarta cuadros cuando el
socket se atrasa) y el log de la tablet: `adb logcat -s TabDisplay`.
