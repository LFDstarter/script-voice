import AppKit
import Combine
import SwiftUI

/// L'editeur de script, et le prompteur qui vit dedans.
///
/// Le prompteur ne touche jamais au texte : il pose des attributs temporaires
/// sur le gestionnaire de disposition. Couper l'enregistrement rend donc
/// exactement le texte tape, sans la moindre trace de couleur.

@MainActor
final class Prompteur: ObservableObject {
    @Published var actif = false
    @Published var enPause = false
    @Published var index = 0              // mot courant
    @Published var vitesse: Double = 145  // mots par minute

    var mots: [NSRange] = []
    /// Le mot ou la lecture a commence : avant lui, rien n'a ete dit, donc rien
    /// n'est surligne meme si le texte le precede.
    private(set) var depart = 0
    private let battement = Battement()
    private var reste: Double = 0

    /// Demarre au mot qui suit le curseur : on se place dans le texte, on lance,
    /// et la lecture part de la ou l'on regarde.
    func demarrer(texte: String, depuis position: Int) {
        mots = Prompteur.decouper(texte)
        index = mots.firstIndex { $0.location >= position } ?? 0
        depart = index
        actif = true
        enPause = false
        reste = 0
        battre()
    }

    func arreter() {
        battement.arreter()
        actif = false
        enPause = false
    }

    func pause() { enPause.toggle() }

    /// Les fleches rattrapent : on avance ou on recule d'une poignee de mots.
    func rattraper(_ sens: Int) {
        index = max(0, min(mots.count - 1, index + sens * 4))
        depart = min(depart, index)
    }

    private func battre() {
        battement.lancer(toutes: 1.0 / 20) { [weak self] in
            guard let self, self.actif, !self.enPause else { return }
            self.reste += (self.vitesse / 60) / 20          // mots par battement
            while self.reste >= 1 {
                self.reste -= 1
                if self.index < self.mots.count - 1 { self.index += 1 }
            }
        }
    }

    static func decouper(_ texte: String) -> [NSRange] {
        var plages: [NSRange] = []
        let ns = texte as NSString
        texte.enumerateSubstrings(in: texte.startIndex..., options: .byWords) { _, r, _, _ in
            plages.append(NSRange(r, in: texte))
        }
        _ = ns
        return plages
    }
}

// MARK: - Le champ

/// Le texte colle prend le style du script, jamais celui d'ou il vient : une
/// page web ou un traitement de texte apportent leur police, leur corps et leur
/// couleur, souvent du noir, illisible sur le fond sombre. Seul un copier-coller
/// a l'interieur du script garde sa mise en forme (gras, titres), reconnu a la
/// marque que le champ pose sur ce qu'il copie.
final class ChampScript: NSTextView {
    static let marque = NSPasteboard.PasteboardType("fr.lfd.scriptvoice.script")

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let ecrit = super.writeSelection(to: pboard, types: types)
        if ecrit { marquer(pboard) }
        return ecrit
    }

    /// Copier et couper passent par le presse-papier general : on y pose la
    /// marque apres coup, quel que soit le chemin pris par AppKit.
    override func copy(_ sender: Any?) {
        super.copy(sender)
        marquer(.general)
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        marquer(.general)
    }

    private func marquer(_ pboard: NSPasteboard) {
        guard pboard.types?.contains(Self.marque) == false else { return }
        pboard.addTypes([Self.marque], owner: nil)
        pboard.setString("1", forType: Self.marque)
    }

    /// Coller, deposer, Services : tout passe par ici. Venu d'ailleurs, le
    /// texte est lu brut, et le champ lui donne le style courant de la frappe.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if pboard.types?.contains(Self.marque) == true || type == .string {
            return super.readSelection(from: pboard, type: type)
        }
        guard pboard.string(forType: .string) != nil else { return false }
        return super.readSelection(from: pboard, type: .string)
    }
}

// MARK: - La vue

