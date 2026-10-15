import Accelerate
import AVFoundation
import SwiftUI

/// Le cache des formes d'onde. Sans elles on coupe a l'aveugle, et une voix off
/// se coupe au silence, pas au hasard.
///
/// L'onde est relevee sur la prise traitee : c'est elle qu'on entend, et c'est
/// elle qui dit si la voix est assez forte. Le meme passage remplit le cache des
/// prises traitees, si bien que la premiere lecture part sans attendre.
@MainActor
final class Ondes: ObservableObject {
    @Published private(set) var pics: [String: [Float]] = [:]
    private var enCours: Set<String> = []

    func pics(pour fichier: String, dans dossier: URL?, traitement: Bool) -> [Float]? {
        let cle = "\(fichier)|\(traitement)"
        if let p = pics[cle] { return p }
        guard let dossier, !enCours.contains(cle) else { return nil }
        enCours.insert(cle)
        let url = dossier.appendingPathComponent(fichier)
        Task.detached(priority: .utility) {
            let p = Ondes.analyser(url, traitement: traitement)
            await MainActor.run { self.pics[cle] = p; self.enCours.remove(cle) }
        }
        return nil
    }

    /// Un pic pour chaque tranche de 20 ms : assez fin pour viser une respiration.
    nonisolated static func analyser(_ url: URL, traitement: Bool) -> [Float] {
        guard let t = PrisesTraitees.partage.tampon(url, traitement: traitement),
              let c = t.floatChannelData else { return [] }
        let parTranche = Int(t.format.sampleRate * 0.02)
        let n = Int(t.frameLength)
        guard parTranche > 0 else { return [] }
        let base = traitement ? Voix.gain(volume: 0, traitement: true) : 1
        var sortie: [Float] = []
        sortie.reserveCapacity(n / parTranche + 1)
        var i = 0
        while i < n {
            var m: Float = 0
            vDSP_maxmgv(c[0] + i, 1, &m, vDSP_Length(min(parTranche, n - i)))
            sortie.append(m * base)
            i += parTranche
        }
        return sortie
    }
}

// MARK: - La vue

/// Ce que la souris touche dans la timeline.
private enum Zone: Equatable {
    case regle, vide, corps, bordDebut, bordFin, volume, fonduEntree, fonduSortie
}

private struct Touche {
    var zone: Zone
    var piste: Int?
    var clip: Clip?
}

/// Le geste en cours, du clic au lacher.
private enum Geste {
    case deplacer(ids: Set<UUID>, saisi: UUID, t: Double, mods: NSEvent.ModifierFlags, bouge: Bool)
    case elaguer(id: UUID, piste: Int, bord: Edition.Bord, origine: Piste, ripple: Bool, retenu: Bool)
    case volume(id: UUID, piste: Int, depart: Double, retenu: Bool)
    case fondu(id: UUID, piste: Int, entree: Bool, depart: Double, retenu: Bool)
    case cadre(depart: CGPoint, base: Set<UUID>)
    case tete
    case main(ancre: CGFloat)
    case rien
}

private struct Apercu: Equatable {
    var dt: Double
    var dp: Int
    var copie: Bool
}

private struct Survol: Equatable {
    var id: UUID
    var zone: Zone
    var x: CGFloat
}

/// La timeline.
///
/// Toute la souris passe par un seul geste, pose sur le montage entier et mesure
/// dans son repere, qui ne bouge jamais. Un geste pose sur le clip lui-meme se
/// mesurait dans un repere qui se deplacait avec lui : le clip tire tremblait et
/// sautait, surtout sans aimantation pour le retenir. Ici, chaque clic est
/// rapporte au clip qu'il touche par le calcul, a partir du modele.
///
/// Un deplacement ne touche au modele qu'au lacher : pendant le geste, on
/// dessine un apercu, et la fenetre ne se recalcule pas a chaque pixel.
struct VueTimeline: View {
    @ObservedObject var projet: Projet
    @ObservedObject var lecteur: Lecteur
    @ObservedObject var ondes: Ondes
    @ObservedObject var enregistreur: Enregistreur
    @ObservedObject var montage: Montage
    @Binding var outil: Outil

    @State private var geste: Geste?
    @State private var apercu: Apercu?
    @State private var cadre: CGRect?
    @State private var survol: Survol?
    @State private var pointeur: CGFloat = 0
    @State private var defilement: NSScrollView?
    @State private var zoomDepart: Double?
    /// de combien les pistes ont defile vers le bas : la regle reste en haut
    @State private var yDefile: CGFloat = 0
    /// largeur a l'ecran : le montage ne fait jamais moins
    @State private var largeurVisible: CGFloat = 0

    static let hauteurPiste: CGFloat = 96
    static let hauteurRegle: CGFloat = 26
    private let marge: CGFloat = 4
    private var pas: CGFloat { Self.hauteurPiste + 1 }
    private var hClip: CGFloat { Self.hauteurPiste - 2 * marge }

    var echelle: CGFloat { CGFloat(projet.reglages.zoomTimeline) }
    var largeur: CGFloat {
        let fin = max(projet.duree, enregistreur.enCours
                      ? enregistreur.debutTimeline + enregistreur.duree : 0)
        return max(1200, largeurVisible, CGFloat(fin + 20) * echelle)
    }

    /// Hauteur reelle du montage : la timeline ne s'etire pas pour remplir,
    /// elle garde sa taille et se cale en haut, comme un banc de montage.
    private var hauteurContenu: CGFloat {
        Self.hauteurRegle + CGFloat(projet.pistes.count) * pas + Self.bandeDefilement
    }
    /// une bande vide sous les pistes, pour la barre de defilement : sans elle,
    /// la barre recouvrait le bas des clips de la derniere piste
    static let bandeDefilement: CGFloat = 14

