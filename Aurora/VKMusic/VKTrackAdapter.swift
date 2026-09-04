// Path: Aurora/VKMusic/VKTrackAdapter.swift

import CryptoKit
import Foundation

nonisolated enum VKTrackAdapter {
    nonisolated struct Result: Sendable {
        let track: Track
        let isRestricted: Bool
        let compoundID: String
        let accessKey: String?
    }

    nonisolated static func adapt(_ item: VKTrackDTO) -> Result {
        let compoundID = item.compoundID
        let albumTitle = item.album?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = item.album?.thumb?.bestURL
        let track = Track(
            id: stableID(from: "vk|\(compoundID)"),
            fileName: "vk_\(compoundID).mp3",
            relativePath: "",
            title: title.isEmpty ? "Без названия" : title,
            artist: artist.isEmpty ? "Неизвестный исполнитель" : artist,
            album: albumTitle?.isEmpty == false ? albumTitle! : "VK Музыка",
            duration: Double(max(0, item.duration)),
            artworkSeed: stableSeed(from: compoundID),
            colorsHex: ["#2787F5", "#07F"],
            hasEmbeddedArtwork: false,
            isFavorite: false,
            addedAt: Date(),
            isStream: true,
            streamUrlString: item.url,
            coverURL: artworkURL
        )
        return Result(
            track: track,
            isRestricted: item.isRestricted,
            compoundID: compoundID,
            accessKey: item.accessKey
        )
    }

    nonisolated static func adaptPlayable(_ items: [VKTrackDTO]) -> [Track] {
        items.lazy.filter { !$0.isRestricted }.map { adapt($0).track }
    }

    nonisolated private static func stableID(from value: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data(value.utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated private static func stableSeed(from value: String) -> Int {
        value.utf8.reduce(17) { ($0 &* 31) &+ Int($1) }
    }
}
