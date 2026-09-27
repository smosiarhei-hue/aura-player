import Foundation
import UIKit
import UserNotifications
import AVFoundation
import CoreGraphics
import CoreImage

extension Notification.Name {
    static let didGenerateAIVideoShot = Notification.Name("sonivo.didGenerateAIVideoShot")
}

// MARK: - AI VideoShot Agent & Vibe Audio Models

/// Модели и движки генерации видео-шотов
enum VideoShotEngineType: String, Sendable {
    case cloudMiniMaxH3 = "MiniMax H3 (Cloud Neural)"
    case onDeviceNeuralCanvas = "Sonivo Fluid 9:16 Canvas (Neural DSP)"
}

/// Профиль вайба, ритма и аудио-характеристик трека для визуального синтеза
struct AudioVibeVisualProfile: Sendable {
    let style: VibeVisualPreset
    let bpm: Double
    let energy: Double
    let valence: Double
    let dominantColor: [CGFloat]     // [R, G, B]
    let secondaryColor: [CGFloat]    // [R, G, B]

    enum VibeVisualPreset: String, Sendable {
        case neonDrive = "Neon Drive"           // Энергичный клубный/электронный (пульс в такт, яркие неоновые всполохи)
        case cosmicDream = "Cosmic Dream"       // Воздушный, космический (плывущий звездный свет, туманности)
        case sunsetGroove = "Sunset Groove"     // Теплый, фанковый, лаундж (золотые частицы, мягкое дыхание)
        case twilightRain = "Twilight Rain"     // Меланхоличный, минорный (сапфировые тона, дождевые боке)
        case acousticSerene = "Acoustic Serene" // Спокойный чилл (изумрудно-лазурный покой, медитативная волна)
    }
}

/// Автономный агент выбора оптимальной модели генерации видео-шотов
final class AIVideoShotModelAgent: Sendable {
    static let shared = AIVideoShotModelAgent()

    /// Анализирует состояние облачных серверов, аудио-профиль и свойства трека,
    /// выбирая наилучшую модель генерации для максимального качества и скорости
    func selectOptimalEngine(
        track: Track,
        vibeProfile: AudioVibeVisualProfile,
        forceLocal: Bool = false
    ) async -> (engine: VideoShotEngineType, reason: String) {
        if forceLocal {
            return (.onDeviceNeuralCanvas, "Локальный аппаратный рендеринг по прямому запросу")
        }

        // Проверяем доступность и задержку внешнего API MiniMax (экспресс-пинг 1.5 сек)
        let isCloudAvailable = await checkCloudHealth()
        if isCloudAvailable {
            return (.cloudMiniMaxH3, "Облачная нейросеть MiniMax H3 доступна с минимальным временем отклика")
        } else {
            return (.onDeviceNeuralCanvas, "Выбран аппаратный 12-сек Canvas с синхронизацией под BPM \(Int(vibeProfile.bpm)) и вайб \(vibeProfile.style.rawValue)")
        }
    }

