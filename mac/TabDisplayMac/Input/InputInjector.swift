import ApplicationServices
import CoreGraphics
import Foundation

/// Publica `MouseAction` como CGEvent. Requiere el permiso de Accesibilidad.
final class InputInjector {
    /// Si está activo, la presión del S Pen se manda como evento de tableta (experimental).
    var stylusPressureEnabled = false

    private let source = CGEventSource(stateID: .hidSystemState)
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var warnedAboutPermission = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func perform(_ actions: [MouseAction]) {
        guard Self.isTrusted else {
            if !warnedAboutPermission {
                warnedAboutPermission = true
                Log.input.warning("Sin permiso de Accesibilidad: se ignoran los toques")
            }
            return
        }
        warnedAboutPermission = false
        for action in actions {
            perform(action)
        }
    }

    private func perform(_ action: MouseAction) {
        switch action {
        case .move(let point):
            post(mouse: .mouseMoved, at: point, button: .left)

        case let .down(button, point, clickCount, pressure):
            let type: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
            post(mouse: type, at: point, button: button.cgButton, clickCount: clickCount, pressure: pressure)

        case let .drag(button, point, pressure):
            let type: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
            post(mouse: type, at: point, button: button.cgButton, pressure: pressure)

        case let .up(button, point, clickCount):
            let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
            post(mouse: type, at: point, button: button.cgButton, clickCount: clickCount)

        case let .scroll(dx, dy, scrollPhase, momentumPhase):
            postScroll(dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase)
        }
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton,
                      clickCount: Int? = nil, pressure: Double? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        if let clickCount {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        if let pressure {
            // NSEvent.pressure la leen apps como Notas o editores de dibujo.
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            if stylusPressureEnabled {
                event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
                event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            }
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double, scrollPhase: Int64, momentumPhase: Int64) {
        if scrollPhase == ScrollPhaseValue.began {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
        // Las unidades en píxeles son enteras: se acumulan las fracciones para no perder desplazamiento.
        let totalX = dx + scrollRemainderX
        let totalY = dy + scrollRemainderY
        let wheelX = totalX.rounded(.towardZero)
        let wheelY = totalY.rounded(.towardZero)
        scrollRemainderX = totalX - wheelX
        scrollRemainderY = totalY - wheelY

        // wheel1 = eje vertical, wheel2 = horizontal. Positivo = contenido hacia abajo/derecha,
        // igual que un dedo que arrastra en una pantalla táctil.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int(wheelY)), wheel2: Int32(clamping: Int(wheelX)),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }
}

private extension MouseButton {
    var cgButton: CGMouseButton { self == .left ? .left : .right }
}