    var body: some View {
        // Les pistes defilent dans les deux sens. Le montage remplit au moins
        // la hauteur visible, pour que le vide sous les pistes recoive les clics.
        GeometryReader { cadreVisible in
            ScrollView([.horizontal, .vertical]) {
                contenu
                    // au moins la taille visible : plus petit, le montage se
                    // centrait dans la fenetre au lieu de partir du bord gauche
                    .frame(width: largeur,
                           height: max(hauteurContenu, cadreVisible.size.height),
                           alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged(glisser)
                        .onEnded(lacher))
                    .onContinuousHover(coordinateSpace: .local, perform: survoler)
                    .background(AccesDefilement { defilement = $0 })
                    .background(ClicDroit { p, e, vue in menu(en: p, evenement: e, vue: vue) })
            }
            .onAppear { largeurVisible = cadreVisible.size.width }
            .onChange(of: cadreVisible.size.width) { _, l in largeurVisible = l }
            // pincer le trackpad zoome
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if zoomDepart == nil { zoomDepart = projet.reglages.zoomTimeline }
                    projet.reglages.zoomTimeline = Self.borner(zoom: (zoomDepart ?? 60) * v.magnification)
                }
                .onEnded { _ in zoomDepart = nil })
        }
        .background(Color(white: 0.10))
        .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { n in
            guard let d = defilement, (n.object as? NSView) === d.contentView, let doc = d.documentView else { return }
            let v = d.documentVisibleRect
            let y = max(0, doc.isFlipped ? v.minY : doc.bounds.height - v.maxY)
            if abs(y - yDefile) > 0.5 { yDefile = y }
        }
        .onChange(of: defilement) { _, d in d?.contentView.postsBoundsChangedNotifications = true }
        .onAppear {
            montage.zoomer = { zoomer($0) }
            // --essai-defile 150 : les pistes descendent, pour la capture
            if let i = CommandLine.arguments.firstIndex(of: "--essai-defile"), i + 1 < CommandLine.arguments.count,
               let y = Double(CommandLine.arguments[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let d = defilement, let doc = d.documentView else { return }
                    let haut = doc.isFlipped ? CGFloat(y) : doc.bounds.height - d.documentVisibleRect.height - CGFloat(y)
                    d.contentView.scroll(to: NSPoint(x: d.documentVisibleRect.minX, y: haut))
                    d.reflectScrolledClipView(d.contentView)
                }
            }
        }
        .onChange(of: lecteur.tete) { _, t in suivreTete(t) }
    }

    // MARK: Dessin

    private var contenu: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.10)
            ForEach(Array(projet.pistes.enumerated()), id: \.element.id) { rang, piste in
                Rectangle()
                    .fill(Color(white: piste.muette ? 0.11 : 0.125))
                    .frame(width: largeur, height: Self.hauteurPiste)
                    .offset(y: haut(rang))
                Rectangle()
                    .fill(Color(white: 0.18))
                    .frame(width: largeur, height: 1)
                    .offset(y: haut(rang) + Self.hauteurPiste)
            }
            ForEach(clipsAffiches, id: \.cle) { a in vueClip(a) }
            // La prise en cours s'allonge sous la tete pendant qu'on parle : on
            // voit ce qu'on enregistre au lieu d'attendre la fin pour le decouvrir.
            if enregistreur.enCours, projet.pistes.indices.contains(enregistreur.pisteTimeline) {
                VuePriseEnCours(duree: enregistreur.duree, onde: enregistreur.onde,
                                echelle: echelle, hauteur: Self.hauteurPiste)
                    .offset(x: CGFloat(enregistreur.debutTimeline) * echelle,
                            y: haut(enregistreur.pisteTimeline))
            }
            if let cadre {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .overlay(Rectangle().stroke(Color(white: 0.85), lineWidth: 1))
                    .frame(width: cadre.width, height: cadre.height)
                    .offset(x: cadre.minX, y: cadre.minY)
            }
            tete
            // la regle reste en haut quand les pistes defilent, avec le
            // sommet de la tete, qu'on y saisit
            regle
                .background(Color(white: 0.10))
                .offset(y: yDefile)
            sommetTete
                .offset(x: CGFloat(positionTete) * echelle - 5.5, y: yDefile)
        }
    }

    private func haut(_ rang: Int) -> CGFloat { Self.hauteurRegle + CGFloat(rang) * pas }

    private struct Affiche {
        let cle: String
        let clip: Clip
        let piste: Int
    }

    /// Les clips tels qu'a l'ecran : pendant un deplacement, ceux qu'on tire
    /// sont dessines a leur place d'arrivee, par-dessus les autres.
    private var clipsAffiches: [Affiche] {
        var fixes: [Affiche] = [], tires: [Affiche] = []
        var ids: Set<UUID> = []
        if let apercu, case .deplacer(let i, _, _, _, true) = geste { ids = i; _ = apercu }
        for (rang, p) in projet.pistes.enumerated() {
            for c in p.clips {
                guard ids.contains(c.id), let a = apercu else {
                    fixes.append(Affiche(cle: c.id.uuidString, clip: c, piste: rang)); continue
                }
                var m = c
                m.debut = max(0, c.debut + a.dt)
                if a.copie {
                    fixes.append(Affiche(cle: c.id.uuidString, clip: c, piste: rang))
                    tires.append(Affiche(cle: "copie-" + c.id.uuidString, clip: m, piste: rang + a.dp))
                } else {
                    tires.append(Affiche(cle: c.id.uuidString, clip: m, piste: rang + a.dp))
                }
            }
        }
        return fixes + tires
    }

    private func vueClip(_ a: Affiche) -> some View {
        let c = a.clip
        let s = survol?.id == c.id ? survol : nil
        var enVolume = false
        if case .volume(let id, _, _, _) = geste, id == c.id { enVolume = true }
        let essai = VueClip.essaiVolume && montage.selection.contains(c.id)
        return VueClip(clip: c, choisi: montage.selection.contains(c.id), echelle: echelle,
                       hauteur: hClip,
                       pics: ondes.pics(pour: c.fichier, dans: projet.dossierPrises,
                                        traitement: projet.reglages.voixJenaate && c.voix),
                       ligne: outil == .selection,
                       ligneActive: enVolume || s?.zone == .volume || essai,
                       xEtiquette: enVolume ? pointeur - CGFloat(c.debut) * echelle : (s?.x ?? 140),
                       poignees: outil == .selection && (s != nil || montage.selection.contains(c.id)))
            .offset(x: CGFloat(c.debut) * echelle, y: haut(a.piste) + marge)
    }

    // La regle en secondes, graduee comme celle d'un banc de montage.
    private var regle: some View {
        Canvas { ctx, taille in
            let pas: Double = echelle > 90 ? 1 : (echelle > 35 ? 5 : (echelle > 8 ? 10 : 30))
            var t: Double = 0
            while CGFloat(t) * echelle < taille.width {
                let x = CGFloat(t) * echelle
                ctx.stroke(Path { $0.move(to: .init(x: x, y: 14)); $0.addLine(to: .init(x: x, y: 26)) },
                           with: .color(Color(white: 0.42)), lineWidth: 1)
                ctx.draw(Text(Horloge.texte(t)).font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(white: 0.55)),
                         at: .init(x: x + 4, y: 8), anchor: .leading)
                t += pas
            }
        }
        .frame(width: largeur, height: Self.hauteurRegle)
    }

    /// Pendant une prise, la tete suit le bout de ce qui s'ecrit.
    private var positionTete: Double {
        enregistreur.enCours ? enregistreur.debutTimeline + enregistreur.duree : lecteur.tete
    }

    private static let rouge = Color(red: 0.95, green: 0.33, blue: 0.24)

    private var tete: some View {
        Rectangle().fill(Self.rouge)
            .frame(width: 1.5, height: hauteurContenu - Self.bandeDefilement)
            .offset(x: CGFloat(positionTete) * echelle - 0.75)
    }

    /// La tete se saisit dans la regle : un repere a son sommet.
    private var sommetTete: some View {
        Path { p in
            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 11, y: 0))
            p.addLine(to: .init(x: 11, y: 7)); p.addLine(to: .init(x: 5.5, y: 12))
            p.addLine(to: .init(x: 0, y: 7)); p.closeSubpath()
        }
        .fill(Self.rouge)
        .frame(width: 11, height: 12)
    }

    // MARK: Ce que touche la souris

    private func rectClip(_ c: Clip, _ rang: Int) -> CGRect {
        CGRect(x: CGFloat(c.debut) * echelle, y: haut(rang) + marge,
               width: max(2, CGFloat(c.duree) * echelle), height: hClip)
    }

    private func toucher(_ p: CGPoint) -> Touche {
        if p.y < yDefile + Self.hauteurRegle { return Touche(zone: .regle) }
        let rang = Int((p.y - Self.hauteurRegle) / pas)
        guard projet.pistes.indices.contains(rang) else { return Touche(zone: .vide) }
        guard let c = projet.pistes[rang].clips.last(where: {
            rectClip($0, rang).insetBy(dx: -1, dy: 0).contains(p)
        }) else { return Touche(zone: .vide, piste: rang) }
        let r = rectClip(c, rang)
        guard outil == .selection else { return Touche(zone: .corps, piste: rang, clip: c) }
        // Les poignees de fondu, en haut de l'onde, l'emportent sur les bords.
        if abs(p.y - (r.minY + VueClip.yPoignee)) <= 7, r.width > 16 {
            if abs(p.x - (r.minX + VueClip.xFonduEntree(c, echelle, largeur: r.width))) <= 6 {
                return Touche(zone: .fonduEntree, piste: rang, clip: c)
            }
            if abs(p.x - (r.minX + VueClip.xFonduSortie(c, echelle, largeur: r.width))) <= 6 {
                return Touche(zone: .fonduSortie, piste: rang, clip: c)
            }
        }
        if r.width > 20 {
            if p.x - r.minX <= 6 { return Touche(zone: .bordDebut, piste: rang, clip: c) }
            if r.maxX - p.x <= 6 { return Touche(zone: .bordFin, piste: rang, clip: c) }
        }
        if r.width > 24, abs(p.y - (r.minY + VueClip.yVolume(c.volume, hauteur: hClip))) <= 4.5 {
            return Touche(zone: .volume, piste: rang, clip: c)
        }
        return Touche(zone: .corps, piste: rang, clip: c)
    }

    // MARK: Le geste

    private func glisser(_ g: DragGesture.Value) {
        if geste == nil { commencer(g.startLocation) }
        pointeur = g.location.x
        let dx = g.translation.width, dy = g.translation.height
        switch geste {
        case .deplacer(let ids, let saisi, let t, let mods, let bouge):
            if !bouge {
                guard hypot(dx, dy) >= 3 else { return }
                geste = .deplacer(ids: ids, saisi: saisi, t: t, mods: mods, bouge: true)
            }
            let dt = aimanter(ids, dt: Double(dx / echelle))
            let (bt, bp) = Edition.borner(ids, dt: dt, dp: Int((dy / pas).rounded()), dans: projet.pistes)
            let a = Apercu(dt: bt, dp: bp, copie: NSEvent.modifierFlags.contains(.option))
            if a != apercu { apercu = a }

        case .elaguer(let id, let piste, let bord, let origine, let ripple, let retenu):
            guard dx != 0, let c = origine.clips.first(where: { $0.id == id }) else { return }
            if !retenu {
                projet.retenir("Élaguer le clip")
                geste = .elaguer(id: id, piste: piste, bord: bord, origine: origine, ripple: ripple, retenu: true)
            }
            var delta = Double(dx / echelle)
            // le bord qui bouge s'accroche aux autres bords et a la tete
            if !(ripple && bord == .debut) {
                let x = bord == .debut ? c.debut : c.fin
                delta = aimanter(point: x + delta, sauf: id) - x
            }
            projet.pistes[piste] = Edition.elaguer(origine, id: id, bord: bord, de: delta, ripple: ripple)
            projet.modifie = true

        case .volume(let id, let piste, let depart, let retenu):
            guard dy != 0 else { return }
            if !retenu {
                projet.retenir("Volume du clip")
                geste = .volume(id: id, piste: piste, depart: depart, retenu: true)
            }
            var v: Double
            if NSEvent.modifierFlags.contains(.option) {
                // Option : reglage fin, un dixieme de dB par point
                v = ((depart - Double(dy) * 0.1) * 10).rounded() / 10
            } else {
                v = VueClip.volume(VueClip.yVolume(depart, hauteur: hClip) + dy, hauteur: hClip).rounded()
            }
            v = min(Voix.volumeMax, max(Voix.volumeMin, v))
            if let j = projet.pistes[piste].clips.firstIndex(where: { $0.id == id }),
               projet.pistes[piste].clips[j].volume != v {
                projet.pistes[piste].clips[j].volume = v
                projet.modifie = true
            }

        case .fondu(let id, let piste, let entree, let depart, let retenu):
            guard dx != 0, let j = projet.pistes[piste].clips.firstIndex(where: { $0.id == id }) else { return }
            if !retenu {
                projet.retenir("Fondu audio")
                geste = .fondu(id: id, piste: piste, entree: entree, depart: depart, retenu: true)
            }
            let c = projet.pistes[piste].clips[j]
            let autre = entree ? c.fonduSortie : c.fonduEntree
            let d = min(max(0, depart + Double((entree ? dx : -dx) / echelle)), max(0, c.duree - autre))
            if entree { projet.pistes[piste].clips[j].fonduEntree = d }
            else { projet.pistes[piste].clips[j].fonduSortie = d }
            projet.modifie = true

        case .cadre(let depart, let base):
            guard hypot(dx, dy) >= 3 else { return }
            let r = CGRect(x: min(depart.x, g.location.x), y: min(depart.y, g.location.y),
                           width: abs(dx), height: abs(dy))
            cadre = r
            var touches: Set<UUID> = []
            for (rang, p) in projet.pistes.enumerated() {
                for c in p.clips where rectClip(c, rang).intersects(r) { touches.insert(c.id) }
            }
            let s = base.union(touches)
            if s != montage.selection { montage.selection = s }

        case .tete:
            lecteur.tete = max(0, Double(g.location.x / echelle))

        case .main(let ancre):
            guard let vue = defilement else { return }
            let x = max(0, ancre - dx)
            vue.contentView.scroll(to: NSPoint(x: x, y: vue.documentVisibleRect.origin.y))
            vue.reflectScrolledClipView(vue.contentView)

        default:
            break
        }
    }

    private func commencer(_ p: CGPoint) {
        // Un clic dans la timeline retire le clavier au script : espace y lance
        // alors la lecture, ou arrete la prise. Recliquer dans le script y
        // remet le curseur.
        if let f = NSApp.keyWindow, f.firstResponder is NSTextView { f.makeFirstResponder(nil) }
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let clics = NSApp.currentEvent?.clickCount ?? 1
        let t = max(0, Double(p.x / echelle))
        let touche = toucher(p)
        geste = .rien

        if outil == .main {
            geste = .main(ancre: defilement?.documentVisibleRect.origin.x ?? 0)
            NSCursor.closedHand.set()
            return
        }
        guard let c = touche.clip, let rang = touche.piste else {
            if touche.zone == .vide, outil == .selection {
                // Majuscule ou Commande : le rectangle s'ajoute a la selection
                let garder = mods.contains(.command) || mods.contains(.shift)
                let base = garder ? montage.selection : []
                if !garder { montage.selection = [] }
                geste = .cadre(depart: p, base: base)
            } else {
                // la regle : la tete suit la souris tant qu'on tient le bouton
                if lecteur.enLecture { lecteur.arreter() }
                lecteur.tete = t
                geste = .tete
            }
            return
        }
        switch outil {
        case .lame:
            let coupe = projet.reglages.aimantation ? aimanter(point: t, sauf: c.id) : t
            montage.agir("Couper") { Edition.lame(a: coupe, ids: [c.id], pistes: nil, dans: &$0) }
        case .elaguer:
            let bord: Edition.Bord = p.x < rectClip(c, rang).midX ? .debut : .fin
            geste = .elaguer(id: c.id, piste: rang, bord: bord, origine: projet.pistes[rang],
                             ripple: false, retenu: false)
        case .selection:
            switch touche.zone {
            case .fonduEntree, .fonduSortie:
                let entree = touche.zone == .fonduEntree
                geste = .fondu(id: c.id, piste: rang, entree: entree,
                               depart: entree ? c.fonduEntree : c.fonduSortie, retenu: false)
            case .bordDebut, .bordFin:
                // l'outil Selection elague en entrainant la suite
                geste = .elaguer(id: c.id, piste: rang, bord: touche.zone == .bordDebut ? .debut : .fin,
                                 origine: projet.pistes[rang], ripple: true, retenu: false)
            case .volume where clics >= 2:
                // double-clic sur la ligne : retour a 0 dB
                montage.agir("Rétablir le volume") { Edition.modifier([c.id], dans: &$0) { $0.volume = 0 } }
            case .volume:
                geste = .volume(id: c.id, piste: rang, depart: c.volume, retenu: false)
            default:
                if mods.contains(.command) {
                    // Commande-clic : ajoute ou retire de la selection
                    if montage.selection.contains(c.id) { montage.selection.remove(c.id) }
                    else { montage.selection.insert(c.id) }
                    return
                }
                if mods.contains(.shift) { montage.selection.insert(c.id) }
                else if !montage.selection.contains(c.id) { montage.selection = [c.id] }
                geste = .deplacer(ids: montage.selection, saisi: c.id, t: t, mods: mods, bouge: false)
            }
        case .main:
            break
        }
    }

    private func lacher(_ g: DragGesture.Value) {
        defer { geste = nil; apercu = nil; cadre = nil }
        switch geste {
        case .deplacer(let ids, let saisi, let t, let mods, let bouge):
            if bouge, let a = apercu {
                guard a.dt != 0 || a.dp != 0 || a.copie else { return }
                var nouveaux = ids
                montage.agir(a.copie ? "Dupliquer" : "Déplacer le clip") {
                    nouveaux = Edition.deplacer(ids, dt: a.dt, dp: a.dp, copie: a.copie, dans: &$0)
                }
                montage.selection = nouveaux
            } else if !bouge {
                // un simple clic : ce clip seul, et la tete vient s'y poser
                // (Option-clic selectionne sans deplacer la tete)
                if mods.isDisjoint(with: [.shift, .command]) { montage.selection = [saisi] }
                if !mods.contains(.option) { montage.deplacerTete(t) }
            }
        case .elaguer(_, _, _, _, _, true), .volume(_, _, _, true), .fondu(_, _, _, _, true):
            montage.relancer()
        case .cadre(let depart, _):
            // un clic dans le vide pose la tete
            if cadre == nil { montage.deplacerTete(max(0, Double(depart.x / echelle))) }
        case .tete:
            break
        case .main:
            NSCursor.openHand.set()
        default:
            break
        }
    }

    // MARK: Aimantation

    private var seuilAimant: Double { Double(8 / echelle) }

    /// Le groupe tire s'accroche par son debut ou par sa fin, au point le plus
    /// proche : bords des autres clips, tete de lecture, zero.
    private func aimanter(_ ids: Set<UUID>, dt: Double) -> Double {
        guard projet.reglages.aimantation else { return dt }
        let p = Edition.places(ids, dans: projet.pistes)
        guard let d = p.map(\.clip.debut).min(), let f = p.map(\.clip.fin).max() else { return dt }
        let points = Edition.points(projet.pistes, sauf: ids) + [lecteur.tete]
        var correction: Double?
        for pt in points {
            for bord in [d + dt, f + dt] {
                let c = pt - bord
                if abs(c) < seuilAimant, abs(c) < abs(correction ?? .infinity) { correction = c }
            }
        }
        return dt + (correction ?? 0)
    }

    private func aimanter(point x: Double, sauf id: UUID) -> Double {
        guard projet.reglages.aimantation else { return x }
        return Aimant.caler(x, sur: Edition.points(projet.pistes, sauf: [id]) + [lecteur.tete],
                            seuil: seuilAimant)
    }

    // MARK: Survol et curseur

    private func survoler(_ phase: HoverPhase) {
        guard geste == nil else { return }
        switch phase {
        case .active(let p):
            let t = toucher(p)
            let nouveau = t.clip.map { Survol(id: $0.id, zone: t.zone, x: p.x - CGFloat($0.debut) * echelle) }
            // l'etiquette de volume suit la souris ; ailleurs, inutile de redessiner
            if nouveau?.id != survol?.id || nouveau?.zone != survol?.zone || nouveau?.zone == .volume {
                survol = nouveau
            }
            curseur(t.zone, surClip: t.clip != nil)
        case .ended:
            survol = nil
            NSCursor.arrow.set()
        }
    }

    private func curseur(_ z: Zone, surClip: Bool) {
        switch outil {
        case .main: NSCursor.openHand.set()
        case .lame: (surClip ? NSCursor.crosshair : NSCursor.arrow).set()
        case .elaguer: (surClip ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        case .selection:
            switch z {
            case .bordDebut, .bordFin, .fonduEntree, .fonduSortie: NSCursor.resizeLeftRight.set()
            case .volume: NSCursor.resizeUpDown.set()
            default: NSCursor.arrow.set()
            }
        }
    }

    // MARK: Zoom et defilement

    static func borner(zoom z: Double) -> Double { min(320, max(2, z)) }

    /// Commande + et Commande - : la tete reste au meme endroit de l'ecran.
    /// nil : Majuscule Z, tout le montage dans la largeur visible.
    private func zoomer(_ facteur: Double?) {
        let ancien = projet.reglages.zoomTimeline
        let visible = Double(defilement?.documentVisibleRect.width ?? 1000)
        let nouveau = Self.borner(zoom: facteur.map { ancien * $0 }
                                  ?? (projet.duree > 0 ? (visible - 40) / projet.duree : ancien))
        let xEcran = CGFloat(lecteur.tete * ancien) - (defilement?.documentVisibleRect.minX ?? 0)
        projet.reglages.zoomTimeline = nouveau
        let t = lecteur.tete
        DispatchQueue.main.async {
            guard let d = defilement else { return }
            let x = facteur == nil ? 0 : max(0, CGFloat(t * nouveau) - xEcran)
            d.contentView.scroll(to: NSPoint(x: x, y: d.documentVisibleRect.minY))
            d.reflectScrolledClipView(d.contentView)
        }
    }

    /// Pendant la lecture, la timeline defile pour garder la tete a l'ecran.
    private func suivreTete(_ t: Double) {
        guard lecteur.enLecture, geste == nil, let d = defilement else { return }
        let x = CGFloat(t) * echelle, v = d.documentVisibleRect
        guard x > v.maxX - 30 || x < v.minX else { return }
        d.contentView.scroll(to: NSPoint(x: max(0, x - v.width * 0.1), y: v.minY))
        d.reflectScrolledClipView(d.contentView)
    }

    // MARK: Clic droit

    private func menu(en p: CGPoint, evenement e: NSEvent, vue: NSView) {
        let touche = toucher(p)
        if let c = touche.clip, !montage.selection.contains(c.id) { montage.selection = [c.id] }
        let m = montage
        let sel = !m.selection.isEmpty
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let c = touche.clip {
            menu.addItem(ActionMenu.item("Couper", "x") { m.couper() })
            menu.addItem(ActionMenu.item("Copier", "c") { m.copier() })
            menu.addItem(ActionMenu.item("Coller", "v", actif: m.peutColler) { m.coller() })
            menu.addItem(ActionMenu.item("Coller sur une piste libre", "v", .option, actif: m.peutColler) {
                m.coller(inserer: false)
            })
            menu.addItem(ActionMenu.item("Dupliquer", "d") { m.dupliquer() })
            menu.addItem(.separator())
            menu.addItem(ActionMenu.item("Supprimer", "\u{8}", []) { m.supprimer(refermer: true) })
            menu.addItem(ActionMenu.item("Remplacer par un blanc", "\u{8}", .shift) {
                m.supprimer(refermer: false)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenu.item("Lame de rasoir à la tête de lecture", "b") { m.lame(toutesPistes: false) })
            menu.addItem(ActionMenu.item("Élaguer le début jusqu'à la tête", "[", .option) {
                m.elaguerJusquaTete(debut: true)
            })
            menu.addItem(ActionMenu.item("Élaguer la fin jusqu'à la tête", "]", .option) {
                m.elaguerJusquaTete(debut: false)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenu.item("Appliquer les fondus audio", "") { m.fondus(0.5) })
            menu.addItem(ActionMenu.item("Supprimer les fondus", "",
                                         actif: c.fonduEntree > 0 || c.fonduSortie > 0) { m.fondus(0) })
            menu.addItem(ActionMenu.item("Monter le volume de 1 dB", "=", .control) { m.volume(1) })
            menu.addItem(ActionMenu.item("Baisser le volume de 1 dB", "-", .control) { m.volume(-1) })
            menu.addItem(ActionMenu.item("Réinitialiser le volume (0 dB)", "", actif: c.volume != 0) { m.volume(nil) })
            menu.addItem(.separator())
            menu.addItem(ActionMenu.item(c.actif ? "Désactiver" : "Activer", "v", []) { m.basculerActif() })
            menu.addItem(.separator())
        } else {
            menu.addItem(ActionMenu.item("Coller", "v", actif: m.peutColler) { m.coller() })
            menu.addItem(ActionMenu.item("Coller sur une piste libre", "v", .option, actif: m.peutColler) {
                m.coller(inserer: false)
            })
            menu.addItem(ActionMenu.item("Lame de rasoir sur tout", "b", [.command, .shift]) {
                m.lame(toutesPistes: true)
            })
            menu.addItem(.separator())
        }
        let instant = max(0, Double(p.x / echelle))
        menu.addItem(ActionMenu.item("Importer un son ici…", "i", [.command, .shift]) { m.importerSon(a: instant) })
        menu.addItem(.separator())
        // Les pistes : autant qu'on veut, au-dessus ou en dessous de celle cliquee.
        if let rang = touche.piste {
            let nom = projet.pistes[rang].nom
            menu.addItem(ActionMenu.item("Nouvelle piste au-dessus de « \(nom) »", "") { m.ajouterPiste(a: rang) })
            menu.addItem(ActionMenu.item("Nouvelle piste en dessous de « \(nom) »", "") { m.ajouterPiste(a: rang + 1) })
            menu.addItem(ActionMenu.item("Supprimer la piste « \(nom) »", "", actif: projet.pistes.count > 1) {
                m.supprimerPiste(rang)
            })
        } else {
            menu.addItem(ActionMenu.item("Nouvelle piste", "") { m.ajouterPiste(a: projet.pistes.count) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenu.item("Tout sélectionner", "a") { m.toutSelectionner() })
        menu.addItem(ActionMenu.item("Tout désélectionner", "a", [.command, .shift], actif: sel) {
            m.deselectionner()
        })
        NSMenu.popUpContextMenu(menu, with: e, for: vue)
    }
}

/// Le clic droit (ou Controle-clic) sur la timeline. SwiftUI ne dit pas ou le
/// menu contextuel a ete demande ; cette vue, posee sous le montage, le sait.
private struct ClicDroit: NSViewRepresentable {
    let action: (CGPoint, NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> Vue {
        let v = Vue()
        v.action = action
        return v
    }
    func updateNSView(_ v: Vue, context: Context) { v.action = action }

    final class Vue: NSView {
        var action: ((CGPoint, NSEvent, NSView) -> Void)?
        private var moniteur: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow fenetre: NSWindow?) {
            super.viewWillMove(toWindow: fenetre)
            if let m = moniteur { NSEvent.removeMonitor(m); moniteur = nil }
            guard fenetre != nil else { return }
            moniteur = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                if e.type == .leftMouseDown, !e.modifierFlags.contains(.control) { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.visibleRect.contains(p) else { return e }
                self.action?(p, e, self)
                return nil
            }
        }
    }
}

/// La prise en train de s'ecrire. Meme dessin qu'un clip, mais dans le rouge de
/// l'enregistrement, et sans bord droit : elle n'a pas encore de fin.
private struct VuePriseEnCours: View {
    let duree: Double
    let onde: [Float]
    let echelle: CGFloat
    let hauteur: CGFloat

    var body: some View {
        let l = max(2, CGFloat(duree) * echelle)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(red: 0.31, green: 0.15, blue: 0.14))
            Canvas { ctx, taille in
                guard !onde.isEmpty, taille.width > 1 else { return }
                let milieu = taille.height / 2
                var chemin = Path()
                // une colonne par tranche de 20 ms, a l'echelle courante
                for (i, pic) in onde.enumerated() {
                    let x = CGFloat(Double(i) * 0.02) * echelle
                    guard x <= taille.width else { break }
                    let h = CGFloat(pic) * (taille.height * 0.44)
                    chemin.move(to: .init(x: x, y: milieu - h))
                    chemin.addLine(to: .init(x: x, y: milieu + h))
                }
                ctx.stroke(chemin, with: .color(Color(red: 0.95, green: 0.55, blue: 0.47)), lineWidth: 1)
            }
            .padding(.top, 14)
            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.95, green: 0.33, blue: 0.24)).frame(width: 5, height: 5)
                Text("Enregistrement")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.82))
            }
            .padding(.horizontal, 5).padding(.top, 2)
        }
        .frame(width: l, height: hauteur - 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(red: 0.95, green: 0.33, blue: 0.24)).frame(width: 2)
        }
        .padding(.vertical, 4)
    }
}

