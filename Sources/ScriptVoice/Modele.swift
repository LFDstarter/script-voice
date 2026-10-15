import AppKit
import Foundation
import SwiftUI

/// Un projet Script Voice est un dossier sur le disque, rien d'autre.
///
///     MonProjet.scriptvoice/
///         projet.json      le script, sa mise en forme, les pistes, les reglages
///         prises/          un wav par prise, jamais modifie
///
/// Les prises ne sont jamais retouchees : couper un clip ne fait que bouger
/// deux bornes dans projet.json. On peut donc toujours revenir en arriere, et
/// un projet reste lisible meme si l'application disparait.

// MARK: - Le montage

/// Les trois structures ci-dessous se decodent champ par champ, avec une valeur
/// de repli pour chacun. Le decodage synthetise par Swift, lui, exige que toutes
/// les cles soient presentes : ajouter un reglage rendrait alors illisibles tous
/// les projets enregistres avant. Un projet doit survivre aux versions.
struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    /// nom du fichier dans prises/, sans le chemin : un projet reste deplaçable
    var fichier: String
    /// position du debut du clip sur la timeline
    var debut: Double
    /// bornes a l'interieur du fichier source
    var entree: Double
    var sortie: Double
    var nom: String = ""
    /// volume du clip en dB, au-dessus ou au-dessous du traitement de la voix ;
    /// 0 rend la voix telle que le traitement vocal la donne
    var volume: Double = 0
    /// duree totale du fichier source, pour borner l'elagage
    var dureeSource: Double = 0
    /// fondus audio, en secondes, tires depuis les poignees en haut du clip
    var fonduEntree: Double = 0
    var fonduSortie: Double = 0
    /// un clip desactive (touche V) reste en place mais ne sonne plus
    var actif = true
    /// une prise de voix passe par le traitement vocal ; un son
    /// importe (musique, ambiance) est joue tel quel
    var voix = true

    var duree: Double { max(0, sortie - entree) }
    var fin: Double { debut + duree }
    func contient(_ t: Double) -> Bool { t >= debut && t < fin }

    enum CodingKeys: String, CodingKey {
        case id, fichier, debut, entree, sortie, nom, volume, dureeSource
        case fonduEntree, fonduSortie, actif, voix
        case gain           // ancien reglage lineaire, lu seulement
    }

    init(id: UUID = UUID(), fichier: String, debut: Double, entree: Double, sortie: Double,
         nom: String = "", volume: Double = 0, dureeSource: Double = 0, voix: Bool = true) {
        self.id = id; self.fichier = fichier; self.debut = debut; self.entree = entree
        self.sortie = sortie; self.nom = nom; self.volume = volume; self.dureeSource = dureeSource
        self.voix = voix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fichier = try c.decodeIfPresent(String.self, forKey: .fichier) ?? ""
        debut = try c.decodeIfPresent(Double.self, forKey: .debut) ?? 0
        entree = try c.decodeIfPresent(Double.self, forKey: .entree) ?? 0
        sortie = try c.decodeIfPresent(Double.self, forKey: .sortie) ?? 0
        nom = try c.decodeIfPresent(String.self, forKey: .nom) ?? ""
        if let v = try c.decodeIfPresent(Double.self, forKey: .volume) {
            volume = v
        } else if let g = try c.decodeIfPresent(Double.self, forKey: .gain), g > 0 {
            volume = 20 * log10(g)
        }
        dureeSource = try c.decodeIfPresent(Double.self, forKey: .dureeSource) ?? sortie
        fonduEntree = try c.decodeIfPresent(Double.self, forKey: .fonduEntree) ?? 0
        fonduSortie = try c.decodeIfPresent(Double.self, forKey: .fonduSortie) ?? 0
        actif = try c.decodeIfPresent(Bool.self, forKey: .actif) ?? true
        voix = try c.decodeIfPresent(Bool.self, forKey: .voix) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fichier, forKey: .fichier)
        try c.encode(debut, forKey: .debut)
        try c.encode(entree, forKey: .entree)
        try c.encode(sortie, forKey: .sortie)
        try c.encode(nom, forKey: .nom)
        try c.encode(volume, forKey: .volume)
        try c.encode(dureeSource, forKey: .dureeSource)
        try c.encode(fonduEntree, forKey: .fonduEntree)
        try c.encode(fonduSortie, forKey: .fonduSortie)
        try c.encode(actif, forKey: .actif)
        try c.encode(voix, forKey: .voix)
    }
}

