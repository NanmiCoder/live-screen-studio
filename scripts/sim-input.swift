// Posts synthetic mouse input for smoke tests.
//   swift scripts/sim-input.swift where
//   swift scripts/sim-input.swift click [button=2]
//   swift scripts/sim-input.swift hold-scroll <notches> [button=2]   (positive = wheel away from you)
//   swift scripts/sim-input.swift move <x> <y> [seconds=0]           (global coordinates, top-left origin)
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().map { $0 }
let source = CGEventSource(stateID: .hidSystemState)
var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

func post(_ type: CGEventType, button: Int) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                        mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
    event.post(tap: .cghidEventTap)
}

switch args.first {
case "where":
    print(location)
case "click":
    let button = args.count > 1 ? Int(args[1])! : 2
    post(.otherMouseDown, button: button)
    usleep(60_000)
    post(.otherMouseUp, button: button)
case "hold-scroll":
    let notches = Int(args[1])!
    let button = args.count > 2 ? Int(args[2])! : 2
    post(.otherMouseDown, button: button)
    usleep(60_000)
    for _ in 0..<abs(notches) {
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                wheel1: Int32(notches > 0 ? 1 : -1), wheel2: 0, wheel3: 0)!.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    post(.otherMouseUp, button: button)
case "move":
    let target = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    let seconds = args.count > 3 ? Double(args[3])! : 0
    let start = location
    let steps = max(1, Int(seconds * 120))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
            .post(tap: .cghidEventTap)
        if steps > 1 { usleep(useconds_t(1_000_000 / 120)) }
    }
default:
    print("usage: where | click [button] | hold-scroll <notches> [button] | move <x> <y> [seconds]")
    exit(1)
}