/// Un clip dessine : le nom, la forme d'onde, les fondus, la ligne de volume.
/// Il ne recoit aucun geste : la timeline les traite tous, dans son repere.
private struct VueClip: View {
    let clip: Clip
    let choisi: Bool
    let echelle: CGFloat
    let hauteur: CGFloat
    let pics: [Float]?
    /// la ligne de volume se montre avec l'outil Selection
    let ligne: Bool
    let ligneActive: Bool
    /// l'etiquette suit le pointeur
    let xEtiquette: CGFloat
    let poignees: Bool

    static let essaiVolume = CommandLine.arguments.contains("--essai-volume")
    static let hautOnde: CGFloat = 14
    /// hauteur des poignees de fondu, en haut de l'onde
    static let yPoignee: CGFloat = hautOnde + 5

    // MARK: Geometrie, partagee avec la timeline qui fait les gestes

    /// La course n'est pas lineaire : fine autour de zero, ou l'on retouche,
    /// rapide vers les extremes, ou l'on ne fait que passer.
    private static let courbe = 1.6
    private static func zone(_ h: CGFloat) -> CGFloat { h - hautOnde }
    /// Le zero est au milieu de l'onde ; le haut vaut +30 dB, le bas -30 dB.
    private static func demiCourse(_ h: CGFloat) -> CGFloat { zone(h) / 2 - 7 }

