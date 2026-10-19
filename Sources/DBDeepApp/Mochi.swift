import SwiftUI

struct Mochi: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 42
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31).fill(Color(hex: colorScheme == .dark ? 0x3C2C53 : 0xE8E0FC))
            if colorScheme == .dark {
                MochiHorns().fill(Color(hex: 0xEDA5BC))
                    .frame(width: size * 0.73, height: size * 0.3).offset(y: -size * 0.25)
            }
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


struct MochiHorns: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for mirrored in [false, true] {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + (mirrored ? 1 - x : x) * rect.width, y: rect.minY + y * rect.height)
            }
            path.move(to: point(0.1, 1))
            path.addCurve(to: point(0.04, 0.05), control1: point(0, 0.72), control2: point(0.01, 0.24))
            path.addCurve(to: point(0.34, 0.85), control1: point(0.08, 0), control2: point(0.13, 0.68))
            path.closeSubpath()
        }
        return path
    }
}
