import AVFoundation
import Foundation

/// Le traitement vocal : une chaîne de voix off qui enchaîne un compresseur,
/// un de-esser et un égaliseur, puis ramène le volume à -6 dB, la voix sortant
/// sinon beaucoup trop fort. Les modules sont écrits ici, sans aucun greffon
/// extérieur, avec ces valeurs :
///
///     Compresseur entrée +4,5 dB, seuil -14 dB, taux 5,8:1, genou doux,
///                 attaque 5 ms, relâchement 51 ms, détection crête,
///                 gain +2 dB, mélange 81,5 %, sortie +7 dB, limiteur -2,9 dB
///     De-esser    -6 dB au-dessus de 6 kHz, sensibilité 50 %, lissage 10 ms
///     Égaliseur   coupe-bas 40 Hz 24 dB/oct, +1 dB à 110 Hz, -1,5 dB à 500 Hz,
///                 +2 dB à 3,45 kHz, +1 dB à 4,35 kHz, plateau aigu +3 dB à 9 kHz
///     Volume      -6 dB
///
/// Le zéro de la ligne de volume d'un clip correspond à ce résultat.
enum Voix {
    /// le -6 dB que le traitement pose sur chaque clip
    static let volumeDeBase: Double = -6
    /// rien ne sort au-dessus, quel que soit le volume demandé
    static let plafond: Float = 0.891          // -1 dBFS
    static let volumeMin: Double = -30
    static let volumeMax: Double = 30

    /// Gain linéaire final d'un clip, traitement compris.
    static func gain(volume: Double, traitement: Bool) -> Float {
        Float(pow(10, (volume + (traitement ? volumeDeBase : 0)) / 20))
    }

    /// Passe un canal entier dans la chaîne. Une prise se traite d'un seul
    /// tenant : le compresseur garde ainsi la même mémoire qu'en continu, et
    /// couper un clip ne change pas le son de part et d'autre de la coupe.
    static func traiter(_ x: UnsafeMutablePointer<Float>, _ n: Int, sr: Double) {
        compresser(x, n, sr: sr)
        desser(x, n, sr: sr)
        egaliser(x, n, sr: sr)
    }

    // MARK: Compressor

    private static func compresser(_ x: UnsafeMutablePointer<Float>, _ n: Int, sr: Double) {
        let entree = db(4.5), sortie = db(7), gainComp = db(2)
        let seuil: Float = -14, taux: Float = 5.8, genou: Float = 12
        let melange: Float = 0.815
        let attaque = coef(0.005, sr), relache = coef(0.051, sr)
        let plafondLimiteur = db(-2.9)
        let relacheLimiteur = coef(0.05, sr)
        var env: Float = 0
        var gLim: Float = 1

        for i in 0..<n {
            let s = x[i] * entree
            let a = abs(s)
            env = a > env ? attaque * env + (1 - attaque) * a : relache * env + (1 - relache) * a
            let niveau = 20 * log10(max(env, 1e-9))
            let depasse = niveau - seuil
            var reduction: Float = 0
            if 2 * depasse >= genou {
                reduction = (1 / taux - 1) * depasse
            } else if 2 * depasse > -genou {
                let d = depasse + genou / 2
                reduction = (1 / taux - 1) * d * d / (2 * genou)
            }
            let comprime = s * pow(10, reduction / 20) * gainComp
            var y = melange * comprime + (1 - melange) * s
            // Limiteur, puis gain de sortie. Dans cet ordre, comme dans Final
            // Cut : les voix qui en sortaient avaient des crêtes au-dessus de
            // 0 dBFS, ce qu'un limiteur placé en bout de chaîne aurait empêché.
            let besoin = abs(y) > plafondLimiteur ? plafondLimiteur / abs(y) : 1
            gLim = besoin < gLim ? besoin : relacheLimiteur * gLim + (1 - relacheLimiteur) * besoin
            y *= gLim * sortie
            x[i] = y
        }
    }

    // MARK: DeEsser

