# TabDisplay

Usa una **Samsung Galaxy Tab S8+** como **segundo monitor extendido** de una **Mac con Apple Silicon**,
con control táctil y S Pen, por cable USB-C (principal) o Wi-Fi.

```
MAC (Swift)                                                      TABLET (Kotlin)
CGVirtualDisplay → ScreenCaptureKit → VideoToolbox H.264 ─TCP─→ MediaCodec → SurfaceView
CGEvent (clic, arrastre, scroll) ←──────────────────────── TCP ←─ toques / S Pen
```

- **Mac:** app de barra de menús (`mac/`). Crea un monitor virtual de 1400 × 876 pt HiDPI (2800 × 1752 px),
  lo captura, lo codifica en H.264 de baja latencia y lo manda por TCP. Recibe toques y los convierte en
  eventos de mouse. Detecta la tablet por `adb`, hace `adb reverse` y abre la app de Android sola.
- **Tablet:** app de una sola pantalla (`android/`). Decodifica por hardware y muestra cada cuadro en cuanto
  sale; manda toques, scroll con inercia y el S Pen (hover, presión, botón lateral).
- **Protocolo:** [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Decisiones: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Estado

**Funciona en el hardware real** (MacBook Pro con Apple Silicon + Galaxy Tab S8+ SM-X800, por USB), probado el 22–23 nov 2026:

| | Resultado |
|---|---|
| Escritorio extendido | Se ve en la tablet a 2800 × 1752, nítido (HiDPI 2×) |
| Fluidez | 58 fps enviados y mostrados con H.264 a 60 Hz |
| Latencia captura → pantalla | ~12–18 ms típicos, picos ocasionales de ~55 ms (overlay / menú) |
| Codificación | Pocos ms por cuadro; sube en cambios grandes de pantalla (mover ventanas, cambiar de app) |
| Gestos | Tap, doble tap, arrastre, scroll con 2 dedos, clic derecho con 2 dedos y S Pen (hover y trazo): funcionan |

**Configuración recomendada:** Extender · 1400 × 876 · **H.264** · **60 Hz** · **30 Mbps**.
HEVC a 120 Hz con 50 Mbps saturó el codificador de la Mac (51 ms por cuadro, ~82 fps, retraso notable
con el S Pen), por eso sigue marcado como experimental.

Pendiente de probar: reconexión del cable, arranque en frío, modo Wi-Fi, 10 minutos sin acumular retraso,
la grabación de prueba (Fase 1) y la medición vidrio a vidrio con cámara.

Además del hardware, el repositorio tiene pruebas automáticas: 19 pruebas unitarias en Android
(protocolo, reloj, inercia), XCTest en la Mac (protocolo y gestos) y simuladores en Python del
protocolo (ver "Probar un lado sin el otro").

## Instalación (una sola vez)

### 1. Herramientas en la Mac
```bash
brew install xcodegen android-platform-tools ffmpeg
```
Además, **Xcode** (App Store). Para compilar la app de Android hacen falta un JDK 17+ y el SDK de Android.
No es necesario Android Studio; con Homebrew basta:
```bash
brew install openjdk@21
brew install --cask android-commandlinetools
```
`scripts/install-android.sh` los encuentra solos (también el JDK y el SDK de Android Studio si lo tienes),
acepta las licencias del SDK y descarga lo que falte la primera vez.

### 2. Firma de la app de Mac
macOS guarda los permisos (Grabación de pantalla, Accesibilidad) por firma. Firmar siempre con tu
certificado "Apple Development" evita que se pierdan en cada compilación.

`scripts/build-mac.sh` detecta tu Team ID solo (del certificado del Llavero) y lo guarda en
`mac/Config/Signing.xcconfig`. Si no tienes certificado: Xcode → Settings → Accounts → agrega tu Apple ID →
**Manage Certificates… → + → Apple Development**. Sin certificado también compila (firma ad-hoc), pero
macOS volverá a pedir los permisos tras cada compilación.

### 3. Compilar e instalar la app de Mac
```bash
scripts/build-mac.sh --install
```
Aparece un icono de rectángulo en la barra de menús. Ábrelo y concede **Grabación de pantalla** y
**Accesibilidad** con los botones naranjas (macOS puede pedir reabrir la app tras dar Grabación de pantalla).

### 4. Preparar la tablet
1. Ajustes → Acerca de la tablet → Información de software → toca 7 veces **Número de compilación**.
2. Ajustes → Opciones de desarrollador → activa **Depuración USB**.
3. Conecta el cable USB-C (de datos) a la Mac y acepta **"¿Permitir depuración USB?"** (marca "Permitir siempre").
4. Instala la app:
```bash
scripts/install-android.sh
```

## Uso diario

1. Abre TabDisplay en la Mac (o activa **Abrir al iniciar sesión** en el menú).
2. **Conecta el cable.** En unos 2–3 s la tablet muestra el escritorio extendido. No hay que tocar la terminal.
3. La primera vez, acomoda el monitor "Tab S8+" en **Ajustes del Sistema → Pantallas** (botón ⚙︎ del menú).
   macOS recuerda la posición.

### Gestos

| En la tablet | En la Mac |
|---|---|
| Tap | Clic |
| Doble tap | Doble clic |
| Tocar y arrastrar | Arrastrar (ventanas, selección) |
| Mantener 0.5 s | Mantener el botón presionado |
| Deslizar con 2 dedos | Scroll con inercia (rebote nativo en Safari, etc.) |
| Tap con 2 dedos | Clic derecho |
| S Pen sobre la pantalla (hover) | Mover el cursor |
| S Pen tocando | Clic / arrastre inmediato, con presión |
| S Pen con botón lateral + tocar | Clic derecho |
| Tap con 3 dedos | Muestra/oculta el overlay (fps, Mbps, RTT, latencia) |

Mientras el S Pen está cerca de la pantalla se ignoran los dedos (rechazo de palma).

### Menú de la Mac
- **Modo:** Extender (monitor nuevo) o Duplicar (la pantalla principal).
- **Resolución:** 1400 × 876 (nítida, 2×) o presets con más espacio (1600 × 1000, 1680 × 1050).
- **Códec:** H.264 (recomendado) o HEVC (experimental). **120 Hz** (experimental: a esta resolución satura el
  codificador y agrega retraso; ver Estado).
- **Bitrate USB:** 15–50 Mbps (30 por defecto y recomendado).
- **Wi-Fi:** permite conexiones por la red local (ver abajo).
- **Reconectar:** rehace `adb reverse`, relanza la app y renegocia la sesión.
- **Grabar prueba 10 s:** graba el monitor a `~/Desktop/test.h264` sin la tablet (`ffplay ~/Desktop/test.h264`).
- **Avanzado:** tiempo que el monitor sigue vivo tras desconectar (10 s por defecto), abrir la app de la
  tablet al conectar, presión del S Pen como tableta, ruta de `adb`, dispositivos detectados.

### Modo Wi-Fi
1. En el menú de la Mac activa **Permitir conexión por Wi-Fi** (macOS pedirá permiso de red local).
2. Conecta la tablet **una vez por cable**: queda emparejada (recibe un token secreto).
3. Desconecta el cable. Con la app abierta, la tablet encuentra a la Mac por Bonjour y se conecta sola.
   El bitrate se ajusta automáticamente al estado de la red.

Para mejores resultados: red de 5/6 GHz y la Mac por Ethernet al router. "Revocar emparejamiento Wi-Fi"
(menú Avanzado) invalida el token; la tablet tendrá que conectarse por cable otra vez.

## Solución de problemas

| Síntoma | Qué revisar |
|---|---|
| La tablet dice "Esperando a la Mac…" con el cable puesto | Menú → Avanzado → dispositivos: debe decir "adb reverse activo". Si dice "sin autorizar", acepta la huella RSA en la tablet. Prueba `scripts/usb-connect.sh`. El cable debe ser de datos. |
| "No se encontró adb" | `brew install android-platform-tools` o pon la ruta en Avanzado. |
| Imagen negra en la tablet | Permiso de Grabación de pantalla (botón en el menú). Tras darlo, a veces hay que reabrir TabDisplay. |
| Los toques no hacen nada | Permiso de Accesibilidad. Si recompilaste con firma ad-hoc, quita TabDisplay de la lista y vuelve a agregarlo. |
| "CGVirtualDisplay no está disponible" | Una actualización de macOS cambió la API privada. Usa el modo Duplicar; el arreglo va en `mac/TabDisplayMac/Display/`. |
| Se ve borroso | Usa la resolución 1400 × 876 (las otras se reescalan) o sube el bitrate. |
| Latencia alta / tirones por Wi-Fi | Usa el cable; en Wi-Fi, red de 5/6 GHz y Mac por Ethernet. |

Logs:
```bash
adb logcat -s TabDisplay                                          # tablet
log stream --predicate 'subsystem == "dev.jose.tabdisplay.mac"'   # Mac
```

## Desarrollo

```
docs/         PROTOCOL.md (protocolo binario), DECISIONS.md (decisiones y mediciones)
mac/          project.yml (XcodeGen) + TabDisplayMac/{App,Display,Capture,Encode,Net,Input,Device}
android/      app Kotlin: MainActivity, net/ (cliente TCP, NSD), video/ (MediaCodec), input/ (toques, S Pen)
scripts/      usb-connect.sh, build-mac.sh, install-android.sh, measure-latency.md,
              mock_tablet.py / mock_mac.py (simuladores), tdproto.py (protocolo en Python)
```

Pruebas:
```bash
cd android && ./gradlew testDebugUnitTest lintDebug    # Android
scripts/build-mac.sh --test                            # Mac (XCTest)
```

### Probar un lado sin el otro
- **App de Mac sin tablet** (tablet simulada: guarda el video recibido y muestra fps/Mbps/RTT):
  ```bash
  python3 scripts/mock_tablet.py --seconds 15 --tap 0.5 0.5
  ffplay rx.h264
  ```
- **App de Android sin Mac** (Mac simulada que sirve un video y muestra los toques que recibe):
  ```bash
  ffmpeg -f lavfi -i testsrc2=size=2800x1752:rate=60 -t 20 -c:v libx264 -tune zerolatency -profile:v high -g 60 -bf 0 -pix_fmt yuv420p test.h264
  adb reverse tcp:47800 tcp:47800
  python3 scripts/mock_mac.py test.h264 --loop
  ```
  (Cierra antes TabDisplay en la Mac: usan el mismo puerto.)

### Criterios de aceptación por fase (PLAN.md)
- [x] **Fase 0:** ambas apps compilan desde terminal (`build-mac.sh`, `install-android.sh`); el monitor "Tab S8+" aparece al conectar la tablet.
- [ ] **Fase 1:** "Grabar prueba 10 s" → `ffplay ~/Desktop/test.h264` se ve nítido a 2800 × 1752; ~60 fps moviendo una ventana y codificación < 8 ms. *(La codificación ya se vio en pocos ms durante el uso; falta correr la grabación.)*
- [ ] **Fase 2:** con el cable, la tablet muestra el escritorio extendido ✓; arrastrar una ventana se ve fluido ✓; desconectar y reconectar el cable recupera la imagen sola *(pendiente)*.
- [ ] **Fase 3:** latencia vidrio a vidrio por USB < 80 ms (`scripts/measure-latency.md`); sin acumulación de retraso en 10 min. *(Captura → pantalla medida: ~12–18 ms; falta la medición con cámara y la prueba de 10 min.)*
- [x] **Fase 4:** mover una ventana, hacer scroll, abrir un menú contextual solo desde la tablet; el cursor sigue al S Pen en hover.
- [ ] **Fase 5:** con ambas apps cerradas (TabDisplay con "Abrir al iniciar sesión"), conectar el cable → escritorio en < 3 s.
- [ ] **Fase 6:** sin cable, < 120 ms y sin cortes > 1 s en 10 min; una tablet sin token es rechazada (`python3 scripts/mock_tablet.py --host <ip-de-la-mac>` debe recibir "Tablet no emparejada").
- Fase 7 (parcial): modo Duplicar, presión del S Pen como tableta y error claro si falla la API privada están hechos; falta el modo vertical.
