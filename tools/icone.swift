import AppKit
import Foundation

// Dessine l'icone de Script Voice et ecrit le jeu .iconset.
//
// Le motif vient de l'application elle-meme : le prompteur, ou tout ce qui a
// deja ete lu reste surligne et ou une barre marque l'endroit exact ou l'on en
// est. Quatre lignes de script, les deux premieres lues, la troisieme a moitie,
// la derniere encore a venir.

let vert = NSColor(red: 0.41, green: 0.81, blue: 0.59, alpha: 1)
let gris = NSColor(red: 0.31, green: 0.35, blue: 0.34, alpha: 1)
let fond = NSColor(red: 0.071, green: 0.082, blue: 0.078, alpha: 1)

/// Les icones macOS vivent dans un carre de 824 sur une toile de 1024.
func dessiner(_ taille: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: taille, height: taille))
    image.lockFocus()
    let k = taille / 1024
    NSGraphicsContext.current?.imageInterpolation = .high

    let cote: CGFloat = 824 * k
    let origine = (taille - cote) / 2
    let cadre = NSRect(x: origine, y: origine, width: cote, height: cote)
    let coque = NSBezierPath(roundedRect: cadre, xRadius: 185 * k, yRadius: 185 * k)

    // Une ombre portee douce, comme toutes les icones du Dock.
    NSGraphicsContext.saveGraphicsState()
    let ombre = NSShadow()
    ombre.shadowColor = NSColor(white: 0, alpha: 0.45)
    ombre.shadowBlurRadius = 26 * k
    ombre.shadowOffset = NSSize(width: 0, height: -12 * k)
    ombre.set()
    fond.setFill()
    coque.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Un eclairement a peine marque en haut : un aplat parfaitement plat fait
    // un carre mort a cote des autres icones du systeme.
    NSGraphicsContext.saveGraphicsState()
    coque.addClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.055), ending: NSColor(white: 1, alpha: 0))?
        .draw(in: cadre, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Les lignes du script.
    let gauche = origine + 128 * k
    let utile = cote - 256 * k
    let hauteurLigne: CGFloat = 112 * k
    let interligne: CGFloat = 76 * k
    let bloc = 4 * hauteurLigne + 3 * interligne
    var y = origine + (cote + bloc) / 2 - hauteurLigne

    let lignes: [(largeur: CGFloat, lu: CGFloat)] = [
        (1.00, 1.00),   // lue
        (0.84, 1.00),   // lue
        (0.95, 0.56),   // en cours : le surlignage s'arrete au milieu
        (0.60, 0.00),   // pas encore dite
    ]

    for ligne in lignes {
        let l = utile * ligne.largeur
        let r = hauteurLigne / 2
        // la part non lue
        gris.setFill()
        NSBezierPath(roundedRect: NSRect(x: gauche, y: y, width: l, height: hauteurLigne),
                     xRadius: r, yRadius: r).fill()
        // la part deja dite, par-dessus
        if ligne.lu > 0 {
            vert.setFill()
            let lue = l * ligne.lu
            let chemin = NSBezierPath(roundedRect: NSRect(x: gauche, y: y, width: lue, height: hauteurLigne),
                                      xRadius: r, yRadius: r)
            if ligne.lu < 1 {
                // bord droit net : c'est une frontiere de lecture, pas une pastille
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: gauche, y: y - 4 * k,
                                          width: lue, height: hauteurLigne + 8 * k)).addClip()
                NSBezierPath(roundedRect: NSRect(x: gauche, y: y, width: lue + r, height: hauteurLigne),
                             xRadius: r, yRadius: r).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                chemin.fill()
            }
        }
        y -= hauteurLigne + interligne
    }

    // La barre de lecture, posee la ou le surlignage s'arrete.
    let x = gauche + utile * 0.95 * 0.56
    let hautBarre = origine + (cote + bloc) / 2 - hauteurLigne
                  - 2 * (hauteurLigne + interligne) - 46 * k
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 11 * k, y: hautBarre,
                                     width: 22 * k, height: hauteurLigne + 92 * k),
                 xRadius: 11 * k, yRadius: 11 * k).fill()

    image.unlockFocus()
    return image
}

let sortie = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Icone.iconset"
try? FileManager.default.createDirectory(atPath: sortie, withIntermediateDirectories: true)

let jeu: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (nom, taille) in jeu {
    let image = dessiner(taille)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: sortie).appendingPathComponent(nom))
}
print("iconset ecrit : \(sortie)")
