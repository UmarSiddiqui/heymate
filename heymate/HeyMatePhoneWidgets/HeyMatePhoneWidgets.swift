import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HeyMatePhoneWidgets: WidgetBundle {
    var body: some Widget {
        HeyMateReplyActivity()
        HeyMateQuickChatWidget()
    }
}

struct HeyMateReplyActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompanionActivity.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(HeyMatePalette.accent(nil, towardWhite: 0.28))
                VStack(alignment: .leading, spacing: 4) {
                    Text("HeyMate").font(.headline)
                    Text(context.isStale ? "Open HeyMate to refresh" : context.state.stage.title)
                        .font(.subheadline)
                        .foregroundStyle(HeyMatePalette.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: context.isStale ? "arrow.clockwise" : context.state.stage.icon)
                    .font(.headline)
            }
            .padding()
            .foregroundStyle(HeyMatePalette.primary)
            .activityBackgroundTint(HeyMatePalette.workspace)
            .activitySystemActionForegroundColor(HeyMatePalette.primary)
            .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(HeyMatePalette.accent(nil, towardWhite: 0.28))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.isStale ? "arrow.clockwise" : context.state.stage.icon)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open HeyMate to refresh" : context.state.stage.title)
                        .font(.headline)
                }
            } compactLeading: {
                Image(systemName: "bubble.left.and.bubble.right.fill").accessibilityLabel("HeyMate")
            } compactTrailing: {
                Image(systemName: context.isStale ? "arrow.clockwise" : context.state.stage.icon)
                    .accessibilityLabel(context.isStale ? "Refresh HeyMate" : context.state.stage.title)
            } minimal: {
                Image(systemName: "bubble.left.fill").accessibilityLabel("HeyMate")
            }
            .widgetURL(context.attributes.link)
            .keylineTint(HeyMatePalette.accent(nil))
        }
    }
}

struct HeyMateQuickChatWidget: Widget {
    private struct Entry: TimelineEntry { let date: Date }

    private struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(placeholder(in: context))
        }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [placeholder(in: context)], policy: .never))
        }
    }


    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HeyMateQuickChat", provider: Provider()) { _ in
            QuickChatView()
        }
        .configurationDisplayName("Quick Chat")
        .description("Start a conversation with HeyMate.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }

    private struct QuickChatView: View {
        @Environment(\.widgetFamily) private var family

        var body: some View {
            Group {
                if family == .accessoryCircular {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: "bubble.left.and.bubble.right.fill").font(.title3)
                    }
                } else {
                    VStack(alignment: .leading) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title2)
                            .foregroundStyle(HeyMatePalette.accent(nil, towardWhite: 0.28))
                        Spacer(minLength: 8)
                        Text("HeyMate").font(.headline)
                        Text("New chat").font(.caption).foregroundStyle(HeyMatePalette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .foregroundStyle(HeyMatePalette.primary)
                }
            }
            .accessibilityLabel("New chat with HeyMate")
            .containerBackground(HeyMatePalette.workspace, for: .widget)
            .widgetURL(PhoneCompanionLink.newChat.url)
        }
    }
}
