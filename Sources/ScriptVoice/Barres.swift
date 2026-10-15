import AVFoundation
import SwiftUI

private let vert = Color(red: 0.41, green: 0.81, blue: 0.59)
private let rouge = Color(red: 0.90, green: 0.29, blue: 0.22)

// MARK: - La barre du haut

struct BarreHaut: View {
    @ObservedObject var projet: Projet
    @ObservedObject var enregistreur: Enregistreur
    @ObservedObject var lecteur: Lecteur
    @ObservedObject var prompteur: Prompteur
    @Binding var micros: [Peripherique]
    @Binding var outil: Outil
    @Binding var reglagesOuverts: Bool
    let basculerEnregistrement: () -> Void
    let basculerLecture: () -> Void
    let exporter: () -> Void

    var body: some View {
        // Trois blocs : la prise et le montage a gauche, le temps au milieu de
        // la barre, les reglages puis l'export au bout.
        RangeeCentree {
            // Quand la place manque (PDF large, vitesse du prompteur affichee
            // pendant la prise), la barre se resserre au lieu de deborder : le
            // choix du micro part d'abord, puis le gain, puis les outils de
            // montage, puis le vumetre raccourcit. Le bouton d'enregistrement,
            // lui, ne disparait jamais, et le vumetre en tout dernier.
            ViewThatFits(in: .horizontal) {
                gauche(choixDuMicro: true, gain: true)
                gauche(choixDuMicro: false, gain: true)
                gauche(choixDuMicro: false, gain: false)
                HStack(spacing: 12) { boutonEnregistrer; vumetre; transport }.fixedSize()
                HStack(spacing: 12) { boutonEnregistrer; vumetre(segments: 10); transport }.fixedSize()
                HStack(spacing: 12) { boutonEnregistrer; transport }.fixedSize()
            }
            horloge
            HStack(spacing: 14) {
                if prompteur.actif { vitesse }
                bouton("slider.horizontal.3", "Réglages") { reglagesOuverts = true }
                bouton("square.and.arrow.up", "Exporter", exporter)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.13))
    }

    private func gauche(choixDuMicro: Bool, gain: Bool) -> some View {
        HStack(spacing: 12) {
            boutonEnregistrer
            vumetre
            if choixDuMicro || gain { micro(choix: choixDuMicro) }
            Divider().frame(height: 22).overlay(Color(white: 0.25))
            transport
            Divider().frame(height: 22).overlay(Color(white: 0.25))
            outils
        }
        .fixedSize()
    }

    // Le bouton d'enregistrement : un disque, comme sur un magnetophone.
    private var boutonEnregistrer: some View {
        Button(action: basculerEnregistrement) {
            ZStack {
                Circle().strokeBorder(Color(white: 0.45), lineWidth: 1.5).frame(width: 30, height: 30)
                if enregistreur.enCours {
                    RoundedRectangle(cornerRadius: 2).fill(rouge).frame(width: 11, height: 11)
                } else {
                    Circle().fill(rouge).frame(width: 17, height: 17)
                }
            }
        }
        .buttonStyle(.plain)
        .help(enregistreur.enCours ? "Arrêter (Échap)" : "Enregistrer")
    }

    /// Vumetre a segments : on voit d'un coup d'oeil si on sature.
    private var vumetre: some View { vumetre(segments: 19) }

