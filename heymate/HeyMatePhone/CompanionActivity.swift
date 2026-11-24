import ActivityKit
import Foundation

struct CompanionActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Stage: String, Codable, Hashable {
            case queued, working, ready, failed, stopped

            var title: String {
                switch self {
                case .queued: "Waiting for your Mac"
                case .working: "Working on your Mac"
                case .ready: "Reply ready"
                case .failed: "Check your chat"
                case .stopped: "Reply stopped"
                }
            }

            var icon: String {
                switch self {
                case .queued: "clock"
                case .working: "ellipsis"
                case .ready: "checkmark"
                case .failed: "exclamationmark"
                case .stopped: "stop.fill"
                }
            }
        }

        let stage: Stage
    }

    let mateID: UUID
    let chatID: UUID

    var link: URL { PhoneCompanionLink.chat(mateID: mateID, chatID: chatID).url }
}

enum PhoneCompanionLink: Equatable {
    case newChat
    case chat(mateID: UUID, chatID: UUID)

    var url: URL {
        switch self {
        case .newChat: URL(string: "heymate-companion://new-chat")!
        case .chat(let mateID, let chatID):
            URL(string: "heymate-companion://chat/\(mateID.uuidString)/\(chatID.uuidString)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == "heymate-companion", url.query == nil, url.fragment == nil else { return nil }
        let path = url.pathComponents.dropFirst()
        switch url.host {
        case "new-chat" where path.isEmpty: self = .newChat
        case "chat" where path.count == 2:
            guard let mateID = UUID(uuidString: path[path.startIndex]),
                  let chatID = UUID(uuidString: path[path.index(after: path.startIndex)]) else { return nil }
            self = .chat(mateID: mateID, chatID: chatID)
        default: return nil
        }
    }
}
