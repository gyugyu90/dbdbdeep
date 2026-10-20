import SwiftUI

struct ResultColumnHeader: View {
    let name: String
    let width: CGFloat
    let sortDirection: ResultGridState.SortDirection?
    let isDragging: Bool
    let dropAfter: Bool?
    let onSort: () -> Void
    let onResize: (CGFloat) -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    @State private var resizeStartWidth: CGFloat?
    @State private var isResizeHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 34).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("resultColumns"))
                    .onChanged { value in
                        NSCursor.closedHand.set()
                        onDragChanged(value.location.x)
                    }
                    .onEnded { value in
                        onDragEnded(value.location.x)
                        NSCursor.openHand.set()
                    })
                .help("Drag to move \(name)")
                .accessibilityLabel("Move \(name) column")
                .onHover { hovering in (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
            Button(action: onSort) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    if let sortDirection {
                        Image(systemName: sortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.purple)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.trailing, 8)
                .help("Sort \(name) \(sortDirection == .ascending ? "descending" : "ascending")")
                .accessibilityLabel("Sort by \(name)")
                .accessibilityValue(sortDirection.map { $0 == .ascending ? "Ascending" : "Descending" } ?? "Not sorted")
        }.opacity(isDragging ? 0.45 : 1)
            .frame(width: width, height: 34).clipped()
            .background(dropAfter != nil ? Theme.tint("lavender") : Theme.sidebar)
            .overlay(alignment: .trailing) {
                Rectangle().fill(isResizeHovered || resizeStartWidth != nil ? Theme.purple : Theme.line)
                    .frame(width: 1).frame(width: 8, height: 34, alignment: .trailing).contentShape(Rectangle())
                    .onHover { hovering in
                        isResizeHovered = hovering
                        (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if resizeStartWidth == nil { resizeStartWidth = width }
                            onResize((resizeStartWidth ?? width) + value.translation.width)
                        }
                        .onEnded { _ in resizeStartWidth = nil })
                    .help("Drag to resize \(name)")
                    .accessibilityLabel("Resize \(name) column")
            }
            .overlay(alignment: dropAfter == true ? .trailing : .leading) {
                if dropAfter != nil {
                    Theme.purple.frame(width: 2).allowsHitTesting(false)
                }
            }
    }
}