    /// Vumetre a segments. En version courte, moins de segments, meme echelle.
    private func vumetre(segments: Int) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                let seuil = Float(i) / Float(segments)
                let allume = enregistreur.niveau > seuil
                Rectangle()
                    .fill(allume ? (seuil > 0.88 ? rouge : (seuil > 0.72 ? Color.orange : vert))
                                 : Color(white: 0.22))
                    .frame(width: 4, height: seuil > 0.88 ? 15 : 11)
            }
        }
        .frame(width: CGFloat(segments) * 5.5 + 5, alignment: .leading)
        .animation(.linear(duration: 0.05), value: enregistreur.niveau)
    }

    private func micro(choix: Bool) -> some View {
        HStack(spacing: 7) {
            if choix { choixMicro }
            Image(systemName: "mic")
                .font(.system(size: 10)).foregroundColor(Color(white: 0.5))
            Slider(value: Binding(get: { projet.reglages.gainEntree },
                                  set: { projet.reglages.gainEntree = $0
                                         enregistreur.gain = Float($0) }),
                   in: 0.2...4)
                .frame(width: 72)
                .help("Gain d'entrée")
        }
    }

    private var choixMicro: some View {
            Picker("", selection: Binding(
                get: { projet.reglages.peripheriqueID },
                set: { uid in
                    projet.reglages.peripheriqueID = uid
                    enregistreur.choisir(Micros.parUID(uid))
                    projet.modifie = true
                })) {
                ForEach(micros) { m in Text(m.nom).tag(m.uid) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(enregistreur.enCours)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            bouton("backward.end", "Début") { lecteur.tete = 0 }
            Button(action: basculerLecture) {
                Image(systemName: lecteur.enLecture ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.88))
            }.buttonStyle(.plain).help("Lecture (espace)")
        }
    }

    private var outils: some View {
        HStack(spacing: 3) {
            ForEach(Outil.allCases, id: \.self) { o in
                Button { outil = o } label: {
                    Image(systemName: o.symbole)
                        .font(.system(size: 11))
                        .frame(width: 25, height: 21)
                        .background(outil == o ? Color(white: 0.27) : Color.clear)
                        .foregroundColor(outil == o ? vert : Color(white: 0.62))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .help("\(o.libelle) (\(o.touche))")
            }
        }
    }

    private var vitesse: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.aligncenter").font(.system(size: 10)).foregroundColor(vert)
            Slider(value: Binding(get: { prompteur.vitesse },
                                  set: { prompteur.vitesse = $0; projet.reglages.vitessePrompteur = $0 }),
                   in: 70...260)
                .frame(width: 80)
            Text("\(Int(prompteur.vitesse)) m/min")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
        }
    }

    private var horloge: some View {
        Text(enregistreur.enCours ? Horloge.precis(enregistreur.duree) : Horloge.precis(lecteur.tete))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(enregistreur.enCours ? rouge : Color(white: 0.8))
            .fixedSize()
    }

    private func bouton(_ symbole: String, _ aide: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbole).font(.system(size: 12)).foregroundColor(Color(white: 0.7))
        }
        .buttonStyle(.plain).help(aide)
    }
}

/// Trois blocs sur une ligne : le premier cale a gauche, le dernier a droite,
/// celui du milieu au centre de la barre. Quand la place manque, le milieu se
/// centre entre ses voisins plutot que de les chevaucher.
struct RangeeCentree: Layout {
    var ecart: CGFloat = 16

    /// Le bloc de gauche recoit la place laissee par les deux autres : s'il ne
    /// tient pas, il choisit une forme plus courte (ViewThatFits). La rangee ne
    /// deborde jamais de la largeur qu'on lui donne.
    private func tailles(_ largeur: CGFloat?, _ subviews: Subviews) -> [CGSize] {
        guard subviews.count == 3 else { return subviews.map { $0.sizeThatFits(.unspecified) } }
        let milieu = subviews[1].sizeThatFits(.unspecified), droite = subviews[2].sizeThatFits(.unspecified)
        let reste = largeur.map { max(0, $0 - milieu.width - droite.width - 2 * ecart) }
        let gauche = subviews[0].sizeThatFits(ProposedViewSize(width: reste, height: nil))
        return [gauche, milieu, droite]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let t = tailles(proposal.width, subviews)
        let minimum = t.reduce(0) { $0 + $1.width } + ecart * CGFloat(max(0, t.count - 1))
        return CGSize(width: proposal.width ?? minimum, height: t.map(\.height).max() ?? 0)
    }

