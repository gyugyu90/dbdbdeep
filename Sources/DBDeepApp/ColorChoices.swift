import SwiftUI

struct ColorChoices: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Theme.colorNames, id: \.self) { name in
                Button { selection = name } label: {
                    Circle().fill(Theme.accent(name).opacity(0.8)).frame(width: 24, height: 24)
                        .overlay { if selection == name { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        .padding(3).overlay(Circle().stroke(selection == name ? Theme.accent(name) : .clear, lineWidth: 1))
                }.buttonStyle(.plain).help(name.capitalized).accessibilityLabel(name.capitalized)
            }
        }
    }
}
