import SwiftUI

/// Le shell : la carte, puis des emplacements fixes où les modules se montent.
///   top     — recherche (mode exploration)
///   rail    — boutons ronds à droite (masqués pendant l'aperçu d'itinéraire)
///   sheet   — panneau du bas (empilé)
///   hud     — affichage de conduite (mode drive)
///   overlay — plein écran (accueil, toasts, modales)
///   settings — sections de l'écran Réglages (ouvert par core.settingsOpen)
///
/// Convention des panneaux du bas : si `core.panel` n'est pas nil, seul le module propriétaire
/// de ce panneau affiche quelque chose. Sinon : browse → search, preview → routing, drive → guidance.
struct RootView: View {
    @Environment(Core.self) private var core
    @Environment(Prefs.self) private var prefs
    @State private var started = false

    var body: some View {
        @Bindable var core = core
        ZStack {
            MapView().ignoresSafeArea()

            VStack(spacing: 8) {
                if core.mode == .browse { SlotView(slot: .top) }
                if core.mode == .drive { SlotView(slot: .hud) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    VStack(spacing: 10) { SlotView(slot: .rail) }
                        .opacity(core.mode == .preview ? 0 : 1)
                        .allowsHitTesting(core.mode != .preview)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                VStack(spacing: 8) { SlotView(slot: .sheet) }
                    .frame(maxWidth: 560)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { core.sheetHeight = $0 }
            }

            SlotView(slot: .overlay)
        }
        .animation(Osa.anim, value: core.mode)
        .sheet(isPresented: $core.settingsOpen) { SettingsScreen() }
        .task {
            guard !started else { return }
            started = true
            for f in Registry.features { f.start?() }
            Links.ready()
            // la position n'est demandée qu'après l'écran d'accueil qui l'explique (ou en simulation)
            if prefs.onboarded || Location.shared.simulated { Location.shared.start() }
        }
        .onOpenURL { Links.handle($0) }
        .onChange(of: prefs.onboarded) { _, done in if done { Location.shared.requestAndStart() } }
        .onChange(of: core.mode) { _, mode in Location.shared.setBackgroundNavigation(mode == .drive) }
    }
}

/// Écran Réglages : chaque module y ajoute sa section (slot "settings").
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { SlotView(slot: .settings) }
                    .padding(20)
            }
            .background(Osa.bg)
            .navigationTitle("Réglages")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } } }
        }
        .presentationBackground(Osa.bg)
    }
}
