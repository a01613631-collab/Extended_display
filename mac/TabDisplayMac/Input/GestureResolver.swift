import CoreGraphics
import Foundation

// Resuelve gestos a partir de la secuencia de TOUCH/SCROLL de la tablet (PROTOCOL.md).
// Lógica pura: no publica eventos; emite `MouseAction` que InputInjector convierte en CGEvent.
// Así se puede probar sin permisos de Accesibilidad.

enum MouseButton: Equatable {
    case left
    case right
}

/// Valores de CGScrollPhase y CGMomentumScrollPhase (campos de CGEvent).
enum ScrollPhaseValue {
    static let none: Int64 = 0
    static let began: Int64 = 1
    static let changed: Int64 = 2
    static let ended: Int64 = 4
}

enum MomentumPhaseValue {
    static let none: Int64 = 0
    static let begin: Int64 = 1
    static let `continue`: Int64 = 2
    static let end: Int64 = 3
}

enum MouseAction: Equatable {
    case move(CGPoint)
    case down(MouseButton, CGPoint, clickCount: Int, pressure: Double?)
    case drag(MouseButton, CGPoint, pressure: Double?)
    case up(MouseButton, CGPoint, clickCount: Int)
    /// dx/dy en puntos de la Mac; positivo = contenido hacia la derecha/abajo.
    case scroll(dx: Double, dy: Double, scrollPhase: Int64, momentumPhase: Int64)
}

final class GestureResolver {
    struct Config {
        /// Distancia (puntos) que un dedo puede moverse y seguir contando como tap.
        var tapSlop: CGFloat = 10
        /// Mantener el dedo quieto este tiempo = botón presionado (como mantener el clic).
        var longPressDelay: TimeInterval = 0.5
        var doubleClickInterval: TimeInterval = 0.5
        var doubleClickDistance: CGFloat = 16
        var twoFingerTapMaxDuration: TimeInterval = 0.35
    }

    private enum FingerState {
        case idle
        /// Un dedo abajo; aún no se sabe si es tap, arrastre o mantener.
        case pending(pointer: UInt8, start: CGPoint)
        case dragging(pointer: UInt8, last: CGPoint)
        /// Dos o más dedos: posible clic derecho (si es un tap de 2) o scroll (lo manda la tablet).
        case multi(maxPointers: Int, startTime: TimeInterval, anchor: CGPoint, cancelled: Bool)
    }

    let config: Config
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let emit: ([MouseAction]) -> Void

    private var finger: FingerState = .idle
    private var fingersDown = Set<UInt8>()
    private var dragClickCount = 1
    private var longPressToken = 0

    private var penButton: MouseButton?
    private var penLast = CGPoint.zero
    private var penClickCount = 1

    private var gestureScrollActive = false
    private var momentumActive = false
    private var lastClick: (time: TimeInterval, point: CGPoint, button: MouseButton, count: Int)?

