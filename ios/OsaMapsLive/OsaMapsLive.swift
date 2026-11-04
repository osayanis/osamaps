import WidgetKit
import SwiftUI
import ActivityKit

@main
struct OsaMapsLiveBundle: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}

/// Couleurs Osa (l'extension ne voit pas Theme.swift de l'app).
private enum LiveOsa {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.059)
    static let dim = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.38)
    static let line = Color.white.opacity(0.12)
    static let ok = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let slow = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let jam = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let police = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.8, blue: 0.0)

    static func tone(_ t: String?) -> Color {
        switch t {
        case "danger": jam
        case "police": police
        case "warn": danger
        default: Color.white.opacity(0.7)
        }
    }

    static func distance(_ m: Double) -> String {
        if m < 50 { return "\(Int((m / 5).rounded()) * 5) m" }
        if m < 1000 { return "\(Int((m / 10).rounded()) * 10) m" }
        if m < 10_000 { return String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",") }
        return "\(Int((m / 1000).rounded())) km"
    }
}

/// Live Activity de guidage : écran verrouillé + Dynamic Island, sobriété Osa.
struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LiveLockScreen(state: context.state, destination: context.attributes.destinationName)
                .activityBackgroundTint(LiveOsa.bg)
                .activitySystemActionForegroundColor(.white)
                .environment(\.locale, Locale(identifier: "fr_FR"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveArrowTile(state: s, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.arrived ? "Arrivé" : LiveOsa.distance(s.distance))
                            .font(.system(size: 30, weight: .heavy))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(s.street ?? s.instruction)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LiveOsa.dim)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !s.arrived {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(s.eta, style: .time)
                                .font(.system(size: 18, weight: .heavy))
                                .monospacedDigit()
                            Text(LiveOsa.distance(s.remaining))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LiveOsa.dim)
                                .monospacedDigit()
                        }
                        .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let alert = s.alert { LiveAlertRow(text: alert, tone: s.alertTone, distance: s.alertDistance) }
                        LiveProgress(value: s.progress)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                LiveArrow(kind: s.kind, exit: nil, size: 22)
                    .foregroundStyle(s.alert != nil ? LiveOsa.tone(s.alertTone) : .white)
                    .padding(.leading, 2)
            } compactTrailing: {
                Text(s.arrived ? "Arrivé" : LiveOsa.distance(s.distance))
                    .font(.system(size: 14, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(s.imminent ? .white : .white.opacity(0.9))
            } minimal: {
                LiveArrow(kind: s.kind, exit: nil, size: 20)
            }
            .keylineTint(.white)
        }
    }
}

/// Vue écran verrouillé : flèche, distance, rue, heure d'arrivée, alerte, progression.
struct LiveLockScreen: View {
    let state: NavActivityAttributes.ContentState
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                LiveArrowTile(state: state, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    if state.arrived {
                        Text("Vous voilà à destination").font(.system(size: 21, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(state.street ?? destination).font(.system(size: 15, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                    } else {
                        Text(LiveOsa.distance(state.distance))
                            .font(.system(size: 32, weight: .heavy))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(state.street.map { state.instruction.isEmpty || state.kind == "straight" ? $0 : "\(state.instruction) · \($0)" } ?? state.instruction)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LiveOsa.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !state.arrived {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.eta, style: .time)
                            .font(.system(size: 20, weight: .heavy))
                            .monospacedDigit()
                        Text(LiveOsa.distance(state.remaining))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiveOsa.dim)
                            .monospacedDigit()
                    }
                }
            }
            if let alert = state.alert, !state.arrived {
                LiveAlertRow(text: alert, tone: state.alertTone, distance: state.alertDistance)
            }
            if !state.arrived {
                HStack(spacing: 8) {
                    LiveProgress(value: state.progress)
                    Text(destination)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveOsa.faint)
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// Flèche dans une tuile : verre blanc 8 % ; blanche à flèche noire quand la manœuvre est imminente ; verte à l'arrivée.
struct LiveArrowTile: View {
    let state: NavActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        let fill: Color = state.arrived ? LiveOsa.ok : state.imminent ? .white : Color.white.opacity(0.08)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(fill)
            if state.arrived {
                Image(systemName: "flag.checkered").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.black)
            } else {
                LiveArrow(kind: state.kind, exit: state.exit, size: size * 0.82)
                    .foregroundStyle(state.imminent ? .black : .white)
            }
        }
        .frame(width: size, height: size)
    }
}

struct LiveAlertRow: View {
    let text: String
    let tone: String?
    let distance: Double?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(LiveOsa.tone(tone)).frame(width: 10, height: 10)
            Text(text).font(.system(size: 15, weight: .bold)).lineLimit(1)
            Spacer(minLength: 4)
            if let distance {
                Text(distance <= 20 ? "ici" : LiveOsa.distance(distance))
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(LiveOsa.tone(tone).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LiveOsa.tone(tone).opacity(0.45)))
    }
}

struct LiveProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LiveOsa.line)
                Capsule().fill(Color.white.opacity(0.8)).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
    }
}