struct Piste: Identifiable, Codable, Equatable {
    var id = UUID()
    var nom: String
    var clips: [Clip] = []
    var muette: Bool = false
    var solo: Bool = false

    enum CodingKeys: String, CodingKey { case id, nom, clips, muette, solo }

    init(id: UUID = UUID(), nom: String, clips: [Clip] = [],
         muette: Bool = false, solo: Bool = false) {
        self.id = id; self.nom = nom; self.clips = clips; self.muette = muette; self.solo = solo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        nom = try c.decodeIfPresent(String.self, forKey: .nom) ?? "Voix"
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        muette = try c.decodeIfPresent(Bool.self, forKey: .muette) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
    }
}

// MARK: - Les reglages

struct Reglages: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case policeEditeur, interligneEditeur, vitessePrompteur, peripheriqueID
        case gainEntree, formatExport, zoomTimeline, aimantation, voixJenaate
        case largeurPDF, hauteurTimeline
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policeEditeur = try c.decodeIfPresent(Double.self, forKey: .policeEditeur) ?? 19
        interligneEditeur = try c.decodeIfPresent(Double.self, forKey: .interligneEditeur) ?? 1.5
        vitessePrompteur = try c.decodeIfPresent(Double.self, forKey: .vitessePrompteur) ?? 145
        peripheriqueID = try c.decodeIfPresent(String.self, forKey: .peripheriqueID) ?? ""
        gainEntree = try c.decodeIfPresent(Double.self, forKey: .gainEntree) ?? 1
        formatExport = try c.decodeIfPresent(String.self, forKey: .formatExport) ?? "wav"
        zoomTimeline = try c.decodeIfPresent(Double.self, forKey: .zoomTimeline) ?? 60
        aimantation = try c.decodeIfPresent(Bool.self, forKey: .aimantation) ?? true
        voixJenaate = try c.decodeIfPresent(Bool.self, forKey: .voixJenaate) ?? true
        largeurPDF = try c.decodeIfPresent(Double.self, forKey: .largeurPDF) ?? 0
        hauteurTimeline = try c.decodeIfPresent(Double.self, forKey: .hauteurTimeline) ?? 0
    }

    var policeEditeur: Double = 19
    var interligneEditeur: Double = 1.5
    var vitessePrompteur: Double = 145      // mots par minute
    var peripheriqueID: String = ""         // UID CoreAudio du micro choisi
    var gainEntree: Double = 1.0
    var formatExport: String = "wav"
    var zoomTimeline: Double = 60           // pixels par seconde
    var aimantation: Bool = true
    /// le traitement vocal (Voix.swift) sur toutes les prises
    var voixJenaate: Bool = true
    /// La disposition de la fenetre, retrouvee a l'ouverture du projet :
    /// largeur de la colonne du PDF, hauteur de la timeline. 0 : celle par defaut.
    var largeurPDF: Double = 0
    var hauteurTimeline: Double = 0
}

/// Une plage du script mise en forme. Les tailles sont relatives — un rang
/// dans la liste des tailles, pas un corps en points : changer la taille du
/// texte dans les reglages doit faire suivre les titres, pas les laisser en
/// arriere. Et rien ici ne depend du nom d'une police, qui ne survit pas d'une
/// machine a l'autre.
struct Marque: Codable, Equatable {
    var debut: Int
    var longueur: Int
    var gras = false
    var italique = false
    var souligne = false
    /// rang dans `PaletteTexte.tailles` ; 1 est la taille du corps de texte
    var taille = 1

    var neutre: Bool { !gras && !italique && !souligne && taille == 1 }

    enum CodingKeys: String, CodingKey { case debut, longueur, gras, italique, souligne, taille }

    init(debut: Int, longueur: Int, gras: Bool = false, italique: Bool = false,
         souligne: Bool = false, taille: Int = 1) {
        self.debut = debut; self.longueur = longueur; self.gras = gras
        self.italique = italique; self.souligne = souligne; self.taille = taille
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        debut = try c.decodeIfPresent(Int.self, forKey: .debut) ?? 0
        longueur = try c.decodeIfPresent(Int.self, forKey: .longueur) ?? 0
        gras = try c.decodeIfPresent(Bool.self, forKey: .gras) ?? false
        italique = try c.decodeIfPresent(Bool.self, forKey: .italique) ?? false
        souligne = try c.decodeIfPresent(Bool.self, forKey: .souligne) ?? false
        taille = try c.decodeIfPresent(Int.self, forKey: .taille) ?? 1
    }
}

