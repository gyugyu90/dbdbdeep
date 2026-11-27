import AppKit
import Combine

final class CommandKeyboard: ObservableObject {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { Self.normalize($0) }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    static func character(in event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return keys[event.keyCode] }
        return characters.unicodeScalars.allSatisfy(\.isASCII) ? characters.lowercased() : keys[event.keyCode]
    }

    static func normalize(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty,
              let original = event.charactersIgnoringModifiers,
              !original.unicodeScalars.allSatisfy(\.isASCII), let character = keys[event.keyCode] else { return event }
        let text = event.modifierFlags.contains(.shift) ? character.uppercased() : character
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private static let keys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m", 27: "-", 44: "/"
    ]
}
