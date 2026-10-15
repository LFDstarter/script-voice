import AVFoundation
import AppKit
import SwiftUI

/// Un clip et la piste ou il vit.
struct ClipPlace: Equatable {
    var piste: Int
    var clip: Clip
}

/// Les commandes de montage, sur les pistes seules. Aucune ne touche a
/// l'interface : le banc d'essai les verifie toutes, et la souris, le clavier
/// et le clic droit passent tous par elles.
///
/// La regle de pose est celle des couloirs : aucun clip n'en
/// cache jamais un autre. Un clip pose sur une place prise monte sur une piste
/// libre, et rien ne joue jamais en double sur une meme piste.
enum Edition {
    /// Un pas de deplacement fin : une image a 25 images par seconde.
    static let image = 1.0 / 25
    private static let epsilon = 0.0005

    static func trier(_ pistes: inout [Piste]) {
        for i in pistes.indices { pistes[i].clips.sort { $0.debut < $1.debut } }
    }

    static func places(_ ids: Set<UUID>, dans pistes: [Piste]) -> [ClipPlace] {
        pistes.enumerated().flatMap { i, p in
            p.clips.filter { ids.contains($0.id) }.map { ClipPlace(piste: i, clip: $0) }
        }
    }

    /// Tous les bords de clips, et le zero : les points de montage.
    static func points(_ pistes: [Piste], sauf: Set<UUID> = []) -> [Double] {
        var p: Set<Double> = [0]
        for piste in pistes {
            for c in piste.clips where !sauf.contains(c.id) { p.insert(c.debut); p.insert(c.fin) }
        }
        return p.sorted()
    }

    // MARK: Poser

    /// Vrai si la plage du clip est libre sur la piste.
    static func libre(_ piste: Piste, pour c: Clip, sauf: Set<UUID> = []) -> Bool {
        !piste.clips.contains { !sauf.contains($0.id) && $0.debut < c.fin - epsilon && $0.fin > c.debut + epsilon }
    }

    /// Pose des clips (deplaces, colles, dupliques, enregistres). Aucun clip
    /// n'en cache jamais un autre : si la place visee est prise, le clip monte
    /// sur la premiere piste du dessus qui est libre a cet endroit ; s'il n'y
    /// en a pas, une piste se cree au-dessus de la piste visee, et ce qui etait
    /// la reste visible sur sa piste, devenue celle du dessous.
    /// Renvoie les clips avec la piste ou ils ont fini.
    @discardableResult
    static func poser(_ morceaux: [ClipPlace], dans pistes: inout [Piste]) -> [ClipPlace] {
        var reste = morceaux.sorted { ($0.piste, $0.clip.debut) < ($1.piste, $1.clip.debut) }
        var poses: [ClipPlace] = []
        while !reste.isEmpty {
            let m = reste.removeFirst()
            var cible = max(0, m.piste)
            while cible >= pistes.count { pistes.append(Piste(nom: nomDePiste(pistes))) }
            if !libre(pistes[cible], pour: m.clip) {
                if let r = stride(from: cible - 1, through: 0, by: -1).first(where: { libre(pistes[$0], pour: m.clip) }) {
                    cible = r
                } else {
                    pistes.insert(Piste(nom: nomDePiste(pistes)), at: cible)
                    // ce qui reste a poser plus bas descend d'un cran avec sa piste
                    for k in reste.indices where reste[k].piste >= cible { reste[k].piste += 1 }
                    for k in poses.indices where poses[k].piste >= cible { poses[k].piste += 1 }
                }
            }
            pistes[cible].clips.append(m.clip)
            poses.append(ClipPlace(piste: cible, clip: m.clip))
        }
        trier(&pistes)
        return poses
    }

    // MARK: Sons importes

    /// La piste ou poser des sons importes : sous les voix. La derniere piste
    /// si elle ne porte deja que des sons et qu'elle a la place, sinon une
    /// piste neuve, tout en bas.
    static func pisteDeSon(pour clips: [Clip], dans pistes: inout [Piste]) -> Int {
        if let derniere = pistes.last, !derniere.clips.isEmpty, derniere.clips.allSatisfy({ !$0.voix }),
           clips.allSatisfy({ libre(derniere, pour: $0) }) {
            return pistes.count - 1
        }
        pistes.append(Piste(nom: nomDePiste(pistes, prefixe: "Son")))
        return pistes.count - 1
    }

    // MARK: Pistes

