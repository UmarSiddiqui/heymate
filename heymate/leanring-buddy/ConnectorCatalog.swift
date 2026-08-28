//
//  ConnectorCatalog.swift
//  leanring-buddy
//
//  Every service HeyMate knows how to reach, as data.
//
//  Ordering principle: the ones that need nothing from anybody come first.
//  Apple frameworks work with a TCC prompt. Local CLIs work because the
//  user already signed those tools in — HeyMate never sees the token.
//  MCP servers are next because one client implementation covers the whole
//  ecosystem. Everything that needs a vendor account — Gmail, Slack, Notion,
//  and 1,400 others — is not here at all: those are Composio toolkits,
//  fetched at runtime by `ComposioToolkitDirectory`, because a list that
//  large has no business being hand-maintained in a Swift file.
//
//  Adding a connector is a data edit, not a code change. That is the point.
//

import Foundation

enum ConnectorCatalog {

    // MARK: - On this Mac (no account, no network)

    static let appleNativeConnectors: [Connector] = [
        Connector(
            id: "apple-calendar",
            displayName: "Apple Calendar",
            summary: "Read your schedule and create events with EventKit.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "calendar",
            maximumRisk: .reversibleWrite,
            capabilities: ["Find free time", "Create and move events", "Next-meeting peek in the notch"]
        ),
        Connector(
            id: "apple-reminders",
            displayName: "Reminders",
            summary: "Capture tasks by voice straight into your lists.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "checklist",
            maximumRisk: .reversibleWrite,
            capabilities: ["Add reminders", "Read today's list", "Complete items"]
        ),
        Connector(
            id: "apple-contacts",
            displayName: "Contacts",
            summary: "Resolve names to addresses so drafts go to the right person.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "person.crop.circle",
            maximumRisk: .readOnly,
            capabilities: ["Look up a person", "Resolve an email or number"]
        ),
        Connector(
            id: "apple-notes",
            displayName: "Apple Notes",
            summary: "Append to and search Notes through scripting.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "note.text",
            maximumRisk: .reversibleWrite,
            capabilities: ["Create a note", "Append to a note", "Search notes"]
        ),
        Connector(
            id: "apple-mail",
            displayName: "Mail",
            summary: "Draft in Mail.app. Sending always asks first.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "envelope",
            maximumRisk: .externalSideEffect,
            capabilities: ["Create a draft", "Search mailboxes", "Send after approval"]
        ),
        Connector(
            id: "apple-messages",
            displayName: "Messages",
            summary: "Compose an iMessage; you press send.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "message",
            maximumRisk: .externalSideEffect,
            capabilities: ["Draft a message", "Send after approval"]
        ),
        Connector(
            id: "apple-shortcuts",
            displayName: "Shortcuts",
            summary: "Run any shortcut you have already built.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "square.stack.3d.up",
            maximumRisk: .externalSideEffect,
            capabilities: ["List shortcuts", "Run a shortcut with input"]
        ),
        Connector(
            id: "apple-music",
            displayName: "Music",
            summary: "Transport controls and now-playing for the notch.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "music.note",
            maximumRisk: .reversibleWrite,
            capabilities: ["Play / pause / skip", "Now playing in the notch"]
        ),
        Connector(
            id: "apple-finder",
            displayName: "Files",
            summary: "Folders you explicitly grant, held as security-scoped bookmarks.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "folder",
            maximumRisk: .reversibleWrite,
            capabilities: ["Read a chosen folder", "Write into a chosen folder", "Reveal in Finder"]
        ),
        Connector(
            id: "apple-maps",
            displayName: "Maps",
            summary: "Places, directions, and travel time via MapKit.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "map",
            maximumRisk: .readOnly,
            capabilities: ["Search places", "Estimate travel time"]
        ),
        Connector(
            id: "apple-screen",
            displayName: "Screen & windows",
            summary: "What is in front of you, via ScreenCaptureKit and the accessibility tree.",
            category: .appleBuiltIn,
            transport: .appleNative,
            symbolName: "macwindow",
            maximumRisk: .readOnly,
            capabilities: ["Read the active window", "Capture a region", "Locate a UI element"]
        )
    ]

