import SwiftUI
import Observation

// MARK: - Локализация Sonivo (Русский по умолчанию / English)

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru = "ru"
    case en = "en"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        }
    }
}

@Observable
final class SonivoL10n {
    static let shared = SonivoL10n()

    var language: AppLanguage = .ru {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "sonivo_app_language")
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "sonivo_app_language"),
           let lang = AppLanguage(rawValue: saved) {
            self.language = lang
        } else {
            // По умолчанию строго русский
            self.language = .ru
        }
    }

    var isRussian: Bool { language == .ru }

    func toggleLanguage() {
        language = (language == .ru) ? .en : .ru
    }

    // MARK: - Strings

    var topSongs: String { isRussian ? "Популярные треки" : "Top Songs" }
    var latestRelease: String { isRussian ? "Свежий релиз" : "Latest Release" }
    var releaseBadge: String { isRussian ? "РЕЛИЗ" : "RELEASE" }
    var single: String { isRussian ? "Сингл" : "Single" }
    var album: String { isRussian ? "Альбом" : "Album" }
    var albumsAndSingles: String { isRussian ? "Альбомы и синглы" : "Albums & Singles" }
    var similarArtists: String { isRussian ? "Похожие исполнители" : "Similar Artists" }
    var play: String { isRussian ? "Воспроизвести" : "Play" }
    var shuffle: String { isRussian ? "Перемешать" : "Shuffle" }
    var listenNow: String { isRussian ? "Слушать сейчас" : "Listen Now" }
    var artistWave: String { isRussian ? "Волна артиста" : "Artist Wave" }
    var aboutArtist: String { isRussian ? "Об артисте" : "About Artist" }
    var addToFavorites: String { isRussian ? "Добавить в избранное" : "Add to Favorites" }
    var removeFromFavorites: String { isRussian ? "Удалить из избранного" : "Remove from Favorites" }
    var downloadToPhone: String { isRussian ? "Скачать на iPhone" : "Download to iPhone" }
    var trackWave: String { isRussian ? "Волна по треку" : "Track Wave" }
    var goToAlbum: String { isRussian ? "Перейти к альбому" : "Go to Album" }
    var stations: String { isRussian ? "Станции" : "Stations" }
    var radio: String { isRussian ? "Радио" : "Radio" }
    var radioSubtitle: String { isRussian ? "Музыка без границ. Новые открытия каждый день." : "Music without borders. New discoveries every day." }
    var languageSwitchLabel: String { isRussian ? "Язык: Русский" : "Language: English" }

    func songsCount(_ n: Int) -> String {
        if !isRussian { return "\(n) \(n == 1 ? "song" : "songs")" }
        let rem10 = n % 10
        let rem100 = n % 100
        if rem100 >= 11 && rem100 <= 19 { return "\(n) песен" }
        if rem10 == 1 { return "\(n) песня" }
        if rem10 >= 2 && rem10 <= 4 { return "\(n) песни" }
        return "\(n) песен"
    }

    func tracksCount(_ n: Int) -> String {
        if !isRussian { return "\(n) \(n == 1 ? "track" : "tracks")" }
        let rem10 = n % 10
        let rem100 = n % 100
        if rem100 >= 11 && rem100 <= 19 { return "\(n) треков" }
        if rem10 == 1 { return "\(n) трек" }
        if rem10 >= 2 && rem10 <= 4 { return "\(n) трека" }
        return "\(n) треков"
    }

    func minutesText(_ m: Int) -> String {
        isRussian ? "\(m) мин." : "\(m) min."
    }
}
