import AppKit
import SwiftUI

@main
struct MakeIcon {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let colorScheme: ColorScheme = CommandLine.arguments.contains("--dark") ? .dark : .light
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let renderer = ImageRenderer(content: Mochi(size: 880)
            .frame(width: 1024, height: 1024)
            .environment(\.colorScheme, colorScheme))

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                renderer.scale = CGFloat(size * scale) / 1024
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