// MARK: - Le projet

final class Projet: ObservableObject, Codable {
    @Published var script: String = ""
    /// La mise en forme du script, par plages. Le texte brut reste la
    /// référence — c'est lui que lit le prompteur — et la mise en forme n'est
    /// qu'une couche posée dessus, qu'un projet peut parfaitement ne pas avoir.
    @Published var scriptFormat: [Marque] = []
    @Published var pistes: [Piste] = [Piste(nom: "Voix 1")]
    @Published var reglages = Reglages()
    @Published var pdf: String = ""         // chemin absolu du PDF ouvert a cote

    /// dossier .scriptvoice ; nil tant que le projet n'a pas ete enregistre
    @Published var dossier: URL?
    @Published var modifie = false

    init() {}

    enum CodingKeys: String, CodingKey { case script, scriptFormat, pistes, reglages, pdf }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        scriptFormat = try c.decodeIfPresent([Marque].self, forKey: .scriptFormat) ?? []
        pistes = try c.decodeIfPresent([Piste].self, forKey: .pistes) ?? [Piste(nom: "Voix 1")]
        reglages = try c.decodeIfPresent(Reglages.self, forKey: .reglages) ?? Reglages()
        pdf = try c.decodeIfPresent(String.self, forKey: .pdf) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(script, forKey: .script)
        try c.encode(scriptFormat, forKey: .scriptFormat)
        try c.encode(pistes, forKey: .pistes)
        try c.encode(reglages, forKey: .reglages)
        try c.encode(pdf, forKey: .pdf)
    }

    var dossierPrises: URL? { dossier?.appendingPathComponent("prises") }

    func urlDe(_ clip: Clip) -> URL? { dossierPrises?.appendingPathComponent(clip.fichier) }

    /// Fin du montage, pour dimensionner la timeline et l'export.
    var duree: Double { pistes.flatMap(\.clips).map(\.fin).max() ?? 0 }

    // MARK: Annuler

    /// La pile d'annulation de la fenetre, celle-la meme que remplit l'editeur
    /// de texte : frappes et gestes de montage s'y rangent dans l'ordre ou on
    /// les a faits, et Commande Z les defait dans l'ordre inverse, quoi qu'ils soient.
    @MainActor static var annulation: UndoManager? {
        if let pileEssai { return pileEssai }
        return NSApp.windows.first { $0.sheetParent == nil && $0.contentView?.premierTexte() != nil }?.undoManager
    }

    /// Retient l'etat du montage AVANT une action. `avant` sert quand l'action
    /// est deja faite et qu'on ne sait qu'apres si elle a eu lieu (une coupe
    /// au ras du bord ne coupe rien, et ne doit rien laisser a annuler).
    @MainActor func retenir(_ nom: String, avant: [Piste]? = nil) {
        guard let pile = Projet.annulation else { return }
        // La frappe en cours se referme : sans cela, le texte tape apres un
        // geste de montage rejoignait le meme paquet que le texte tape avant.
        NSApp.windows.lazy.compactMap { $0.contentView?.premierTexte() }.first?.breakUndoCoalescing()
        let etat = avant ?? pistes
        pile.registerUndo(withTarget: self) { p in
            MainActor.assumeIsolated { p.restaurer(etat, nom: nom) }
        }
        pile.setActionName(nom)
    }

    /// Remet le montage dans un etat retenu, et retient celui qu'on quitte :
    /// c'est ce qui rend Commande Majuscule Z possible.
    @MainActor private func restaurer(_ etat: [Piste], nom: String) {
        let quitte = pistes
        Projet.annulation?.registerUndo(withTarget: self) { p in
            MainActor.assumeIsolated { p.restaurer(quitte, nom: nom) }
        }
        Projet.annulation?.setActionName(nom)
        pistes = etat
        modifie = true
    }

    /// Le banc d'essai travaille sans fenetre : il fournit sa propre pile.
    @MainActor static var pileEssai: UndoManager?

    /// Un autre projet arrive : l'historique de l'ancien n'a plus de sens.
    @MainActor static func oublierHistorique() { annulation?.removeAllActions() }

    // MARK: Disque

    func enregistrer(dans url: URL? = nil) throws {
        guard let cible = url ?? dossier else { return }
        try FileManager.default.createDirectory(at: cible.appendingPathComponent("prises"),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: cible.appendingPathComponent("projet.json"))
        dossier = cible
        modifie = false
        dernierEcrit = try? enc.encode(self)
        Journal.ecrire("projet enregistre : \(cible.lastPathComponent)")
    }

    /// Ce qui a ete ecrit sur le disque en dernier.
    private var dernierEcrit: Data?

    /// L'enregistrement automatique, appele un instant apres chaque
    /// modification, quelle qu'elle soit : une lettre du script, un clip
    /// deplace, un reglage, la taille d'une colonne. On n'ecrit que si le
    /// projet a vraiment change, et sans rien noter au journal : il y aurait
    /// une ligne par lettre tapee.
    func enregistrerSiChange() {
        guard let dossier else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self), data != dernierEcrit else { return }
        do {
            try FileManager.default.createDirectory(at: dossier.appendingPathComponent("prises"),
                                                    withIntermediateDirectories: true)
            try data.write(to: dossier.appendingPathComponent("projet.json"), options: .atomic)
            dernierEcrit = data
            if modifie { modifie = false }
        } catch {
            Journal.erreur("enregistrement automatique impossible", error)
        }
    }

    /// Prend le contenu d'un projet lu sur le disque. La fenetre garde son
    /// propre objet : ce sont ses champs qui changent, pas l'objet.
    func reprendre(_ autre: Projet) {
        script = autre.script
        scriptFormat = autre.scriptFormat
        pistes = autre.pistes
        reglages = autre.reglages
        pdf = autre.pdf
        dossier = autre.dossier
        modifie = false
        // ce qui vient d'etre lu n'a pas a etre reecrit
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        dernierEcrit = try? enc.encode(self)
    }

    static func ouvrir(_ url: URL) throws -> Projet {
        let data = try Data(contentsOf: url.appendingPathComponent("projet.json"))
        let p = try JSONDecoder().decode(Projet.self, from: data)
        p.dossier = url
        return p
    }

    /// Enregistre sans bruit, sur une minuterie : perdre un script parce qu'on
    /// a oublie Commande-S ne doit pas pouvoir arriver.
    func enregistrerSiPossible() {
        guard dossier != nil, modifie else { return }
        try? enregistrer()
    }
}

