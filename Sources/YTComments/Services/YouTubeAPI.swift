import Foundation

/// Загрузка комментариев видео через YouTube Data API v3.
/// Грузит все верхнеуровневые комментарии и все ответы (полный офлайн-датасет).

/// Seam (интерфейс) для загрузчика комментариев. Реализация: YouTubeAPI (реальная сеть).
/// Позволяет 2+ adapters (реальный + in-memory фейк в тестах) для настоящего seam'а.
/// Улучшает leverage (тесты изолируют без сети/квоты), locality оркестрации в AppState.
protocol CommentFetcher {
    func fetchAll(
        videoId: String,
        apiKey: String,
        progress: @escaping (Int) -> Void
    ) async throws -> [StoredComment]

    /// Название видео через videos.list (1 единица квоты). nil, если видео не найдено.
    func fetchVideoTitle(videoId: String, apiKey: String) async throws -> String?
}

struct YouTubeAPI: CommentFetcher {
    var session: URLSession = .shared
    private let base = "https://www.googleapis.com/youtube/v3"

    /// Возвращает плоский список: корни тредов + все ответы.
    /// `progress` вызывается по мере накопления (общее число комментариев).
    func fetchAll(
        videoId: String,
        apiKey: String,
        progress: @escaping (Int) -> Void
    ) async throws -> [StoredComment] {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw YouTubeError.missingAPIKey
        }

        var result: [StoredComment] = []
        var pageToken: String?

        repeat {
            let page: ThreadListResponse = try await get(
                path: "commentThreads",
                query: [
                    "part": "snippet,replies",
                    "videoId": videoId,
                    "maxResults": "100",
                    "order": "time",
                    "textFormat": "plainText",
                    "pageToken": pageToken,
                    "key": apiKey
                ]
            )

            for item in page.items {
                let top = item.snippet.topLevelComment
                result.append(top.toStored(
                    threadId: top.id,
                    isTopLevel: true,
                    totalReplyCount: item.snippet.totalReplyCount
                ))

                let total = item.snippet.totalReplyCount
                if total > 0 {
                    let inline = item.replies?.comments ?? []
                    if inline.count == total {
                        result.append(contentsOf: inline.map {
                            $0.toStored(threadId: top.id, isTopLevel: false, totalReplyCount: 0)
                        })
                    } else {
                        let all = try await fetchAllReplies(parentId: top.id, apiKey: apiKey)
                        result.append(contentsOf: all)
                    }
                }
                progress(result.count)
            }

            pageToken = page.nextPageToken
        } while pageToken != nil

        return result
    }

    /// Название видео через videos.list (1 единица квоты). nil, если видео не найдено.
    func fetchVideoTitle(videoId: String, apiKey: String) async throws -> String? {
        let resp: VideoListResponse = try await get(
            path: "videos",
            query: [
                "part": "snippet",
                "id": videoId,
                "key": apiKey
            ]
        )
        return resp.items.first?.snippet.title
    }

    private func fetchAllReplies(parentId: String, apiKey: String) async throws -> [StoredComment] {
        var replies: [StoredComment] = []
        var pageToken: String?

        repeat {
            let page: CommentListResponse = try await get(
                path: "comments",
                query: [
                    "part": "snippet",
                    "parentId": parentId,
                    "maxResults": "100",
                    "textFormat": "plainText",
                    "pageToken": pageToken,
                    "key": apiKey
                ]
            )
            replies.append(contentsOf: page.items.map {
                $0.toStored(threadId: parentId, isTopLevel: false, totalReplyCount: 0)
            })
            pageToken = page.nextPageToken
        } while pageToken != nil

        return replies
    }

    // MARK: - Networking

    private func get<T: Decodable>(path: String, query: [String: String?]) async throws -> T {
        var components = URLComponents(string: "\(base)/\(path)")!
        components.queryItems = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        guard let url = components.url else { throw YouTubeError.invalidURL }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw YouTubeError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw mapError(status: status, data: data)
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw YouTubeError.decoding(error.localizedDescription)
        }
    }

    private func mapError(status: Int, data: Data) -> YouTubeError {
        if let envelope = try? Self.decoder.decode(APIErrorEnvelope.self, from: data) {
            let reason = envelope.error.errors?.first?.reason
            let message = envelope.error.errors?.first?.message ?? envelope.error.message
            return YouTubeError.from(status: status, reason: reason, message: message)
        }
        return YouTubeError.http(status: status, reason: nil, message: nil)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601WithFraction.date(from: string) ?? iso8601Plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Неизвестный формат даты: \(string)"
            )
        }
        return decoder
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