    init(config: Config = Config(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         emit: @escaping ([MouseAction]) -> Void) {
        self.config = config
        self.now = now
        self.schedule = schedule
        self.emit = emit
    }

    /// `point` es la posición ya convertida a coordenadas globales de pantalla (puntos).
    func handle(_ touch: TouchEvent, at point: CGPoint) {
        switch touch.toolType {
        case .stylus, .eraser:
            handlePen(touch, at: point)
        case .finger:
            handleFinger(touch, at: point)
        }
    }

    /// dx/dy ya en puntos de la Mac.
    func handleScroll(dx: Double, dy: Double, phase: ScrollPhase) {
        if case let .multi(maxPointers, startTime, anchor, _) = finger, phase == .began || phase == .changed {
            // Hubo scroll: al soltar no será clic derecho.
            finger = .multi(maxPointers: maxPointers, startTime: startTime, anchor: anchor, cancelled: true)
        }
        var actions: [MouseAction] = []
        switch phase {
        case .began:
            if momentumActive {
                actions.append(.scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.end))
                momentumActive = false
            }
            gestureScrollActive = true
            actions.append(.scroll(dx: dx, dy: dy, scrollPhase: ScrollPhaseValue.began, momentumPhase: MomentumPhaseValue.none))
        case .changed:
            // Sin "began" previo (p. ej. rueda de un mouse en la tablet): scroll sin fase.
            let phaseValue = gestureScrollActive ? ScrollPhaseValue.changed : ScrollPhaseValue.none
            actions.append(.scroll(dx: dx, dy: dy, scrollPhase: phaseValue, momentumPhase: MomentumPhaseValue.none))
        case .ended:
            guard gestureScrollActive else { return }
            gestureScrollActive = false
            actions.append(.scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.ended, momentumPhase: MomentumPhaseValue.none))
        case .momentum:
            if dx == 0 && dy == 0 {
                guard momentumActive else { return }
                momentumActive = false
                actions.append(.scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.end))
            } else {
                let momentumPhase = momentumActive ? MomentumPhaseValue.continue : MomentumPhaseValue.begin
                momentumActive = true
                actions.append(.scroll(dx: dx, dy: dy, scrollPhase: ScrollPhaseValue.none, momentumPhase: momentumPhase))
            }
        }
        emit(actions)
    }

    /// Suelta cualquier botón presionado y termina gestos en curso (desconexión, cancel).
    func reset() {
        var actions: [MouseAction] = []
        if case let .dragging(_, last) = finger {
            actions.append(.up(.left, last, clickCount: dragClickCount))
        }
        if let button = penButton {
            actions.append(.up(button, penLast, clickCount: penClickCount))
        }
        if momentumActive {
            actions.append(.scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.end))
        } else if gestureScrollActive {
            actions.append(.scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.ended, momentumPhase: MomentumPhaseValue.none))
        }
        finger = .idle
        fingersDown.removeAll()
        penButton = nil
        momentumActive = false
        gestureScrollActive = false
        longPressToken += 1
        if !actions.isEmpty { emit(actions) }
    }

    // MARK: - S Pen (y mouse de la tablet): eventos inmediatos, sin umbrales

    private func handlePen(_ touch: TouchEvent, at point: CGPoint) {
        let pressure = Double(min(max(touch.pressure, 0), 1))
        switch touch.action {
        case .hoverMove:
            if penButton == nil { emit([.move(point)]) }
        case .hoverExit:
            break
        case .down:
            if case .idle = finger {} else { reset() }
            if let button = penButton { emit([.up(button, penLast, clickCount: penClickCount)]) }
            let button: MouseButton = touch.isSideButtonPressed ? .right : .left
            penClickCount = clickCount(button, at: point)
            penButton = button
            penLast = point
            emit([.down(button, point, clickCount: penClickCount, pressure: pressure)])
        case .move:
            if let button = penButton {
                penLast = point
                emit([.drag(button, point, pressure: pressure)])
            } else {
                emit([.move(point)])
            }
        case .up, .cancel:
            if let button = penButton {
                emit([.up(button, touch.action == .up ? point : penLast, clickCount: penClickCount)])
                penButton = nil
            }
        }
    }

    // MARK: - Dedos

    private func handleFinger(_ touch: TouchEvent, at point: CGPoint) {
        let id = touch.pointerId
        switch touch.action {
        case .down:
            fingersDown.insert(id)
            switch finger {
            case .idle:
                finger = .pending(pointer: id, start: point)
                // El cursor va donde está el dedo (hover en botones, y destino del scroll).
                emit([.move(point)])
                scheduleLongPress()
            case let .pending(_, start):
                longPressToken += 1
                finger = .multi(maxPointers: 2, startTime: now(), anchor: start, cancelled: false)
            case let .dragging(_, last):
                // Un segundo dedo durante un arrastre termina el arrastre; no habrá clic derecho.
                emit([.up(.left, last, clickCount: dragClickCount)])
                finger = .multi(maxPointers: fingersDown.count, startTime: now(), anchor: last, cancelled: true)
            case let .multi(maxPointers, startTime, anchor, cancelled):
                finger = .multi(maxPointers: max(maxPointers, fingersDown.count), startTime: startTime,
                                anchor: anchor, cancelled: cancelled)
            }

        case .move:
            switch finger {
            case let .pending(pointer, start) where pointer == id:
                guard distance(point, start) > config.tapSlop else { return }
                longPressToken += 1
                dragClickCount = clickCount(.left, at: start)
                emit([.down(.left, start, clickCount: dragClickCount, pressure: nil), .drag(.left, point, pressure: nil)])
                finger = .dragging(pointer: id, last: point)
            case let .dragging(pointer, _) where pointer == id:
                emit([.drag(.left, point, pressure: nil)])
                finger = .dragging(pointer: id, last: point)
            default:
                break
            }

        case .up:
            fingersDown.remove(id)
            switch finger {
            case let .pending(pointer, start) where pointer == id:
                longPressToken += 1
                let count = clickCount(.left, at: start)
                emit([.down(.left, start, clickCount: count, pressure: nil), .up(.left, start, clickCount: count)])
                finger = .idle
            case let .dragging(pointer, _) where pointer == id:
                emit([.up(.left, point, clickCount: dragClickCount)])
                finger = .idle
            case let .multi(maxPointers, startTime, anchor, cancelled):
                guard fingersDown.isEmpty else { return }
                if maxPointers == 2 && !cancelled && now() - startTime <= config.twoFingerTapMaxDuration {
                    let count = clickCount(.right, at: anchor)
                    emit([.down(.right, anchor, clickCount: count, pressure: nil), .up(.right, anchor, clickCount: count)])
                }
                finger = .idle
            default:
                if fingersDown.isEmpty { finger = .idle }
            }

        case .cancel:
            reset()

        case .hoverMove, .hoverExit:
            break
        }
    }

    private func scheduleLongPress() {
        longPressToken += 1
        let token = longPressToken
        schedule(config.longPressDelay) { [weak self] in
            guard let self, self.longPressToken == token,
                  case let .pending(pointer, start) = self.finger else { return }
            // Mantener quieto = mantener presionado el botón; al soltar se suelta en el mismo punto.
            self.dragClickCount = self.clickCount(.left, at: start)
            self.emit([.down(.left, start, clickCount: self.dragClickCount, pressure: nil)])
            self.finger = .dragging(pointer: pointer, last: start)
        }
    }

    private func clickCount(_ button: MouseButton, at point: CGPoint) -> Int {
        let time = now()
        var count = 1
        if let last = lastClick, last.button == button,
           time - last.time <= config.doubleClickInterval,
           distance(point, last.point) <= config.doubleClickDistance {
            count = last.count + 1
        }
        lastClick = (time, point, button, count)
        return count
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
