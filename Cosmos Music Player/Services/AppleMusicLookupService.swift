//
//  AppleMusicLookupService.swift
//  Cosmos Music Player
//
//  Artist/album metadata lookup backed by Apple's public iTunes Search API
//  (https://itunes.apple.com/search). Deliberately NOT MusicKit — MusicKit
//  requires an Apple Music entitlement tied to real provisioning, which this
//  project already confirmed doesn't survive ad-hoc/TrollStore builds (see
//  the CloudKit crash earlier in this project's history). The iTunes Search
//  API is a plain, unauthenticated REST endpoint with no entitlement
//  requirement, and is backed by the same underlying Apple Music catalog.
//

import Foundation

struct ITunesArtist: Decodable, Identifiable, Hashable {
    let artistId: Int
    let artistName: String
    var id: Int { artistId }
}

struct ITunesAlbum: Decodable, Identifiable, Hashable {
    let collectionId: Int
    let collectionName: String
    let artistName: String
    let artworkUrl100: String?
    let releaseDate: String?
    var id: Int { collectionId }

    /// iTunes only ever serves a handful of fixed artwork sizes via URL
    /// substitution. Swapping in a larger size gives noticeably better
    /// quality for use as embedded album art.
    var highResArtworkURL: URL? {
        guard let artworkUrl100 else { return nil }
        let upsized = artworkUrl100.replacingOccurrences(of: "100x100", with: "1200x1200")
        return URL(string: upsized)
    }

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

enum AppleMusicLookupError: Error {
    case invalidResponse
}

enum AppleMusicLookupService {

    private struct SearchResponse<T: Decodable>: Decodable {
        let results: [T]
    }

    static func searchArtists(term: String, limit: Int = 8) async throws -> [ITunesArtist] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw AppleMusicLookupError.invalidResponse }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResponse<ITunesArtist>.self, from: data)

        // Dedupe — iTunes sometimes returns the same artist name multiple
        // times under different artistIds (regional catalog entries, etc.)
        var seen = Set<String>()
        return decoded.results.filter { seen.insert($0.artistName.lowercased()).inserted }
    }

    static func searchAlbums(artistName: String, limit: Int = 25) async throws -> [ITunesAlbum] {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw AppleMusicLookupError.invalidResponse }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResponse<ITunesAlbum>.self, from: data)

        // The artistTerm attribute is fuzzy, not exact — filter to albums
        // actually credited to (approximately) this artist so a search for
        // "Lana Del Rey" doesn't also surface unrelated compilation albums
        // that merely mention her.
        let lowerTarget = trimmed.lowercased()
        return decoded.results.filter { $0.artistName.lowercased().contains(lowerTarget) || lowerTarget.contains($0.artistName.lowercased()) }
    }

    static func downloadArtworkJPEGData(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}
