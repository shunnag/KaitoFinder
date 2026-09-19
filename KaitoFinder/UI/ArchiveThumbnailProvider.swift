import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 表示された小さい画像だけを取り出す。選択・進捗シート・パスワード UI とは独立させる。
@MainActor final class ArchiveThumbnailProvider {
    typealias Generate = @MainActor (URL, QLThumbnailGenerator.Request) async throws -> NSImage

    private final class Production {
        let progress = Progress()
        var request: QLThumbnailGenerator.Request?
        var task: Task<Void, Never>?
    }

    private let materializer: EntryMaterializer
    private let session: ArchiveSession
    private let generation: UInt64
    private let pointSize: CGFloat
    private let scale: CGFloat
    private let generate: Generate
    private var cache: [ObjectIdentifier: NSImage] = [:]
    private var requested: Set<ObjectIdentifier> = []
    private var queue: [EntryNode] = []
    private var inFlight: [ObjectIdentifier: Production] = [:]
    private var cancelled = false
    private var cancellation: Task<Void, Never>?
    var didProduce: ((EntryNode) -> Void)?
    var isIdle: Bool { queue.isEmpty && inFlight.isEmpty }

    convenience init(materializer: EntryMaterializer, session: ArchiveSession, generation: UInt64,
                     pointSize: CGFloat = 16, scale: CGFloat = 2) {
        self.init(materializer: materializer, session: session, generation: generation,
                  pointSize: pointSize, scale: scale) { _, request in
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation.nsImage
        }
    }

    // 実際の抽出を通したまま、生成の完了順序と取消しをテストで固定できる。
    init(materializer: EntryMaterializer, session: ArchiveSession, generation: UInt64,
         pointSize: CGFloat = 16, scale: CGFloat = 2, generate: @escaping Generate) {
        self.materializer = materializer
        self.session = session
        self.generation = generation
        self.pointSize = pointSize
        self.scale = scale
        self.generate = generate
    }

    /// 生成を始めずに、既にあるサムネイルだけを返す（ドラッグ画像など、副作用を持ち込めない場面向け）。
    func cachedThumbnail(for node: EntryNode) -> NSImage? { cache[ObjectIdentifier(node)] }

    func thumbnail(for node: EntryNode) -> NSImage? {
        guard !cancelled else { return nil }
        let id = ObjectIdentifier(node)
        if let image = cache[id] { return image }
        // 暗号化の除外は await より前に行い、session の password prompt に到達させない。
        guard !node.isDirectory, let entry = node.entry, entry.kind == .file,
              !entry.isEncrypted, !entry.isIncomplete, entry.solidGroup < 0,
              let size = entry.uncompressedSize, size <= 8 * 1024 * 1024,
              UTType(filenameExtension: (node.name as NSString).pathExtension)?.conforms(to: .image) == true,
              requested.insert(id).inserted else { return nil }
        queue.append(node)
        startNext()
        return nil
    }

    private func startNext() {
        while !cancelled, inFlight.count < 2, !queue.isEmpty {
            let node = queue.removeFirst()
            let production = Production()
            inFlight[ObjectIdentifier(node)] = production
            production.task = Task { [weak self] in
                guard let self else { return }
                await self.produce(node, production: production)
            }
        }
    }

    private func produce(_ node: EntryNode, production: Production) async {
        let id = ObjectIdentifier(node)
        defer {
            inFlight.removeValue(forKey: id)
            startNext()
        }
        do {
            try Task.checkCancellation()
            let payload = ArchiveEntryPayload(node: node, archiveURL: session.sourceURL, generation: generation)
            let url = try await materializer.materialize(payload, progress: production.progress)
            let image: NSImage
            do {
                try Task.checkCancellation()
                let request = QLThumbnailGenerator.Request(fileAt: url,
                    size: CGSize(width: pointSize, height: pointSize), scale: scale, representationTypes: .thumbnail)
                production.request = request
                image = try await generate(url, request)
            } catch {
                await EntryMaterializer.discard(url)
                throw error
            }
            // 完了通知より先に削除する。取消しを無視して返った生成結果もここで回収する。
            await EntryMaterializer.discard(url)
            guard !cancelled, !Task.isCancelled, !production.progress.isCancelled else { return }
            let longestSide = max(image.size.width, image.size.height)
            if longestSide > pointSize {
                let ratio = pointSize / longestSide
                image.size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            }
            cache[id] = image
            didProduce?(node)
        } catch {
            // 失敗も requested に残し、この表示世代では再試行しない。通知やシートは出さない。
        }
    }

    @discardableResult func cancelAll() -> Task<Void, Never> {
        if let cancellation { return cancellation }
        cancelled = true
        queue.removeAll()
        cache.removeAll()
        didProduce = nil
        let tasks = inFlight.values.compactMap(\.task)
        for production in inFlight.values {
            production.progress.cancel()
            production.task?.cancel()
            if let request = production.request { QLThumbnailGenerator.shared.cancel(request) }
        }
        let draining = Task {
            for task in tasks { await task.value }
        }
        cancellation = draining
        return draining
    }
}
