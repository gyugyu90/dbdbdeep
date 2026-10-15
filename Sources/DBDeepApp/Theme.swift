import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum Theme {
    static let ink = Color(hex: 0x393747)
    static let secondary = Color(hex: 0x95929F)
    static let purple = Color(hex: 0x8D75D6)
    static let line = Color(hex: 0xEDEBF1)
    static let canvas = Color(hex: 0xFCFBFE)
    static let sidebar = Color(hex: 0xF7F6FA)
    static let green = Color(hex: 0x6CA58E)
    static let colorNames = ["lavender", "mint", "peach", "yellow", "blue", "rose"]
    static func tint(_ name: String) -> Color {
        switch name {
        case "mint": return Color(hex: 0xE7F3ED)
        case "peach": return Color(hex: 0xFFF0E8)
        case "yellow": return Color(hex: 0xFFF7DB)
        case "blue": return Color(hex: 0xEAF1FC)
        case "rose": return Color(hex: 0xFBEAF0)
        default: return Color(hex: 0xF0EBFC)
        }
    }
    static func accent(_ name: String) -> Color {
        switch name {
        case "mint": return Color(hex: 0x77AE95)
        case "peach": return Color(hex: 0xDD9D79)
        case "yellow": return Color(hex: 0xC7A64E)
        case "blue": return Color(hex: 0x80A5D8)
        case "rose": return Color(hex: 0xCE88A5)
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
                .foregroundStyle(prominent ? .white : Theme.ink)
                .background(prominent ? Theme.purple : Color.white, in: RoundedRectangle(cornerRadius: 8))
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
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
    }
}

struct Mochi: View {
    var size: CGFloat = 42
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31).fill(Color(hex: 0xE8E0FC))
            VStack(spacing: -size * 0.07) {
                Ellipse().fill(Color(hex: 0xA78DDF)).frame(width: size * 0.55, height: size * 0.18)
                ZStack {
                    UnevenRoundedRectangle(bottomLeadingRadius: size * 0.16, bottomTrailingRadius: size * 0.16).fill(Color(hex: 0xBFA9EA))
                    HStack(spacing: size * 0.12) {
                        Circle().fill(Color(hex: 0x5C487B)).frame(width: size * 0.055, height: size * 0.055)
                        Text("ᴗ").font(.system(size: size * 0.19, weight: .bold)).foregroundStyle(Color(hex: 0x5C487B)).offset(y: size * 0.015)
                        Circle().fill(Color(hex: 0x5C487B)).frame(width: size * 0.055, height: size * 0.055)
                    }
                }.frame(width: size * 0.55, height: size * 0.36)
            }
        }.frame(width: size, height: size)
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