    /// Le premier nom « Voix n » libre.
    static func nomDePiste(_ pistes: [Piste], prefixe: String = "Voix") -> String {
        var n = 1
        while pistes.contains(where: { $0.nom == "\(prefixe) \(n)" }) { n += 1 }
        return "\(prefixe) \(n)"
    }

    // MARK: Supprimer

    /// Supprimer. `refermer` : la suite de la piste recule pour boucher le
    /// trou, comme dans un logiciel de montage. Sans, le vide reste
    /// (Majuscule Supprimer).
    static func supprimer(_ ids: Set<UUID>, dans pistes: inout [Piste], refermer: Bool) {
        for i in pistes.indices {
            let partis = pistes[i].clips.filter { ids.contains($0.id) }
            guard !partis.isEmpty else { continue }
            pistes[i].clips.removeAll { ids.contains($0.id) }
            guard refermer else { continue }
            for (a, b) in fusionner(partis.map { ($0.debut, $0.fin) }).reversed() {
                // Un clip restant qui deborde dans le trou en reduit la fermeture.
                let bord = pistes[i].clips.filter { $0.debut < b - epsilon && $0.fin > a }
                    .map(\.fin).max().map { max(a, $0) } ?? a
                let recul = b - bord
                guard recul > epsilon else { continue }
                for j in pistes[i].clips.indices where pistes[i].clips[j].debut >= b - epsilon {
                    pistes[i].clips[j].debut -= recul
                }
            }
        }
    }

    private static func fusionner(_ plages: [(Double, Double)]) -> [(Double, Double)] {
        var r: [(Double, Double)] = []
        for p in plages.sorted(by: { $0.0 < $1.0 }) {
            if let d = r.last, p.0 <= d.1 + epsilon { r[r.count - 1].1 = max(d.1, p.1) } else { r.append(p) }
        }
        return r
    }

    // MARK: Copier, coller, dupliquer

    /// Le presse-papier : le debut et la piste de chaque clip sont relatifs au
    /// premier d'entre eux, pour que plusieurs clips gardent leur disposition.
    static func copier(_ ids: Set<UUID>, dans pistes: [Piste]) -> [ClipPlace] {
        let p = places(ids, dans: pistes)
        guard let t0 = p.map(\.clip.debut).min(), let p0 = p.map(\.piste).min() else { return [] }
        return p.map { m in
            var c = m.clip
            c.debut -= t0
            return ClipPlace(piste: m.piste - p0, clip: c)
        }
    }

    /// Colle a l'instant `t`, a partir de la piste donnee. Des pistes
    /// s'ajoutent si le presse-papier en demande plus qu'il n'y en a.
    ///
    /// `inserer` (Commande V) : ce qui se trouve sous la tete
    /// est coupe, et la suite des pistes visees recule pour faire la place.
    /// Sans (Option V), le collage se pose sur une piste libre, comme un plan
    /// connecte dans un couloir.
    static func coller(_ presse: [ClipPlace], a t: Double, piste: Int, inserer: Bool = false,
                       dans pistes: inout [Piste]) -> Set<UUID> {
        guard !presse.isEmpty else { return [] }
        if inserer {
            let largeur = (presse.map(\.clip.fin).max() ?? 0) - (presse.map(\.clip.debut).min() ?? 0)
            let visees = Set(presse.map { max(0, piste) + $0.piste })
            for i in pistes.indices where visees.contains(i) {
                for c in pistes[i].clips where c.contient(t) { _ = pistes[i].couper(c.id, a: t) }
                for j in pistes[i].clips.indices where pistes[i].clips[j].debut >= t - epsilon {
                    pistes[i].clips[j].debut += largeur
                }
            }
        }
        let morceaux = presse.map { m -> ClipPlace in
            var c = m.clip
            c.id = UUID()
            c.debut = max(0, t) + m.clip.debut
            return ClipPlace(piste: max(0, piste) + m.piste, clip: c)
        }
        let besoin = (morceaux.map(\.piste).max() ?? 0) + 1
        while pistes.count < besoin { pistes.append(Piste(nom: nomDePiste(pistes))) }
        poser(morceaux, dans: &pistes)
        return Set(morceaux.map(\.clip.id))
    }

    /// Une copie de la selection, posee juste apres elle.
    static func dupliquer(_ ids: Set<UUID>, dans pistes: inout [Piste]) -> Set<UUID> {
        let p = places(ids, dans: pistes)
        guard let fin = p.map(\.clip.fin).max(), let p0 = p.map(\.piste).min() else { return [] }
        return coller(copier(ids, dans: pistes), a: fin, piste: p0, dans: &pistes)
    }