    /// Les sifflantes se reconnaissent à leur proportion d'aigu : sur un « s »,
    /// presque toute l'énergie passe au-dessus de 6 kHz, sur une voyelle presque
    /// rien. Quand la part d'aigu dépasse le seuil, seul l'aigu est baissé.
    ///
    /// La séparation se fait en Linkwitz-Riley : les deux bandes se recomposent
    /// sans creux ni bosse. Retrancher un simple passe-haut du signal laissait,
    /// à cause du déphasage, une bonne part de la sifflante dans le grave.
    static func desser(_ x: UnsafeMutablePointer<Float>, _ n: Int, sr: Double) {
        let q = 0.7071
        var bas = [Biquad.passeBas(6000, q: q, sr: sr), Biquad.passeBas(6000, q: q, sr: sr)]
        var haut = [Biquad.passeHaut(6000, q: q, sr: sr), Biquad.passeHaut(6000, q: q, sr: sr)]
        let lissage = coef(0.010, sr), saisie = coef(0.001, sr)
        let reduction = db(-6)
        let seuil: Float = 0.45                 // sensibilité 50 %
        var envAigu: Float = 0, envTout: Float = 0, g: Float = 1
        for i in 0..<n {
            let s = x[i]
            let l = bas[1].filtrer(bas[0].filtrer(s))
            let h = haut[1].filtrer(haut[0].filtrer(s))
            envAigu = suivre(envAigu, abs(h), saisie, lissage)
            envTout = suivre(envTout, abs(s), saisie, lissage)
            let part = envAigu / max(envTout, 1e-6)
            let force = min(1, max(0, (part - seuil) / 0.2))
            let cible = 1 + (reduction - 1) * force
            g = lissage * g + (1 - lissage) * cible
            x[i] = l + h * g
        }
    }

    // MARK: Channel EQ

    private static func egaliser(_ x: UnsafeMutablePointer<Float>, _ n: Int, sr: Double) {
        // 24 dB/oct : deux cellules de Butterworth à la suite
        var filtres = [
            Biquad.passeHaut(40, q: 0.5412, sr: sr),
            Biquad.passeHaut(40, q: 1.3066, sr: sr),
            Biquad.cloche(110, gain: 1, q: 0.71, sr: sr),
            Biquad.cloche(500, gain: -1.5, q: 0.71, sr: sr),
            Biquad.cloche(3450, gain: 2, q: 0.71, sr: sr),
            Biquad.cloche(4350, gain: 1, q: 0.71, sr: sr),
            Biquad.plateauAigu(9000, gain: 3, q: 0.71, sr: sr)
        ]
        for k in filtres.indices {
            for i in 0..<n { x[i] = filtres[k].filtrer(x[i]) }
        }
    }

    // MARK: Volume du clip

    /// Applique le volume puis un plafond à -1 dBFS : on peut monter un clip
    /// de 30 dB sans que le fichier exporté ne sature.
    static func appliquerVolume(_ x: UnsafeMutablePointer<Float>, _ n: Int, gain: Float, sr: Double) {
        let relache = coef(0.08, sr)
        var g: Float = 1
        for i in 0..<n {
            let y = x[i] * gain
            let besoin = abs(y) > plafond ? plafond / abs(y) : 1
            g = besoin < g ? besoin : relache * g + (1 - relache) * besoin
            x[i] = y * g
        }
    }

    /// Les fondus d'un clip, poses sur un extrait qui commence `depuis`
    /// secondes apres le debut du clip. Courbe en quart de sinus (+3 dB au
    /// milieu, a puissance constante) : la voix ne se creuse pas au milieu.
    static func fondre(_ x: UnsafeMutablePointer<Float>, _ n: Int, sr: Double, fondus: Fondus) {
        guard fondus.entree > 0.001 || fondus.sortie > 0.001 else { return }
        for i in 0..<n {
            let t = fondus.depuis + Double(i) / sr
            var g = 1.0
            if fondus.entree > 0.001, t < fondus.entree { g *= sin(.pi / 2 * max(0, t) / fondus.entree) }
            let reste = fondus.total - t
            if fondus.sortie > 0.001, reste < fondus.sortie { g *= sin(.pi / 2 * max(0, reste) / fondus.sortie) }
            if g < 1 { x[i] *= Float(g) }
        }
    }

    struct Fondus {
        var entree: Double, sortie: Double
        /// ou commence l'extrait dans le clip, et la duree du clip entier
        var depuis: Double, total: Double
    }

    // MARK: Outils

