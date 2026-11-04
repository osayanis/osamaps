import SwiftUI

/// La sobriété Osa (comme OsaHUB / OsaWallpaper / la version web) :
/// fond quasi noir, blanc à différentes opacités, gras, pilules blanches à texte noir,
/// cartes blanc 5 % + trait 8 %. La couleur ne dit qu'un ÉTAT (trafic, police, danger, succès).
enum Osa {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.059)
    static let surface = Color.white.opacity(0.05)
    static let surfaceHi = Color.white.opacity(0.08)
    static let line = Color.white.opacity(0.08)
    static let lineHi = Color.white.opacity(0.16)
    static let text = Color.white.opacity(0.95)
    static let dim = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.38)

    // états
    static let ok = Color(red: 0.204, green: 0.78, blue: 0.349)       // fluide
    static let slow = Color(red: 1.0, green: 0.624, blue: 0.039)      // ralenti
    static let jam = Color(red: 1.0, green: 0.271, blue: 0.227)       // bouchon / accident
    static let police = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.8, blue: 0.0)

    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 24

    /// Animation par défaut : courte, ease-out (pas de rebond décoratif).
    static let anim = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.25)
}

extension Font {
    static func osa(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

/// Pilule blanche à texte noir (action principale) ; `.secondary` = verre sombre.
struct OsaPillStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.osa(16, .bold))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .frame(minHeight: 48)
            .foregroundStyle(secondary ? Osa.text : .black)
            .background(secondary ? AnyShapeStyle(Osa.surfaceHi) : AnyShapeStyle(Color.white), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Bouton rond en verre (rail de droite).
struct OsaRoundStyle: ButtonStyle {
    var size: CGFloat = 48
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(prominent ? .black : Osa.text)
            .frame(width: size, height: size)
            .background {
                if prominent { Circle().fill(.white) } else { Circle().fill(.ultraThinMaterial).overlay(Circle().fill(Osa.bg.opacity(0.55))) }
            }
            .overlay(Circle().strokeBorder(Osa.line))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OsaPillStyle {
    static var osaPill: OsaPillStyle { .init() }
    static var osaPillSecondary: OsaPillStyle { .init(secondary: true) }
}

extension ButtonStyle where Self == OsaRoundStyle {
    static var osaRound: OsaRoundStyle { .init() }
}

extension View {
    /// Carte sobre : blanc 5 % + trait 8 %.
    func osaCard(_ radius: CGFloat = Osa.radiusM) -> some View {
        background(Osa.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Osa.line))
    }

    /// Verre sombre (panneaux posés sur la carte).
    func osaGlass(_ radius: CGFloat = Osa.radiusL) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Osa.bg.opacity(0.72)))
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Osa.line))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
    }
}

/// Retour haptique (utilisable partout).
@MainActor
enum Haptic {
    static func play(_ kind: String) {
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
