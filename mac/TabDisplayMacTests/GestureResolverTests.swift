import CoreGraphics
import XCTest

final class GestureResolverTests: XCTestCase {
    private var time: TimeInterval = 100
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var actions: [MouseAction] = []
    private var resolver: GestureResolver!

    override func setUp() {
        super.setUp()
        time = 100
        scheduled = []
        actions = []
        resolver = GestureResolver(
            now: { [unowned self] in self.time },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
            emit: { [unowned self] in self.actions.append(contentsOf: $0) })
    }

    private func finger(_ action: TouchAction, _ id: UInt8 = 0) -> TouchEvent {
        TouchEvent(action: action, pointerId: id, toolType: .finger, buttons: 0, x: 0, y: 0, pressure: 1)
    }

    private func pen(_ action: TouchAction, button: Bool = false, pressure: Float = 0.5) -> TouchEvent {
        TouchEvent(action: action, pointerId: 0, toolType: .stylus, buttons: button ? 1 : 0, x: 0, y: 0, pressure: pressure)
    }

    private let p = CGPoint(x: 100, y: 100)

    func testTapIsClick() {
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.move), at: CGPoint(x: 103, y: 102))
        time += 0.1
        resolver.handle(finger(.up), at: CGPoint(x: 103, y: 102))
        XCTAssertEqual(actions, [
            .move(p),
            .down(.left, p, clickCount: 1, pressure: nil),
            .up(.left, p, clickCount: 1),
        ])
    }

    func testDoubleTapIsDoubleClick() {
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.up), at: p)
        time += 0.2
        resolver.handle(finger(.down), at: CGPoint(x: 104, y: 100))
        resolver.handle(finger(.up), at: CGPoint(x: 104, y: 100))
        XCTAssertEqual(actions.last, .up(.left, CGPoint(x: 104, y: 100), clickCount: 2))
    }

    func testSlowSecondTapIsNewClick() {
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.up), at: p)
        time += 2
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.up), at: p)
        XCTAssertEqual(actions.last, .up(.left, p, clickCount: 1))
    }

    func testDragStartsAtTouchDownPoint() {
        let far = CGPoint(x: 160, y: 100)
        let end = CGPoint(x: 200, y: 120)
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.move), at: far)
        resolver.handle(finger(.move), at: end)
        resolver.handle(finger(.up), at: end)
        XCTAssertEqual(actions, [
            .move(p),
            .down(.left, p, clickCount: 1, pressure: nil),
            .drag(.left, far, pressure: nil),
            .drag(.left, end, pressure: nil),
            .up(.left, end, clickCount: 1),
        ])
    }

    func testTwoFingerTapIsRightClick() {
        resolver.handle(finger(.down, 0), at: p)
        resolver.handle(finger(.down, 1), at: CGPoint(x: 150, y: 100))
        time += 0.1
        resolver.handle(finger(.up, 1), at: CGPoint(x: 150, y: 100))
        resolver.handle(finger(.up, 0), at: p)
        XCTAssertEqual(actions, [
            .move(p),
            .down(.right, p, clickCount: 1, pressure: nil),
            .up(.right, p, clickCount: 1),
        ])
    }

    func testTwoFingerScrollIsNotRightClick() {
        resolver.handle(finger(.down, 0), at: p)
        resolver.handle(finger(.down, 1), at: CGPoint(x: 150, y: 100))
        resolver.handleScroll(dx: 0, dy: 20, phase: .began)
        resolver.handleScroll(dx: 0, dy: 5, phase: .changed)
        resolver.handleScroll(dx: 0, dy: 0, phase: .ended)
        resolver.handle(finger(.up, 1), at: p)
        resolver.handle(finger(.up, 0), at: p)
        XCTAssertFalse(actions.contains { if case .down(.right, _, _, _) = $0 { return true } else { return false } })
        XCTAssertEqual(actions.filter { if case .scroll = $0 { return true } else { return false } }.count, 3)
    }

    func testSlowTwoFingerTapIsIgnored() {
        resolver.handle(finger(.down, 0), at: p)
        resolver.handle(finger(.down, 1), at: p)
        time += 1
        resolver.handle(finger(.up, 1), at: p)
        resolver.handle(finger(.up, 0), at: p)
        XCTAssertEqual(actions, [.move(p)])
    }

    func testThreeFingerTapDoesNothing() {
        for id: UInt8 in 0...2 { resolver.handle(finger(.down, id), at: p) }
        for id: UInt8 in 0...2 { resolver.handle(finger(.up, id), at: p) }
        XCTAssertEqual(actions, [.move(p)])
    }

    func testLongPressHoldsButton() {
        resolver.handle(finger(.down), at: p)
        XCTAssertEqual(scheduled.count, 1)
        time += 0.6
        scheduled[0].1()
        XCTAssertEqual(actions.last, .down(.left, p, clickCount: 1, pressure: nil))
        let end = CGPoint(x: 300, y: 300)
        resolver.handle(finger(.move), at: end)
        resolver.handle(finger(.up), at: end)
        XCTAssertEqual(actions.suffix(2), [.drag(.left, end, pressure: nil), .up(.left, end, clickCount: 1)])
    }

    func testLongPressTimerIgnoredAfterTap() {
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.up), at: p)
        let count = actions.count
        scheduled[0].1()
        XCTAssertEqual(actions.count, count)
    }

    func testCancelReleasesDrag() {
        resolver.handle(finger(.down), at: p)
        resolver.handle(finger(.move), at: CGPoint(x: 200, y: 100))
        resolver.handle(finger(.cancel), at: .zero)
        XCTAssertEqual(actions.last, .up(.left, CGPoint(x: 200, y: 100), clickCount: 1))
    }

    func testPenWithSideButtonIsRightClick() {
        resolver.handle(pen(.down, button: true), at: p)
        resolver.handle(pen(.up, button: true), at: p)
        XCTAssertEqual(actions, [
            .down(.right, p, clickCount: 1, pressure: 0.5),
            .up(.right, p, clickCount: 1),
        ])
    }

    func testPenHoverMovesAndDrawsImmediately() {
        resolver.handle(pen(.hoverMove), at: p)
        resolver.handle(pen(.down), at: p)
        resolver.handle(pen(.move, pressure: 0.75), at: CGPoint(x: 101, y: 100))
        resolver.handle(pen(.up), at: CGPoint(x: 101, y: 100))
        XCTAssertEqual(actions, [
            .move(p),
            .down(.left, p, clickCount: 1, pressure: 0.5),
            .drag(.left, CGPoint(x: 101, y: 100), pressure: 0.75),
            .up(.left, CGPoint(x: 101, y: 100), clickCount: 1),
        ])
    }

    func testMomentumPhases() {
        resolver.handleScroll(dx: 0, dy: 10, phase: .began)
        resolver.handleScroll(dx: 0, dy: 0, phase: .ended)
        resolver.handleScroll(dx: 0, dy: 8, phase: .momentum)
        resolver.handleScroll(dx: 0, dy: 4, phase: .momentum)
        resolver.handleScroll(dx: 0, dy: 0, phase: .momentum)
        XCTAssertEqual(actions, [
            .scroll(dx: 0, dy: 10, scrollPhase: ScrollPhaseValue.began, momentumPhase: MomentumPhaseValue.none),
            .scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.ended, momentumPhase: MomentumPhaseValue.none),
            .scroll(dx: 0, dy: 8, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.begin),
            .scroll(dx: 0, dy: 4, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.continue),
            .scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.end),
        ])
    }

    func testNewScrollEndsMomentum() {
        resolver.handleScroll(dx: 0, dy: 8, phase: .momentum)
        resolver.handleScroll(dx: 0, dy: 3, phase: .began)
        XCTAssertEqual(actions.suffix(2), [
            .scroll(dx: 0, dy: 0, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.end),
            .scroll(dx: 0, dy: 3, scrollPhase: ScrollPhaseValue.began, momentumPhase: MomentumPhaseValue.none),
        ])
    }

    func testWheelWithoutBeganHasNoPhase() {
        resolver.handleScroll(dx: 0, dy: 24, phase: .changed)
        XCTAssertEqual(actions, [.scroll(dx: 0, dy: 24, scrollPhase: ScrollPhaseValue.none, momentumPhase: MomentumPhaseValue.none)])
    }

    func testResetReleasesPenButton() {
        resolver.handle(pen(.down), at: p)
        resolver.reset()
        XCTAssertEqual(actions.last, .up(.left, p, clickCount: 1))
    }
}
