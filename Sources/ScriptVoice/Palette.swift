import AppKit

/// La palette de mise en forme : elle apparaît au-dessus du texte sélectionné,
/// et disparaît dès qu'on désélectionne.
///
/// C'est un panneau non activant : il se montre sans prendre le clavier, sans
/// quoi le simple fait de l'afficher effacerait la sélection qu'il sert à mettre
/// en forme. Son dessin reprend celui de la barre d'outils du haut — même fond,
/// même carré d'état vert sur l'outil actif — plutôt qu'une bulle rapportée.
@MainActor
final class PaletteTexte {
    private let panneau: NSPanel
    private let fond = VueFondPalette()
    private var boutons: [String: BoutonPalette] = [:]
    private weak var vue: NSTextView?
    /// taille de référence du script, celle des réglages
    var policeBase: Double = 15

    /// Les quatre tailles, en facteur de la taille de base.
    static let tailles: [(nom: String, facteur: Double, corps: CGFloat)] = [
        ("Petite", 0.80, 9), ("Normale", 1.00, 11), ("Grande", 1.45, 13), ("Très grande", 2.00, 16),
    ]

    init() {
        panneau = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 34),
                          styleMask: [.nonactivatingPanel, .borderless],
                          backing: .buffered, defer: false)
        panneau.isFloatingPanel = true
        panneau.level = .floating
        panneau.backgroundColor = .clear
        panneau.isOpaque = false
        panneau.hasShadow = true
        panneau.hidesOnDeactivate = true
        panneau.contentView = fond
        monter()
    }

    private func monter() {
        var x: CGFloat = 9
        func ajouter(_ cle: String, _ symbole: String?, _ titre: NSAttributedString?,
                     _ aide: String, _ largeur: CGFloat) {
            let b = BoutonPalette(frame: NSRect(x: x, y: 5, width: largeur, height: 24))
            if let symbole {
                b.image = NSImage(systemSymbolName: symbole, accessibilityDescription: aide)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
                b.imagePosition = .imageOnly
                b.title = ""                       // sinon AppKit dessine « Button »
                b.estTexte = false
            } else if let titre {
                b.attributedTitle = titre
                b.estTexte = true
            }
            b.toolTip = aide
            b.cle = cle
            b.palette = self
            boutons[cle] = b
            fond.addSubview(b)
            x += largeur + 2
        }

        ajouter("gras", "bold", nil, "Gras", 28)
        ajouter("italique", "italic", nil, "Italique", 28)
        ajouter("souligne", "underline", nil, "Souligné", 28)

        let filet = NSView(frame: NSRect(x: x + 5, y: 8, width: 1, height: 18))
        filet.wantsLayer = true
        filet.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        fond.addSubview(filet)
        x += 12

        for (i, t) in PaletteTexte.tailles.enumerated() {
            let titre = NSAttributedString(string: "T", attributes: [
                .font: NSFont.systemFont(ofSize: t.corps, weight: .semibold),
                .foregroundColor: NSColor(white: 0.62, alpha: 1),
            ])
            ajouter("taille\(i)", nil, titre, t.nom, 28)
        }
        panneau.setContentSize(NSSize(width: x + 7, height: 34))
        fond.frame = NSRect(x: 0, y: 0, width: x + 7, height: 34)
    }

    // MARK: Apparition

    /// Montre la palette au-dessus de la sélection, ou la cache s'il n'y en a pas.
    func suivre(_ vue: NSTextView, fenetre: NSWindow?) {
        self.vue = vue
        let plage = vue.selectedRange()
        guard plage.length > 0, vue.isEditable, let fenetre,
              let lm = vue.layoutManager, let conteneur = vue.textContainer else {
            cacher(); return
        }
        let glyphes = lm.glyphRange(forCharacterRange: plage, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphes, in: conteneur)
        r.origin.x += vue.textContainerInset.width
        r.origin.y += vue.textContainerInset.height
        let dansFenetre = vue.convert(r, to: nil)
        let surEcran = fenetre.convertToScreen(dansFenetre)

        let taille = panneau.frame.size
        var x = surEcran.midX - taille.width / 2
        var y = surEcran.maxY + 9
        // Elle se pose au-dessus de la sélection, sauf s'il n'y a pas la place
        // dans la zone de texte : elle masquerait alors la barre d'outils.
        let hautDuTexte = fenetre.convertToScreen(vue.convert(vue.bounds, to: nil)).maxY
        if y + taille.height > hautDuTexte { y = surEcran.minY - taille.height - 9 }
        if let visible = fenetre.screen?.visibleFrame {
            x = min(max(visible.minX + 8, x), visible.maxX - taille.width - 8)
            if y < visible.minY { y = surEcran.maxY + 9 }
        }
        panneau.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        if panneau.parent == nil { fenetre.addChildWindow(panneau, ordered: .above) }
        panneau.orderFront(nil)
        rafraichir(vue, plage)
    }

    func cacher() {
        panneau.parent?.removeChildWindow(panneau)
        panneau.orderOut(nil)
    }

    /// Allume les boutons qui décrivent déjà la sélection.
    private func rafraichir(_ vue: NSTextView, _ plage: NSRange) {
        guard let storage = vue.textStorage else { return }
        var gras = true, italique = true, souligne = true
        var corps: CGFloat?
        var melange = false
        storage.enumerateAttributes(in: plage) { attributs, _, _ in
            let f = attributs[.font] as? NSFont ?? NSFont.systemFont(ofSize: self.policeBase)
            let traits = NSFontManager.shared.traits(of: f)
            if !traits.contains(.boldFontMask) { gras = false }
            if !traits.contains(.italicFontMask) { italique = false }
            let s = attributs[.underlineStyle] as? Int ?? 0
            if s == 0 { souligne = false }
            if let c = corps, abs(c - f.pointSize) > 0.4 { melange = true } else { corps = f.pointSize }
        }
        boutons["gras"]?.actif = gras
        boutons["italique"]?.actif = italique
        boutons["souligne"]?.actif = souligne
        for (i, t) in PaletteTexte.tailles.enumerated() {
            let attendu = CGFloat(policeBase * t.facteur)
            boutons["taille\(i)"]?.actif = !melange && corps != nil && abs(corps! - attendu) < 0.6
        }
    }

    // MARK: Les actions, passées au coordinateur

    var action: ((String) -> Void)?

    /// Le menu Format passe par là : il ne connaît pas l'éditeur ouvert, il
    /// annonce la commande et c'est l'éditeur qui a le focus qui l'applique.
    static let commande = Notification.Name("fr.lfd.scriptvoice.miseEnForme")

    static func demander(_ cle: String) {
        NotificationCenter.default.post(name: commande, object: cle)
    }

    fileprivate func declencher(_ cle: String) {
        action?(cle)
        if let vue, vue.selectedRange().length > 0 { rafraichir(vue, vue.selectedRange()) }
    }
}

