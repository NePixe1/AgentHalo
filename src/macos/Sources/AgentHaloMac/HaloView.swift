import AppKit
import AgentHaloCore
import QuartzCore

@MainActor
final class HaloView: NSView {
    private static let dragActivationDistance = 3.0
    // Active cadence runs at 60fps for smoother orbit motion. This is cheap
    // because the ring is rendered as CAShapeLayer sublayers, so Core Animation
    // rasterizes on the render server (GPU) each frame instead of the app
    // rasterizing a backing store via draw(_:). The per-frame CPU cost is just
    // the path/width/color property sets in applyRingLayers, so 60fps no longer
    // carries the ripc_DrawPath cost that previously justified lowering it.
    private static let normalAnimationInterval = 1.0 / 60.0
    private static let lowPowerAnimationInterval = 1.0 / 30.0

    var aggregate = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.codex.offlineDetail,
        sessions: [],
        focusedAgent: .codex
    ) {
        didSet {
            guard !previewMode else {
                return
            }
            applyVisualState(
                aggregate.state,
                presentation: liveErrorPresentation,
                answerStreaming: aggregate.answerStreaming
            )
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
    var isDragging: Bool { isDraggingWindow }
    private var pendingClickActivation = false
    nonisolated(unsafe) private var animationTimer: Timer?
    private var systemOverlaySuspended = false
    private var pointerInsideHoverSurface = false
    private var ringLayers: [CAShapeLayer] = []
    private var lastFrameTimestamp = CACurrentMediaTime()
    private var visualState: HaloState = .idle
    private var errorPresentation: ErrorPresentation = .flashing
    private var liveErrorPresentation: ErrorPresentation = .flashing
    private var steadyDone = false
    private var answerStreaming = false
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
        setupRingLayers()
        startAnimationDriver(interval: preferredAnimationInterval())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    deinit {
        animationTimer?.invalidate()
    }

    // Host the ring as CAShapeLayer sublayers so Core Animation rasterizes on the
    // render server (GPU) instead of the app rasterizing a backing store via
    // draw(_:) every frame. All eight layers share one two-arc CGPath; only line
    // width and stroke color differ per layer.
    private func setupRingLayers() {
        guard let host = layer else { return }
        var layers: [CAShapeLayer] = []
        for _ in 0..<HaloRenderer.ringLayerCount {
            let shape = CAShapeLayer()
            shape.fillColor = NSColor.clear.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.frame = bounds
            host.addSublayer(shape)
            layers.append(shape)
        }
        ringLayers = layers
        redrawRing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        for layer in ringLayers {
            layer.contentsScale = scale
        }
    }

    private func currentRenderInput() -> HaloRenderInput {
        HaloRenderInput(
            state: visualState,
            errorPresentation: errorPresentation,
            steadyDone: steadyDone,
            answerStreaming: answerStreaming,
            transitionFrom: transitionFromVisual,
            time: animationTime,
            sinceState: sinceState,
            transition: HaloMath.smootherStep(transitionProgress),
            gapA: gapA,
            gapB: gapB
        )
    }

    func redrawRing() {
        guard !ringLayers.isEmpty else { return }
        HaloRenderer.applyRingLayers(ringLayers, bounds: bounds, input: currentRenderInput())
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
        guard !systemOverlaySuspended else {
            return
        }
        guard abs((animationTimer?.timeInterval ?? 0) - interval) > 0.001 else {
            return
        }
        startAnimationDriver(interval: interval)
    }

    private func animationTimerDidFire() {
        guard !systemOverlaySuspended else {
            return
        }
        let now = CACurrentMediaTime()
        let delta = HaloMath.clamp(now - lastFrameTimestamp, 0.001, 0.08)
        lastFrameTimestamp = now
        stepAnimation(delta: delta)
    }

    func setSystemOverlaySuspended(_ suspended: Bool) {
        guard systemOverlaySuspended != suspended else {
            return
        }
        systemOverlaySuspended = suspended
        if suspended {
            animationTimer?.invalidate()
            animationTimer = nil
            dragStart = nil
            dragStartInWindow = nil
            windowStart = nil
            isDraggingWindow = false
            pendingClickActivation = false
        } else {
            startAnimationDriver(interval: preferredAnimationInterval())
        }
        redrawRing()
    }

    func resizeForHaloSize(_ size: CGFloat) {
        let resizedBounds = NSRect(x: 0, y: 0, width: size, height: size)
        frame = resizedBounds
        bounds = resizedBounds
        layer?.frame = resizedBounds
        for shape in ringLayers {
            shape.frame = resizedBounds
        }
        updateTrackingAreas()
        redrawRing()
    }

    var usesCommonRunLoopAnimationDriverForChecks: Bool {
        animationTimer != nil
    }

    var hasAnimationDriverForChecks: Bool {
        animationTimer != nil
    }

    func advanceAnimationForChecks(delta: Double) {
        guard !systemOverlaySuspended else {
            return
        }
        stepAnimation(delta: delta)
    }

    func animationSnapshotForChecks() -> (time: Double, gapA: Double, gapB: Double) {
        (animationTime, gapA, gapB)
    }

    func updateLiveAggregate(
        _ aggregate: AggregateSnapshot,
        errorPresentation: ErrorPresentation
    ) {
        liveErrorPresentation = errorPresentation
        self.aggregate = aggregate
    }

    private func stepAnimation(delta: Double) {
        animationTime += max(0.001, min(delta, 0.08))
        sinceState += max(0.001, min(delta, 0.08))
        let currentRenderState = renderState(state: visualState, answerStreaming: answerStreaming)
        let targetVelocity = HaloMath.targetGapVelocity(currentRenderState) *
            HaloMath.gapVelocityEnvelope(currentRenderState, time: animationTime)
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
            smallGapInertiaVelocity *= exp(-HaloMath.smallGapInertiaDamping(currentRenderState) * delta)
            smallGapInertiaOffset += smallGapInertiaVelocity * delta
            gapB = smallGapAnchor +
                smallGapInertiaOffset +
                HaloMath.smallGapDriftOffset(
                    state: currentRenderState,
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
        redrawRing()
        setAnimationFrameInterval(preferredAnimationInterval())
    }

    func showPreview(state: HaloState, presentation: ErrorPresentation) {
        previewMode = true
        applyVisualState(state, presentation: presentation, answerStreaming: false)
    }

    func useLiveState() {
        previewMode = false
        applyVisualState(
            aggregate.state,
            presentation: liveErrorPresentation,
            answerStreaming: aggregate.answerStreaming
        )
    }

    private func applyVisualState(_ state: HaloState, presentation: ErrorPresentation, answerStreaming nextAnswerStreaming: Bool) {
        let nextSteadyDone = state == .done && aggregate.sessions.isEmpty
        let nextPresentation: ErrorPresentation = state == .error ? presentation : .flashing
        if visualState != state
            || steadyDone != nextSteadyDone
            || errorPresentation != nextPresentation
            || answerStreaming != nextAnswerStreaming {
            transitionFromVisual = HaloVisualModel.targetVisual(
                state: renderState(state: visualState, answerStreaming: answerStreaming),
                time: sinceState,
                errorPresentation: errorPresentation,
                steadyDone: steadyDone
            )
            sinceState = 0
            transitionProgress = 0
            if nextAnswerStreaming {
                transitionDuration = 0.92
            } else if answerStreaming {
                transitionDuration = 1.12
            } else if visualState == state && state == .error && errorPresentation != nextPresentation {
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
        answerStreaming = nextAnswerStreaming
        setAnimationFrameInterval(preferredAnimationInterval())
        redrawRing()
    }

    private func preferredAnimationInterval() -> TimeInterval {
        if isLowPowerAnimationState {
            return Self.lowPowerAnimationInterval
        }
        return Self.normalAnimationInterval
    }

    private var isLowPowerAnimationState: Bool {
        guard transitionProgress >= 0.999,
              !answerStreaming else {
            return false
        }
        if visualState == .error, errorPresentation == .flashing {
            return false
        }
        return visualState == .idle || (visualState == .done && steadyDone)
    }

    private func renderState(state: HaloState, answerStreaming: Bool) -> HaloState {
        answerStreaming ? .done : state
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !systemOverlaySuspended else {
            return
        }
        setPointerInsideHoverSurface(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard !systemOverlaySuspended else {
            return
        }
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
        guard !systemOverlaySuspended else {
            return
        }
        if let onRightClick {
            onRightClick(event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !systemOverlaySuspended else {
            return
        }
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
            pointerInsideHoverSurface = false
            animationTimer?.invalidate()
            animationTimer = nil
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
        guard !systemOverlaySuspended else {
            return
        }
        let completedDrag = isDraggingWindow
        if completedDrag, let frame = window?.frame {
            onMoved?(frame)
        }
        if pendingClickActivation && !completedDrag {
            onClick?()
        }
        if completedDrag {
            startAnimationDriver(interval: preferredAnimationInterval())
        }
        dragStart = nil
        dragStartInWindow = nil
        windowStart = nil
        isDraggingWindow = false
        pendingClickActivation = false
        updateHoverState(with: event)
    }

    private func updateHoverState(with event: NSEvent) {
        guard !systemOverlaySuspended, !isDraggingWindow else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        setPointerInsideHoverSurface(HaloGeometry.contains(point: point, in: bounds))
    }

    private func setPointerInsideHoverSurface(_ isInside: Bool) {
        guard pointerInsideHoverSurface != isInside else {
            return
        }
        pointerInsideHoverSurface = isInside
        if isInside {
            onMouseEntered?()
        } else {
            onMouseExited?()
        }
    }

    private static func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return sqrt(dx * dx + dy * dy)
    }
}
