//
//  UnsplashClient.swift
//  Screendrop
//
//  Searches Unsplash for frame backgrounds, straight from the app: public
//  endpoints only need an Access Key, so there is no server in between.
//  Release builds carry the project's key in a git-ignored Secrets.plist;
//  a build without one asks for the user's own key, kept in UserDefaults.
//
//  Unsplash's API guidelines, which this follows: images load from the URLs
//  the API returns, a photo's download endpoint is pinged when it is used,
//  and the photographer and Unsplash are credited with UTM-tagged links.
//

import Foundation

nonisolated struct UnsplashPhoto: Decodable, Identifiable, Hashable, Sendable {
    struct URLs: Decodable, Hashable, Sendable {
        let raw: URL
        let small: URL
    }

    struct Links: Decodable, Hashable, Sendable {
        let downloadLocation: URL

        enum CodingKeys: String, CodingKey {
            case downloadLocation = "download_location"
        }
    }

    struct User: Decodable, Hashable, Sendable {
        struct Links: Decodable, Hashable, Sendable {
            let html: URL
        }

        let name: String
        let links: Links
    }

    let id: String
    let width: Int
    let height: Int
    /// The photo's average color, shown while its thumbnail loads.
    let color: String?
    let altDescription: String?
    let urls: URLs
    let links: Links
    let user: User

    enum CodingKeys: String, CodingKey {
        case id, width, height, color, urls, links, user
        case altDescription = "alt_description"
    }

    /// The photographer's profile, tagged as the guidelines ask.
    var photographerURL: URL { UnsplashClient.referral(user.links.html) }

    /// Large enough for a Retina canvas without pulling the original.
    var backgroundURL: URL {
        var components = URLComponents(url: urls.raw, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items += [
            URLQueryItem(name: "w", value: "3840"),
            URLQueryItem(name: "fit", value: "max"),
            URLQueryItem(name: "q", value: "85"),
            URLQueryItem(name: "fm", value: "jpg")
        ]
        components?.queryItems = items
        return components?.url ?? urls.raw
    }
}

nonisolated enum UnsplashClient {
    struct Page: Sendable {
        let photos: [UnsplashPhoto]
        let hasMore: Bool
    }

    enum ClientError: LocalizedError, Equatable {
        case missingKey
        case invalidKey
        case rateLimited
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add an Unsplash Access Key to search."
            case .invalidKey: "Unsplash didn't accept the Access Key."
            case .rateLimited: "Unsplash's hourly limit is used up. Try again later."
            case .http(let status): "Unsplash returned an error (HTTP \(status))."
            }
        }
    }

    static let pageSize = 12
    static let unsplashURL = referral(URL(string: "https://unsplash.com")!)
    static let developersURL = URL(string: "https://unsplash.com/developers")!
    static let userKeyDefaultsKey = "unsplashAccessKey"

    private static let apiBase = URL(string: "https://api.unsplash.com")!
    private static let bundledKey: String? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["UnsplashAccessKey"] as? String
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    /// The user's own key wins over the bundled one.
    static var accessKey: String? {
        let userKey = UserDefaults.standard.string(forKey: userKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let userKey, !userKey.isEmpty { return userKey }
        return bundledKey
    }

    static var hasBundledKey: Bool { bundledKey != nil }

    static func referral(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "utm_source", value: "screendrop"),
            URLQueryItem(name: "utm_medium", value: "referral")
        ]
        return components.url ?? url
    }

    /// Landscape photos for `query`, or Unsplash's Wallpapers topic when it
    /// is empty.
    static func photos(query: String, page: Int) async throws -> Page {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let common = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(pageSize)),
            URLQueryItem(name: "orientation", value: "landscape")
        ]
        if query.isEmpty {
            let photos: [UnsplashPhoto] = try await get("/topics/wallpapers/photos", query: common)
            return Page(photos: photos, hasMore: photos.count == pageSize)
        }
        struct SearchResponse: Decodable {
            let totalPages: Int
            let results: [UnsplashPhoto]

            enum CodingKeys: String, CodingKey {
                case results
                case totalPages = "total_pages"
            }
        }
        let response: SearchResponse = try await get(
            "/search/photos",
            query: common + [URLQueryItem(name: "query", value: query)]
        )
        return Page(photos: response.results, hasMore: page < response.totalPages)
    }

    /// Downloads the photo into `directory`, named for its photographer so
    /// the background row credits them, and reports the download to
    /// Unsplash. A photo downloaded before is reused without either.
    static func download(_ photo: UnsplashPhoto, to directory: URL) async throws -> URL {
        let name = photo.user.name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: " ")
        let destination = directory.appendingPathComponent("Photo by \(name) (\(photo.id)).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let (downloadedURL, response) = try await URLSession.shared.download(from: photo.backgroundURL)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
            throw ClientError.http(status)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloadedURL, to: destination)

        // Counts the download for the photographer. Failing it must not
        // take away a background the user already has.
        _ = try? await request(photo.links.downloadLocation)
        return destination
    }

    private static func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw ClientError.http(0) }
        return try JSONDecoder().decode(T.self, from: try await request(url))
    }

    private static func request(_ url: URL) async throws -> Data {
        guard let key = accessKey else { throw ClientError.missingKey }
        var request = URLRequest(url: url)
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(0) }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw ClientError.invalidKey
        case 403 where http.value(forHTTPHeaderField: "X-Ratelimit-Remaining") == "0": throw ClientError.rateLimited
        case 429: throw ClientError.rateLimited
        default: throw ClientError.http(http.statusCode)
        }
    }
}