    // MARK: - Local CLIs (the user's own logins, never ours)

    static let localCLIConnectors: [Connector] = [
        Connector(
            id: "gog-workspace",
            displayName: "Google Workspace",
            summary: "Gmail, Calendar, Drive, Docs and Sheets through the gogcli tool you sign in yourself.",
            category: .communication,
            transport: .localCLI,
            symbolName: "envelope.badge",
            maximumRisk: .externalSideEffect,
            capabilities: ["Search mail", "Read calendar", "Drive files", "Draft — sending asks first"],
            requiredExecutableName: "gog",
            installHint: "brew install steipete/tap/gogcli && gog auth add you@example.com"
        ),
        Connector(
            id: "github-cli",
            displayName: "GitHub",
            summary: "Issues, pull requests, releases and Actions via the gh CLI.",
            category: .developer,
            transport: .localCLI,
            symbolName: "chevron.left.forwardslash.chevron.right",
            maximumRisk: .externalSideEffect,
            capabilities: ["Read issues and PRs", "Comment", "Open a PR after approval"],
            requiredExecutableName: "gh",
            installHint: "brew install gh && gh auth login"
        ),
        Connector(
            id: "git-local",
            displayName: "Git",
            summary: "Local repository history, diffs, and branches.",
            category: .developer,
            transport: .localCLI,
            symbolName: "arrow.triangle.branch",
            maximumRisk: .reversibleWrite,
            capabilities: ["Read log and diff", "Create a branch", "Commit after approval"],
            requiredExecutableName: "git",
            installHint: "xcode-select --install"
        ),
        Connector(
            id: "docker-cli",
            displayName: "Docker",
            summary: "Containers, images, and compose stacks on this machine.",
            category: .cloudAndInfra,
            transport: .localCLI,
            symbolName: "shippingbox",
            maximumRisk: .destructive,
            capabilities: ["List containers", "Read logs", "Start or stop after approval"],
            requiredExecutableName: "docker",
            installHint: "brew install --cask docker"
        ),
        Connector(
            id: "kubectl-cli",
            displayName: "Kubernetes",
            summary: "Cluster state through your existing kubeconfig.",
            category: .cloudAndInfra,
            transport: .localCLI,
            symbolName: "square.grid.3x3",
            maximumRisk: .destructive,
            capabilities: ["Read pods and events", "Tail logs", "Apply after approval"],
            requiredExecutableName: "kubectl",
            installHint: "brew install kubectl"
        ),
        Connector(
            id: "aws-cli",
            displayName: "AWS",
            summary: "Your configured AWS profiles.",
            category: .cloudAndInfra,
            transport: .localCLI,
            symbolName: "cloud",
            maximumRisk: .destructive,
            capabilities: ["Describe resources", "Read CloudWatch", "Mutations always ask"],
            requiredExecutableName: "aws",
            installHint: "brew install awscli && aws configure"
        ),
        Connector(
            id: "vercel-cli",
            displayName: "Vercel",
            summary: "Deployments, logs, and environment variables.",
            category: .cloudAndInfra,
            transport: .localCLI,
            symbolName: "triangle",
            maximumRisk: .externalSideEffect,
            capabilities: ["List deployments", "Read build logs", "Deploy after approval"],
            requiredExecutableName: "vercel",
            installHint: "npm i -g vercel && vercel login"
        ),
        Connector(
            id: "supabase-cli",
            displayName: "Supabase",
            summary: "Local and hosted project management.",
            category: .cloudAndInfra,
            transport: .localCLI,
            symbolName: "cylinder.split.1x2",
            maximumRisk: .destructive,
            capabilities: ["Inspect schema", "Run migrations after approval"],
            requiredExecutableName: "supabase",
            installHint: "brew install supabase/tap/supabase"
        ),
        Connector(
            id: "stripe-cli",
            displayName: "Stripe",
            summary: "Read-only by default; every write is money, so every write asks.",
            category: .commerceAndFinance,
            transport: .localCLI,
            symbolName: "creditcard",
            maximumRisk: .destructive,
            capabilities: ["Read customers and charges", "Tail events"],
            requiredExecutableName: "stripe",
            installHint: "brew install stripe/stripe-cli/stripe && stripe login"
        ),
        Connector(
            id: "ffmpeg-cli",
            displayName: "FFmpeg",
            summary: "Convert, trim, and inspect media files locally.",
            category: .designAndMedia,
            transport: .localCLI,
            symbolName: "film",
            maximumRisk: .reversibleWrite,
            capabilities: ["Probe a file", "Transcode", "Extract frames"],
            requiredExecutableName: "ffmpeg",
            installHint: "brew install ffmpeg"
        ),
        Connector(
            id: "yt-dlp-cli",
            displayName: "yt-dlp",
            summary: "Fetch a video or its transcript for the agent to read.",
            category: .webAndResearch,
            transport: .localCLI,
            symbolName: "arrow.down.video",
            maximumRisk: .reversibleWrite,
            capabilities: ["Download media", "Pull captions"],
            requiredExecutableName: "yt-dlp",
            installHint: "brew install yt-dlp"
        ),
        Connector(
            id: "opencode-cli",
            displayName: "OpenCode",
            summary: "Headless coding agent that does the building.",
            category: .developer,
            transport: .localCLI,
            symbolName: "terminal",
            maximumRisk: .destructive,
            capabilities: ["Run a coding job in a sandbox folder", "Attach to an existing repo with approval"],
            requiredExecutableName: "opencode",
            installHint: "curl -fsSL https://opencode.ai/install | bash"
        ),
        Connector(
            id: "claude-code-cli",
            displayName: "Claude Code",
            summary: "The other headless executor HeyMate can hand work to.",
            category: .developer,
            transport: .localCLI,
            symbolName: "sparkles",
            maximumRisk: .destructive,
            capabilities: ["Run a coding job", "Stream progress into the Agents tab"],
            requiredExecutableName: "claude",
            installHint: "npm i -g @anthropic-ai/claude-code"
        )
    ]

