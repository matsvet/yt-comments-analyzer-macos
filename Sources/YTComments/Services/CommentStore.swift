import Foundation

/// Краткая запись о загруженном видео для боковой панели.
struct LibraryEntry: Identifiable, Hashable {
    let videoId: String
    let fetchedAt: Date
    var title: String?
    var id: String { videoId }
}

/// Seam (интерфейс) для хранилища видео-кэша. Позволяет подменять реализации (adapter pattern).
/// Реальная: CommentStore (использует FS, ~/Library/Application Support/...).
/// Тестовый: in-memory adapter (без FS, для leverage в тестах и deletion test).
/// Уважает Data Compatibility: тестовые адаптеры тоже не backfill'ят старые данные.
protocol VideoCache {
    func save(_ video: VideoComments) throws
    func load(videoId: String) throws -> VideoComments
    func delete(videoId: String) throws
    func listLibrary() -> [LibraryEntry]
}

/// Хранение кэша комментариев в Application Support по `videoId`.
struct CommentStore: VideoCache {
    private let fileManager = FileManager.default

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("YTCommentsAnalyzer", isDirectory: true)
    }

    private func fileURL(for videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).json")
    }

    func save(_ video: VideoComments) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(video)
        try data.write(to: fileURL(for: video.videoId), options: .atomic)
    }

    func load(videoId: String) throws -> VideoComments {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: fileURL(for: videoId))
        return try decoder.decode(VideoComments.self, from: data)
    }

    func delete(videoId: String) throws {
        try fileManager.removeItem(at: fileURL(for: videoId))
    }

    /// Лёгкие метаданные видео (только то, что нужно для списка библиотеки).
    private struct VideoMetadata: Decodable {
        let videoId: String
        let title: String?
    }

    /// Список загруженных видео, новые сверху. Дата = время записи файла.
    /// Загружает название видео из кэша (если есть), чтобы показывать в сайдбаре вместо ID.
    func listLibrary() -> [LibraryEntry] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .map { url in
                let videoId = url.deletingPathExtension().lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                var title: String? = nil
                if let data = try? Data(contentsOf: url),
                   let meta = try? decoder.decode(VideoMetadata.self, from: data) {
                    title = meta.title
                }

                return LibraryEntry(videoId: videoId, fetchedAt: date, title: title)
            }
            .sorted { $0.fetchedAt > $1.fetchedAt }
    }
}