    static func yVolume(_ v: Double, hauteur h: CGFloat) -> CGFloat {
        let p = pow(abs(v) / Voix.volumeMax, 1 / courbe) * (v < 0 ? -1 : 1)
        return hautOnde + zone(h) / 2 - CGFloat(p) * demiCourse(h)
    }

    static func volume(_ y: CGFloat, hauteur h: CGFloat) -> Double {
        let p = Double((hautOnde + zone(h) / 2 - y) / demiCourse(h))
        return Voix.volumeMax * pow(min(1, abs(p)), courbe) * (p < 0 ? -1 : 1)
    }

    static func xFonduEntree(_ c: Clip, _ e: CGFloat, largeur l: CGFloat) -> CGFloat {
        min(max(5, CGFloat(c.fonduEntree) * e), l - 5)
    }
    static func xFonduSortie(_ c: Clip, _ e: CGFloat, largeur l: CGFloat) -> CGFloat {
        max(min(l - 5, l - CGFloat(c.fonduSortie) * e), 5)
    }

    /// Le gain d'un fondu a `t` secondes du bord : quart de sinus, +3 dB.
    private static func fondu(_ t: Double, _ d: Double) -> Double {
        d > 0.001 ? sin(.pi / 2 * min(1, max(0, t / d))) : 1
    }