    // MARK: - MCP servers (one client, the whole ecosystem)

    static let mcpConnectors: [Connector] = [
        // Deliberately first: one entry that covers hundreds of services, so
        // the per-service entries below become a convenience rather than the
        // only route. Its launch command is written at connect time — the
        // Tool Router URL does not exist until a session is created against
        // the user's own API key.
        Connector(
            id: "composio",
            displayName: "Composio",
            summary: "The sign-in service behind the browser connectors. One free key, then Gmail, Drive, Outlook and the rest connect for real.",
            category: .automation,
            transport: .mcp,
            symbolName: "square.grid.3x3.topleft.filled",
            maximumRisk: .destructive,
            capabilities: [
                "Powers every Sign in with browser connector",
                "One MCP surface over every app you authorise",
                "Free tier, no card"
            ],
            mcpLaunchCommand: nil
        ),
        Connector(
            id: "mcp-postgres",
            displayName: "PostgreSQL",
            summary: "Query a database you point it at. Read-only unless you say otherwise.",
            category: .dataAndAnalytics,
            transport: .mcp,
            symbolName: "cylinder",
            maximumRisk: .destructive,
            capabilities: ["Inspect schema", "Run a select", "Writes always ask"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-postgres"
        ),
        Connector(
            id: "mcp-sqlite",
            displayName: "SQLite",
            summary: "A local .sqlite file as a queryable source.",
            category: .dataAndAnalytics,
            transport: .mcp,
            symbolName: "tablecells",
            maximumRisk: .reversibleWrite,
            capabilities: ["Inspect tables", "Query", "Insert after approval"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-sqlite"
        ),
        Connector(
            id: "mcp-filesystem",
            displayName: "Project files",
            summary: "A scoped filesystem server rooted at folders you choose.",
            category: .developer,
            transport: .mcp,
            symbolName: "folder.badge.gearshape",
            maximumRisk: .reversibleWrite,
            capabilities: ["Read files in scope", "Write in scope", "Never leaves the chosen roots"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-filesystem"
        ),
        Connector(
            id: "mcp-playwright",
            displayName: "Browser (Playwright)",
            summary: "Drive a real browser: navigate, read, fill, and screenshot.",
            category: .webAndResearch,
            transport: .mcp,
            symbolName: "safari",
            maximumRisk: .externalSideEffect,
            capabilities: ["Open a page", "Read text and DOM", "Click and type after approval"],
            mcpLaunchCommand: "npx -y @playwright/mcp@latest"
        ),
        Connector(
            id: "mcp-fetch",
            displayName: "Web fetch",
            summary: "Pull a URL and convert it to clean text.",
            category: .webAndResearch,
            transport: .mcp,
            symbolName: "globe",
            maximumRisk: .readOnly,
            capabilities: ["Fetch a page", "Readable-text extraction"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-fetch"
        ),
        Connector(
            id: "mcp-brave-search",
            displayName: "Web search",
            summary: "Search the web through the Brave Search API.",
            category: .webAndResearch,
            transport: .mcp,
            symbolName: "magnifyingglass",
            maximumRisk: .readOnly,
            capabilities: ["Web search", "News search"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-brave-search"
        ),
        Connector(
            id: "mcp-memory",
            displayName: "Knowledge graph",
            summary: "A durable entity/relation memory the agent can grow.",
            category: .automation,
            transport: .mcp,
            symbolName: "brain",
            maximumRisk: .reversibleWrite,
            capabilities: ["Remember an entity", "Recall relations", "Fully local"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-memory"
        ),
                Connector(
            id: "mcp-obsidian",
            displayName: "Obsidian",
            summary: "Your local vault as a searchable, writable source.",
            category: .notesAndDocs,
            transport: .mcp,
            symbolName: "book.closed",
            maximumRisk: .reversibleWrite,
            capabilities: ["Search notes", "Read a note", "Append to a note"],
            mcpLaunchCommand: "npx -y mcp-obsidian"
        ),
        Connector(
            id: "mcp-apple-shortcuts",
            displayName: "Shortcuts (MCP)",
            summary: "Expose your Shortcuts library as agent tools.",
            category: .automation,
            transport: .mcp,
            symbolName: "square.stack.3d.up.fill",
            maximumRisk: .externalSideEffect,
            capabilities: ["List shortcuts", "Run one with parameters"],
            mcpLaunchCommand: "npx -y @modelcontextprotocol/server-apple-shortcuts"
        ),
        Connector(
            id: "mcp-time",
            displayName: "Time & timezones",
            summary: "Correct current time and timezone conversion.",
            category: .automation,
            transport: .mcp,
            symbolName: "clock",
            maximumRisk: .readOnly,
            capabilities: ["Current time anywhere", "Convert between zones"],
            mcpLaunchCommand: "uvx mcp-server-time"
        ),
        Connector(
            id: "mcp-custom",
            displayName: "Add your own MCP server",
            summary: "Point HeyMate at any MCP server — local command or remote URL.",
            category: .automation,
            transport: .mcp,
            symbolName: "plus.rectangle.on.folder",
            maximumRisk: .destructive,
            capabilities: ["Any tools that server exposes", "You choose the approval policy"],
            mcpLaunchCommand: nil
        )
    ]

    // MARK: - Assembly

    /// Everything, ordered local-first inside each category.
    static let all: [Connector] = (
        appleNativeConnectors + localCLIConnectors + mcpConnectors
    )

    static func connector(withID id: String) -> Connector? {
        all.first { $0.id == id }
    }

    static func connectors(in category: ConnectorCategory) -> [Connector] {
        all
            .filter { $0.category == category }
            .sorted { left, right in
                if left.transport.localityRank != right.transport.localityRank {
                    return left.transport.localityRank < right.transport.localityRank
                }
                return left.displayName < right.displayName
            }
    }

    /// Categories that actually contain something, in declaration order.
    static var populatedCategories: [ConnectorCategory] {
        ConnectorCategory.allCases.filter { !connectors(in: $0).isEmpty }
    }

    /// Substring match over name, summary, and capabilities. Case- and
    /// diacritic-insensitive so "figma" finds Figma and "sheet" finds both
    /// Google Sheets and Airtable's "spreadsheet" phrasing.
    static func search(_ query: String) -> [Connector] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { connector in
            let haystack = ([connector.displayName, connector.summary] + connector.capabilities)
                .joined(separator: " ")
            return haystack.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}