struct Editeur: NSViewRepresentable {
    @Binding var texte: String
    @Binding var format: [Marque]
    @ObservedObject var prompteur: Prompteur
    var police: Double
    var interligne: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChampScript.scrollableTextView()
        guard let vue = scroll.documentView as? NSTextView else { return scroll }
        if !(vue is ChampScript) { Journal.ecrire("le champ du script n'est pas un ChampScript") }
        vue.delegate = context.coordinator
        // Le script se met en forme : titres plus gros, passages en gras. Ce
        // sont des reperes de lecture, pas de la decoration.
        vue.isRichText = true
        vue.isAutomaticQuoteSubstitutionEnabled = false
        vue.isAutomaticDashSubstitutionEnabled = false
        vue.usesFontPanel = false
        vue.allowsUndo = true
        vue.backgroundColor = NSColor(white: 0.07, alpha: 1)
        vue.insertionPointColor = NSColor(red: 0.41, green: 0.81, blue: 0.59, alpha: 1)
        vue.textColor = NSColor(white: 0.92, alpha: 1)
        vue.textContainerInset = NSSize(width: 26, height: 22)
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.07, alpha: 1)
        context.coordinator.vue = vue
        context.coordinator.charger(texte: texte, marques: format, police: police, interligne: interligne)
        // Le coordinateur ecoute le prompteur directement. S'en remettre au cycle
        // de rafraichissement de SwiftUI ne suffisait pas : la vue recevait bien
        // des mises a jour, mais le surlignage restait fige sur le premier mot.
        context.coordinator.suivre(prompteur)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let vue = scroll.documentView as? NSTextView else { return }
        // Le texte n'est repose que s'il vient d'ailleurs : le reecrire a chaque
        // rafraichissement effacerait la mise en forme et la position du curseur.
        if vue.string != texte, !context.coordinator.ecritParLUtilisateur {
            context.coordinator.charger(texte: texte, marques: format, police: police, interligne: interligne)
        }
        vue.isEditable = !prompteur.actif          // on ne tape pas pendant qu'on lit
        // Le style ne se repose que s'il a change : le reposer sur tout le texte a
        // chaque rafraichissement de la fenetre ralentissait la timeline, qui en
        // provoque des dizaines par seconde quand on tire un clip.
        if context.coordinator.styleChange(police: police, interligne: interligne) {
            context.coordinator.appliquerStyle(police: police, interligne: interligne)
        }
        context.coordinator.peindre(prompteur)
        if prompteur.actif { context.coordinator.palette.cacher() }
    }

    func makeCoordinator() -> Coordinateur { Coordinateur(self) }

    @MainActor final class Coordinateur: NSObject, NSTextViewDelegate {
        let parent: Editeur
        weak var vue: NSTextView?
        let palette = PaletteTexte()
        /// vrai tant que la frappe en cours vient du clavier, pas du modele
        private(set) var ecritParLUtilisateur = false
        private var dernierIndex = -1
        private var policeAppliquee: Double = 0
        private var abonnement: AnyCancellable?

        func suivre(_ prompteur: Prompteur) {
            abonnement = prompteur.objectWillChange.sink { [weak self, weak prompteur] _ in
                DispatchQueue.main.async {
                    guard let prompteur else { return }
                    self?.peindre(prompteur)
                }
            }
        }

        init(_ parent: Editeur) {
            self.parent = parent
            super.init()
            palette.action = { [weak self] cle in self?.mettreEnForme(cle) }
            NotificationCenter.default.addObserver(forName: PaletteTexte.commande,
                                                   object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let cle = note.object as? String,
                          self.vue?.window?.firstResponder === self.vue else { return }
                    self.mettreEnForme(cle)
                }
            }
        }

        /// Pose le script dans la vue, puis sa mise en forme par-dessus.
        func charger(texte: String, marques: [Marque], police: Double, interligne: Double) {
            guard let vue else { return }
            vue.string = texte
            policeAppliquee = 0
            appliquerStyle(police: police, interligne: interligne)
            appliquer(marques, police: police)
        }

        func textDidChange(_ notification: Notification) {
            guard let vue = notification.object as? NSTextView else { return }
            ecritParLUtilisateur = true
            parent.texte = vue.string
            parent.format = marques(de: vue)
            DispatchQueue.main.async { [weak self] in self?.ecritParLUtilisateur = false }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let vue else { return }
            palette.policeBase = policeAppliquee > 0 ? policeAppliquee : 15
            palette.suivre(vue, fenetre: vue.window)
        }

        /// Releve la mise en forme de la vue, plage par plage. On n'enregistre
        /// ni police ni corps en points : seulement ce que l'utilisateur a
        /// demande, pour que le script se relise partout a l'identique.
        private func marques(de vue: NSTextView) -> [Marque] {
            guard let storage = vue.textStorage, storage.length > 0 else { return [] }
            let base = policeAppliquee > 0 ? policeAppliquee : 15
            let gestionnaire = NSFontManager.shared
            var releve: [Marque] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { a, p, _ in
                let f = a[.font] as? NSFont ?? NSFont.systemFont(ofSize: base)
                let traits = gestionnaire.traits(of: f)
                // la taille la plus proche parmi les quatre proposees
                let rapport = Double(f.pointSize) / base
                let rang = PaletteTexte.tailles.enumerated().min {
                    abs($0.element.facteur - rapport) < abs($1.element.facteur - rapport)
                }?.offset ?? 1
                let m = Marque(debut: p.location, longueur: p.length,
                               gras: traits.contains(.boldFontMask),
                               italique: traits.contains(.italicFontMask),
                               souligne: (a[.underlineStyle] as? Int ?? 0) != 0,
                               taille: rang)
                guard !m.neutre else { return }
                // deux plages voisines de meme aspect n'en font qu'une
                if var derniere = releve.last, derniere.debut + derniere.longueur == m.debut,
                   derniere.gras == m.gras, derniere.italique == m.italique,
                   derniere.souligne == m.souligne, derniere.taille == m.taille {
                    derniere.longueur += m.longueur
                    releve[releve.count - 1] = derniere
                } else {
                    releve.append(m)
                }
            }
            return releve
        }

        /// Repose la mise en forme sur un texte qui vient d'etre charge.
        private func appliquer(_ marques: [Marque], police: Double) {
            guard let vue, let storage = vue.textStorage, storage.length > 0 else { return }
            let gestionnaire = NSFontManager.shared
            storage.beginEditing()
            for m in marques {
                let plage = NSRange(location: m.debut, length: m.longueur)
                guard plage.location >= 0, NSMaxRange(plage) <= storage.length, plage.length > 0
                else { continue }
                let rang = min(max(0, m.taille), PaletteTexte.tailles.count - 1)
                var f = NSFont.systemFont(ofSize: police * PaletteTexte.tailles[rang].facteur)
                if m.gras { f = gestionnaire.convert(f, toHaveTrait: .boldFontMask) }
                if m.italique { f = gestionnaire.convert(f, toHaveTrait: .italicFontMask) }
                storage.addAttribute(.font, value: f, range: plage)
                if m.souligne {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: plage)
                }
            }
            storage.endEditing()
        }

        /// Le style de base. La taille reglee dans les Reglages est celle du
        /// corps de texte : quand elle change, tout le script suit dans la meme
        /// proportion, et un titre mis en grand reste grand.
        private var interligneApplique: Double = 0

        func styleChange(police: Double, interligne: Double) -> Bool {
            abs(policeAppliquee - police) > 0.01 || abs(interligneApplique - interligne) > 0.001
        }

        func appliquerStyle(police: Double, interligne: Double) {
            interligneApplique = interligne
            guard let vue, let storage = vue.textStorage else { return }
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = interligne
            p.paragraphSpacing = police * 0.5
            let base = NSFont.systemFont(ofSize: police, weight: .regular)
            vue.defaultParagraphStyle = p
            vue.typingAttributes = [.font: base, .foregroundColor: NSColor(white: 0.92, alpha: 1),
                                    .paragraphStyle: p]
            let tout = NSRange(location: 0, length: storage.length)
            guard tout.length > 0 else { policeAppliquee = police; return }

            let changementDeTaille = policeAppliquee > 0 && abs(policeAppliquee - police) > 0.01
            storage.beginEditing()
            storage.addAttributes([.paragraphStyle: p, .foregroundColor: NSColor(white: 0.92, alpha: 1)],
                                  range: tout)
            if policeAppliquee <= 0 { storage.addAttributes([.font: base], range: tout) }
            storage.endEditing()
            let anciennes = changementDeTaille ? marques(de: vue) : []
            policeAppliquee = police
            // Le corps de texte a change de taille : les titres suivent, puisque
            // leur taille est un rapport et non un nombre de points.
            if changementDeTaille {
                storage.beginEditing()
                storage.addAttributes([.font: base], range: tout)
                storage.endEditing()
                appliquer(anciennes, police: police)
            }
        }

        // MARK: La mise en forme demandee par la palette

        private func mettreEnForme(_ cle: String) {
            guard let vue, let storage = vue.textStorage else { return }
            let plage = vue.selectedRange()
            guard plage.length > 0 else { return }
            let gestionnaire = NSFontManager.shared
            let base = policeAppliquee > 0 ? policeAppliquee : 15

            vue.shouldChangeText(in: plage, replacementString: nil)
            storage.beginEditing()
            switch cle {
            case "gras", "italique":
                let trait: NSFontTraitMask = cle == "gras" ? .boldFontMask : .italicFontMask
                // Si toute la selection porte deja le trait, le clic l'enleve.
                var partout = true
                storage.enumerateAttribute(.font, in: plage) { valeur, _, _ in
                    let f = valeur as? NSFont ?? NSFont.systemFont(ofSize: base)
                    if !gestionnaire.traits(of: f).contains(trait) { partout = false }
                }
                storage.enumerateAttribute(.font, in: plage) { valeur, p, _ in
                    let f = valeur as? NSFont ?? NSFont.systemFont(ofSize: base)
                    let n = partout ? gestionnaire.convert(f, toNotHaveTrait: trait)
                                    : gestionnaire.convert(f, toHaveTrait: trait)
                    storage.addAttribute(.font, value: n, range: p)
                }
            case "souligne":
                var partout = true
                storage.enumerateAttribute(.underlineStyle, in: plage) { valeur, _, _ in
                    if (valeur as? Int ?? 0) == 0 { partout = false }
                }
                storage.addAttribute(.underlineStyle,
                                     value: partout ? 0 : NSUnderlineStyle.single.rawValue,
                                     range: plage)
            default:
                guard cle.hasPrefix("taille"), let i = Int(cle.dropFirst(6)),
                      i < PaletteTexte.tailles.count else { break }
                let corps = CGFloat(base * PaletteTexte.tailles[i].facteur)
                storage.enumerateAttribute(.font, in: plage) { valeur, p, _ in
                    let f = valeur as? NSFont ?? NSFont.systemFont(ofSize: base)
                    storage.addAttribute(.font, value: gestionnaire.convert(f, toSize: corps), range: p)
                }
            }
            storage.endEditing()
            vue.didChangeText()
            parent.format = marques(de: vue)
            vue.setSelectedRange(plage)
        }

        /// Peint d'un seul tenant tout ce qui a deja ete dit, mot courant compris.
        /// La frontiere du surlignage est l'endroit ou l'on en est : c'est elle
        /// qu'on suit des yeux, pas un mot isole qui clignote.
        /// Rien n'est ecrit dans le texte : ce sont des attributs temporaires de
        /// la mise en page, et couper le prompteur rend le texte intact.
        func peindre(_ prompteur: Prompteur) {
            guard let vue, let lm = vue.layoutManager else { return }
            let tout = NSRange(location: 0, length: (vue.string as NSString).length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: tout)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: tout)
            guard prompteur.actif, !prompteur.mots.isEmpty else { dernierIndex = -1; return }

            let i = min(prompteur.index, prompteur.mots.count - 1)
            let d = min(prompteur.depart, i)
            let courant = prompteur.mots[i]
            let debut = prompteur.mots[d].location
            let fin = courant.location + courant.length
            let dit = NSRange(location: debut, length: max(0, fin - debut))
            let marque: [NSAttributedString.Key: Any] = [
                .backgroundColor: NSColor(red: 0.41, green: 0.81, blue: 0.59, alpha: 0.26),
                .foregroundColor: NSColor(white: 1, alpha: 1)
            ]
            // Ligne par ligne, et sans le retour a la ligne : un fond pose sur un
            // saut de ligne s'etire jusqu'au bord droit et barre les paragraphes
            // vides d'un bandeau qui n'a jamais ete lu.
            let ns = vue.string as NSString
            ns.enumerateSubstrings(in: dit, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
                guard r.length > 0 else { return }
                lm.addTemporaryAttributes(marque, forCharacterRange: r)
            }

            if i != dernierIndex {
                dernierIndex = i
                vue.scrollRangeToVisible(NSRange(location: courant.location,
                                                 length: min(400, tout.length - courant.location)))
            }
        }
    }
}