    // MARK: Deplacer

    /// Le groupe ne passe pas avant zero et reste dans les pistes existantes.
    static func borner(_ ids: Set<UUID>, dt: Double, dp: Int, dans pistes: [Piste]) -> (Double, Int) {
        let p = places(ids, dans: pistes)
        guard let debut = p.map(\.clip.debut).min(),
              let haut = p.map(\.piste).min(), let bas = p.map(\.piste).max() else { return (0, 0) }
        return (max(dt, -debut), min(max(dp, -haut), pistes.count - 1 - bas))
    }

    /// Deplace des clips de `dt` secondes et `dp` pistes. `copie` laisse les
    /// originaux en place : c'est Option-glisser.
    static func deplacer(_ ids: Set<UUID>, dt: Double, dp: Int, copie: Bool,
                         dans pistes: inout [Piste]) -> Set<UUID> {
        let (dt, dp) = borner(ids, dt: dt, dp: dp, dans: pistes)
        let p = places(ids, dans: pistes)
        if !copie { for i in pistes.indices { pistes[i].clips.removeAll { ids.contains($0.id) } } }
        let morceaux = p.map { m -> ClipPlace in
            var c = m.clip
            if copie { c.id = UUID() }
            c.debut = max(0, c.debut + dt)
            return ClipPlace(piste: m.piste + dp, clip: c)
        }
        poser(morceaux, dans: &pistes)
        return Set(morceaux.map(\.clip.id))
    }

    // MARK: Lame et elagage a la tete

    /// Coupe a l'instant `t` les clips vises qui passent par la. `ids` nil :
    /// tous ceux des pistes `filtre` (toutes si nil).
    @discardableResult
    static func lame(a t: Double, ids: Set<UUID>?, pistes filtre: Set<Int>?,
                     dans pistes: inout [Piste]) -> Set<UUID> {
        var droites: Set<UUID> = []
        for i in pistes.indices where filtre?.contains(i) ?? true {
            for c in pistes[i].clips where (ids?.contains(c.id) ?? true) && c.contient(t) {
                if let d = pistes[i].couper(c.id, a: t) { droites.insert(d) }
            }
        }
        return droites
    }

    /// Retire ce qui precede la tete (Option [) ou ce qui la suit (Option ]),
    /// sans rien decaler d'autre.
    static func elaguerJusqua(_ t: Double, debut: Bool, ids: Set<UUID>?, pistes filtre: Set<Int>?,
                              dans pistes: inout [Piste]) -> Bool {
        var fait = false
        for i in pistes.indices where filtre?.contains(i) ?? true {
            for j in pistes[i].clips.indices {
                var c = pistes[i].clips[j]
                guard ids?.contains(c.id) ?? true,
                      t > c.debut + 0.02, t < c.fin - 0.02 else { continue }
                if debut {
                    c.entree += t - c.debut
                    c.debut = t
                } else {
                    c.sortie = c.entree + (t - c.debut)
                }
                c.fonduEntree = min(c.fonduEntree, c.duree)
                c.fonduSortie = min(c.fonduSortie, c.duree - c.fonduEntree)
                pistes[i].clips[j] = c
                fait = true
            }
        }
        return fait
    }

    // MARK: Elagage a la souris

    enum Bord { case debut, fin }

    /// Elague un bord, a partir de l'etat de la piste au debut du geste.
    ///
    /// Sans `ripple` (outil Selection), le bord suit la souris et s'arrete au
    /// voisin. Avec (outil Elaguer), la suite de la piste suit le bord : le
    /// montage se resserre ou s'allonge d'autant.
    static func elaguer(_ origine: Piste, id: UUID, bord: Bord, de delta: Double, ripple: Bool) -> Piste {
        var piste = origine
        guard let i = piste.clips.firstIndex(where: { $0.id == id }) else { return piste }
        let c = origine.clips[i]
        let source = c.dureeSource > 0 ? c.dureeSource : c.sortie
        let mini = 0.05
        var n = c
        switch (bord, ripple) {
        case (.debut, false):
            let voisin = origine.clips.filter { $0.id != id && $0.fin <= c.debut + epsilon }.map(\.fin).max() ?? 0
            var d = delta
            d = max(d, -c.entree, voisin - c.debut)
            d = min(d, c.duree - mini)
            n.entree += d
            n.debut += d
        case (.fin, false):
            let voisin = origine.clips.filter { $0.id != id && $0.debut >= c.fin - epsilon }.map(\.debut).min()
                ?? .infinity
            var d = delta
            d = min(d, source - c.sortie, voisin - c.fin)
            d = max(d, -(c.duree - mini))
            n.sortie += d
        case (.debut, true):
            // le debut reste en place, la matiere coule, la suite recule d'autant
            var d = delta
            d = max(d, -c.entree)
            d = min(d, c.duree - mini)
            n.entree += d
            for j in piste.clips.indices where j != i && origine.clips[j].debut >= c.fin - epsilon {
                piste.clips[j].debut = origine.clips[j].debut - d
            }
        case (.fin, true):
            var d = delta
            d = min(d, source - c.sortie)
            d = max(d, -(c.duree - mini))
            n.sortie += d
            for j in piste.clips.indices where j != i && origine.clips[j].debut >= c.fin - epsilon {
                piste.clips[j].debut = origine.clips[j].debut + d
            }
        }
        n.fonduEntree = min(n.fonduEntree, n.duree)
        n.fonduSortie = min(n.fonduSortie, n.duree - n.fonduEntree)
        piste.clips[i] = n
        return piste
    }

