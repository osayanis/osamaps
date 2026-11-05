import WidgetKit
import SwiftUI
import ActivityKit

// Les vues sont dans Shared/LiveViews.swift (aussi affichées par l'écran d'aperçu DEBUG de l'app : -livePreview).

@main
struct OsaMapsLiveBundle: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
        FriendLiveActivity()
    }
}

/// Live Activity de guidage : écran verrouillé + Dynamic Island.
/// Pendant une notification (alerte, recalcul, retard, arrivée), l'app l'ouvre en grand (AlertConfiguration)
/// et les vues passent en mode « notification » quelques secondes.
struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LiveNavLockScreen(state: context.state, destination: context.attributes.destinationName)
                .activityBackgroundTint(LiveOsa.bg)
                .activitySystemActionForegroundColor(.white)
                .environment(\.locale, Locale(identifier: "fr_FR"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { LiveNavExpandedLeading(state: s) }
                DynamicIslandExpandedRegion(.center) { LiveNavExpandedCenter(state: s) }
                DynamicIslandExpandedRegion(.trailing) { LiveNavExpandedTrailing(state: s) }
                DynamicIslandExpandedRegion(.bottom) { LiveNavExpandedBottom(state: s) }
            } compactLeading: {
                LiveNavCompactLeading(state: s)
            } compactTrailing: {
                LiveNavCompactTrailing(state: s)
            } minimal: {
                LiveNavMinimal(state: s)
            }
            .keylineTint(s.hasBanner ? LiveOsa.tone(s.bannerTone) : .white)
        }
    }
}

/// Live Activity « un ami arrive » (suivi d'un trajet partagé).
struct FriendLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FriendActivityAttributes.self) { context in
            LiveFriendLockScreen(name: context.attributes.name, state: context.state)
                .activityBackgroundTint(LiveOsa.bg)
                .activitySystemActionForegroundColor(.white)
                .environment(\.locale, Locale(identifier: "fr_FR"))
        } dynamicIsland: { context in
            let s = context.state
            let name = context.attributes.name
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveFriendAvatar(name: name, arrived: s.arrived, size: 48).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    LiveFriendTitle(name: name, state: s).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveFriendETA(state: s, big: 18).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !s.arrived { LiveProgress(value: s.progress).padding(.horizontal, 4).padding(.top, 4) }
                }
            } compactLeading: {
                LiveFriendAvatar(name: name, arrived: s.arrived, size: 22).padding(.leading, 2)
            } compactTrailing: {
                LiveFriendCompactTrailing(state: s)
            } minimal: {
                LiveFriendAvatar(name: name, arrived: s.arrived, size: 22)
            }
            .keylineTint(s.arrived ? LiveOsa.ok : .white)
        }
    }
}
