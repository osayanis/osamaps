import SwiftUI

/// Panneau « mascot-editor » : personnaliser sa mascotte (couleur, tête, lunettes, visage, cou, véhicule, nom).
/// Aperçu en direct qui sautille à chaque changement ; chaque vignette montre la mascotte actuelle avec l'option.
struct MascotEditor: View {
    @Environment(Core.self) private var core
    /// Onglet de départ (argument de test `-mascotTab hat`).
    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "mascotTab") ?? "") ?? .body
    @State private var hop = 0
    @State private var mood: MascotEngine.Mood = .calm
    @State private var arms: MascotEngine.Arms = .rest
    @State private var calmTask: Task<Void, Never>?
    @State private var name = MascotLookStore.shared.look.name
    @FocusState private var naming: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case body, hat, glasses, face, neck, ride
        var id: String { rawValue }
        var label: String {
            switch self {
            case .body: "Couleur"
            case .hat: "Tête"
            case .glasses: "Lunettes"
            case .face: "Visage"
            case .neck: "Cou"
            case .ride: "Véhicule"
            }
        }
        func symbol(_ v: Vehicle.Kind) -> String {
            switch self {
            case .body: "paintpalette.fill"
            case .hat: "crown.fill"
            case .glasses: "eyeglasses"
            case .face: "face.smiling.inverse"
            case .neck: "tshirt.fill"
            case .ride: v.symbol
            }
        }
    }

    private var store: MascotLookStore { MascotLookStore.shared }
    private var animated: Bool { MascotEngine.shared.settings.animations }
    private var vehicle: Vehicle.Kind { Prefs.shared.vehicle.kind }

    /// Le panneau partage la colonne avec le rail de boutons (au-dessus) : il ne garde que la hauteur restante.
    /// Grand écran : grand aperçu, titre posé dessus. Petit écran : aperçu à gauche, titre et nom à droite.
    private static var screenH: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 844
    }
    /// Argument de test `-mascotTall YES` : force la mise en page des grands écrans.
    private var compact: Bool { Self.screenH < 780 && !UserDefaults.standard.bool(forKey: "mascotTall") }
    /// Hauteur dispo pour le panneau (écran − rail − haut de l'écran).
    private var budget: CGFloat { Self.screenH - 290 }
    private var previewH: CGFloat { compact ? 112 : 150 }
    /// Ce qui reste pour les options (au moins une rangée, au plus deux) ; au-delà, ça défile.
    private var optionsH: CGFloat { max(96, min(206, budget - (compact ? 283 : 387))) }

    var body: some View {
        VStack(spacing: compact ? 10 : 12) {
            MascotGrabber()
            if compact {
                HStack(alignment: .center, spacing: 12) {
                    preview.frame(width: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Ma mascotte").font(.osa(20, .bold)).foregroundStyle(Osa.text)
                            Spacer(minLength: 0)
                            closeButton
                        }
                        nameField(width: nil)
                    }
                }
            } else {
                preview
                    .overlay(alignment: .topLeading) {
                        // la cabine de camion est large : le titre s'efface dans l'onglet Véhicule
                        VStack(alignment: .leading, spacing: 2) {
                            MascotEyebrow("Personnaliser")
                            Text("Ma mascotte").font(.osa(20, .bold)).foregroundStyle(Osa.text)
                        }
                        .opacity(tab == .ride && vehicle != .car ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: tab)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topTrailing) { closeButton.offset(x: 10, y: -6) }
                nameField(width: 230)
            }
            tabBar
            ScrollView {
                options.padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(height: optionsH)
            HStack(spacing: 10) {
                Button { shuffle() } label: {
                    Label("Au hasard", systemImage: "dice.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.osaPillSecondary)
                Button { naming = false; core.openPanel(nil) } label: { Text("Terminé").lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(.osaPill)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .mascotSheet()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personnaliser la mascotte")
        .onDisappear { calmTask?.cancel() }
    }

    // MARK: - En-tête et aperçu

    private var closeButton: some View {
        Button { naming = false; core.openPanel("profile") } label: {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Osa.dim)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fermer")
    }

    private var preview: some View {
        let look = store.shown
        let size = (previewH * 0.58).rounded()
        return ZStack(alignment: .bottom) {
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.11), .white.opacity(0)], center: .center, startRadius: 0, endRadius: size * 1.2))
                .frame(width: size * 2.4, height: size * 0.6)
                .offset(y: size * 0.12)
            MascotFigure(mood: mood, arms: arms, size: size, hop: hop, kart: tab == .ride,
                         style: look, vehicle: vehicle, animated: animated)
                .padding(.bottom, size * 0.07)
        }
        .frame(maxWidth: .infinity)
        .frame(height: previewH, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { cheer(.happy, .wave, seconds: 1.4); Haptic.play("light") }
        .accessibilityElement()
        .accessibilityLabel("Aperçu de \(look.displayName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Touche pour lui faire coucou")
    }

    private func nameField(width: CGFloat?) -> some View {
        HStack(spacing: 8) {
            TextField("Son nom", text: $name)
                .font(.osa(18, .bold))
                .foregroundStyle(Osa.text)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($naming)
                .onSubmit { naming = false }
            Image(systemName: "pencil").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.faint)
                .accessibilityHidden(true)
        }
        .padding(.leading, 30).padding(.trailing, 14)
        .frame(width: width, height: 44)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(Osa.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(naming ? Osa.lineHi : Osa.line))
        .onTapGesture { naming = true }
        .onChange(of: name) { _, v in
            if v.count > MascotLook.maxName { name = String(v.prefix(MascotLook.maxName)); return }
            store.update { $0.name = v }
        }
        .accessibilityLabel("Nom de la mascotte")
    }

    // MARK: - Catégories

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                let on = tab == t
                Button {
                    naming = false
                    let hopNow = (tab == .ride) != (t == .ride)
                    withAnimation(.easeOut(duration: 0.2)) { tab = t }
                    if hopNow { hop += 1 }
                    Haptic.play("light")
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol(vehicle)).font(.system(size: 15, weight: .semibold)).frame(height: 18)
                        Text(t.label).font(.osa(11, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.black : Osa.dim)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(on ? AnyShapeStyle(Osa.text) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(MascotPressStyle())
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Osa.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Osa.line))
    }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    @ViewBuilder private var options: some View {
        let l = store.look
        switch tab {
        case .body:
            tiles(MascotLook.Body.allCases, selected: l.body, label: \.label) { v in var x = l; x.body = v; return x } set: { v in store.update { $0.body = v } }
        case .hat:
            tiles(MascotLook.Hat.allCases, selected: l.hat, label: \.label, locked: { store.isUnlocked($0) ? nil : $0.level }) { v in var x = l; x.hat = v; return x } set: { v in store.update { $0.hat = v } }
        case .glasses:
            tiles(MascotLook.Glasses.allCases, selected: l.glasses, label: \.label) { v in var x = l; x.glasses = v; return x } set: { v in store.update { $0.glasses = v } }
        case .face:
            tiles(MascotLook.Face.allCases, selected: l.face, label: \.label) { v in var x = l; x.face = v; return x } set: { v in store.update { $0.face = v } }
        case .neck:
            tiles(MascotLook.Neck.allCases, selected: l.neck, label: \.label) { v in var x = l; x.neck = v; return x } set: { v in store.update { $0.neck = v } }
        case .ride:
            rides(l.ride)
        }
    }

    /// Une grille de vignettes : la mascotte actuelle essayant chaque option.
    private func tiles<T: Hashable>(_ all: [T], selected: T, label: KeyPath<T, String>, locked: @escaping (T) -> Int? = { _ in nil },
                                    preview: @escaping (T) -> MascotLook, set: @escaping (T) -> Void) -> some View {
        LazyVGrid(columns: grid, spacing: 8) {
            ForEach(all, id: \.self) { v in
                let on = v == selected
                let need = locked(v)
                Button {
                    guard need == nil else { Haptic.play("warning"); return }
                    if !on { set(v); cheer(tab == .face ? .calm : .happy, .rest, seconds: 0.9); Haptic.play("light") }
                } label: {
                    VStack(spacing: 4) {
                        MascotFigure(size: 52, style: preview(v), blinks: false, head: true, animated: false)
                            .opacity(need == nil ? 1 : 0.4).grayscale(need == nil ? 0 : 1)
                            .overlay(alignment: .topTrailing) {
                                if need != nil {
                                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Osa.text)
                                        .frame(width: 20, height: 20).background(Osa.surfaceHi, in: Circle())
                                }
                            }
                        Text(need.map { "Niveau \($0)" } ?? v[keyPath: label])
                            .font(.osa(12, on ? .bold : .semibold)).foregroundStyle(on ? Osa.text : Osa.dim)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8).padding(.bottom, 8)
                    .background(on ? Osa.surfaceHi : Osa.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Osa.text : Osa.line, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(MascotPressStyle())
                .accessibilityLabel(v[keyPath: label])
                .accessibilityValue(need.map { "à débloquer au niveau \($0)" } ?? (on ? "choisi" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .transition(.opacity)
        .id(tab)
    }

    private func rides(_ selected: MascotLook.Ride) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: vehicle.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Osa.text)
                    .frame(width: 34, height: 34).background(Osa.surfaceHi, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    (Text(selected.label).foregroundColor(Osa.text)
                     + Text(vehicle == .car ? " · sa petite voiture" : " · ton \(vehicle.label.lowercased())").foregroundColor(Osa.dim))
                        .font(.osa(15, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("Le type de véhicule se change dans les Réglages.").font(.osa(12, .medium)).foregroundStyle(Osa.faint)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                ForEach(MascotLook.Ride.allCases, id: \.self) { r in
                    let on = r == selected
                    Button {
                        if !on { store.update { $0.ride = r }; cheer(.happy, .rest, seconds: 0.9); Haptic.play("light") }
                    } label: {
                        Circle().fill(r.color)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center)))
                            .overlay(Circle().strokeBorder(.white.opacity(r.isLight ? 0 : 0.16)))
                            .frame(width: 32, height: 32)
                            .padding(4)
                            .overlay(Circle().strokeBorder(on ? Osa.text : .clear, lineWidth: 2))
                            .scaleEffect(on ? 1 : 0.9)
                            .animation(.easeOut(duration: 0.18), value: on)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MascotPressStyle())
                    .accessibilityLabel(r.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
            .background(Osa.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Osa.line))
        }
        .transition(.opacity)
    }

    // MARK: - Réactions

    /// Petite réaction de l'aperçu (un saut, une émotion qui retombe).
    private func cheer(_ m: MascotEngine.Mood, _ a: MascotEngine.Arms, seconds: Double) {
        hop += 1
        mood = m
        arms = a
        calmTask?.cancel()
        calmTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            mood = .calm
            arms = .rest
        }
    }

    private func shuffle() {
        naming = false
        store.randomize()
        cheer(.excited, .up, seconds: 1.1)
        Haptic.play("medium")
    }
}