    // MARK: Reglages de clip

    static func modifier(_ ids: Set<UUID>, dans pistes: inout [Piste], _ changer: (inout Clip) -> Void) {
        for i in pistes.indices {
            for j in pistes[i].clips.indices where ids.contains(pistes[i].clips[j].id) {
                changer(&pistes[i].clips[j])
            }
        }
    }

    /// Fondus d'entree et de sortie sur chaque clip, bornes a sa moitie.
    static func fondus(_ ids: Set<UUID>, duree: Double, dans pistes: inout [Piste]) {
        modifier(ids, dans: &pistes) { c in
            let d = min(duree, c.duree / 2)
            c.fonduEntree = d
            c.fonduSortie = d
        }
    }
}

// MARK: - Le montage, cote interface

/// La selection, le presse-papier, et les commandes telles que les declenchent
/// la souris, le clavier, le menu et le clic droit. Chaque commande retient
/// l'etat des pistes avant d'agir : Commande Z la defait.
@MainActor
final class Montage: ObservableObject {
    @Published var selection: Set<UUID> = []
    @Published private(set) var presse: [ClipPlace] = []

    weak var projet: Projet?
    weak var lecteur: Lecteur?
    var pisteActive: () -> Int = { 0 }
    /// la timeline zoome elle-meme : elle seule sait ce qui est a l'ecran
    var zoomer: ((Double?) -> Void)?

    /// Le montage de la fenetre, pour le menu Edition.
    static weak var courant: Montage?

    private var tete: Double { lecteur?.tete ?? 0 }

    /// Applique une commande aux pistes. Rien n'est retenu si rien ne change.
    @discardableResult
    func agir(_ nom: String, _ faire: (inout [Piste]) -> Void) -> Bool {
        guard let projet else { return false }
        var pistes = projet.pistes
        faire(&pistes)
        guard pistes != projet.pistes else { return false }
        projet.retenir(nom)
        projet.pistes = pistes
        projet.modifie = true
        relancer()
        return true
    }

    /// Une lecture en cours repart du meme endroit, avec le montage a jour.
    func relancer() {
        guard let projet, let lecteur, lecteur.enLecture else { return }
        lecteur.jouer(projet, depuis: lecteur.tete)
    }

    /// Les clips vises par une commande : la selection, sinon ce qui passe
    /// sous la tete sur la piste active.
    private var vises: Set<UUID> {
        guard selection.isEmpty, let projet else { return selection }
        let i = min(max(0, pisteActive()), projet.pistes.count - 1)
        guard projet.pistes.indices.contains(i) else { return [] }
        return Set(projet.pistes[i].clips.filter { $0.contient(tete) }.map(\.id))
    }

    // MARK: Selection

    func toutSelectionner() {
        selection = Set(projet?.pistes.flatMap { $0.clips.map(\.id) } ?? [])
    }
    func deselectionner() { selection = [] }

    // MARK: Presse-papier

    var peutCopier: Bool { !selection.isEmpty }
    var peutColler: Bool { !presse.isEmpty }

    func copier() {
        guard let projet, !selection.isEmpty else { return }
        presse = Edition.copier(selection, dans: projet.pistes)
    }

    func couper() {
        guard !selection.isEmpty else { return }
        copier()
        let ids = selection
        agir("Couper") { Edition.supprimer(ids, dans: &$0, refermer: true) }
        selection = []
    }

