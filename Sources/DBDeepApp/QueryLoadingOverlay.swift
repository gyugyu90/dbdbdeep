import SwiftUI

struct QueryLoadingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = false
    let status: String

    var body: some View {
        ZStack {
            Color.white.opacity(0.5)
            VStack(spacing: 7) {
                ZStack(alignment: .bottom) {
                    Ellipse().fill(Theme.purple.opacity(0.18))
                        .frame(width: 32, height: 5).scaleEffect(raised ? 0.8 : 1)
                    Mochi(size: 48).offset(y: raised ? -14 : -6)
                }.frame(width: 64, height: 62)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: raised)
                    .accessibilityHidden(true)
                Text("Waiting for results…")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink)
                Text(status).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }.padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: 280)
                .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.06), radius: 16, y: 5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waiting for query results")
            .accessibilityValue(status)
            .onAppear { raised = !reduceMotion }
            .onChange(of: reduceMotion) { _, value in raised = !value }
    }
}
