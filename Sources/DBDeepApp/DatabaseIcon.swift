import AppKit
import SwiftUI
import DBDeepCore

struct DatabaseIcon: View {
    let kind: DBConnection.Kind
    var size: CGFloat = 18

    private static var resources: Bundle {
        if let url = Bundle.main.url(forResource: "dbdbdeep_DBDeepApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }

    private static let images: [DBConnection.Kind: NSImage] = {
        let files: [(DBConnection.Kind, String, String)] = [(.oracle, "oracle", "ico"), (.mongodb, "mongodb", "ico"), (.sample, "sqlite", "png")]
        return Dictionary(uniqueKeysWithValues: files.compactMap { kind, name, ext in
            guard let url = resources.url(forResource: name, withExtension: ext, subdirectory: "DatabaseIcons"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = false
            return (kind, image)
        })
    }()

    var body: some View {
        Group {
            if let image = Self.images[kind] {
                Image(nsImage: image).resizable().renderingMode(.original).scaledToFit()
            } else {
                Image(systemName: "externaldrive").resizable().scaledToFit().foregroundStyle(Theme.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
