import WidgetKit
import SwiftUI
import ActivityKit

@main
struct OsaMapsLiveBundle: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}

/// Affichage minimal de la Live Activity de guidage — le module guidance le peaufine.
struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.symbol).font(.system(size: 30, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.distance(context.state.distance)).font(.system(size: 24, weight: .bold))
                    Text(context.state.street ?? context.state.instruction).font(.system(size: 14, weight: .semibold)).opacity(0.6).lineLimit(1)
                }
                Spacer()
                Text(context.state.eta, style: .time).font(.system(size: 16, weight: .bold))
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color(red: 0.039, green: 0.039, blue: 0.059))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: context.state.symbol).font(.title2.bold()) }
                DynamicIslandExpandedRegion(.center) { Text(Self.distance(context.state.distance)).font(.title3.bold()) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.eta, style: .time).font(.headline) }
            } compactLeading: {
                Image(systemName: context.state.symbol)
            } compactTrailing: {
                Text(Self.distance(context.state.distance)).font(.caption.bold())
            } minimal: {
                Image(systemName: context.state.symbol)
            }
        }
    }

    static func distance(_ m: Double) -> String {
        m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
    }
}