// MARK: - Les regles de montage, verifiables sans interface

extension Piste {
    /// Coupe le clip en deux a l'instant `t` de la timeline.
    /// Les deux morceaux pointent vers le meme fichier : rien n'est reecrit.
    /// Renvoie l'identifiant du morceau de droite, ou nil si la coupe tombe
    /// hors du clip.
    mutating func couper(_ id: UUID, a t: Double) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = clips[i]
        guard t > clip.debut + 0.02, t < clip.fin - 0.02 else { return nil }
        let dans = t - clip.debut
        var gauche = clip
        gauche.sortie = clip.entree + dans
        // le fondu de sortie reste a la fin, celui d'entree au debut
        gauche.fonduSortie = 0
        gauche.fonduEntree = min(clip.fonduEntree, gauche.duree)
        var droite = clip
        droite.id = UUID()
        droite.debut = t
        droite.entree = clip.entree + dans
        droite.fonduEntree = 0
        droite.fonduSortie = min(clip.fonduSortie, droite.duree)
        clips[i] = gauche
        clips.insert(droite, at: i + 1)
        return droite.id
    }
}

enum Aimant {
    /// Cale `t` sur le point le plus proche, s'il est a portee.
    static func caler(_ t: Double, sur points: [Double], seuil: Double) -> Double {
        guard let p = points.min(by: { abs($0 - t) < abs($1 - t) }), abs(p - t) < seuil else { return t }
        return p
    }
}

// MARK: - Les outils de la timeline

enum Outil: String, CaseIterable {
    case selection, lame, elaguer, main

    var touche: String {
        switch self {
        case .selection: return "A"
        case .lame:      return "B"
        case .elaguer:   return "T"
        case .main:      return "H"
        }
    }
    var libelle: String {
        switch self {
        case .selection: return "Sélection"
        case .lame:      return "Lame de rasoir"
        case .elaguer:   return "Élaguer"
        case .main:      return "Main"
        }
    }
    var symbole: String {
        switch self {
        case .selection: return "cursorarrow"
        case .lame:      return "scissors"
        case .elaguer:   return "arrow.left.and.right.square"
        case .main:      return "hand.raised"
        }
    }
}
