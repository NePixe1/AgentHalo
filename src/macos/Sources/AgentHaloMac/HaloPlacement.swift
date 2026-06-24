import AppKit
import CoreGraphics

struct HaloDisplaySnapshot: Equatable {
    let identifier: String
    let visibleFrame: NSRect
}

struct HaloStoredPlacement: Equatable {
    var displayIdentifier: String?
    var absoluteOrigin: NSPoint
    var relativeOffset: NSPoint?
}

struct HaloResolvedPlacement: Equatable {
    let display: HaloDisplaySnapshot
    let origin: NSPoint
    let relativeOffset: NSPoint
}

enum HaloPlacementResolver {
    static func resolve(
        _ placement: HaloStoredPlacement,
        haloSize: CGFloat,
        displays: [HaloDisplaySnapshot]
    ) -> HaloResolvedPlacement? {
        let display: HaloDisplaySnapshot
        let desiredOrigin: NSPoint

        if let identifier = placement.displayIdentifier {
            guard let match = displays.first(where: { $0.identifier == identifier }) else {
                return nil
            }
            display = match
            if let offset = placement.relativeOffset {
                desiredOrigin = NSPoint(
                    x: display.visibleFrame.minX + offset.x,
                    y: display.visibleFrame.minY + offset.y
                )
            } else {
                desiredOrigin = placement.absoluteOrigin
            }
        } else {
            let center = NSPoint(
                x: placement.absoluteOrigin.x + haloSize / 2,
                y: placement.absoluteOrigin.y + haloSize / 2
            )
            guard let match = displays.first(where: { $0.visibleFrame.contains(center) }) else {
                return nil
            }
            display = match
            desiredOrigin = placement.absoluteOrigin
        }

        let origin = clampedOrigin(desiredOrigin, haloSize: haloSize, inside: display.visibleFrame)
        return HaloResolvedPlacement(
            display: display,
            origin: origin,
            relativeOffset: NSPoint(
                x: origin.x - display.visibleFrame.minX,
                y: origin.y - display.visibleFrame.minY
            )
        )
    }

    static func capture(
        frame: NSRect,
        displays: [HaloDisplaySnapshot]
    ) -> HaloStoredPlacement? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let display = displays.first(where: { $0.visibleFrame.contains(center) })
            ?? displays.max { lhs, rhs in
                lhs.visibleFrame.intersection(frame).positiveArea
                    < rhs.visibleFrame.intersection(frame).positiveArea
            }
        guard let display, display.visibleFrame.intersects(frame) else {
            return nil
        }
        return HaloStoredPlacement(
            displayIdentifier: display.identifier,
            absoluteOrigin: frame.origin,
            relativeOffset: NSPoint(
                x: frame.minX - display.visibleFrame.minX,
                y: frame.minY - display.visibleFrame.minY
            )
        )
    }

    static func clampedOrigin(
        _ origin: NSPoint,
        haloSize: CGFloat,
        inside visibleFrame: NSRect
    ) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - haloSize),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - haloSize)
        )
    }
}

struct HaloPlacementRuntimeState {
    private(set) var isUsingTemporaryFallback = false
    var shouldPersistCurrentFrame: Bool { !isUsingTemporaryFallback }

    mutating func didUseTemporaryFallback() {
        isUsingTemporaryFallback = true
    }

    mutating func didApplyPreferredPlacement() {
        isUsingTemporaryFallback = false
    }

    mutating func didChoosePlacement() {
        isUsingTemporaryFallback = false
    }
}

enum HaloScreenIdentity {
    @MainActor
    static func identifier(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-id:\(displayID)"
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}

private extension NSRect {
    var positiveArea: CGFloat {
        guard !isNull else {
            return 0
        }
        return max(0, width) * max(0, height)
    }
}
