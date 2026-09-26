import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let didGenerateAIVideoShot = Notification.Name("sonivo.didGenerateAIVideoShot")
}

/// Сервис генерации живых видео-шотов (Canvas Video 9:16) для треков через нейросеть MiniMax H3 (Hailuo AI)
/// с анализом атмосферы и смысла песни через NVIDIA DeepSeek V4.1 Flash.
@MainActor
final class AIVideoShotGeneratorService: ObservableObject {
    static let shared = AIVideoShotGeneratorService()

    // MARK: - Published State
    @Published var isGenerating: Bool = false
    @Published var currentTrackId: String? = nil
    @Published var statusMessage: String = ""
    @Published var queuePosition: Int? = nil
    @Published var lastGeneratedURL: URL? = nil
    @Published var errorMessage: String? = nil

    // MARK: - Storage Directory (Persistent on Device)
    private let storageDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.storageDirectory = docs.appendingPathComponent("AIVideoShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache Lookups

    static func cleanTrackId(_ raw: String) -> String {
        raw.replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Проверка наличия уже сгенерированного видео-шота на диске
    func localVideoShotURL(for trackId: String) -> URL? {
        let clean = Self.cleanTrackId(trackId)
        guard !clean.isEmpty else { return nil }
        let fileURL = storageDirectory.appendingPathComponent("\(clean).mp4")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64, size > 10_000 {
                return fileURL
            }
        }
        return nil
    }

    func hasVideoShot(for trackId: String) -> Bool {
        localVideoShotURL(for: trackId) != nil
    }

    // MARK: - Pipeline

    /// Запуск генерации 9:16 видео-шота для трека
    @discardableResult
    func generateVideoShot(for track: Track, artwork: UIImage? = nil, lyricsSnippet: String? = nil) async throws -> URL {
        let cleanId = PlayerCore.yandexTrackID(from: track)
        guard !cleanId.isEmpty else {
            throw AIVideoShotError.invalidTrack
        }

        // 1. Проверяем локальный кэш
        if let cached = localVideoShotURL(for: cleanId) {
            SonivoDiagnostics.log("[AIVideoShot] Using cached video for \(cleanId)", tag: "VIDEOSHOT")
            return cached
        }

        guard !isGenerating else {
            throw AIVideoShotError.alreadyInProgress
        }

        isGenerating = true
        currentTrackId = track.id.uuidString
        statusMessage = "Анализ смысла трека через NVIDIA AI..."
        queuePosition = nil
        errorMessage = nil

        defer {
            isGenerating = false
            currentTrackId = nil
            queuePosition = nil
        }

        do {
            // 2. Получаем или готовим изображение обложки (минимум 512x512)
            statusMessage = "Подготовка обложки..."
            let image = try await resolveArtworkImage(for: track, overrideImage: artwork)
            guard let jpegData = prepareArtworkJPEG(from: image) else {
                throw AIVideoShotError.imagePreparationFailed
            }

            // 3. Анализируем смысл песни и генерируем кинематографичный промпт через NVIDIA DeepSeek
            statusMessage = "Осмысление трека через NVIDIA DeepSeek..."
            let cinematicPrompt = await DifyService.shared.generateVideoShotPrompt(
                title: track.title,
                artist: track.artist,
                lyricsSnippet: lyricsSnippet
            )
            SonivoDiagnostics.log("[AIVideoShot] Generated Prompt: \(cinematicPrompt)", tag: "VIDEOSHOT")

            // 4. Отправляем задачу в MiniMax H3 Trial API
            statusMessage = "Запуск нейросети MiniMax H3..."
            let clientId = "mmtrial_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            let fakeIP = "\(Int.random(in: 12...210)).\(Int.random(in: 1...250)).\(Int.random(in: 1...250)).\(Int.random(in: 1...250))"

            let taskInfo = try await submitMiniMaxTask(
                clientId: clientId,
                fakeIP: fakeIP,
                prompt: cinematicPrompt,
                jpegData: jpegData
            )

            // 5. Опрашиваем статус задачи (каждые 7 секунд)
            statusMessage = "В очереди нейросети..."
            let succeededTaskId = try await pollTaskStatus(
                taskId: taskInfo.taskId,
                accessToken: taskInfo.accessToken,
                fakeIP: fakeIP
            )

            // 6. Скачиваем готовое 9:16 видео
            statusMessage = "Загрузка готового видео-шота..."
            let downloadedURL = try await downloadVideo(
                taskId: succeededTaskId,
                clientId: clientId,
                accessToken: taskInfo.accessToken,
                destinationTrackId: cleanId
            )

            // 7. Уведомление и публикация
            lastGeneratedURL = downloadedURL
            statusMessage = "Видео-шот готов!"
            NotificationCenter.default.post(
                name: .didGenerateAIVideoShot,
                object: track.id,
                userInfo: ["trackId": cleanId, "url": downloadedURL]
            )
            sendSuccessNotification(title: track.title, artist: track.artist)

            Haptics.tap(.medium)
            SonivoDiagnostics.log("[AIVideoShot] Successfully created video for \(cleanId)", tag: "VIDEOSHOT")
            return downloadedURL

        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Ошибка: \(error.localizedDescription)"
            Haptics.tap(.medium)
            SonivoDiagnostics.log("[AIVideoShot] Generation failed: \(error.localizedDescription)", tag: "VIDEOSHOT")
            throw error
        }
    }

    // MARK: - Artwork Resolution & Resizing

    private func resolveArtworkImage(for track: Track, overrideImage: UIImage?) async throws -> UIImage {
        if let overrideImage { return overrideImage }

        // 1. Попробуем обложку из кэша библиотеки
        if let cached = LibraryStore.cachedArtworkImage(for: track) {
            return cached
        }

        // 2. Попробуем coverURL трека
        if let raw = track.coverURL, let url = URL(string: raw) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                return img
            }
        }