    func placeSubviews(in cadre: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let t = tailles(cadre.width, subviews)
        let milieu = cadre.midY
        subviews[0].place(at: CGPoint(x: cadre.minX, y: milieu), anchor: .leading,
                          proposal: ProposedViewSize(width: t[0].width, height: nil))
        subviews[2].place(at: CGPoint(x: cadre.maxX, y: milieu), anchor: .trailing, proposal: .unspecified)
        let auPlusTot = cadre.minX + t[0].width + ecart
        let auPlusTard = cadre.maxX - t[2].width - ecart - t[1].width
        // Au centre de la barre si la place le permet, sinon au centre de
        // l'espace libre : colle aux outils, il avait l'air d'en faire partie.
        let centre = cadre.midX - t[1].width / 2
        let x = (auPlusTot...max(auPlusTot, auPlusTard)).contains(centre)
            ? centre : max(auPlusTot, (auPlusTot + auPlusTard) / 2)
        subviews[1].place(at: CGPoint(x: x, y: milieu), anchor: .leading, proposal: .unspecified)
    }
}

// MARK: - La bande des pistes

struct BarrePistes: View {
    @ObservedObject var projet: Projet
    @Binding var pisteActive: Int
    @ObservedObject var montage: Montage

    var body: some View {
        HStack(spacing: 9) {
            // Autant de pistes qu'on veut : la rangee defile de cote plutot que
            // de pousser le zoom hors de la barre.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(Array(projet.pistes.enumerated()), id: \.element.id) { i, piste in
                        HStack(spacing: 5) {
                            Circle().fill(pisteActive == i ? Color(red: 0.90, green: 0.29, blue: 0.22) : Color(white: 0.3))
                                .frame(width: 6, height: 6)
                                .help("Piste d'enregistrement")
                            Text(piste.nom).font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: pisteActive == i ? 0.92 : 0.62))
                            bascule("speaker.slash", actif: piste.muette) {
                                projet.retenir(piste.muette ? "Rétablir le son" : "Couper le son")
                                projet.pistes[i].muette.toggle(); projet.modifie = true
                            }
                            bascule("headphones", actif: piste.solo) {
                                projet.retenir("Solo")
                                projet.pistes[i].solo.toggle(); projet.modifie = true
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(pisteActive == i ? Color(white: 0.2) : Color(white: 0.145))
                        .cornerRadius(4)
                        .onTapGesture { pisteActive = i }
                    }

                    Button {
                        projet.retenir("Ajouter une piste")
                        projet.pistes.append(Piste(nom: Edition.nomDePiste(projet.pistes)))
                        pisteActive = projet.pistes.count - 1
                        projet.modifie = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10)).foregroundColor(Color(white: 0.6))
                    }.buttonStyle(.plain).help("Ajouter une piste")

                    if projet.pistes.count > 1 {
                        Button {
                            projet.retenir("Supprimer la piste")
                            projet.pistes.remove(at: pisteActive)
                            pisteActive = max(0, pisteActive - 1)
                            projet.modifie = true
                        } label: {
                            Image(systemName: "minus").font(.system(size: 10)).foregroundColor(Color(white: 0.6))
                        }.buttonStyle(.plain).help("Supprimer la piste active")
                    }
                }
            }

            if !montage.selection.isEmpty {
                Button { montage.supprimer(refermer: true) } label: {
                    Label(montage.selection.count > 1 ? "Supprimer les \(montage.selection.count) clips"
                                                      : "Supprimer le clip", systemImage: "trash")
                        .font(.system(size: 11)).foregroundColor(Color(white: 0.7))
                }.buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(Color(white: 0.5))
                Slider(value: $projet.reglages.zoomTimeline, in: 2...320).frame(width: 110)
            }
            Toggle("Aimant", isOn: $projet.reglages.aimantation)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .foregroundColor(Color(white: 0.65))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(white: 0.145))
    }

    private func bascule(_ symbole: String, actif: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbole)
                .font(.system(size: 9))
                .foregroundColor(actif ? Color(red: 1, green: 0.74, blue: 0.25) : Color(white: 0.38))
        }.buttonStyle(.plain)
    }
}

// MARK: - Les reglages

