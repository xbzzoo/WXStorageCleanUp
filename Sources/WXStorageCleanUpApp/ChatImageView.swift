import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WXStorageCleanUpCore

private actor ImagePreviewCache {
    static let shared = ImagePreviewCache()
    private let cache = NSCache<NSString, NSData>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    func image(root: URL, path: String, key: String, large: Bool) throws -> Data {
        try Task.checkCancellation()
        let url = try FileSafety.checkedURL(relativePath: path, root: root)
        let identity = try FileSafety.identity(url)
        guard identity.bytes <= 32 * 1024 * 1024 else { throw StorageError.invalid("图片超过 32MB 预览限制。") }
        let cacheKey = "\(url.path)|\(identity.bytes)|\(identity.modifiedSeconds)|\(identity.modifiedNanos)|\(large)|\(key)" as NSString
        if let value = cache.object(forKey: cacheKey) { return value as Data }
        let data = try LocalImageDecoder.decode(Data(contentsOf: url), imageKey: key)
        guard try FileSafety.identity(url) == identity else { throw StorageError.invalid("图片已变化，请重新加载。") }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: large ? 1600 : 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw StorageError.invalid("图片格式暂不支持或文件已损坏，可在 Finder 中查看原文件。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw StorageError.invalid("无法创建预览。") }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw StorageError.invalid("无法创建预览。") }
        let result = output as Data
        cache.setObject(result as NSData, forKey: cacheKey, cost: result.count)
        return result
    }
}

struct ChatImageView: View {
    @EnvironmentObject var model: AppModel
    let root: URL
    let path: String
    var imageKey = ""
    var large = false
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Button { expanded = true } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: large ? 1000 : 260, maxHeight: large ? 650 : 180)
                }.buttonStyle(.plain).disabled(large)
            } else if let failure {
                Label(failure, systemImage: "photo.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)
            } else { ProgressView("正在加载图片…").font(.caption) }
            Button("在 Finder 中显示图片") {
                guard !model.busy else { return }
                if let url = try? FileSafety.checkedURL(relativePath: path, root: root) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.buttonStyle(.link).font(.caption)
        }
        .task(id: path + imageKey + String(large)) {
            image = nil; failure = nil
            do {
                let bytes = try await ImagePreviewCache.shared.image(root: root, path: path, key: imageKey, large: large)
                guard !Task.isCancelled else { return }
                image = NSImage(data: bytes)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .sheet(isPresented: $expanded) {
            VStack { ChatImageView(root: root, path: path, imageKey: imageKey, large: true); Button("关闭") { expanded = false } }
                .padding(24).frame(minWidth: 640, minHeight: 400)
                .modifier(GlobalLoading()).interactiveDismissDisabled(model.busy)
        }
    }
}

struct ChatImagesView: View {
    @EnvironmentObject var model: AppModel
    let root: URL
    let paths: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var images: [String] = []
    @State private var limit = 100
    @State private var keyDraft = ""
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("聊天图片").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            DisclosureGroup("高级：已有图片密钥") {
                HStack { SecureField("16 字节文本或 32 位十六进制图片 AES 密钥", text: $keyDraft); Button("应用") { key = keyDraft } }
                Text("仅用于本次内存预览，不会写入文件。图片密钥与数据库密钥不同。").font(.caption)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260))], spacing: 20) {
                    ForEach(images.prefix(limit), id: \.self) { path in ChatImageView(root: root, path: path, imageKey: key).frame(minHeight: 100) }
                }
                if images.count > limit { Button("加载更多图片") { limit += 100 }.padding() }
                if images.isEmpty { Text("没有找到本地图片附件").foregroundStyle(.secondary).padding() }
            }
        }.padding(24).frame(width: 900, height: 650)
            .modifier(GlobalLoading()).interactiveDismissDisabled(model.busy)
            .task {
                images = await Task.detached(priority: .userInitiated) {
                    paths.filter { $0.contains("/Img/") || ["jpg", "jpeg", "png", "gif", "heic", "webp", "dat"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
                }.value
            }
    }
}
