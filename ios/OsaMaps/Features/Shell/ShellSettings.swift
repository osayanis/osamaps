import SwiftUI

/// Titre de section + carte de lignes (style commun des réglages du shell).
struct ShellSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.osa(12, .bold))
                .tracking(0.6)
                .foregroundStyle(Osa.faint)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .osaCard()
        }
    }
}

struct ShellRow<Trailing: View>: View {
    let label: String
    var hint: String?
    var danger = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let row = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.osa(16, .semibold)).foregroundStyle(danger ? Osa.jam : Osa.text)
                if let hint { Text(hint).font(.osa(13, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.foregroundStyle(danger ? Osa.jam : Osa.dim)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(ShellRowStyle())
        } else {
            row
        }
    }
}

struct ShellRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Osa.surfaceHi : .clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ShellDivider: View {
    var body: some View { Rectangle().fill(Osa.line).frame(height: 1).padding(.leading, 16) }
}

/// Section « Général » (en haut des réglages).
struct ShellGeneralSettings: View {
    @Environment(Prefs.self) private var prefs
    @Environment(Core.self) private var core
    @State private var haptics = ShellPrefs.haptics

    private static let styles: [(id: String, label: String, icon: String)] = [
        ("auto", "Auto", "circle.lefthalf.filled"), ("light", "Clair", "sun.max.fill"), ("dark", "Sombre", "moon.fill"),
    ]

    var body: some View {
        ShellSection(title: "Général") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Style de carte").font(.osa(16, .semibold)).foregroundStyle(Osa.text)
                    Text(styleHint).font(.osa(13, .regular)).foregroundStyle(Osa.dim)
                        .contentTransition(.opacity)
                }
                HStack(spacing: 6) {
                    ForEach(Self.styles, id: \.id) { s in
                        let on = prefs.mapStyle == s.id
                        Button {
                            Haptic.play("light")
                            withAnimation(Osa.anim) { prefs.mapStyle = s.id }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: s.icon).font(.system(size: 14, weight: .semibold))
                                Text(s.label).font(.osa(14, .bold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(on ? .black : Osa.text)
                            .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.clear), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                .padding(4)
                .background(Osa.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Osa.line))
            }
            .padding(16)
            ShellDivider()
            ShellRow(label: "Unités", hint: "Distances en kilomètres, vitesses en km/h.") {
                Text("km · km/h").font(.osa(14, .semibold))
            }
            ShellDivider()
            ShellRow(label: "Vibrations", hint: "Un petit retour sur les actions importantes et les alertes.") {
                Toggle("Vibrations", isOn: $haptics).labelsHidden().tint(Osa.ok)
            }
            .onChange(of: haptics) { _, v in ShellPrefs.haptics = v; if v { Haptic.play("light") } }
        }
    }

    private var styleHint: String {
        switch prefs.mapStyle {
        case "light": return "Toujours clair."
        case "dark": return "Toujours sombre."
        default:
            let c = core.position?.coordinate ?? Location.defaultCenter
            guard let t = ShellSun.times(.now, lat: c.latitude, lng: c.longitude) else { return "Selon le jour et la nuit." }
            let f = Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "fr_FR"))
            return "Clair de \(t.sunrise.formatted(f)) à \(t.sunset.formatted(f)), sombre le reste du temps."
        }
    }
}

/// Sections « Accueil et données » + « À propos » (en bas des réglages).
struct ShellAboutSettings: View {
    @Environment(Prefs.self) private var prefs
    @Environment(Core.self) private var core
    @Environment(\.openURL) private var openURL
    @State private var confirmWipe = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShellSection(title: "Accueil et données") {
                ShellRow(label: "Revoir l’accueil", hint: "Les écrans du premier lancement.", action: replay) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .semibold))
                }
                ShellDivider()
                ShellRow(label: "Effacer toutes mes données", hint: "Réglages, pseudo, code ami, favoris et tout ce qu’OsaMaps garde sur cet iPhone. Irréversible.",
                         danger: true, action: { Haptic.play("warning"); confirmWipe = true }) {
                    Image(systemName: "trash").font(.system(size: 17, weight: .semibold))
                }
            }
            .confirmationDialog("Effacer toutes les données d’OsaMaps sur cet iPhone ?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Tout effacer", role: .destructive, action: wipe)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("OsaMaps repartira comme au premier lancement.")
            }

            ShellSection(title: "À propos") {
                HStack(spacing: 14) {
                    ShellMark(size: 52, animated: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OsaMaps").font(.osa(18, .bold)).foregroundStyle(Osa.text)
                        Text(version).font(.osa(13, .medium)).foregroundStyle(Osa.dim).monospacedDigit()
                    }
                    Spacer()
                }
                .padding(16)
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").font(.system(size: 11))
                    Text("Fait par Yanis, OsaLabs")
                }
                .font(.osa(13, .semibold)).foregroundStyle(Osa.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
                ShellDivider()
                ShellRow(label: "osalabs.fr", hint: "Toute la suite Osa", action: { openURL(URL(string: "https://osalabs.fr")!) }) {
                    Image(systemName: "arrow.up.right").font(.system(size: 15, weight: .semibold))
                }
                ShellDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Carte Apple Plans. Itinéraires Valhalla (serveur FOSSGIS) sur les données © les contributeurs OpenStreetMap.")
                    Text("Adresses IGN / Base Adresse Nationale · trafic et évènements Bison Futé · radars et données ouvertes data.gouv.fr.")
                }
                .font(.osa(12, .regular)).foregroundStyle(Osa.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func replay() {
        Haptic.play("light")
        core.settingsOpen = false
        // laisser la feuille se fermer avant que l'accueil n'apparaisse
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            prefs.onboarded = false
        }
    }

    private func wipe() {
        Haptic.play("error")
        let d = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        URLCache.shared.removeAllCachedResponses()
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let files = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        // remettre les préférences en mémoire à leurs valeurs par défaut (elles se réécrivent)
        prefs.avoidTolls = false; prefs.avoidHighways = false; prefs.avoidFerries = false
        prefs.mapStyle = "dark"; prefs.voice = true; prefs.speedTolerance = 5
        prefs.shareLocation = false; prefs.contributeTraffic = true
        prefs.vehicle = Vehicle(); prefs.vehicleChosen = false
        core.settingsOpen = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            prefs.onboarded = false
            Bus.shared.emit(.toast(Toast(id: "shell-wiped", text: "Données effacées. OsaMaps repart de zéro.", icon: "trash", tone: .good)))
        }
    }
}
