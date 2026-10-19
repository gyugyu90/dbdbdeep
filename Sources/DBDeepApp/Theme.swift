import AppKit
import SwiftUI

enum Theme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }

    static let ink = adaptive(0x393747, 0xE9E4F3)
    static let secondary = adaptive(0x95929F, 0xA8A1B6)
    static let purple = adaptive(0x8D75D6, 0xB59AF2)
    static let onAccent = adaptive(0xFFFFFF, 0x251B39)
    static let line = adaptive(0xEDEBF1, 0x34303F)
    static let surface = adaptive(0xFFFFFF, 0x23212D)
    static let canvas = adaptive(0xFCFBFE, 0x1E1C27)
    static let sidebar = adaptive(0xF7F6FA, 0x1A1922)
    static let bookmarks = adaptive(0xFCFAF8, 0x211C26)
    static let green = adaptive(0x6CA58E, 0x8AC4A7)
    static let editorText = adaptive(0x555064, 0xDAD3E7)
    static let sqlNumber = adaptive(0xC59362, 0xE8B985)
    static let sqlString = adaptive(0x6C9D87, 0x94C7AB)
    static let sqlComment = adaptive(0xAAA5B6, 0x928A9F)
    static let lineNumber = adaptive(0xC2BDCC, 0x81778E)
    static let colorNames = ["lavender", "mint", "peach", "yellow", "blue", "rose"]
    static func tint(_ name: String) -> Color {
        switch name {
        case "mint": return adaptive(0xE7F3ED, 0x233B33)
        case "peach": return adaptive(0xFFF0E8, 0x443027)
        case "yellow": return adaptive(0xFFF7DB, 0x403823)
        case "blue": return adaptive(0xEAF1FC, 0x26344A)
        case "rose": return adaptive(0xFBEAF0, 0x442A39)
        default: return adaptive(0xF0EBFC, 0x352B4D)
        }
    }
    static func accent(_ name: String) -> Color {
        switch name {
        case "mint": return adaptive(0x77AE95, 0x94C9AD)
        case "peach": return adaptive(0xDD9D79, 0xE9B291)
        case "yellow": return adaptive(0xC7A64E, 0xE0C274)
        case "blue": return adaptive(0x80A5D8, 0x9BBCE9)
        case "rose": return adaptive(0xCE88A5, 0xE4A0BE)
        default: return purple
        }
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 25, height: 25).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(help)
    }
}

struct SoftButton: View {
    let title: String
    let icon: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)); Text(title).font(.system(size: 12, weight: .semibold)) }
                .padding(.horizontal, 13).frame(height: 32)
                .foregroundStyle(prominent ? Theme.onAccent : Theme.ink)
                .background(prominent ? Theme.purple : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? .clear : Theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 11))
            if !text.isEmpty { IconButton(icon: "xmark.circle.fill", help: "Clear search") { text = "" } }
        }.foregroundStyle(Theme.secondary).padding(.horizontal, 10).frame(height: 32)
            .background(Theme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
    }
}

struct CapsuleTag: View {
    let text: String
    var color: String = "lavender"
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent(color)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.tint(color), in: Capsule())
    }
}
