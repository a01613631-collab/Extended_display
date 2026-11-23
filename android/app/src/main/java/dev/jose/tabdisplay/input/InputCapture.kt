package dev.jose.tabdisplay.input

import android.view.Choreographer
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import dev.jose.tabdisplay.net.Protocol
import dev.jose.tabdisplay.net.ScrollPhase
import dev.jose.tabdisplay.net.ToolType
import dev.jose.tabdisplay.net.TouchAction
import kotlin.math.hypot

/**
 * Convierte MotionEvents del SurfaceView en mensajes TOUCH y SCROLL (PROTOCOL.md).
 *
 * - Dedos: se mandan down/up de cada dedo y move solo con un dedo; la Mac resuelve tap/arrastre/clic derecho.
 * - Dos dedos que se desplazan: SCROLL (con inercia calculada aquí).
 * - Tres dedos (tap): alterna el overlay de depuración. La Mac recibe los down/up, pero no hace clic con 3 dedos.
 * - S Pen / mouse: down/move/up inmediatos, hover y botón lateral.
 * Corre en el hilo de UI.
 */
class InputCapture(
    private val view: View,
    private val sink: Sink,
    private val onThreeFingerTap: () -> Unit,
) {
    interface Sink {
        fun sendTouch(payload: ByteArray)
        fun sendScroll(payload: ByteArray)
    }

    /** Ancho del stream en píxeles; convierte desplazamientos de la vista a píxeles del stream. */
    var streamWidthPx = 0

    var enabled = false
        set(value) {
            if (!value) reset()
            field = value
        }

    private val touchSlop = ViewConfiguration.get(view.context).scaledTouchSlop.toFloat()
    private val choreographer = Choreographer.getInstance()
    private val momentum = ScrollMomentum()
    private var lastMomentumFrameNs = 0L

    private var velocityTracker: VelocityTracker? = null
    private var lastStylusEventMs = 0L
    private var penDown = false

    // Estado del gesto con dedos.
    private var fingerGesture = false
    private var gestureStartMs = 0L
    private var maxPointers = 0
    private var movedBeyondSlop = false
    private var downX = 0f
    private var downY = 0f
    private var scrolling = false
    private var anchorX = 0f
    private var anchorY = 0f
    private var lastCentroidX = 0f
    private var lastCentroidY = 0f
    private val activePointerIds = IntArray(2)

    private val momentumCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            val dtMs = if (lastMomentumFrameNs == 0L) 16.0 else (frameTimeNanos - lastMomentumFrameNs) / 1e6
            lastMomentumFrameNs = frameTimeNanos
            momentum.step(dtMs)?.let { (dx, dy) -> sendScroll(dx.toFloat(), dy.toFloat(), ScrollPhase.MOMENTUM) }
            if (momentum.isActive) {
                choreographer.postFrameCallback(this)
            } else {
                sendScroll(0f, 0f, ScrollPhase.MOMENTUM) // fin de la inercia
            }
        }
    }

    fun onTouchEvent(event: MotionEvent): Boolean {
        if (!enabled || view.width == 0 || view.height == 0) return true
        val toolType = event.getToolType(event.actionIndex)
        if (isPrecisePointer(toolType)) {
            handlePen(event, toolType)
            return true
        }
        // Rechazo de palma: con el S Pen cerca o recién usado, se ignoran los dedos.
        if (penDown || event.eventTime - lastStylusEventMs < PALM_REJECTION_MS) {
            if (fingerGesture) cancelFingers()
            return true
        }
        handleFingers(event)
        return true
    }

    fun onHoverEvent(event: MotionEvent): Boolean {
        if (!enabled || view.width == 0) return false
        val toolType = event.getToolType(0)
        if (!isPrecisePointer(toolType)) return false
        lastStylusEventMs = event.eventTime
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE ->
                sendTouch(TouchAction.HOVER_MOVE, event, 0, wireTool(toolType), 0, pressure = 0f)
            MotionEvent.ACTION_HOVER_EXIT ->
                sendTouch(TouchAction.HOVER_EXIT, event, 0, wireTool(toolType), 0, pressure = 0f)
        }
        return true
    }

    /** Rueda de un mouse conectado a la tablet. */
    fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!enabled || event.actionMasked != MotionEvent.ACTION_SCROLL) return false
        val scale = streamScale()
        val dx = -event.getAxisValue(MotionEvent.AXIS_HSCROLL) * WHEEL_STEP_PX * scale
        val dy = event.getAxisValue(MotionEvent.AXIS_VSCROLL) * WHEEL_STEP_PX * scale
        sendScroll(dx, dy, ScrollPhase.CHANGED)
        return true
    }

    // --- S Pen y mouse ---

    private fun handlePen(event: MotionEvent, toolType: Int) {
        lastStylusEventMs = event.eventTime
        val buttons = if (event.buttonState and SECONDARY_BUTTONS != 0) Protocol.BUTTON_STYLUS_PRIMARY else 0
        val tool = wireTool(toolType)
        val pressure = if (toolType == MotionEvent.TOOL_TYPE_MOUSE) 1f else event.getPressure(0)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (fingerGesture) cancelFingers()
                stopMomentum()
                penDown = true
                sendTouch(TouchAction.DOWN, event, 0, tool, buttons, pressure)
            }
            MotionEvent.ACTION_MOVE -> if (penDown) sendTouch(TouchAction.MOVE, event, 0, tool, buttons, pressure)
            MotionEvent.ACTION_UP -> {
                penDown = false
                sendTouch(TouchAction.UP, event, 0, tool, buttons, 0f)
            }
            MotionEvent.ACTION_CANCEL -> {
                penDown = false
                sendTouch(TouchAction.CANCEL, event, 0, tool, buttons, 0f)
            }
        }
    }

    // --- Dedos ---

    private fun handleFingers(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                stopMomentum()
                fingerGesture = true
                gestureStartMs = event.eventTime
                maxPointers = 1
                movedBeyondSlop = false
                scrolling = false
                downX = event.getX(0)
                downY = event.getY(0)
                velocityTracker?.recycle()
                velocityTracker = VelocityTracker.obtain().also { it.addMovement(event) }
                sendFinger(TouchAction.DOWN, event, 0)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (!fingerGesture) return
                velocityTracker?.addMovement(event)
                maxPointers = maxOf(maxPointers, event.pointerCount)
                sendFinger(TouchAction.DOWN, event, event.actionIndex)
                if (event.pointerCount == 2) {
                    setScrollAnchor(event, excludeIndex = -1)
                } else if (scrolling) {
                    endScroll(withMomentum = false)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (!fingerGesture) return
                velocityTracker?.addMovement(event)
                when (event.pointerCount) {
                    1 -> {
                        if (hypot(event.getX(0) - downX, event.getY(0) - downY) > touchSlop) movedBeyondSlop = true
                        sendFinger(TouchAction.MOVE, event, 0)
                    }
                    2 -> handleTwoFingerMove(event)
                    else -> if (centroidMoved(event)) movedBeyondSlop = true
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (!fingerGesture) return
                velocityTracker?.addMovement(event)
                if (event.pointerCount == 2 && scrolling) endScroll(withMomentum = true)
                sendFinger(TouchAction.UP, event, event.actionIndex)
                // Si quedan exactamente dos dedos, el ancla se recalcula sin el que se levantó.
                if (event.pointerCount == 3) setScrollAnchor(event, excludeIndex = event.actionIndex)
            }
            MotionEvent.ACTION_UP -> {
                if (!fingerGesture) return
                if (scrolling) endScroll(withMomentum = false)
                sendFinger(TouchAction.UP, event, 0)
                val quick = event.eventTime - gestureStartMs < MULTI_TAP_MAX_MS
                if (maxPointers == 3 && quick && !movedBeyondSlop) onThreeFingerTap()
                finishGesture()
            }
            MotionEvent.ACTION_CANCEL -> cancelFingers()
        }
    }

    private fun handleTwoFingerMove(event: MotionEvent) {
        val (cx, cy) = centroid(event, excludeIndex = -1)
        if (!scrolling) {
            if (hypot(cx - anchorX, cy - anchorY) <= touchSlop) return
            scrolling = true
            movedBeyondSlop = true
            val scale = streamScale()
            sendScroll((cx - anchorX) * scale, (cy - anchorY) * scale, ScrollPhase.BEGAN)
        } else {
            val scale = streamScale()
            sendScroll((cx - lastCentroidX) * scale, (cy - lastCentroidY) * scale, ScrollPhase.CHANGED)
        }
        lastCentroidX = cx
        lastCentroidY = cy
    }

    private fun endScroll(withMomentum: Boolean) {
        scrolling = false
        sendScroll(0f, 0f, ScrollPhase.ENDED)
        if (!withMomentum) return
        val tracker = velocityTracker ?: return
        tracker.computeCurrentVelocity(1000)
        // Velocidad media de los dos dedos (que son los punteros activos de este gesto).
        var vx = 0f
        var vy = 0f
        var count = 0
        for (id in activePointerIds) {
            vx += tracker.getXVelocity(id)
            vy += tracker.getYVelocity(id)
            count++
        }
        if (count == 0) return
        val scale = streamScale()
        if (momentum.start((vx / count * scale).toDouble(), (vy / count * scale).toDouble())) {
            lastMomentumFrameNs = 0L
            choreographer.postFrameCallback(momentumCallback)
        }
    }

    private fun setScrollAnchor(event: MotionEvent, excludeIndex: Int) {
        val (cx, cy) = centroid(event, excludeIndex)
        anchorX = cx
        anchorY = cy
        lastCentroidX = cx
        lastCentroidY = cy
        var n = 0
        for (i in 0 until event.pointerCount) {
            if (i == excludeIndex || n >= 2) continue
            activePointerIds[n++] = event.getPointerId(i)
        }
    }

    private fun centroid(event: MotionEvent, excludeIndex: Int): Pair<Float, Float> {
        var x = 0f
        var y = 0f
        var n = 0
        for (i in 0 until event.pointerCount) {
            if (i == excludeIndex) continue
            x += event.getX(i)
            y += event.getY(i)
            n++
        }
        return if (n == 0) 0f to 0f else x / n to y / n
    }

    private fun centroidMoved(event: MotionEvent): Boolean {
        val (cx, cy) = centroid(event, -1)
        return hypot(cx - downX, cy - downY) > touchSlop * 2
    }

    private fun cancelFingers() {
        if (scrolling) sendScroll(0f, 0f, ScrollPhase.ENDED)
        // Un solo CANCEL basta: la Mac suelta cualquier botón y reinicia el gesto.
        sink.sendTouch(Protocol.encodeTouch(TouchAction.CANCEL, 0, ToolType.FINGER, 0, 0f, 0f, 0f))
        finishGesture()
    }

    private fun finishGesture() {
        fingerGesture = false
        scrolling = false
        velocityTracker?.recycle()
        velocityTracker = null
    }

    private fun stopMomentum() {
        if (!momentum.isActive) return
        momentum.cancel()
        choreographer.removeFrameCallback(momentumCallback)
        sendScroll(0f, 0f, ScrollPhase.MOMENTUM)
    }

    private fun reset() {
        if (momentum.isActive) {
            momentum.cancel()
            choreographer.removeFrameCallback(momentumCallback)
        }
        penDown = false
        finishGesture()
    }

    // --- Envío ---

    private fun sendFinger(action: Int, event: MotionEvent, index: Int) =
        sendTouch(action, event, index, ToolType.FINGER, 0, event.getPressure(index))

    private fun sendTouch(action: Int, event: MotionEvent, index: Int, tool: Int, buttons: Int, pressure: Float) {
        val x = (event.getX(index) / view.width).coerceIn(0f, 1f)
        val y = (event.getY(index) / view.height).coerceIn(0f, 1f)
        val id = event.getPointerId(index) and 0xFF
        sink.sendTouch(Protocol.encodeTouch(action, id, tool, buttons, x, y, pressure.coerceIn(0f, 1f)))
    }

    private fun sendScroll(dx: Float, dy: Float, phase: Int) {
        sink.sendScroll(Protocol.encodeScroll(dx, dy, phase))
    }

    private fun streamScale(): Float =
        if (streamWidthPx > 0 && view.width > 0) streamWidthPx.toFloat() / view.width else 1f

    private fun isPrecisePointer(toolType: Int) =
        toolType == MotionEvent.TOOL_TYPE_STYLUS ||
            toolType == MotionEvent.TOOL_TYPE_ERASER ||
            toolType == MotionEvent.TOOL_TYPE_MOUSE

    private fun wireTool(toolType: Int) =
        if (toolType == MotionEvent.TOOL_TYPE_ERASER) ToolType.ERASER else ToolType.STYLUS

    private companion object {
        const val PALM_REJECTION_MS = 400L
        const val MULTI_TAP_MAX_MS = 400L
        const val WHEEL_STEP_PX = 48f
        // Botón lateral del S Pen (BUTTON_STYLUS_PRIMARY) o clic derecho de un mouse.
        const val SECONDARY_BUTTONS = MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY
    }
}
