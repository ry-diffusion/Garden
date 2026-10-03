import LinkPresentation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Brand logos, fetched on device from the brand's own website (LinkPresentation reads its
/// apple-touch-icon / favicon) and cached on disk. No third-party logo service ever sees which
/// merchants you pay. Fetches run one at a time; failures are remembered for the session.
@Observable
final class LogoStore {
    static let shared = LogoStore()

    private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var queueTail: Task<Void, Never>?

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for domain: String) -> PlatformImage? { images[domain] }

    /// Loads from disk, or queues a fetch from the brand's site.
    func load(_ domain: String) {
        guard images[domain] == nil, !requested.contains(domain) else { return }
        requested.insert(domain)

        let file = Self.directory.appendingPathComponent(domain + ".png")
        let miss = Self.directory.appendingPathComponent(domain + ".miss")
        if let data = try? Data(contentsOf: file), let image = PlatformImage(data: data) {
            images[domain] = image
            return
        }
        // A site that had no usable icon is retried after a week, not on every launch.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: miss.path),
           let date = attributes[.modificationDate] as? Date, date.timeIntervalSinceNow > -7 * 86_400 {
            return
        }
        let previous = queueTail
        queueTail = Task { [weak self] in
            await previous?.value
            guard let image = await Self.fetch(domain) else {
                FileManager.default.createFile(atPath: miss.path, contents: nil)
                return
            }
            if let data = image.pngRepresentation { try? data.write(to: file, options: .atomic) }
            self?.images[domain] = image
        }
    }

    /// Below this a favicon looks blurry in a 36pt badge; the category symbol reads better.
    nonisolated private static let minimumPixels: CGFloat = 48

    /// 1. /apple-touch-icon.png  2. the largest icon the homepage declares  3. LinkPresentation.
    nonisolated private static func fetch(_ domain: String) async -> PlatformImage? {
        for host in [domain, "www." + domain] {
            if let url = URL(string: "https://\(host)/apple-touch-icon.png"), let image = await download(url) { return image }
        }
        for host in [domain, "www." + domain] {
            if let page = URL(string: "https://\(host)"), let image = await declaredIcon(on: page) { return image }
        }
        return await linkPresentationIcon(domain)
    }

    nonisolated private static func download(_ url: URL) async -> PlatformImage? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 Garden", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = PlatformImage(data: data), image.pixelWidth >= minimumPixels
        else { return nil }
        return image
    }

    /// Reads `<link rel="apple-touch-icon" | "icon" sizes=…>` from the homepage, biggest first. SVGs are skipped.
    nonisolated private static func declaredIcon(on page: URL) async -> PlatformImage? {
        var request = URLRequest(url: page, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 Garden", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1)
        else { return nil }
        let base = response.url ?? page

        var candidates: [(url: URL, score: Int)] = []
        for tag in html.matches(of: #/<link\b[^>]*>/#.ignoresCase()) {
            let text = String(tag.output)
            guard let rel = attribute("rel", in: text)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: text), !href.lowercased().hasSuffix(".svg"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            let size = attribute("sizes", in: text).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            let score = (rel.contains("apple-touch") ? 1_000 : 0) + size
            candidates.append((url, score))
        }
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(3) {
            if let image = await download(candidate.url) { return image }
        }
        return nil
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            return rest.split(whereSeparator: { $0 == " " || $0 == ">" }).first.map(String.init)
        }
        return rest.dropFirst().split(separator: quote, maxSplits: 1).first.map(String.init)
    }

    nonisolated private static func linkPresentationIcon(_ domain: String) async -> PlatformImage? {
        guard let url = URL(string: "https://\(domain)") else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let iconProvider = metadata.iconProvider
        else { return nil }
        let image: PlatformImage? = await withCheckedContinuation { continuation in
            _ = iconProvider.loadObject(ofClass: PlatformImage.self) { @Sendable object, _ in
                continuation.resume(returning: object as? PlatformImage)
            }
        }
        guard let image, image.pixelWidth >= minimumPixels else { return nil }
        return image
    }
}

private extension PlatformImage {
    nonisolated var pixelWidth: CGFloat {
        #if canImport(UIKit)
        size.width * scale
        #else
        CGFloat(representations.map(\.pixelsWide).max() ?? Int(size.width))
        #endif
    }

    var pngRepresentation: Data? {
        #if canImport(UIKit)
        pngData()
        #else
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// A merchant's logo when we have one, otherwise a tinted symbol.
struct MerchantBadge: View {
    let domain: String?
    let symbol: String
    let tint: Color
    var size: CGFloat = Theme.rowIconSize
    @State private var logos = LogoStore.shared

    var body: some View {
        Group {
            if let domain, let logo = logos.image(for: domain) {
                Image(platformImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: size * 0.28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
            } else {
                SymbolBadge(symbol: symbol, tint: tint, size: size)
            }
        }
        .task(id: domain) {
            if let domain { logos.load(domain) }
        }
    }
}

/// The leading badge of a movement: brand logo, else category / transfer / income symbol.
struct MovementBadge: View {
    let movement: Movement
    var size: CGFloat = Theme.rowIconSize

    var body: some View {
        MerchantBadge(domain: movement.merchant?.domain, symbol: symbol, tint: tint, size: size)
    }

    private var symbol: String {
        if movement.kind == .transfer { return "arrow.left.arrow.right" }
        if movement.kind == .income || movement.kind == .extraIncome { return movement.category?.symbol ?? "arrow.down.circle" }
        if movement.person != nil { return "person" }
        return movement.category?.symbol ?? "questionmark"
    }

    private var tint: Color {
        if movement.kind == .transfer { return .gray }
        if movement.kind == .income || movement.kind == .extraIncome { return .green }
        return movement.category?.tint.color ?? .gray
    }
}
