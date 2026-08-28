//
//  HeyMateEntrypoint.swift
//  leanring-buddy
//
//  Explicit entrypoint lets this signed executable start either SwiftUI or
//  one detached coding-agent runner without constructing AppKit state first.
//

import SwiftUI

@main
nonisolated enum HeyMateEntrypoint {
    static func main() {
        leanring_buddyApp.main()
    }
}
