import AppKit
import AgentHaloCore

@MainActor
final class HaloView: NSView {
    var aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: "Codex is standing by",
        sessions: []
    )
    var onDoubleClick: (() -> Void)?
    var onMoved: ((NSRect) -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var animationTimer: Timer?
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        animationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stepAnimation),
            userInfo: nil,
            repeats: true
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    @objc private func stepAnimation() {
        phase += speedForCurrentState()
        if phase > 360 {
            phase -= 360
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.36
        let color = colorForCurrentState()
        let breath = breathForCurrentState()

        context.setLineCap(.round)
        context.setLineWidth(12)
        context.setStrokeColor(color.withAlphaComponent(0.18 + breath * 0.20).cgColor)
        drawHaloArcs(context: context, center: center, radius: radius, offset: phase)

        context.setLineWidth(6)
        context.setStrokeColor(color.withAlphaComponent(0.78 + breath * 0.22).cgColor)
        drawHaloArcs(context: context, center: center, radius: radius, offset: phase)

        context.setLineWidth(2)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.55 + breath * 0.35).cgColor)
        drawHaloArcs(context: context, center: center, radius: radius - 4, offset: phase + 3)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart, let windowStart else {
            return
        }
        let current = NSEvent.mouseLocation
        let next = CGPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        )
        window.setFrameOrigin(next)
    }

    override func mouseUp(with event: NSEvent) {
        if let frame = window?.frame {
            onMoved?(frame)
        }
        dragStart = nil
        windowStart = nil
    }

    func colorForCurrentState() -> NSColor {
        switch aggregate.state {
        case .idle: NSColor(calibratedRed: 0.82, green: 0.88, blue: 0.90, alpha: 1)
        case .thinking: NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.22, alpha: 1)
        case .working: NSColor(calibratedRed: 0.16, green: 0.73, blue: 1.00, alpha: 1)
        case .done: NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.48, alpha: 1)
        case .attention: NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.32, alpha: 1)
        case .error: NSColor(calibratedRed: 1.00, green: 0.14, blue: 0.18, alpha: 1)
        }
    }

    private func speedForCurrentState() -> CGFloat {
        switch aggregate.state {
        case .thinking: 1.8
        case .working: 2.8
        case .done: 0.7
        case .attention: 1.4
        case .error: 2.2
        case .idle: 0.35
        }
    }

    private func breathForCurrentState() -> CGFloat {
        switch aggregate.state {
        case .idle:
            0.08
        case .error:
            0.35 + 0.65 * abs(sin(phase * .pi / 45))
        case .attention:
            0.25 + 0.65 * abs(sin(phase * .pi / 80))
        case .done:
            0.18 + 0.28 * abs(sin(phase * .pi / 140))
        case .thinking, .working:
            0.22 + 0.52 * abs(sin(phase * .pi / 110))
        }
    }

    private func drawHaloArcs(
        context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        offset: CGFloat
    ) {
        let startA = radians(-52 + offset)
        let endA = radians(88 + offset)
        let startB = radians(106 + offset)
        let endB = radians(300 + offset)
        context.addArc(center: center, radius: radius, startAngle: startA, endAngle: endA, clockwise: false)
        context.strokePath()
        context.addArc(center: center, radius: radius, startAngle: startB, endAngle: endB, clockwise: false)
        context.strokePath()
    }

    private func radians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
    }
}