    var body: some View {
        let l = max(2, CGFloat(clip.duree) * echelle)
        let gain = CGFloat(pow(10, clip.volume / 20))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(!clip.actif ? Color(white: 0.19)
                      : clip.voix ? Color(red: 0.16, green: 0.26, blue: 0.34)
                      : Color(red: 0.14, green: 0.27, blue: 0.21))
            if let pics, !pics.isEmpty {
                Canvas { ctx, taille in
                    let debut = Int(clip.entree / 0.02)
                    let nb = Int(clip.duree / 0.02)
                    guard nb > 0 else { return }
                    let milieu = taille.height / 2
                    var chemin = Path()
                    for x in stride(from: 0, to: taille.width, by: 1) {
                        let i = debut + Int(Double(x) / Double(taille.width) * Double(nb))
                        guard i >= 0, i < pics.count else { continue }
                        // l'onde suit le volume et les fondus
                        let t = Double(x / echelle)
                        let f = VueClip.fondu(t, clip.fonduEntree) * VueClip.fondu(clip.duree - t, clip.fonduSortie)
                        let h = min(1, CGFloat(pics[i]) * gain * CGFloat(f)) * (taille.height * 0.44)
                        chemin.move(to: .init(x: x, y: milieu - h))
                        chemin.addLine(to: .init(x: x, y: milieu + h))
                    }
                    // les voix en bleu, les sons importes dans le vert de l'application
                    let teinte = !clip.actif ? Color(white: 0.45)
                        : clip.voix ? Color(red: 0.55, green: 0.73, blue: 0.86)
                        : Color(red: 0.41, green: 0.81, blue: 0.59)
                    ctx.stroke(chemin, with: .color(teinte), lineWidth: 1)
                }
                .padding(.top, VueClip.hautOnde)
            }
            fondus(largeur: l)
            Text(clip.nom.isEmpty ? clip.fichier : clip.nom)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: clip.actif ? 0.85 : 0.5))
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.top, 2)
                .frame(width: l, alignment: .leading)
                .clipped()
            if ligne, l > 24 { ligneVolume(largeur: l) }
            if poignees, l > 16 { poigneesFondu(largeur: l) }
        }
        .frame(width: l, height: hauteur)
        .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(choisi ? Color(red: 1, green: 0.84, blue: 0.3) : Color.clear, lineWidth: 2))
    }

    /// La courbe de chaque fondu, et l'ombre de ce qu'elle retire.
    private func fondus(largeur l: CGFloat) -> some View {
        Canvas { ctx, taille in
            let haut = VueClip.hautOnde, bas = taille.height
            func trace(_ depuisGauche: Bool, _ d: Double) {
                guard d > 0.001 else { return }
                let w = min(l, CGFloat(d) * echelle)
                var courbe = Path(), ombre = Path()
                ombre.move(to: .init(x: depuisGauche ? 0 : l, y: haut))
                for i in 0...24 {
                    let u = CGFloat(i) / 24
                    let x = depuisGauche ? u * w : l - u * w
                    let y = bas - (bas - haut) * CGFloat(VueClip.fondu(Double(u), 1))
                    if i == 0 { courbe.move(to: .init(x: x, y: y)) } else { courbe.addLine(to: .init(x: x, y: y)) }
                    ombre.addLine(to: .init(x: x, y: y))
                }
                ombre.closeSubpath()
                ctx.fill(ombre, with: .color(Color.black.opacity(0.32)))
                ctx.stroke(courbe, with: .color(Color(white: 0.92).opacity(0.8)), lineWidth: 1)
            }
            trace(true, clip.fonduEntree)
            trace(false, clip.fonduSortie)
        }
        .frame(width: l, height: hauteur)
        .allowsHitTesting(false)
    }

    private func poigneesFondu(largeur l: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([VueClip.xFonduEntree(clip, echelle, largeur: l),
                     VueClip.xFonduSortie(clip, echelle, largeur: l)], id: \.self) { x in
                Rectangle()
                    .fill(Color(white: 0.95))
                    .frame(width: 7, height: 7)
                    .overlay(Rectangle().stroke(Color(white: 0.1), lineWidth: 1))
                    .offset(x: x - 3.5, y: VueClip.yPoignee - 3.5)
            }
        }
        .frame(width: l, height: hauteur, alignment: .topLeading)
    }

    private func ligneVolume(largeur: CGFloat) -> some View {
        let actif = ligneActive
        let yLigne = VueClip.yVolume(clip.volume, hauteur: hauteur)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(white: actif ? 0.96 : 0.80).opacity(actif ? 1 : 0.75))
                .frame(width: largeur, height: actif ? 1.5 : 1)
                .offset(y: yLigne)
            if actif {
                Text(String(format: "%@%.1f dB", clip.volume > 0 ? "+" : "", clip.volume))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.95))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(white: 0.08).opacity(0.88))
                    .overlay(Rectangle().fill(Color(white: 0.96)).frame(height: 1), alignment: .bottom)
                    .fixedSize()
                    .offset(x: min(max(4, xEtiquette - 36), largeur - 76),
                            y: yLigne < VueClip.hautOnde + 22 ? yLigne + 6 : yLigne - 22)
            }
        }
        .frame(width: largeur, height: hauteur, alignment: .topLeading)
    }
}

enum Horloge {
    static func texte(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func precis(_ t: Double) -> String {
        let s = Int(t)
        let cs = Int((t - Double(s)) * 100)
        return String(format: "%02d:%02d.%02d", s / 60, s % 60, cs)
    }
}

/// Donne acces au NSScrollView qui entoure la timeline : l'outil Main en a besoin
/// pour faire glisser la vue, ce que SwiftUI ne permet pas directement.
struct AccesDefilement: NSViewRepresentable {
    let trouve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let vue = NSView()
        DispatchQueue.main.async {
            var parent = vue.superview
            while let p = parent {
                if let scroll = p as? NSScrollView { trouve(scroll); break }
                parent = p.superview
            }
        }
        return vue
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
