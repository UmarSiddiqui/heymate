//
//  ComposioToolkitDirectory.swift
//  leanring-buddy
//
//  The integrations list, fetched rather than maintained.
//
//  Composio publishes 1,411 toolkits and adds more every week. Shipping a
//  hand-written subset means the list is wrong the day it ships, the
//  descriptions drift from the vendor's, and every new app is a code change.
//  So the catalog is not data in this repo any more — it is an API call.
//
//  Two filters make the result honest rather than merely long:
//
//    composio_managed_auth_schemes — Composio's own OAuth app backs the
//      sign-in, so the user clicks Connect and approves. A toolkit without
//      it would demand they register a developer app first, which is not a
//      thing to hide behind a blue button.
//    no_auth — toolkits that need no account at all (web search, Hacker
//      News). Free to connect, so they stay.
//
//  Anything else is dropped from the list rather than shown and then
//  failing.
//

import Combine
import Foundation

// MARK: - Model

struct ComposioToolkit: Identifiable, Equatable, Sendable {
    let slug: String
    let name: String
    let description: String
    let logoURL: URL?
    let toolCount: Int
    let categories: [String]
    /// Composio's own OAuth app backs this one — Connect just works.
    let usesComposioManagedAuth: Bool
    /// Needs no account at all.
    let requiresNoAuthentication: Bool

    var id: String { slug }

    /// Only these can be connected with one click. The rest would need the
    /// user to bring their own OAuth credentials, which this UI does not ask
    /// for and should not pretend to.
    var isOneClickConnectable: Bool { usesComposioManagedAuth || requiresNoAuthentication }

    static func decode(from item: [String: Any]) -> ComposioToolkit? {
        guard let slug = item["slug"] as? String,
              let name = item["name"] as? String else { return nil }
        let meta = item["meta"] as? [String: Any] ?? [:]
        let categories = (meta["categories"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        return ComposioToolkit(
            slug: slug,
            name: name,
            description: (meta["description"] as? String) ?? "",
            logoURL: (meta["logo"] as? String).flatMap(URL.init(string:)),
            toolCount: (meta["tools_count"] as? Int) ?? 0,
            categories: categories,
            usesComposioManagedAuth: ((item["composio_managed_auth_schemes"] as? [String]) ?? []).isEmpty == false,
            requiresNoAuthentication: (item["no_auth"] as? Bool) ?? false
        )
    }
}

// MARK: - Directory

/// Fetches and caches the toolkit list. One instance, owned by the view that
/// shows integrations.
@MainActor
final class ComposioToolkitDirectory: ObservableObject {

    /// What the list shows before the user types. Popularity order comes
    /// straight from the API — page one is Gmail, GitHub, Calendar, Notion,
    /// Sheets, Slack, in that order — so no local ranking is invented.
    static let defaultPageSize = 60
    static let searchPageSize = 30

    /// Long enough that reopening the window is instant, short enough that a
    /// newly published toolkit shows up the same day.
    static let cacheLifetime: TimeInterval = 60 * 60 * 6

    @Published private(set) var toolkits: [ComposioToolkit] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailureMessage: String?

    private let transport: ComposioAuthBroker.Transport
    private var cachedDefaultPage: (fetchedAt: Date, toolkits: [ComposioToolkit])?
    private var searchTask: Task<Void, Never>?

    init(transport: @escaping ComposioAuthBroker.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    // MARK: Requests

    static func makeListRequest(apiKey: String, search: String?, limit: Int) -> URLRequest {
        var components = URLComponents(
            url: ComposioAuthBroker.apiBaseURL.appendingPathComponent("toolkits"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty {
            // `search` is the parameter the API actually honours; `q` is
            // silently ignored and returns the unfiltered first page, which
            // reads as "search is broken" rather than as a wrong parameter.
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return request
    }

    static func parseToolkits(from data: Data) -> [ComposioToolkit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items
            .compactMap(ComposioToolkit.decode(from:))
            .filter(\.isOneClickConnectable)
    }

    // MARK: Loading

    /// Load the default page, from cache when it is fresh.
    func loadDefaultPage(apiKey: String?) async {
        guard let apiKey, !apiKey.isEmpty else {
            toolkits = []
            loadFailureMessage = ComposioAuthError.notConfigured.localizedDescription
            return
        }
        if let cached = cachedDefaultPage,
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            toolkits = cached.toolkits
            loadFailureMessage = nil
            return
        }
        await fetch(apiKey: apiKey, search: nil, limit: Self.defaultPageSize, cacheAsDefault: true)
    }

    /// Debounced search. Empty query restores the default page rather than
    /// firing a request for nothing.
    func search(_ query: String, apiKey: String?) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            if trimmed.isEmpty {
                await self.loadDefaultPage(apiKey: apiKey)
            } else if let apiKey, !apiKey.isEmpty {
                await self.fetch(apiKey: apiKey, search: trimmed, limit: Self.searchPageSize, cacheAsDefault: false)
            }
        }
    }

    private func fetch(apiKey: String, search: String?, limit: Int, cacheAsDefault: Bool) async {
        isLoading = true
        defer { isLoading = false }

        let request = Self.makeListRequest(apiKey: apiKey, search: search, limit: limit)
        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                loadFailureMessage = ComposioAuthError.rejected(
                    status: http.statusCode,
                    message: ComposioProvisioner.errorMessage(from: data)
                ).localizedDescription
                return
            }
            let parsed = Self.parseToolkits(from: data)
            toolkits = parsed
            loadFailureMessage = nil
            if cacheAsDefault {
                cachedDefaultPage = (Date(), parsed)
            }
        } catch {
            loadFailureMessage = ComposioAuthError.transport(error.localizedDescription).localizedDescription
        }
    }
}