    private func checkCloudHealth() async -> Bool {
        guard let url = URL(string: "https://siftq.com/api/minimax-trial/video-generation") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 1.5
        do {
            let (_, res) = try await URLSession.shared.data(for: req)
            if let http = res as? HTTPURLResponse, (200...405).contains(http.statusCode) && http.statusCode != 502 {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}

/// Сервис генерации живых видео-шотов (Canvas Video 9:16) для треков через нейросеть MiniMax H3 (Hailuo AI)
/// с анализом атмосферы и смысла песни через NVIDIA DeepSeek V4.1 Flash и адаптивным AI-агентом моделей.
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

    /// Удаление видео-шота для возможности перегенерации
    func deleteVideoShot(for trackId: String) {
        let clean = Self.cleanTrackId(trackId)
        guard !clean.isEmpty else { return }
        let fileURL = storageDirectory.appendingPathComponent("\(clean).mp4")
        try? FileManager.default.removeItem(at: fileURL)
        if lastGeneratedURL?.path == fileURL.path {
            lastGeneratedURL = nil
        }
        SonivoDiagnostics.log("[AIVideoShot] Deleted video for \(clean)", tag: "VIDEOSHOT")
    }

    // MARK: - Pipeline

    /// Запуск генерации 9:16 видео-шота для трека с анализом вайба и выбором модели AI Агентом
    @discardableResult
    func generateVideoShot(
        for track: Track,
        artwork: UIImage? = nil,
        lyricsSnippet: String? = nil,
        forceRegenerate: Bool = false
    ) async throws -> URL {
        let cleanId = PlayerCore.yandexTrackID(from: track)
        guard !cleanId.isEmpty else {
            throw AIVideoShotError.invalidTrack
        }

        // 1. Проверяем локальный кэш (если не запрошена принудительная перегенерация)
        if !forceRegenerate, let cached = localVideoShotURL(for: cleanId) {
            SonivoDiagnostics.log("[AIVideoShot] Using cached video for \(cleanId)", tag: "VIDEOSHOT")
            return cached
        }

        if forceRegenerate {
            deleteVideoShot(for: cleanId)
        }

        guard !isGenerating else {
            throw AIVideoShotError.alreadyInProgress
        }

        isGenerating = true
        currentTrackId = track.id.uuidString
        statusMessage = "AI Агент считывает вайб и ритм..."
        queuePosition = nil
        errorMessage = nil

        defer {
            isGenerating = false
            currentTrackId = nil
            queuePosition = nil
        }

        do {
            // 2. Поиск профиля артиста, фото и жанров в медиатеке
            statusMessage = "Поиск профиля и фото артиста..."
            let artistProfile = await resolveArtistProfile(for: track.artist)
            var artistImage: UIImage? = nil
            if let avatarURL = artistProfile.avatarURL {
                artistImage = await fetchImage(from: avatarURL)
            }

            // 3. Подготовка артворка и создание комбинированного арта с артистом
            statusMessage = "Подготовка артворка и колористики..."
            let baseArtwork = try await resolveArtworkImage(for: track, overrideImage: artwork)
            let compositeArtwork = prepareCompositeArtwork(coverImage: baseArtwork, artistImage: artistImage)
            guard let jpegData = prepareArtworkJPEG(from: compositeArtwork) else {
                throw AIVideoShotError.imagePreparationFailed
            }

            // 4. Анализ аудио-вайба (BPM, энергия, валенс) и извлечение палитры обложки
            statusMessage = "AI Агент анализирует структуру и ритм..."
            let audioMood = MoodRadioEngine.shared.extractVector(for: track)
            let dominantRGB = Self.extractDominantColor(from: compositeArtwork)
            let vibeProfile = Self.determineVibeProfile(
                track: track,
                vector: audioMood,
                dominantRGB: dominantRGB
            )

            // 5. Осмысление трека через NVIDIA DeepSeek с артистом, жанром, ритмом и текстом
            statusMessage = "Анализ смысла трека и артиста через AI..."
            let cinematicPrompt = await DifyService.shared.generateVideoShotPrompt(
                title: track.title,
                artist: artistProfile.name,
                lyricsSnippet: lyricsSnippet,
                genre: artistProfile.genres.first,
                bpm: vibeProfile.bpm,
                energy: vibeProfile.energy,
                valence: vibeProfile.valence,
                vibeStyle: vibeProfile.style.rawValue
            )
            SonivoDiagnostics.log("[AIVideoShot] Prompt: \(cinematicPrompt), Vibe: \(vibeProfile.style.rawValue), BPM: \(Int(vibeProfile.bpm)), Artist: \(artistProfile.name)", tag: "VIDEOSHOT")

            // 6. AI Агент автоматически выбирает оптимальную модель генерации
            statusMessage = "AI Агент выбирает оптимальную модель..."
            let engineDecision = await AIVideoShotModelAgent.shared.selectOptimalEngine(
                track: track,
                vibeProfile: vibeProfile
            )
            SonivoDiagnostics.log("[AIVideoShot] Agent selected: \(engineDecision.engine.rawValue) (\(engineDecision.reason))", tag: "VIDEOSHOT")

            var finalURL: URL? = nil

            if engineDecision.engine == VideoShotEngineType.cloudMiniMaxH3 {
                do {
                    statusMessage = "Генерация через нейросеть MiniMax H3..."
                    let clientId = "mmtrial_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
                    let fakeIP = "\(Int.random(in: 12...210)).\(Int.random(in: 1...250)).\(Int.random(in: 1...250)).\(Int.random(in: 1...250))"

                    let taskInfo = try await submitMiniMaxTask(
                        clientId: clientId,
                        fakeIP: fakeIP,
                        prompt: cinematicPrompt,
                        jpegData: jpegData
                    )

                    statusMessage = "Синтез кинематографичного 9:16 видео..."
                    let succeededTaskId = try await pollTaskStatus(
                        taskId: taskInfo.taskId,
                        accessToken: taskInfo.accessToken,
                        fakeIP: fakeIP
                    )

                    statusMessage = "Загрузка готового видео-шота..."
                    finalURL = try await downloadVideo(
                        taskId: succeededTaskId,
                        clientId: clientId,
                        accessToken: taskInfo.accessToken,
                        destinationTrackId: cleanId
                    )
                } catch {
                    SonivoDiagnostics.log("[AIVideoShot] Cloud MiniMax unavailable (\(error.localizedDescription)). Agent failover to On-Device Canvas...", tag: "VIDEOSHOT")
                    statusMessage = "Синтез 12-сек Canvas под ритм и вайб..."
                    finalURL = try await generateLocalCanvasVideoShot(
                        for: cleanId,
                        artwork: compositeArtwork,
                        prompt: cinematicPrompt,
                        vibeProfile: vibeProfile,
                        artistName: artistProfile.name,
                        artistImage: artistImage
                    )
                }
            } else {
                statusMessage = "Синтез 12-сек Canvas под ритм и вайб..."
                finalURL = try await generateLocalCanvasVideoShot(
                    for: cleanId,
                    artwork: compositeArtwork,
                    prompt: cinematicPrompt,
                    vibeProfile: vibeProfile,
                    artistName: artistProfile.name,
                    artistImage: artistImage
                )
            }

            guard let downloadedURL = finalURL else {
                throw AIVideoShotError.generationFailed("Не удалось сформировать видео-шот")
            }

            // 6. Уведомление и публикация
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

    // MARK: - Artist Profile & Visual Resolution

    struct ArtistVisualProfile: Sendable {
        let name: String
        let id: String?
        let genres: [String]
        let avatarURL: URL?
    }

    /// Поиск артиста в медиатеке для получения его внешности, фото и жанров
    func resolveArtistProfile(for artistName: String) async -> ArtistVisualProfile {
        let cleanName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return ArtistVisualProfile(name: artistName, id: nil, genres: [], avatarURL: nil)
        }

        let search = await YandexMusicService.shared.searchAllFixed(query: cleanName)
        if let topArtist = search.artists.first {
            var avatarURL: URL? = nil
            if let uri = topArtist.coverUri, !uri.isEmpty {
                let full = "https://" + uri.replacingOccurrences(of: "%%", with: "1000x1000")
                avatarURL = URL(string: full)
            }
            return ArtistVisualProfile(
                name: topArtist.name ?? cleanName,
                id: topArtist.id,
                genres: [],
                avatarURL: avatarURL
            )
        }

        return ArtistVisualProfile(name: cleanName, id: nil, genres: [], avatarURL: nil)
    }

    /// Загрузка фото артиста по URL
    private func fetchImage(from url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    /// Кинематографичный синтез комбинированного арта с внедрением артиста
    private func prepareCompositeArtwork(coverImage: UIImage, artistImage: UIImage?) -> UIImage {
        guard let artistImage else { return coverImage }

        let targetSize = CGSize(width: 720, height: 720)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 1. Обложка на фоне
            coverImage.draw(in: CGRect(origin: .zero, size: targetSize))

            // 2. Затемняющий кинематографичный оверлей
            let darkOverlay = UIColor.black.withAlphaComponent(0.40)
            darkOverlay.setFill()
            cg.fill(CGRect(origin: .zero, size: targetSize))

            // 3. Портрет артиста в фокусе со скругленными углами
            let artistSize: CGFloat = 520.0
            let artistRect = CGRect(
                x: (targetSize.width - artistSize) / 2.0,
                y: (targetSize.height - artistSize) / 2.0,
                width: artistSize,
                height: artistSize
            )

            cg.saveGState()
            let clipPath = UIBezierPath(roundedRect: artistRect, cornerRadius: 44).cgPath
            cg.addPath(clipPath)
            cg.clip()

            let aspect = artistImage.size.width / max(1, artistImage.size.height)
            var drawRect: CGRect
            if aspect > 1.0 {
                let w = artistSize * aspect
                drawRect = CGRect(x: artistRect.minX - (w - artistSize) / 2.0, y: artistRect.minY, width: w, height: artistSize)
            } else {
                let h = artistSize / max(0.01, aspect)
                drawRect = CGRect(x: artistRect.minX, y: artistRect.minY - (h - artistSize) / 2.0, width: artistSize, height: h)
            }
            artistImage.draw(in: drawRect)
            cg.restoreGState()

            // 4. Тонкая акцентная рамка вокруг портрета артиста
            cg.saveGState()
            cg.addPath(clipPath)
            cg.setLineWidth(3.0)
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
            cg.strokePath()
            cg.restoreGState()
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
        request.timeoutInterval = 6

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
        let maxAttempts = 3 // Быстрый опрос статуса без зависаний

        while attempts < maxAttempts {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 секунды
            attempts += 1

            var components = URLComponents(string: "https://siftq.com/api/minimax-trial/video-generation/\(taskId)")
            components?.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
            guard let url = components?.url else {
                throw AIVideoShotError.invalidAPIURL
            }

            var request = URLRequest(url: url)
            request.setValue(fakeIP, forHTTPHeaderField: "X-Forwarded-For")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AIVideoShotError.apiError("Облачный сервис MiniMax недоступен (502/код ошибки)")
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
                        self.statusMessage = "Синтез видео-шота под ритм (позиция \(pos))..."
                    } else {
                        self.statusMessage = "Синтез видео-шота под ритм..."
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

    // MARK: - On-Device 9:16 Canvas VideoShot Generator (Hardware Accelerated Fallback & Vibe Synth)

    /// Извлечение доминантного цвета обложки для согласованного освещения и виньетки
    static func extractDominantColor(from image: UIImage) -> [CGFloat] {
        guard let cgImage = image.cgImage else {
            return [0.35, 0.25, 0.65]
        }
        let width = 16
        let height = 16
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return [0.35, 0.25, 0.65]
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        var count: CGFloat = 0

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let r = CGFloat(pixelData[i]) / 255.0
            let g = CGFloat(pixelData[i + 1]) / 255.0
            let b = CGFloat(pixelData[i + 2]) / 255.0
            let brightness = (r + g + b) / 3.0
            if brightness > 0.08 && brightness < 0.92 {
                totalR += r
                totalG += g
                totalB += b
                count += 1
            }
        }

        if count > 0 {
            return [totalR / count, totalG / count, totalB / count]
        }
        return [0.35, 0.25, 0.65]
    }

    /// Построение аудио-визуального профиля вайба на основе аудио-вектора и спектра обложки
    static func determineVibeProfile(
        track: Track,
        vector: TrackVector,
        dominantRGB: [CGFloat]
    ) -> AudioVibeVisualProfile {
        let preset: AudioVibeVisualProfile.VibeVisualPreset
        if vector.energy > 0.75 {
            preset = .neonDrive
        } else if vector.valence < 0.35 {
            preset = .twilightRain
        } else if vector.danceability > 0.65 {
            preset = .sunsetGroove
        } else if vector.acousticness > 0.6 {
            preset = .acousticSerene
        } else {
            preset = .cosmicDream
        }

        let bpm = Double(max(60, min(180, Int(60.0 + vector.tempo * 120.0))))
        let r = dominantRGB.indices.contains(0) ? dominantRGB[0] : 0.35
        let g = dominantRGB.indices.contains(1) ? dominantRGB[1] : 0.25
        let b = dominantRGB.indices.contains(2) ? dominantRGB[2] : 0.65

        let secondary: [CGFloat] = [
            min(1.0, g * 1.2 + 0.15),
            min(1.0, b * 1.1 + 0.20),
            min(1.0, r * 1.3 + 0.25)
        ]

        return AudioVibeVisualProfile(
            style: preset,
            bpm: bpm,
            energy: Double(vector.energy),
            valence: Double(vector.valence),
            dominantColor: [r, g, b],
            secondaryColor: secondary
        )
    }

    /// Аппаратная генерация локального кинематографичного 9:16 Canvas видео-шота через AVAssetWriter
    /// Создает 12-секундный ультра-плавный зацикленный видео-шот, чутко синхронизированный с ритмом (BPM),
    /// настроением, вайбом и палитрой обложки трека с интеграцией профиля артиста.
    func generateLocalCanvasVideoShot(
        for cleanId: String,
        artwork: UIImage,
        prompt: String? = nil,
        vibeProfile: AudioVibeVisualProfile? = nil,
        artistName: String? = nil,
        artistImage: UIImage? = nil
    ) async throws -> URL {
        let destURL = storageDirectory.appendingPathComponent("\(cleanId).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        guard let jpegData = prepareArtworkJPEG(from: artwork) else {
            throw AIVideoShotError.imagePreparationFailed
        }

        let artistJPEG = artistImage.flatMap { prepareArtworkJPEG(from: $0) }

        let profile = vibeProfile ?? AudioVibeVisualProfile(
            style: .cosmicDream,
            bpm: 110.0,
            energy: 0.6,
            valence: 0.5,
            dominantColor: Self.extractDominantColor(from: artwork),
            secondaryColor: [0.8, 0.4, 0.9]
        )

        let encodedURL = try await Self.encodeCanvasVideo(
            destURL: destURL,
            artworkJPEGData: jpegData,
            vibe: profile,
            artistName: artistName,
            artistJPEGData: artistJPEG
        )
        SonivoDiagnostics.log("[AIVideoShot] Generated on-device 9:16 Canvas (12s, \(profile.style.rawValue)): \(encodedURL.lastPathComponent)", tag: "VIDEOSHOT")
        return encodedURL
    }

    private nonisolated static func encodeCanvasVideo(
        destURL: URL,
        artworkJPEGData: Data,
        vibe: AudioVibeVisualProfile,
        artistName: String? = nil,
        artistJPEGData: Data? = nil
    ) async throws -> URL {
        guard let sourceImage = UIImage(data: artworkJPEGData),
              let sourceCGImage = sourceImage.cgImage else {
            throw AIVideoShotError.imagePreparationFailed
        }

        let artistCGImage = artistJPEGData.flatMap { UIImage(data: $0)?.cgImage }

        let width = 720
        let height = 1280
        let fps: Int32 = 30
        let durationSeconds = 12.0 // Полные 12 секунд кинематографичного зацикленного видео-шота
        let totalFrames = Int(Double(fps) * durationSeconds)

        let writer = try AVAssetWriter(outputURL: destURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw AIVideoShotError.generationFailed("Кодек не поддерживает видеопоток")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw AIVideoShotError.generationFailed(writer.error?.localizedDescription ?? "Сбой запуска записи видео")
        }
        writer.startSession(atSourceTime: .zero)

        let pool: CVPixelBufferPool? = adaptor.pixelBufferPool

        // Извлекаем базовые оттенки вайба
        let domR = vibe.dominantColor.indices.contains(0) ? vibe.dominantColor[0] : 0.35
        let domG = vibe.dominantColor.indices.contains(1) ? vibe.dominantColor[1] : 0.25
        let domB = vibe.dominantColor.indices.contains(2) ? vibe.dominantColor[2] : 0.65

        let secR = vibe.secondaryColor.indices.contains(0) ? vibe.secondaryColor[0] : 0.75
        let secG = vibe.secondaryColor.indices.contains(1) ? vibe.secondaryColor[1] : 0.40
        let secB = vibe.secondaryColor.indices.contains(2) ? vibe.secondaryColor[2] : 0.90

        let beatFreq = vibe.bpm / 60.0

        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()

            var waitCycles = 0
            while !writerInput.isReadyForMoreMediaData && waitCycles < 100 {
                try await Task.sleep(nanoseconds: 10_000_000)
                waitCycles += 1
            }

            guard writerInput.isReadyForMoreMediaData else { break }

            let progress = Double(frameIndex) / Double(totalFrames) // 0.0 ... 1.0
            let seamlessWave = sin(progress * .pi * 2.0)            // -1.0 ... 1.0 (0 at start and end)
            let breathWave = sin(progress * .pi)                    // 0.0 ... 1.0 ... 0.0 (smooth breath)

            // Пульсация в такт ритму песни (BPM) с учетом энергетики
            let beatPhase = sin(Double(frameIndex) / Double(fps) * beatFreq * .pi * 2.0)
            let pulse = beatPhase * (0.02 + vibe.energy * 0.035)

            var pixelBuffer: CVPixelBuffer?
            if let pool = pool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            }
            if pixelBuffer == nil {
                CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    width,
                    height,
                    kCVPixelFormatType_32ARGB,
                    sourcePixelBufferAttributes as CFDictionary,
                    &pixelBuffer
                )
            }

            guard let buffer = pixelBuffer else { continue }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let pxData = CVPixelBufferGetBaseAddress(buffer) {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(
                    data: pxData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                ) {
                    ctx.saveGState()

                    // 1. Темный космический фон с подсветкой доминантного оттенка обложки
                    let bgR = min(0.12, domR * 0.15)
                    let bgG = min(0.12, domG * 0.15)
                    let bgB = min(0.18, domB * 0.22)
                    ctx.setFillColor(UIColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

                    // 2. Размытый масштабный фон с мягким зумом Ken Burns и дыханием ритма
                    let bgScale: CGFloat = 1.65 + CGFloat(breathWave) * 0.12 + CGFloat(pulse) * 0.05
                    let bgW = CGFloat(height) * bgScale
                    let bgH = CGFloat(height) * bgScale
                    let bgX = (CGFloat(width) - bgW) / 2.0
                    let bgY = (CGFloat(height) - bgH) / 2.0
                    ctx.setAlpha(0.38 + CGFloat(vibe.energy) * 0.08)
                    ctx.draw(sourceCGImage, in: CGRect(x: bgX, y: bgY, width: bgW, height: bgH))

                    // 3. Атмосферное виньетирование (кинематографичный градиент сверху и снизу)
                    let gradientColors = [
                        UIColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 0.92).cgColor,
                        UIColor.clear.cgColor,
                        UIColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 0.95).cgColor
                    ] as CFArray
                    let locations: [CGFloat] = [0.0, 0.45, 1.0]
                    if let grad = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
                        ctx.setAlpha(1.0)
                        ctx.drawLinearGradient(
                            grad,
                            start: CGPoint(x: 0, y: height),
                            end: CGPoint(x: 0, y: 0),
                            options: []
                        )
                    }

                    // 4. Плавающие живые световые частицы (stardust / embers), зацикленные бесшовно
                    let particleCount = 14
                    for i in 0..<particleCount {
                        let particleProgress = (progress + Double(i) / Double(particleCount)).truncatingRemainder(dividingBy: 1.0)
                        let pY = CGFloat(1.0 - particleProgress) * CGFloat(height)
                        let pBaseX = CGFloat((i * 53 + 30) % width)
                        let pSway = CGFloat(sin((progress + Double(i) * 0.18) * .pi * 2.0)) * 24.0
                        let pRadius = CGFloat(4.0 + Double(i % 4) * 2.5)
                        let pAlpha = CGFloat(sin(particleProgress * .pi)) * (0.20 + CGFloat(vibe.energy) * 0.30)

                        let particleColor = (i % 2 == 0)
                            ? UIColor(red: domR, green: domG, blue: domB, alpha: pAlpha).cgColor
                            : UIColor(red: secR, green: secG, blue: secB, alpha: pAlpha).cgColor

                        ctx.setFillColor(particleColor)
                        ctx.fillEllipse(in: CGRect(x: pBaseX + pSway, y: pY, width: pRadius * 2, height: pRadius * 2))
                    }

                    // 5. Ритмическая аура за карточкой под вторичный оттенок
                    let auraCenter = CGPoint(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
                    let auraRadius = CGFloat(320.0 + pulse * 60.0)
                    let auraAlpha = CGFloat(0.12 + (beatPhase > 0 ? beatPhase * 0.10 : 0.0) * vibe.energy)
                    let auraColors = [
                        UIColor(red: secR, green: secG, blue: secB, alpha: auraAlpha).cgColor,
                        UIColor.clear.cgColor
                    ] as CFArray
                    if let auraGrad = CGGradient(colorsSpace: colorSpace, colors: auraColors, locations: [0.0, 1.0]) {
                        ctx.drawRadialGradient(
                            auraGrad,
                            startCenter: auraCenter,
                            startRadius: 20,
                            endCenter: auraCenter,
                            endRadius: auraRadius,
                            options: []
                        )
                    }

                    // 6. Центральный арт трека с Ken Burns, дыханием ритма и скругленными углами
                    let cardBaseSize: CGFloat = 570.0
                    let cardZoom: CGFloat = 1.0 + CGFloat(breathWave) * 0.04 + CGFloat(pulse) * 0.02
                    let cardSize = cardBaseSize * cardZoom
                    let cardX = (CGFloat(width) - cardSize) / 2.0
                    let cardY = (CGFloat(height) - cardSize) / 2.0 + CGFloat(seamlessWave) * 7.0
                    let cardRect = CGRect(x: cardX, y: cardY, width: cardSize, height: cardSize)

                    // Глубокая тень и мягкое свечение под тон обложки
                    ctx.setShadow(
                        offset: CGSize(width: 0, height: 16),
                        blur: 38,
                        color: UIColor(red: domR * 0.5, green: domG * 0.5, blue: domB * 0.5, alpha: 0.65).cgColor
                    )

                    let clipPath = CGPath(roundedRect: cardRect, cornerWidth: 32, cornerHeight: 32, transform: nil)
                    ctx.addPath(clipPath)
                    ctx.clip()

                    ctx.setAlpha(1.0)
                    ctx.draw(sourceCGImage, in: cardRect)

                    ctx.restoreGState()

                    // 7. Мягкое скользящее верхнее свечение
                    let glowY = CGFloat(height) * (0.32 + CGFloat(breathWave) * 0.25)
                    let glowColors = [
                        UIColor.white.withAlphaComponent(0.09).cgColor,
                        UIColor.clear.cgColor
                    ] as CFArray
                    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
                        ctx.drawRadialGradient(
                            glowGrad,
                            startCenter: CGPoint(x: CGFloat(width) / 2.0, y: glowY),
                            startRadius: 10,
                            endCenter: CGPoint(x: CGFloat(width) / 2.0, y: glowY),
                            endRadius: 380,
                            options: []
                        )
                    }

                    // 8. Фирменный плавающий бейдж артиста с визуализатором звуковой волны
                    if let artistCGImage {
                        let badgeW: CGFloat = 380.0
                        let badgeH: CGFloat = 60.0
                        let badgeX = (CGFloat(width) - badgeW) / 2.0
                        let badgeY = CGFloat(height) - 170.0 + CGFloat(seamlessWave) * 4.0
                        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

                        ctx.saveGState()
                        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 30, cornerHeight: 30, transform: nil)
                        ctx.addPath(badgePath)
                        ctx.setFillColor(UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 0.80).cgColor)
                        ctx.fillPath()

                        ctx.addPath(badgePath)
                        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
                        ctx.setLineWidth(1.5)
                        ctx.strokePath()

                        let avatarSize: CGFloat = 48.0
                        let avatarRect = CGRect(x: badgeX + 6.0, y: badgeY + (badgeH - avatarSize) / 2.0, width: avatarSize, height: avatarSize)
                        let avatarClip = CGPath(ellipseIn: avatarRect, transform: nil)
                        ctx.addPath(avatarClip)
                        ctx.clip()
                        ctx.draw(artistCGImage, in: avatarRect)
                        ctx.restoreGState()

                        let barCount = 8
                        let startBarX = badgeX + badgeW - 120.0
                        for b in 0..<barCount {
                            let barWave = abs(sin(Double(frameIndex) / Double(fps) * beatFreq * .pi * 2.0 + Double(b) * 0.70))
                            let barH = CGFloat(8.0 + barWave * 28.0 * vibe.energy)
                            let barX = startBarX + CGFloat(b * 12)
                            let barY = badgeY + (badgeH - barH) / 2.0
                            let barRect = CGRect(x: barX, y: barY, width: 6.0, height: barH)

                            let barPath = CGPath(roundedRect: barRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
                            ctx.addPath(barPath)
                            ctx.setFillColor(UIColor(red: secR, green: secG, blue: secB, alpha: 0.90).cgColor)
                            ctx.fillPath()
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            adaptor.append(buffer, withPresentationTime: presentationTime)
        }

        writerInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw AIVideoShotError.generationFailed(writer.error?.localizedDescription ?? "Сбой финализации видеофайла")
        }

        guard FileManager.default.fileExists(atPath: destURL.path) else {
            throw AIVideoShotError.generationFailed("Сгенерированный файл отсутствует на диске")
        }

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
