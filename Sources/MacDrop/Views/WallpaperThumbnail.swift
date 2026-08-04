import AppKit
import MacDropCore
import SwiftUI

struct WallpaperThumbnail: View {
    let wallpaper: Wallpaper
    var height: CGFloat = 130

    @EnvironmentObject private var appModel: AppModel
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .background(.black)
        .task(id: wallpaper.id) {
            let url = appModel.paths.thumbnailURL(for: wallpaper)
            image = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }
}
