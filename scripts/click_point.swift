import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: click_point.swift <x> <y>\n", stderr)
    exit(2)
}

let point = CGPoint(x: x, y: y)

CGWarpMouseCursorPosition(point)

guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
    fputs("failed to create mouse events\n", stderr)
    exit(1)
}

move.post(tap: .cghidEventTap)
usleep(120000)
down.post(tap: .cghidEventTap)
usleep(80000)
up.post(tap: .cghidEventTap)
