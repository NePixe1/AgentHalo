import AppKit
import AgentHaloCore
import QuartzCore

@MainActor
final class HaloView: NSView {
    private static let dragActivationDistance = 3.0
    private static let normalAnimationInterval = 1.0 / 60.0
    private static let draggingAnimationInterval = 1.0 / 15.0

    var aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.codex.standbyDetail,
        sessions: [],
        focusedAgent: .codex
    ) {
        didSet {
            guard !previewMode else {
                return
            }
            applyVisualState(aggregate.state, presentation: .flashing)
        }
    }
    var onDoubleClick: (() -> Void)?
    var onMoved: ((NSRect) -> Void)?
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onDragStarted: (() -> Void)?
    private var dragStart: NSPoint?
    private var dragStartInWindow: NSPoint?
    private var windowStart: NSPoint?
    private var isDraggingWindow = false
    private var pendingClickActivation = false
    nonisolated(unsafe) private var animationTimer: Timer?
    private var lastFrameTimestamp = CACurrentMediaTime()
    private var visualState: HaloState = .idle
    private var errorPresentation: ErrorPresentation = .flashing
    private var steadyDone = false
    private var transitionFromVisual = HaloVisualModel.targetVisual(
        state: .idle,
        time: 0,
        errorPresentation: .flashing,
        steadyDone: false
    )
    private var previewMode = false
    private var animationTime = 0.0
    private var sinceState = 0.0
    private var transitionProgress = 1.0
    private var transitionDuration = 1.0
    private var gapA = 97.0
    private var gapB = 247.0
    private var outerVelocity = 0.0
    private var gapSeparation = GeneratedHaloSpec.maximumGapSeparation
    private var gapRepelling = false
    private var gapRepulsionElapsed = 0.0
    private var gapRepulsionStart = GeneratedHaloSpec.minimumGapSeparation
    private var gapRepulsionDuration = 1.4
    private var gapRepulsionCount = 0
    private var smallGapAnchor = 247.0
    private var smallGapDriftElapsed = 0.0
    private var smallGapInertiaOffset = 0.0
    private var smallGapInertiaVelocity = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        startAnimationDriver(interval: Self.normalAnimationInterval)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    deinit {
        animationTimer?.invalidate()
    }

    private func startAnimationDriver(interval: TimeInterval) {
        animationTimer?.invalidate()
        lastFrameTimestamp = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.animationTimerDidFire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func setAnimationFrameInterval(_ interval: TimeInterval) {
        guard abs((animationTimer?.timeInterval ?? 0) - interval) > 0.001 else {
            return
        }
        startAnimationDriver(interval: interval)
    }

    private func animationTimerDidFire() {
        let now = CACurrentMediaTime()
        let delta = HaloMath.clamp(now - lastFrameTimestamp, 0.001, 0.08)
        lastFrameTimestamp = now
        stepAnimation(delta: delta)
    }

    func resizeForHaloSize(_ size: CGFloat) {
        let resizedBounds = NSRect(x: 0, y: 0, width: size, height: size)
        frame = resizedBounds
        bounds = resizedBounds
        layer?.frame = resizedBounds
        updateTrackingAreas()
        needsDisplay = true
    }

    var usesCommonRunLoopAnimationDriverForChecks: Bool {
        animationTimer != nil
    }

    func advanceAnimationForChecks(delta: Double) {
        stepAnimation(delta: delta)
    }

    func animationSnapshotForChecks() -> (time: Double, gapA: Double, gapB: Double) {
        (animationTime, gapA, gapB)
    }

    private func stepAnimation(delta: Double) {
        animationTime += max(0.001, min(delta, 0.08))
        sinceState += max(0.001, min(delta, 0.08))
        let targetVelocity = HaloMath.targetGapVelocity(visualState) *
            HaloMath.gapVelocityEnvelope(visualState, time: animationTime)
        outerVelocity = HaloMath.damp(
            current: outerVelocity,
            target: targetVelocity,
            delta: delta,
            response: 2.1
        )
        gapA += outerVelocity * delta

        if gapRepelling {
            gapRepulsionElapsed += delta
            let progress = HaloMath.clamp(gapRepulsionElapsed / max(0.01, gapRepulsionDuration), 0, 1)
            gapSeparation = HaloMath.lerp(
                gapRepulsionStart,
                GeneratedHaloSpec.maximumGapSeparation,
                HaloMath.magneticRepulsionEase(progress)
            )
            gapB = gapA + gapSeparation
            if progress >= 1 {
                gapRepelling = false
                gapSeparation = GeneratedHaloSpec.maximumGapSeparation
                gapB = gapA + gapSeparation
                smallGapAnchor = gapB
                smallGapDriftElapsed = 0
                smallGapInertiaOffset = 0
                smallGapInertiaVelocity = HaloMath.repulsionExitVelocityFromOrbit(outerVelocity)
            }
        } else {
            smallGapDriftElapsed += delta
            smallGapInertiaVelocity *= exp(-HaloMath.smallGapInertiaDamping(visualState) * delta)
            smallGapInertiaOffset += smallGapInertiaVelocity * delta
            gapB = smallGapAnchor +
                smallGapInertiaOffset +
                HaloMath.smallGapDriftOffset(
                    state: visualState,
                    time: smallGapDriftElapsed,
                    cycle: gapRepulsionCount
                )
            gapSeparation = HaloMath.positiveModulo(gapB - gapA, 360)
            if gapSeparation <= 41.5 || gapSeparation > 300 {
                gapSeparation = GeneratedHaloSpec.minimumGapSeparation
                gapB = gapA + gapSeparation
                gapRepelling = true
                gapRepulsionElapsed = 0
                gapRepulsionStart = gapSeparation
                gapRepulsionDuration = HaloMath.repulsionDurationFromOrbit(outerVelocity)
                gapRepulsionCount += 1
                smallGapInertiaOffset = 0
                smallGapInertiaVelocity = 0
            }
        }

        if gapA > 36_000 {
            gapA -= 36_000
            gapB -= 36_000
            smallGapAnchor -= 36_000
        }
        transitionProgress = min(1, transitionProgress + delta / max(0.01, transitionDuration))
        needsDisplay = true
    }

    func showPreview(state: HaloState, presentation: ErrorPresentation) {
        previewMode = true
        applyVisualState(state, presentation: presentation)
    }

    func useLiveState() {
        previewMode = false
        applyVisualState(aggregate.state, presentation: .flashing)
    }

    private func applyVisualState(_ state: HaloState, presentation: ErrorPresentation) {
        let nextSteadyDone = state == .done && aggregate.sessions.isEmpty
        let nextPresentation: ErrorPresentation = state == .error ? presentation : .flashing
        if visualState != state || steadyDone != nextSteadyDone || errorPresentation != nextPresentation {
            transitionFromVisual = HaloVisualModel.targetVisual(
                state: visualState,
                time: sinceState,
                errorPresentation: errorPresentation,
                steadyDone: steadyDone
            )
            sinceState = 0
            transitionProgress = 0
            if visualState == state && state == .error && errorPresentation != nextPresentation {
                transitionDuration = nextPresentation == .flashing ? 0.82 : 1.24
            } else if state == .done && nextSteadyDone {
                transitionDuration = 1.45
            } else {
                transitionDuration = GeneratedHaloSpec.transitionDuration(target: state)
            }
        }
        visualState = state
        errorPresentation = nextPresentation
        steadyDone = nextSteadyDone
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        HaloRenderer.drawPureRing(
            context: context,
            bounds: bounds,
            input: HaloRenderInput(
                state: visualState,
                errorPresentation: errorPresentation,
                steadyDone: steadyDone,
                transitionFrom: transitionFromVisual,
                time: animationTime,
                sinceState: sinceState,
                transition: HaloMath.smootherStep(transitionProgress),
                gapA: gapA,
                gapB: gapB
            )
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDraggingWindow else {
            return
        }
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pendingClickActivation = false
            onDoubleClick?()
            return
        }
        pendingClickActivation = event.clickCount == 1
        dragStart = NSEvent.mouseLocation
        dragStartInWindow = event.locationInWindow
        windowStart = window?.frame.origin
        isDraggingWindow = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick {
            onRightClick(event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart, let windowStart else {
            return
        }
        if !isDraggingWindow,
           let dragStartInWindow,
           Self.distance(from: dragStartInWindow, to: event.locationInWindow) < Self.dragActivationDistance {
            return
        }
        if !isDraggingWindow {
            isDraggingWindow = true
            pendingClickActivation = false
            setAnimationFrameInterval(Self.draggingAnimationInterval)
            onDragStarted?()
        }
        let current = NSEvent.mouseLocation
        let next = CGPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        )
        window.setFrameOrigin(next)
    }

    override func mouseUp(with event: NSEvent) {
        let completedDrag = isDraggingWindow
        if completedDrag, let frame = window?.frame {
            onMoved?(frame)
        }
        if pendingClickActivation && !completedDrag {
            onClick?()
        }
        if completedDrag {
            setAnimationFrameInterval(Self.normalAnimationInterval)
        }
        dragStart = nil
        dragStartInWindow = nil
        windowStart = nil
        isDraggingWindow = false
        pendingClickActivation = false
    }

    private static func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return sqrt(dx * dx + dy * dy)
    }
}