struct VueReglages: View {
    @ObservedObject var projet: Projet
    @Environment(\.dismiss) private var fermer

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Réglages").font(.system(size: 17, weight: .semibold))

            groupe("Éditeur") {
                curseur("Taille du texte", $projet.reglages.policeEditeur, 12...32, "%.0f pt")
                curseur("Interligne", $projet.reglages.interligneEditeur, 1.0...2.4, "%.1f")
            }
            groupe("Prompteur") {
                curseur("Vitesse de lecture", $projet.reglages.vitessePrompteur, 70...260, "%.0f mots/min")
                Text("Pendant l'enregistrement : espace met en pause, les flèches haut et bas rattrapent.")
                    .font(.system(size: 11)).foregroundColor(Color(white: 0.55))
            }
            groupe("Voix") {
                Toggle("Traitement vocal", isOn: $projet.reglages.voixJenaate)
                    .font(.system(size: 12))
                Text("Sur chaque prise : compresseur, de-esser, égaliseur, puis -6 dB. Le volume de chaque clip se règle ensuite sur sa ligne, dans la timeline.")
                    .font(.system(size: 11)).foregroundColor(Color(white: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            groupe("Export") {
                Picker("Format", selection: $projet.reglages.formatExport) {
                    Text("WAV 24 bits").tag("wav")
                    Text("MP3 192 kbit/s").tag("mp3")
                    Text("M4A 256 kbit/s").tag("m4a")
                }.pickerStyle(.radioGroup)
            }

            HStack {
                Spacer()
                Button("Fermer") { projet.modifie = true; fermer() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        // fond plein et apparence sombre explicites, comme la feuille de reprise :
        // sans eux, cases, boutons radio et bouton Fermer se dessinaient en
        // blanc, sans coche ni libelle
        .background(Color(white: 0.13))
        .preferredColorScheme(.dark)
    }

    private func groupe<C: View>(_ titre: String, @ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(titre.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(1.4)
                .foregroundColor(Color(red: 0.41, green: 0.81, blue: 0.59))
            contenu()
        }
    }

    private func curseur(_ titre: String, _ valeur: Binding<Double>,
                         _ plage: ClosedRange<Double>, _ format: String) -> some View {
        HStack {
            Text(titre).font(.system(size: 12)).frame(width: 140, alignment: .leading)
            Slider(value: valeur, in: plage)
            Text(String(format: format, valeur.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.6)).frame(width: 92, alignment: .trailing)
        }
    }
}

// MARK: - Les commandes de fichier, appelees depuis le menu

@MainActor
enum Fichier {
    static func nouveau(_ projet: Projet) {
        projet.enregistrerSiPossible()
        projet.script = ""
        projet.scriptFormat = []
        projet.pistes = [Piste(nom: "Voix 1")]
        projet.pdf = ""
        projet.dossier = nil
        Projet.oublierHistorique()
    }

    static func ouvrir(_ projet: Projet) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Ouvrir le projet"
        guard p.runModal() == .OK, let url = p.url,
              let charge = try? Projet.ouvrir(url) else { return }
        projet.enregistrerSiPossible()
        projet.reprendre(charge)
        Projet.oublierHistorique()
    }

    /// Importer un PDF remplace celui qui est ouvert.
    static func importerPDF(_ projet: Projet) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.prompt = "Importer"
        guard p.runModal() == .OK, let url = p.url else { return }
        projet.pdf = url.path
        projet.modifie = true
        Journal.ecrire("pdf importe : \(url.lastPathComponent)")
    }

    static func fermerPDF(_ projet: Projet) {
        guard !projet.pdf.isEmpty else { return }
        projet.pdf = ""
        projet.modifie = true
    }

    static func enregistrer(_ projet: Projet) {
        if projet.dossier == nil { enregistrerSous(projet) } else { try? projet.enregistrer() }
    }

    static func enregistrerSous(_ projet: Projet) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Projet.scriptvoice"
        p.prompt = "Enregistrer"
        guard p.runModal() == .OK, let url = p.url else { return }
        try? projet.enregistrer(dans: url)
    }
}
