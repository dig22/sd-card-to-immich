import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails (RAW previews and video frames), cached for the session.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    func load(_ url: URL, size: CGFloat) async -> NSImage? {
        if let img = image(for: url) { return img }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

struct ThumbnailGrid: View {
    @EnvironmentObject var model: AppModel
    let card: CardInfo
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(card.files, id: \.url) { f in
                    ThumbnailTile(file: f, status: model.statuses[f.url] ?? .pending)
                }
            }
            .padding(2)
        }
    }
}

struct ThumbnailTile: View {
    let file: MediaFile
    let status: FileStatus
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            // The image is an overlay of a fixed-size base, so scaledToFill is cropped to the tile.
            Color.secondary.opacity(0.12)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .overlay {
                    if let image = image ?? ThumbnailCache.shared.image(for: file.url) {  // cached: no flicker
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: file.kind == .video ? "video" : "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) { badge.padding(5) }
            .overlay(alignment: .bottomLeading) {
                if file.kind != .jpg {
                    Text(file.kind == .video ? "VIDEO" : "RAW")
                        .font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(5)
                }
            }
            .opacity(isSkipped ? 0.45 : 1)
            Text(file.url.lastPathComponent).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
        }
        .help(helpText)
        .task(id: file.url) { image = await ThumbnailCache.shared.load(file.url, size: 140) }
    }

    private var isSkipped: Bool { if case .skipped = status { return true } else { return false } }

    @ViewBuilder private var badge: some View {
        switch status {
        case .pending:
            EmptyView()
        case .new:
            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        case .uploading(let p):
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle().trim(from: 0, to: max(0.03, p)).stroke(.white, lineWidth: 2.5).rotationEffect(.degrees(-90))
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
        case .inImmich:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
        case .trashed:
            Image(systemName: "trash.circle.fill").font(.system(size: 20))
                .symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
        case .skipped:
            Image(systemName: "minus.circle.fill").font(.system(size: 18))
                .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20))
                .symbolRenderingMode(.palette).foregroundStyle(.white, .red)
        }
    }

    private var helpText: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        switch status {
        case .pending: return "\(file.url.lastPathComponent) · \(size)"
        case .new: return "New: will be uploaded · \(size)"
        case .uploading(let p): return "Uploading \(Int(p * 100))%"
        case .inImmich: return "In Immich"
        case .trashed: return "Only in Immich's trash: restore it in Immich to keep it"
        case .skipped(let why): return "Skipped: \(why)"
        case .failed: return "Upload failed"
        }
    }
}

/// Counts for the legend above the grid.
struct StatusLegend: View {
    @EnvironmentObject var model: AppModel
    let card: CardInfo
    var body: some View {
        let s = card.files.map { model.statuses[$0.url] ?? .pending }
        let inImmich = s.filter { $0 == .inImmich }.count
        let new = s.filter { $0 == .new }.count
        let skipped = s.filter { if case .skipped = $0 { return true } else { return false } }.count
        let trashed = s.filter { $0 == .trashed }.count
        HStack(spacing: 14) {
            Label("\(inImmich) in Immich", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if new > 0 { Label("\(new) new", systemImage: "circle.fill").foregroundStyle(Color.accentColor) }
            if trashed > 0 { Label("\(trashed) in Immich's trash", systemImage: "trash.circle.fill").foregroundStyle(.orange) }
            if skipped > 0 { Label("\(skipped) skipped", systemImage: "minus.circle.fill").foregroundStyle(.secondary) }
            Spacer()
        }
        .font(.caption)
    }
}
