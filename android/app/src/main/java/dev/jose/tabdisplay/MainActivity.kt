package dev.jose.tabdisplay

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PointerIcon
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import dev.jose.tabdisplay.input.InputCapture
import dev.jose.tabdisplay.net.SessionInfo
import dev.jose.tabdisplay.net.StreamClient
import dev.jose.tabdisplay.net.Transport
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Única Activity: pantalla completa inmersiva con un SurfaceView donde MediaCodec dibuja el
 * escritorio de la Mac. Sin sesión muestra la pantalla de espera.
 */
class MainActivity : Activity(), StreamClient.Listener, SurfaceHolder.Callback {

    private lateinit var prefs: AppPrefs
    private lateinit var surfaceView: SurfaceView
    private lateinit var waitingPanel: View
    private lateinit var statusText: TextView
    private lateinit var hintText: TextView
    private lateinit var pairingText: TextView
    private lateinit var progress: ProgressBar
    private lateinit var wifiSwitch: Switch
    private lateinit var forgetButton: Button
    private lateinit var overlay: TextView
    private lateinit var input: InputCapture

    private var client: StreamClient? = null
    private var session: SessionInfo? = null
    private var maxRefreshRate = 60f
    private val mainHandler = Handler(Looper.getMainLooper())

    private val overlayUpdater = object : Runnable {
        override fun run() {
            updateOverlay()
            mainHandler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = AppPrefs(this)
        setContentView(R.layout.activity_main)

        surfaceView = findViewById(R.id.surface)
        waitingPanel = findViewById(R.id.waiting_panel)
        statusText = findViewById(R.id.status_text)
        hintText = findViewById(R.id.hint_text)
        pairingText = findViewById(R.id.pairing_text)
        progress = findViewById(R.id.progress)
        wifiSwitch = findViewById(R.id.wifi_switch)
        forgetButton = findViewById(R.id.forget_button)
        overlay = findViewById(R.id.debug_overlay)

        configureWindow()

        input = InputCapture(surfaceView, object : InputCapture.Sink {
            override fun sendTouch(payload: ByteArray) {
                client?.sendTouch(payload)
            }

            override fun sendScroll(payload: ByteArray) {
                client?.sendScroll(payload)
            }
        }, ::toggleOverlay)
        attachInput()

        // El cursor de hover de Android no aporta nada: el cursor de la Mac viene en el video.
        surfaceView.pointerIcon = PointerIcon.getSystemIcon(this, PointerIcon.TYPE_NULL)
        surfaceView.holder.addCallback(this)

        wifiSwitch.isChecked = prefs.wifiEnabled
        wifiSwitch.setOnCheckedChangeListener { _, checked ->
            prefs.wifiEnabled = checked
            client?.onWifiSettingsChanged()
            refreshWaitingTexts()
        }
        forgetButton.setOnClickListener {
            prefs.clearPairing()
            client?.onWifiSettingsChanged()
            refreshWaitingTexts()
            Toast.makeText(this, R.string.pairing_forgotten, Toast.LENGTH_SHORT).show()
        }
        refreshWaitingTexts()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachInput() {
        surfaceView.setOnTouchListener { _, event -> input.onTouchEvent(event) }
        surfaceView.setOnHoverListener { _, event -> input.onHoverEvent(event) }
        surfaceView.setOnGenericMotionListener { _, event -> input.onGenericMotionEvent(event) }
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    override fun onDestroy() {
        stopClient()
        super.onDestroy()
    }

    // --- Ventana ---

    private fun configureWindow() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val attributes = window.attributes
        attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        attributes.preferMinimalPostProcessing = true
        // Pide el modo con mayor tasa de refresco a la resolución nativa (120 Hz en la Tab S8+).
        display?.let { display ->
            val current = display.mode
            val best = display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .maxByOrNull { it.refreshRate }
            if (best != null) {
                attributes.preferredDisplayModeId = best.modeId
                maxRefreshRate = best.refreshRate
            }
        }
        window.attributes = attributes
        window.setDecorFitsSystemWindows(false)
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    // --- Surface: la conexión vive mientras exista el Surface ---

    override fun surfaceCreated(holder: SurfaceHolder) {
        // Render lo más rápido posible: se pide la tasa máxima del panel para no esperar vsyncs largos.
        holder.surface.setFrameRate(
            maxRefreshRate,
            Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
            Surface.CHANGE_FRAME_RATE_ALWAYS,
        )
        startClient(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopClient()
    }

    private fun startClient(surface: Surface) {
        if (client != null) return
        val device = DeviceInfo.collect(this)
        Log.i(TAG, "Dispositivo: $device")
        client = StreamClient(this, prefs, device, this).also { it.start(surface) }
    }

    private fun stopClient() {
        client?.stop()
        client = null
        input.enabled = false
    }

    // --- StreamClient.Listener (llegan desde el hilo de red) ---

    override fun onWaiting(message: String?) {
        runOnUiThread {
            if (session == null) {
                statusText.text = message?.let { getString(R.string.mac_rejected, it) } ?: getString(R.string.status_waiting)
            }
        }
    }

    override fun onSessionStarted(session: SessionInfo) {
        runOnUiThread {
            this.session = session
            fitSurfaceToStream(session.widthPx, session.heightPx)
            input.streamWidthPx = session.widthPx
            input.enabled = true
            waitingPanel.visibility = View.GONE
            if (prefs.overlayVisible) showOverlay(true)
        }
    }

    override fun onSessionEnded() {
        runOnUiThread {
            session = null
            input.enabled = false
            showOverlay(false)
            statusText.setText(R.string.status_waiting)
            refreshWaitingTexts()
            waitingPanel.visibility = View.VISIBLE
        }
    }

    override fun onPairingInvalid() {
        runOnUiThread {
            statusText.setText(R.string.wifi_unauthorized)
            refreshWaitingTexts()
        }
    }

    // --- UI ---

    /** Ajusta el SurfaceView a la proporción del stream (normalmente coincide con el panel). */
    private fun fitSurfaceToStream(streamWidth: Int, streamHeight: Int) {
        val root = findViewById<View>(R.id.root)
        val availableW = root.width
        val availableH = root.height
        if (availableW == 0 || availableH == 0) return
        val scale = minOf(availableW.toFloat() / streamWidth, availableH.toFloat() / streamHeight)
        val params = surfaceView.layoutParams as FrameLayout.LayoutParams
        params.width = (streamWidth * scale).roundToInt()
        params.height = (streamHeight * scale).roundToInt()
        surfaceView.layoutParams = params
    }

    private fun refreshWaitingTexts() {
        val token = prefs.pairingToken
        val macName = prefs.pairedMacName ?: "la Mac"
        pairingText.text = if (token != null) getString(R.string.paired_with, macName) else getString(R.string.not_paired)
        forgetButton.isEnabled = token != null
        hintText.text = when {
            !prefs.wifiEnabled -> getString(R.string.hint_usb)
            token == null -> getString(R.string.hint_usb) + "\n" + getString(R.string.hint_wifi_unpaired)
            else -> getString(R.string.hint_usb) + "\n" + getString(R.string.hint_wifi_ready, macName)
        }
    }

    private fun toggleOverlay() {
        val visible = overlay.visibility != View.VISIBLE
        prefs.overlayVisible = visible
        showOverlay(visible)
    }

    private fun showOverlay(visible: Boolean) {
        mainHandler.removeCallbacks(overlayUpdater)
        overlay.visibility = if (visible) View.VISIBLE else View.GONE
        if (visible) overlayUpdater.run()
    }

    private fun updateOverlay() {
        val s = session ?: return
        val c = client ?: return
        val snap = c.lastSnapshot
        val codec = if (s.codec.contains("hevc")) "HEVC" else "H.264"
        val transport = if (s.transport == Transport.USB) "USB" else "Wi-Fi"
        val lines = buildList {
            add("${s.widthPx}×${s.heightPx} $codec @${s.fps} · $transport · ${s.bitrate / 1_000_000} Mbps obj.")
            if (snap != null) {
                add(String.format(Locale.US, "fps rx %.1f · render %.1f", snap.fpsReceived, snap.fpsRendered))
                add(String.format(Locale.US, "%.1f Mbps · descartados %d", snap.mbps, snap.droppedFrames))
                add("RTT " + (snap.rttMs?.let { String.format(Locale.US, "%.1f ms", it) } ?: "—") +
                    " · latencia " + (snap.latencyMs?.let { String.format(Locale.US, "%.0f ms", it) } ?: "—"))
                add("decoder ${snap.decoder}")
            }
            add(getString(R.string.overlay_hint))
        }
        overlay.text = lines.joinToString("\n")
    }

    private companion object {
        const val TAG = "TabDisplay"
    }
}
