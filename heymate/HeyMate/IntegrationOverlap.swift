//
//  IntegrationOverlap.swift
//  HeyMate
//
//  Some services are reachable two ways: a tool on this Mac the user has
//  already signed in to (the `gh` CLI for GitHub) and a web sign-in through
//  Composio. Most people never add a Composio key, so the local route is
//  the one HeyMate leans on, and the web list only fills the gaps. Either
//  way the service is one thing to the user, so it shows up once.
//

import Foundation

enum IntegrationOverlap {
    /// "GitHub", "github" and "Git Hub" are the same service.
    static func matchKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// The web apps worth offering. Drops Composio itself (it is the
    /// sign-in service, not an app) and any app a local tool already
    /// reaches, unless it is also connected on the web so it can still be
    /// disconnected there.
    static func webAppsToList(
        _ toolkits: [ComposioToolkit],
        connectedLocalNames: [String],
        isConnectedOnWeb: (String) -> Bool
    ) -> [ComposioToolkit] {
        let localKeys = Set(connectedLocalNames.map(matchKey))
        return toolkits.filter { toolkit in
            guard toolkit.slug.lowercased() != ComposioSessionStore.connectorID else { return false }
            if isConnectedOnWeb(toolkit.slug) { return true }
            return !localKeys.contains(matchKey(toolkit.name)) && !localKeys.contains(matchKey(toolkit.slug))
        }
    }

    typealias Item = (id: String, name: String, logoSlug: String)

    /// One entry per service. The local one wins, borrowing the web app's
    /// slug for its logo, since a CLI connector has no logo of its own.
    static func merged(local: [Item], web: [Item]) -> [Item] {
        var webByKey: [String: Item] = [:]
        for item in web { webByKey[matchKey(item.name)] = webByKey[matchKey(item.name)] ?? item }
        let localKeys = Set(local.map { matchKey($0.name) })
        let localItems = local.map { item -> Item in
            guard let twin = webByKey[matchKey(item.name)] else { return item }
            return (id: item.id, name: item.name, logoSlug: twin.logoSlug)
        }
        let webOnly = web.filter { !localKeys.contains(matchKey($0.name)) }
        return (localItems + webOnly).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// For lists that keep both routes as separate switches (the composer's
    /// Apps picker): say which is which when a name appears twice.
    static func labeled(local: [Item], web: [Item]) -> [Item] {
        let localKeys = Set(local.map { matchKey($0.name) })
        let webKeys = Set(web.map { matchKey($0.name) })
        let localItems = local.map { item -> Item in
            webKeys.contains(matchKey(item.name))
                ? (id: item.id, name: "\(item.name) (on this Mac)", logoSlug: item.logoSlug)
                : item
        }
        let webItems = web.map { item -> Item in
            localKeys.contains(matchKey(item.name))
                ? (id: item.id, name: "\(item.name) (web)", logoSlug: item.logoSlug)
                : item
        }
        return (localItems + webItems).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