    /// Colle a la tete de lecture, sur la piste active ; la tete passe a la
    /// fin de ce qui vient d'etre colle, pret pour le collage suivant.
    func coller(inserer: Bool = true) {
        guard !presse.isEmpty, let projet else { return }
        var nouveaux: Set<UUID> = []
        let t = tete, piste = min(max(0, pisteActive()), max(0, projet.pistes.count - 1))
        agir(inserer ? "Coller" : "Coller sur une piste libre") {
            nouveaux = Edition.coller(presse, a: t, piste: piste, inserer: inserer, dans: &$0)
        }
        selection = nouveaux
        if let fin = Edition.places(nouveaux, dans: projet.pistes).map(\.clip.fin).max() {
            lecteur?.tete = fin
        }
    }

    func dupliquer() {
        guard !selection.isEmpty else { return }
        var nouveaux: Set<UUID> = []
        let ids = selection
        agir("Dupliquer") { nouveaux = Edition.dupliquer(ids, dans: &$0) }
        selection = nouveaux
    }

    // MARK: Supprimer, couper, elaguer

    func supprimer(refermer: Bool) {
        guard !selection.isEmpty else { return }
        let ids = selection
        agir(refermer ? "Supprimer" : "Supprimer en laissant le vide") {
            Edition.supprimer(ids, dans: &$0, refermer: refermer)
        }
        selection = []
    }

    /// Commande B : la selection sous la tete, sinon la piste active.
    /// Majuscule Commande B : toutes les pistes.
    func lame(toutesPistes: Bool) {
        let t = tete
        if toutesPistes {
            agir("Tout couper") { Edition.lame(a: t, ids: nil, pistes: nil, dans: &$0) }
        } else {
            let ids = vises
            agir("Couper à la tête de lecture") { Edition.lame(a: t, ids: ids, pistes: nil, dans: &$0) }
        }
    }

    func elaguerJusquaTete(debut: Bool) {
        let t = tete, ids = vises
        agir(debut ? "Élaguer le début" : "Élaguer la fin") {
            _ = Edition.elaguerJusqua(t, debut: debut, ids: ids, pistes: nil, dans: &$0)
        }
    }

    /// Virgule et point : la selection glisse d'une image, de dix avec Majuscule.
    func decaler(images: Int) {
        guard !selection.isEmpty, let projet else { return }
        let ids = selection
        let (dt, _) = Edition.borner(ids, dt: Double(images) * Edition.image, dp: 0, dans: projet.pistes)
        guard abs(dt) > 0.0001 else { return }
        var nouveaux = ids
        agir("Déplacer") { nouveaux = Edition.deplacer(ids, dt: dt, dp: 0, copie: false, dans: &$0) }
        selection = nouveaux
    }

    // MARK: Reglages de clip

    func volume(_ delta: Double?) {
        let ids = vises
        guard !ids.isEmpty else { return }
        agir(delta == nil ? "Rétablir le volume" : "Volume du clip") {
            Edition.modifier(ids, dans: &$0) { c in
                c.volume = delta.map { min(Voix.volumeMax, max(Voix.volumeMin, (c.volume + $0).rounded())) } ?? 0
            }
        }
    }

    /// Touche V : desactive la selection, ou la reactive si tout y est deja eteint.
    func basculerActif() {
        guard let projet else { return }
        let ids = vises
        let places = Edition.places(ids, dans: projet.pistes)
        guard !places.isEmpty else { return }
        let allumer = places.allSatisfy { !$0.clip.actif }
        agir(allumer ? "Activer le clip" : "Désactiver le clip") {
            Edition.modifier(ids, dans: &$0) { $0.actif = allumer }
        }
    }

    func fondus(_ duree: Double) {
        let ids = vises
        guard !ids.isEmpty else { return }
        agir(duree > 0 ? "Fondus audio" : "Retirer les fondus") {
            Edition.fondus(ids, duree: duree, dans: &$0)
        }
    }

    // MARK: Pistes

    /// Une piste neuve, inseree a ce rang (0 : tout en haut ; le nombre de
    /// pistes : tout en bas).
    func ajouterPiste(a rang: Int) {
        agir("Ajouter une piste") { pistes in
            let r = min(max(0, rang), pistes.count)
            pistes.insert(Piste(nom: Edition.nomDePiste(pistes)), at: r)
        }
    }

    /// Supprime une piste et ses clips. Il en reste toujours une.
    func supprimerPiste(_ rang: Int) {
        guard let projet, projet.pistes.count > 1, projet.pistes.indices.contains(rang) else { return }
        let ids = Set(projet.pistes[rang].clips.map(\.id))
        agir("Supprimer la piste") { $0.remove(at: rang) }
        selection.subtract(ids)
    }