    private static func db(_ v: Float) -> Float { pow(10, v / 20) }
    private static func coef(_ secondes: Double, _ sr: Double) -> Float {
        Float(exp(-1 / (secondes * sr)))
    }
    private static func suivre(_ env: Float, _ a: Float, _ monte: Float, _ descend: Float) -> Float {
        a > env ? monte * env + (1 - monte) * a : descend * env + (1 - descend) * a
    }
}

/// Un filtre du second ordre, d'après les formules de Robert Bristow-Johnson.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func filtrer(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    static func passeHaut(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func passeBas(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func cloche(_ f: Double, gain: Double, q: Double, sr: Double) -> Biquad {
        let A = pow(10, gain / 40), w = 2 * Double.pi * f / sr, c = cos(w)
        let alpha = sin(w) / (2 * q)
        return Biquad(1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A)
    }

    static func plateauAigu(_ f: Double, gain: Double, q: Double, sr: Double) -> Biquad {
        let A = pow(10, gain / 40), w = 2 * Double.pi * f / sr, c = cos(w)
        let alpha = sin(w) / (2 * q), r = 2 * sqrt(A) * alpha
        return Biquad(A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c),
                      A * ((A + 1) + (A - 1) * c - r),
                      (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c),
                      (A + 1) - (A - 1) * c - r)
    }
}

/// Les prises traitées, gardées en mémoire. Traiter une prise de quelques
/// minutes prend un instant : on le fait une fois, pour la lecture, l'export et
/// la forme d'onde, et on ne recommence que si le fichier change.
final class PrisesTraitees: @unchecked Sendable {
    static let partage = PrisesTraitees()
    private let verrou = NSLock()
    private var tampons: [String: AVAudioPCMBuffer] = [:]
    /// un verrou par prise : la forme d'onde et la lecture demandaient la meme
    /// prise en meme temps, et la traitaient deux fois cote a cote
    private var parPrise: [String: NSLock] = [:]

    /// La prise entière, traitée ou non, au format de lecture du fichier.
    func tampon(_ url: URL, traitement: Bool) -> AVAudioPCMBuffer? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let cle = "\(url.path)|\(date)|\(traitement)"
        verrou.lock()
        if let t = tampons[cle] { verrou.unlock(); return t }
        let attente = parPrise[cle] ?? NSLock()
        parPrise[cle] = attente
        verrou.unlock()

        // Si un autre fil traite deja cette prise, on attend son resultat.
        attente.lock()
        defer { attente.unlock() }
        verrou.lock()
        if let t = tampons[cle] { verrou.unlock(); return t }
        verrou.unlock()

        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let t = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                       frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: t)) != nil, let canaux = t.floatChannelData
        else { return nil }
        if traitement {
            for c in 0..<Int(t.format.channelCount) {
                Voix.traiter(canaux[c], Int(t.frameLength), sr: t.format.sampleRate)
            }
        }
        verrou.lock()
        // une version plus ancienne du meme fichier n'a plus rien a faire ici
        tampons = tampons.filter { !$0.key.hasPrefix("\(url.path)|") || $0.key.contains("|\(date)|") }
        tampons[cle] = t
        verrou.unlock()
        return t
    }

    /// Un morceau de prise, au volume du clip, prêt à jouer ou à mélanger.
    func extrait(_ url: URL, entree: Double, duree: Double, volume: Double,
                 traitement: Bool, fondus: Voix.Fondus? = nil) -> AVAudioPCMBuffer? {
        guard let source = tampon(url, traitement: traitement),
              let canaux = source.floatChannelData else { return nil }
        let sr = source.format.sampleRate
        let debut = max(0, Int(entree * sr))
        let nb = min(Int(source.frameLength) - debut, Int(duree * sr))
        guard nb > 0, let t = AVAudioPCMBuffer(pcmFormat: source.format,
                                               frameCapacity: AVAudioFrameCount(nb)),
              let sortie = t.floatChannelData else { return nil }
        t.frameLength = AVAudioFrameCount(nb)
        let gain = Voix.gain(volume: volume, traitement: traitement)
        for c in 0..<Int(source.format.channelCount) {
            sortie[c].update(from: canaux[c] + debut, count: nb)
            Voix.appliquerVolume(sortie[c], nb, gain: gain, sr: sr)
            if let fondus { Voix.fondre(sortie[c], nb, sr: sr, fondus: fondus) }
        }
        return t
    }
}