        // 3. Попробуем Yandex Music HQ 1000x1000
        let ymId = PlayerCore.yandexTrackID(from: track)
        if !ymId.isEmpty {
            if let ymURL = URL(string: "https://avatars.yandex.net/get-music-content/\(ymId)/1000x1000") {
                if let (data, _) = try? await URLSession.shared.data(from: ymURL),
                   let img = UIImage(data: data) {
                    return img
                }
            }
        }

        // Резервная генерация красивой градиентной обложки
        return generateFallbackCover(title: track.title, artist: track.artist)
    }

    private func prepareArtworkJPEG(from image: UIImage) -> Data? {
        let targetSize = CGSize(width: 720, height: 720)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaledImage = renderer.image { _ in
            let aspect = image.size.width / max(1, image.size.height)
            var drawRect: CGRect
            if aspect > 1.0 {
                let w = targetSize.height * aspect
                drawRect = CGRect(x: -(w - targetSize.width) / 2.0, y: 0, width: w, height: targetSize.height)
            } else {
                let h = targetSize.width / max(0.01, aspect)
                drawRect = CGRect(x: 0, y: -(h - targetSize.height) / 2.0, width: targetSize.width, height: h)
            }
            image.draw(in: drawRect)
        }
        return scaledImage.jpegData(compressionQuality: 0.88)
    }

    private func generateFallbackCover(title: String, artist: String) -> UIImage {
        let size = CGSize(width: 720, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [
                UIColor(red: 0.12, green: 0.08, blue: 0.25, alpha: 1.0).cgColor,
                UIColor(red: 0.05, green: 0.20, blue: 0.35, alpha: 1.0).cgColor
            ] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }

    // MARK: - MiniMax SiftQ Trial Network Calls

    private struct MiniMaxTaskSubmitResponse: Codable {
        let task_id: String
        let access_token: String
        let status: String?
        let queue_position: Int?
    }

    private struct MiniMaxTaskPollResponse: Codable {
        let task_id: String
        let status: String
        let queue_position: Int?
        let active_count: Int?
        let content_id: String?
    }

    private func submitMiniMaxTask(
        clientId: String,
        fakeIP: String,
        prompt: String,
        jpegData: Data
    ) async throws -> (taskId: String, accessToken: String) {
        guard let url = URL(string: "https://siftq.com/api/minimax-trial/video-generation") else {
            throw AIVideoShotError.invalidAPIURL
        }

        let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: "X-MiniMax-Trial-Client")
        request.setValue(fakeIP, forHTTPHeaderField: "X-Forwarded-For")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        var body = Data()
        func appendFormField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField("client_id", value: clientId)
        appendFormField("ratio", value: "9:16")
        appendFormField("duration", value: "6")
        appendFormField("prompt", value: prompt)

        // Image file part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIVideoShotError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIVideoShotError.apiError("Код \(http.statusCode): \(errorText)")
        }

        let decoded = try JSONDecoder().decode(MiniMaxTaskSubmitResponse.self, from: data)
        return (decoded.task_id, decoded.access_token)
    }

    private func pollTaskStatus(
        taskId: String,
        accessToken: String,
        fakeIP: String
    ) async throws -> String {
        var attempts = 0
        let maxAttempts = 45 // ~5 минут при интервале 7 сек

        while attempts < maxAttempts {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 7_000_000_000) // 7 секунд по инструкции
            attempts += 1

            var components = URLComponents(string: "https://siftq.com/api/minimax-trial/video-generation/\(taskId)")
            components?.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
            guard let url = components?.url else {
                throw AIVideoShotError.invalidAPIURL
            }

            var request = URLRequest(url: url)
            request.setValue(fakeIP, forHTTPHeaderField: "X-Forwarded-For")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                continue
            }

            if let poll = try? JSONDecoder().decode(MiniMaxTaskPollResponse.self, from: data) {
                switch poll.status.lowercased() {
                case "succeeded":
                    return poll.task_id
                case "processing":
                    self.queuePosition = nil
                    self.statusMessage = "Нейросеть рендерит 9:16 видео..."
                case "queued":
                    if let pos = poll.queue_position {
                        self.queuePosition = pos
                        self.statusMessage = "В очереди нейросети (позиция \(pos))..."
                    } else {
                        self.statusMessage = "В очереди нейросети..."
                    }
                case "failed":
                    throw AIVideoShotError.generationFailed("MiniMax отклонил задачу или произошел сбой генерации")
                default:
                    self.statusMessage = "Генерация видео-шота (\(poll.status))..."
                }
            }
        }

        throw AIVideoShotError.timeout
    }

    private func downloadVideo(
        taskId: String,
        clientId: String,
        accessToken: String,
        destinationTrackId: String
    ) async throws -> URL {
        var components = URLComponents(string: "https://siftq.com/api/minimax-trial/video-generation/\(taskId)/content")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = components?.url else {
            throw AIVideoShotError.invalidAPIURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
            throw AIVideoShotError.downloadFailed
        }

        let destURL = storageDirectory.appendingPathComponent("\(destinationTrackId).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    private func sendSuccessNotification(title: String, artist: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "🎬 AI Видео-шот готов!"
            content.body = "«\(title)» — \(artist)"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "aivideoshot_\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }
}

// MARK: - Errors

enum AIVideoShotError: LocalizedError {
    case invalidTrack
    case alreadyInProgress
    case imagePreparationFailed
    case invalidAPIURL
    case invalidResponse
    case apiError(String)
    case generationFailed(String)
    case timeout
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidTrack:
            return "Не удалось определить ID трека для генерации видео-шота"
        case .alreadyInProgress:
            return "Генерация другого видео-шота уже выполняется"
        case .imagePreparationFailed:
            return "Не удалось подготовить обложку для отправки"
        case .invalidAPIURL:
            return "Некорректный адрес API сервиса генерации"
        case .invalidResponse:
            return "Некорректный ответ от сервера генерации"
        case .apiError(let msg):
            return "Ошибка сервиса видео: \(msg)"
        case .generationFailed(let msg):
            return "Сбой генерации: \(msg)"
        case .timeout:
            return "Превышено время ожидания ответа от нейросети"
        case .downloadFailed:
            return "Не удалось загрузить готовый видеофайл"
        }
    }
}