    // MARK: Importer un son

    /// Musique de fond, ambiance : le fichier est copie dans le projet, pose a
    /// l'instant donne (la tete par defaut) sur une piste sous les voix, et
    /// joue tel quel, sans le traitement de la voix. Plusieurs fichiers se
    /// suivent.
    func importerSon(a t: Double? = nil) {
        guard let projet else { return }
        guard let dossier = projet.dossierPrises else {
            Montage.prevenir("Enregistrez d'abord le projet (Fichier, Enregistrer sous) : "
                             + "le son importé est copié dans son dossier.")
            return
        }
        let panneau = NSOpenPanel()
        panneau.allowedContentTypes = [.audio]
        panneau.allowsMultipleSelection = true
        panneau.prompt = "Importer"
        panneau.message = "Musique, ambiance : le son se pose sous les voix, à la tête de lecture."
        guard panneau.runModal() == .OK else { return }
        var debut = max(0, t ?? tete)
        var nouveaux: [Clip] = []
        for url in panneau.urls {
            do {
                let copie = try Montage.copier(url, dans: dossier)
                let f = try AVAudioFile(forReading: copie)
                let duree = Double(f.length) / f.processingFormat.sampleRate
                guard duree > 0.05 else { continue }
                nouveaux.append(Clip(fichier: copie.lastPathComponent, debut: debut, entree: 0, sortie: duree,
                                     nom: url.deletingPathExtension().lastPathComponent,
                                     dureeSource: duree, voix: false))
                debut += duree
                Journal.ecrire(String(format: "son importe : %@ (%.1f s)", copie.lastPathComponent, duree))
            } catch {
                Journal.erreur("import impossible : \(url.lastPathComponent)", error)
                Montage.prevenir("Impossible de lire « \(url.lastPathComponent) » comme un son.")
            }
        }
        guard !nouveaux.isEmpty else { return }
        agir(nouveaux.count > 1 ? "Importer des sons" : "Importer un son") { pistes in
            let i = Edition.pisteDeSon(pour: nouveaux, dans: &pistes)
            Edition.poser(nouveaux.map { ClipPlace(piste: i, clip: $0) }, dans: &pistes)
        }
        selection = Set(nouveaux.map(\.id))
    }

    /// Copie dans le dossier des prises, sans jamais ecraser un fichier deja la.
    private static func copier(_ url: URL, dans dossier: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
        let nom = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var cible = dossier.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: cible.path) {
            cible = dossier.appendingPathComponent("\(nom)-\(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: url, to: cible)
        return cible
    }

    static func prevenir(_ texte: String) {
        let a = NSAlert()
        a.messageText = "Script Voice"
        a.informativeText = texte
        a.runModal()
    }

    // MARK: Tete de lecture

    func avancer(images: Int) {
        guard let lecteur else { return }
        let t = max(0, lecteur.tete + Double(images) * Edition.image)
        deplacerTete(t)
    }

    /// Fleches haut et bas : point de montage precedent ou suivant.
    func pointDeMontage(suivant: Bool) {
        guard let projet else { return }
        let points = Edition.points(projet.pistes)
        let t = tete
        let cible = suivant ? points.first { $0 > t + 0.001 } : points.last { $0 < t - 0.001 }
        if let cible { deplacerTete(cible) }
    }

    func allerAuDebut() { deplacerTete(0) }
    func allerALaFin() { deplacerTete(projet?.duree ?? 0) }

    func deplacerTete(_ t: Double) {
        guard let lecteur else { return }
        if lecteur.enLecture, let projet { lecteur.jouer(projet, depuis: t) } else { lecteur.tete = t }
    }
}

/// Un element de menu qui execute un bloc : le clic droit en est fait.
final class ActionMenu: NSObject {
    let bloc: () -> Void
    init(_ bloc: @escaping () -> Void) { self.bloc = bloc }
    @objc func lancer() { bloc() }

    static func item(_ titre: String, _ touche: String = "", _ mods: NSEvent.ModifierFlags = .command,
                     actif: Bool = true, _ bloc: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: titre, action: actif ? #selector(lancer) : nil, keyEquivalent: touche)
        item.keyEquivalentModifierMask = mods
        let cible = ActionMenu(bloc)
        item.target = cible
        item.representedObject = cible
        item.isEnabled = actif
        return item
    }
}