/// Le fond du panneau : un aplat sourd et un liseré, comme la barre d'outils.
private final class VueFondPalette: NSView {
    override func draw(_ rect: NSRect) {
        let chemin = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor(white: 0.20, alpha: 1).setFill()
        chemin.fill()
        NSColor(white: 0.30, alpha: 1).setStroke()
        chemin.lineWidth = 1
        chemin.stroke()
    }
    override var isFlipped: Bool { false }
}

/// Un bouton de la palette : pas de relief, un carré d'état quand il est actif.
private final class BoutonPalette: NSButton {
    var cle = ""
    var estTexte = false
    var actif = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .shadowlessSquare
        wantsLayer = true
        layer?.cornerRadius = 3
        contentTintColor = NSColor(white: 0.62, alpha: 1)
        target = self
        action = #selector(cliquer)
    }
    required init?(coder: NSCoder) { nil }

    weak var palette: PaletteTexte?

    @objc private func cliquer() { palette?.declencher(cle) }

    override func draw(_ rect: NSRect) {
        if actif {
            NSColor(white: 0.30, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        let teinte = actif ? NSColor(red: 0.41, green: 0.81, blue: 0.59, alpha: 1)
                           : NSColor(white: 0.62, alpha: 1)
        contentTintColor = teinte
        if estTexte {
            let m = NSMutableAttributedString(attributedString: attributedTitle)
            m.addAttribute(.foregroundColor, value: teinte,
                           range: NSRange(location: 0, length: m.length))
            let taille = m.size()
            m.draw(at: NSPoint(x: ((bounds.width - taille.width) / 2).rounded(),
                               y: ((bounds.height - taille.height) / 2).rounded()))
        } else {
            super.draw(rect)
        }
    }
}
