import SwiftUI

/// Panneau du bas commun au module : verre sombre, poignée, glisser vers le bas pour fermer (ou replier),
/// vers le haut pour déplier. Entrée courte par le bas.
struct SearchCard<Content: View>: View {
    var onClose: (() -> Void)?
    /// true = vers le haut, false = vers le bas, nil = tap sur la poignée (basculer).
    var onExpand: ((Bool?) -> Void)?
    @ViewBuilder var content: () -> Content

    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            handle
            content()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .osaGlass()
        .offset(y: drag > 0 ? drag : drag * 0.25)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .gesture(dragGesture)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private var handle: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(Rectangle())
            .onTapGesture { onExpand?(nil) }
            .accessibilityElement()
            .accessibilityLabel(onExpand != nil ? "Déplier ou replier" : "Poignée")
            .accessibilityAddTraits(.isButton)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { v, s, _ in s = v.translation.height }
            .onEnded { v in
                let dy = v.translation.height
                let predicted = v.predictedEndTranslation.height
                if dy > 70 || predicted > 220 {
                    if let onExpand { onExpand(false) } else { onClose?() }
                } else if dy < -30 || predicted < -160 {
                    onExpand?(true)
                }
            }
    }
}

/// Pastille d'icône ronde (rangées, en-têtes).
struct SearchBadge: View {
    var symbol: String
    var size: CGFloat = 36
    var prominent = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Osa.text)
            .frame(width: size, height: size)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surfaceHi), in: Circle())
            .overlay(Circle().strokeBorder(prominent ? Color.clear : Osa.line))
    }
}

/// Une ligne de liste : icône, titre, sous-titre, distance, action de suppression facultative.
struct SearchRow: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var meta: String?
    var accent = false
    var number: Int?
    var onRemove: (() -> Void)?
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if let number {
                        Text("\(number)")
                            .font(.osa(14, .bold)).monospacedDigit()
                            .foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                            .background(Color.white, in: Circle())
                            .frame(width: 36)
                    } else {
                        SearchBadge(symbol: symbol, prominent: accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.osa(16, .semibold))
                            .foregroundStyle(Osa.text)
                            .lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.osa(13, .medium))
                                .foregroundStyle(Osa.dim)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let meta {
                        Text(meta)
                            .font(.osa(13, .semibold)).monospacedDigit()
                            .foregroundStyle(Osa.dim)
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(SearchRowPress())
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Osa.faint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retirer \(title) des récents")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Appui discret sur une ligne (fond blanc 5 %).
struct SearchRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
                    .padding(.horizontal, -8)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Titre de section (« Récents »).
struct SearchSection: View {
    var title: String
    var body: some View {
        Text(title.uppercased())
            .font(.osa(12, .bold))
            .tracking(0.6)
            .foregroundStyle(Osa.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12).padding(.bottom, 2)
    }
}

/// Message d'aide / d'état.
struct SearchHint: View {
    var text: String
    var warn = false
    var body: some View {
        Text(text)
            .font(.osa(14, .medium))
            .foregroundStyle(warn ? Osa.slow : Osa.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

/// Lignes « squelette » pendant le chargement.
struct SearchSkeleton: View {
    var rows = 3
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 12) {
                    Circle().fill(Osa.surfaceHi).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Osa.surfaceHi).frame(width: CGFloat(150 + (i * 37) % 70), height: 11)
                        Capsule().fill(Osa.surface).frame(width: CGFloat(100 + (i * 53) % 60), height: 9)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .opacity(on ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true }
        }
        .accessibilityLabel("Recherche en cours")
    }
}

/// Défilement qui prend la hauteur de son contenu, plafonnée (utile dans les panneaux du bas).
struct SearchFitScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
    }
}

/// Petite pilule d'information (direction, heure de stationnement, coordonnées).
struct SearchFact: View {
    var symbol: String
    var text: String
    var rotation: Double = 0
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .rotationEffect(.degrees(rotation))
            Text(text).font(.osa(13, .semibold)).lineLimit(1)
        }
        .foregroundStyle(Osa.dim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Osa.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Osa.line))
    }
}

/// Bouton-outil de la fiche (icône + libellé), cible ≥ 56 pt.
struct SearchToolLabel: View {
    var symbol: String
    var title: String
    var on = false
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)
            Text(title)
                .font(.osa(12, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? Color.black : Osa.text)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surface),
                    in: RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(on ? Color.clear : Osa.line))
        .contentShape(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
    }
}

struct SearchToolPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
