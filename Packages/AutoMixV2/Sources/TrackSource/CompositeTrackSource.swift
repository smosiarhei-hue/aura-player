// Path: Packages/AutoMixV2/Sources/TrackSource/CompositeTrackSource.swift

import Foundation
import MixModels

public enum TrackSourceRoute: String, Sendable, Codable, Equatable {
    case local
    case yandex
}

/// Keeps one PlaybackCoordinator while routing every track to its real source.
/// Routes are registered before playback, so local files and fully downloaded
/// Yandex files can coexist in the same application queue.
public actor CompositeTrackSource: TrackSource {
    private let localSource: any TrackSource
    private let yandexSource: any TrackSource
    private var routes: [TrackID: TrackSourceRoute]

    public init(
        localSource: any TrackSource,
        yandexSource: any TrackSource,
        routes: [TrackID: TrackSourceRoute] = [:]
    ) {
        self.localSource = localSource
        self.yandexSource = yandexSource
        self.routes = routes
    }

    public func register(_ id: TrackID, route: TrackSourceRoute) {
        routes[id] = route
    }

    public func unregister(_ id: TrackID) {
        routes[id] = nil
    }

    public func route(for id: TrackID) -> TrackSourceRoute? {
        routes[id]
    }

    public func localFileURL(for id: TrackID) async throws -> URL {
        switch try registeredRoute(for: id) {
        case .local:
            return try await localSource.localFileURL(for: id)
        case .yandex:
            return try await yandexSource.localFileURL(for: id)
        }
    }

    public func metadata(for id: TrackID) async throws -> TrackMeta {
        switch try registeredRoute(for: id) {
        case .local:
            return try await localSource.metadata(for: id)
        case .yandex:
            return try await yandexSource.metadata(for: id)
        }
    }

    private func registeredRoute(for id: TrackID) throws -> TrackSourceRoute {
        guard let route = routes[id] else {
            throw TrackSourceError.metadataUnavailable
        }
        return route
    }
}
