# Script Voice — guide pour Claude Code

Application macOS native en Swift, construite sans Xcode. Machine cible : MacBook Pro
Intel 2018, macOS Sequoia, architecture x86_64.

## Construire et regarder

```bash
bash tools/build.sh
open -n "dist/Script Voice.app" --args --capture /tmp/vue.png 4
```

`bash tools/build.sh release` construit une application universelle (Intel et puces
Apple M1 à M4, sans Rosetta) et l'archive prête à envoyer, `dist/Script Voice.zip`.
Le compilateur de cette machine Intel produit aussi l'arm64 ; lipo réunit les deux.
L'arm64 se construit dans son propre dossier (`.build/arm64`) : partager `.build`
avec l'Intel fait échouer l'un ou l'autre (« command not registered »). Le debug
reste Intel seul, deux fois plus rapide.

Envoyée à quelqu'un d'autre, l'application n'est signée qu'ad hoc : au premier
lancement, macOS la bloque, et il faut Réglages Système › Confidentialité et
sécurité › Ouvrir quand même. Le traitement vocal ne dépend d'aucun autre
logiciel : ses valeurs sont écrites dans `Voix.swift`.

Aide › Envoyer le journal prépare un fichier (diagnostic, architecture, journal
complet), le met dans le presse-papier comme un fichier copié dans le Finder, et
explique le geste : Commande V dans WhatsApp, Messages ou Mail. Le menu de partage
du système (`NSSharingServicePicker`) ne s'ouvrait pas depuis une instance d'essai
et ne se voit pas dans une capture : il a été écarté. `--essai-envoyer` le vérifie
sur un presse-papier privé.

Toujours vérifier une modification d'interface avec `--capture` : `screencapture` ne
voit pas les fenêtres sans l'autorisation d'enregistrement d'écran, alors que
l'application a toujours le droit de se dessiner elle-même.

## Pièges rencontrés, et leur cause

Une scène SwiftUI `WindowGroup` ne produit aucune fenêtre quand l'application est
construite hors de Xcode : rien ne plante, la boucle d'événements tourne, et l'écran
reste vide. La fenêtre est donc montée en AppKit dans `main.swift`.

Lire `AVAudioEngine.inputNode` avant que macOS n'ait accordé l'accès au micro fige le
fil principal : l'application ne s'affiche jamais. Le périphérique n'est appliqué qu'au
moment d'enregistrer, autorisation en poche.

`PDFView.scaleFactorForSizeToFit` vaut zéro tant que la vue n'a pas sa taille : forcer
l'échelle à ce moment rend le document invisible. `autoScales` s'en charge seul.

Un PDF rangé dans `~/Documents` n'est pas lisible par l'application tant que macOS n'a
pas demandé l'autorisation à l'utilisateur. En ligne de commande, la demande ne peut pas
s'afficher et la lecture échoue en silence : pour un essai, copier le PDF dans `/tmp`.

L'export vers MP3 passe par un WAV intermédiaire. Il doit aller dans un dossier
temporaire : écrire à côté de la cible écrase, puis efface, un export précédent du
même nom.

## Ce que le banc d'essai a trouve

`--autotest` a mis au jour six defauts reels, tous corriges :

Le deplacement d'un clip repartait de sa position deja deplacee a chaque
rafraichissement : le clip filait a l'autre bout de la timeline.

L'export en MP3 ecrivait son WAV intermediaire a cote de la cible, puis le
supprimait : un export WAV precedent du meme nom disparaissait.

Ajouter un champ au modele rendait illisibles tous les projets enregistres
avant, le decodage synthetise par Swift exigeant toutes les cles. Les
structures se decodent desormais champ par champ, avec un repli pour chacun.

`onAppear` etant appele plusieurs fois, le projet se rechargeait et le
prompteur repartait du debut en pleine lecture.

La tete de lecture suivait le temps du premier lecteur : une piste sans clip a
cet instant la laissait figee, et la lecture ne s'arretait jamais en fin de
montage.

Le mode `--capture` photographiait des l'apparition de la fenetre et quittait
aussitot, ce qui faisait croire a un prompteur fige alors qu'il avancait.

## Organisation

| Fichier | Rôle |
|---|---|
| `main.swift` | point d'entrée AppKit, fenêtre, menu |
| `Modele.swift` | projet, pistes, clips, réglages, lecture et écriture sur disque |
| `Audio.swift` | liste des micros, enregistrement, vumètre |
| `Lecteur.swift` | lecture du montage et export |
| `Editeur.swift` | éditeur de texte et prompteur |
| `Timeline.swift` | formes d'onde, dessin des clips, le geste unique, clic droit |
| `Montage.swift` | commandes de montage (`Edition`), sélection et presse-papier (`Montage`) |
| `Barres.swift` | barre de commande (sous le script), bande des pistes, réglages |
| `VisionneusePDF.swift` | colonne du support |
| `Capture.swift` | mode de contrôle visuel |

## Le micro change de format en cours de prise

Un périphérique USB ne livre pas forcément le même format du début à la fin. Le
Yeti Nano commence en entiers 24 bits entrelacés, puis passe en flottants
désentrelacés au bout d'une soixantaine de millisecondes. Un `AVAudioConverter`
bâti une fois pour toutes sur le format du premier tampon refuse alors tous les
suivants — erreur -50, `paramErr` — et la prise fait deux centièmes de seconde.

`Audio.swift` compare donc le format d'entrée à chaque tampon et refait le
convertisseur dès qu'il change. Le format de sortie, lui, reste figé au premier
tampon : c'est lui qui donne son taux au fichier.

Le banc d'essai enregistre sur CHAQUE entrée disponible, pas seulement sur le
micro intégré : c'est ce qui manquait pour voir le défaut, le micro intégré ne
changeant jamais de format.

## La mise en forme du script n'est pas du RTF

Les polices système (`NSFont.systemFont`) ne se sérialisent pas en RTF : la
taille survit, le gras non. La mise en forme est donc enregistrée dans
`projet.json` sous forme de plages (`Marque`), avec un rang de taille et non un
corps en points. Rien ne dépend du nom d'une police, et changer la taille du
texte dans les réglages fait suivre les titres.

## Le texte collé prend le style du script

Coller depuis une page web apportait sa police, son corps et sa couleur : du noir,
illisible sur le fond sombre, et un corps relevé comme « Petite » à l'enregistrement.
`ChampScript` (Editeur.swift) lit tout ce qui vient d'ailleurs en texte brut, par
`readSelection(from:type:)`, chemin commun au collage, au dépôt et aux Services : le
texte prend le style de la frappe. Ce que le script copie lui-même porte la marque
`fr.lfd.scriptvoice.script` et garde son gras et ses titres. `--essai-coller` colle
un passage noir en Times 11 à la fin du script, pour la capture.

## Le lecteur se tait au bout de deux secondes

Confier un fichier à `AVAudioPlayerNode` (`scheduleSegment`, `scheduleFile`) le
laisse lire la prise lui-même au fil de l'eau. Sur cette machine, il s'arrête
au bout de deux secondes : le moteur tourne, la tête avance, le temps du
lecteur aussi, mais il ne sort plus que du silence. Mesuré hors de
l'application, sur un son de synthèse, en 16 bits, 24 bits et flottants : même
résultat à chaque fois.

`Lecteur.swift` lit donc chaque clip en mémoire et le confie au lecteur avec
`scheduleBuffer`, un lecteur par clip, tous lancés au même instant.

Le banc d'essai mesure la crête de ce qui sort du mélangeur après trois
secondes. Regarder seulement si la tête avance ne voit rien.

## Le traitement vocal

Chaque prise passe par une chaîne de voix off écrite dans `Voix.swift` :
compresseur, de-esser, égaliseur, plus un volume de clip à -6 dB. Aucun greffon
extérieur. Le gain de sortie du compresseur (+7 dB) passe après son limiteur :
la voix de référence avait des crêtes au-dessus de 0 dBFS, ce qu'un limiteur en
bout de chaîne aurait interdit. Il se coupe dans Réglages › Voix.

Le zéro de la ligne de volume d'un clip est le son traité, -6 dB compris.
La ligne va de -30 à +30 dB, et un plafond à -1 dBFS empêche toute saturation.
Le traitement se fait sur la prise entière, une fois, gardé en mémoire
(`PrisesTraitees`) pour la lecture, l'export et la forme d'onde.

Le de-esser sépare les bandes en Linkwitz-Riley. Retrancher un passe-haut du
signal laissait, par déphasage, la sifflante dans le grave : -0,6 dB au lieu de -6.

## La timeline ne prend qu'un seul geste

Toute la souris passe par un seul `DragGesture`, posé sur le montage entier et
mesuré dans son repère, qui ne bouge jamais (`VueTimeline`, Timeline.swift).
Les clips sont dessinés, ils ne reçoivent rien : chaque clic est rapporté au
clip qu'il touche par le calcul, à partir du modèle (`toucher`).

Deux essais l'ont imposé. Un geste posé APRÈS le `.offset` d'un clip recevait
la position dans la piste : le début comptait deux fois, la lame ne coupait
juste que le clip posé à zéro. Posé AVANT, il se mesurait dans un repère qui
bougeait avec le clip tiré : le déplacement tremblait et sautait, surtout sans
aimantation pour le retenir.

Un déplacement ne touche au modèle qu'au lâcher : pendant le geste, un aperçu.
L'éditeur de texte ne repose plus son style à chaque rafraîchissement de la
fenêtre, ce qui ralentissait chaque mouvement dans la timeline.

`--essai-lame 3,6,8` et `--essai-annuler` le vérifient par de vrais clics.

## Aucun clip n'en cache un autre

Règle des couloirs (`Edition.poser`, Montage.swift) : un clip
posé sur une place prise monte sur la première piste du dessus libre à cet
endroit ; s'il n'y en a pas, une piste se crée juste au-dessus de la piste
visée, et ce qui s'y trouvait reste entier, sur la piste devenue celle du
dessous. Vaut pour le déplacement, le collage, la duplication et la prise :
la prise en cours choisit dès le départ une piste libre jusqu'au bout.

## Les sons importés

Fichier › Importer un son (Majuscule Commande I, Commande I étant l'italique)
ou le clic droit sur la timeline (« Importer un son ici »). Le fichier est
copié dans `prises/` sans jamais en écraser un autre, et devient un clip
`voix: false` : joué tel quel, sans le traitement vocal ni son -6 dB,
dessiné dans le vert de l'application. Il se pose sous les voix
(`Edition.pisteDeSon`) : sur la dernière piste si elle ne porte que des sons et
a la place, sinon sur une piste « Son n » neuve, tout en bas. Le projet doit
être enregistré, puisque le son est copié dans son dossier.

Le PDF se ferme par le X en haut à droite de la page, ou Fichier › Fermer le
PDF ; Fichier › Importer un PDF remplace celui qui est ouvert.

## Enregistrement automatique et disposition

Le projet s'enregistre tout seul 0,7 s après la dernière modification, quelle
qu'elle soit (`Projet.enregistrerSiChange`, déclenché par `objectWillChange` dans
main.swift). Il n'est écrit que si son JSON a changé, et sans ligne au journal.
Un projet neuf, sans dossier, attend son premier Enregistrer sous.

La largeur de la colonne du PDF et la hauteur de la timeline vivent dans les
réglages du projet (`largeurPDF`, `hauteurTimeline`). SwiftUI ne dit rien de ses
séparateurs : `Disposition` (App.swift) retrouve les NSSplitView qu'il pose, les
relève quand on les tire et les replace à l'ouverture d'un projet. La colonne du
script garde 560 points au minimum.

## La barre de commande se resserre

Pendant une prise, la vitesse du prompteur s'ajoute à la barre. Avec un PDF large,
la barre débordait de sa colonne et le bouton d'enregistrement disparaissait. Le
bloc de gauche est un `ViewThatFits` : `RangeeCentree` lui donne la place laissée
par le timecode et les boutons de droite, et il choisit la forme la plus complète
qui tient. Ordre des renoncements : le choix du micro, le gain, les outils de
montage, un vumètre court. Le bouton d'enregistrement ne part jamais.

## Reprendre un projet

À la fermeture, le dossier du projet ouvert est retenu (`Reprise`, Reprise.swift,
dans les réglages utilisateur) ; au lancement suivant, une feuille propose de le
rouvrir ou de passer. Fichier › Ouvert récemment liste les douze derniers projets
(`Recents`), le dernier en tête, comme VS Code ; un projet introuvable en est
retiré. Les modes d'essai (tout argument commençant par `--`) ne retiennent et ne
proposent rien. `--essai-reprise <dossier>` montre la feuille.

L'application force l'apparence sombre (`NSApp.appearance`) : ses feuilles,
alertes et panneaux suivaient le système et s'ouvraient en clair. Une feuille
SwiftUI a en plus besoin d'un fond plein : son fond translucide ne se dessine
pas dans une capture.

## Les commandes de montage

Elles vivent dans `Edition` (sur les pistes seules, vérifiées par le banc
d'essai) et `Montage` (sélection, presse-papier, annulation). Le clavier n'y
touche que quand le script n'a pas le clavier.

| Geste | Effet |
|---|---|
| clic, Commande-clic, Majuscule-clic, rectangle sur le vide | sélection |
| Commande A, Majuscule Commande A, Échap | tout sélectionner, rien |
| Commande C, X, V, D | copier, couper, coller en insérant à la tête, dupliquer |
| Option V | coller sur une piste libre, sans rien pousser |
| Option-glisser | copie |
| Supprimer, Majuscule Supprimer | supprimer en refermant, laisser un blanc |
| Commande B, Majuscule Commande B | lame à la tête : sélection ou piste active, toutes les pistes |
| Option [ et Option ] (^ et $ en AZERTY) | élaguer le début, la fin, jusqu'à la tête |
| bord d'un clip, outil Sélection | élague en entraînant la suite (ripple) |
| bord d'un clip, outil Élaguer (T) | élague sans rien décaler, s'arrête au voisin |
| virgule, point (; et : en AZERTY), avec Majuscule | décaler d'une image, de dix |
| flèches gauche et droite, avec Majuscule | tête d'une image, de dix |
| flèches haut et bas, Début, Fin | point de montage précédent, suivant, début, fin |
| espace, L, K | lecture, lecture, arrêt |
| N, V | aimantation, désactiver le clip |
| Contrôle = et Contrôle - | volume à plus ou moins 1 dB |
| poignées en haut de l'onde | fondus d'entrée et de sortie, en quart de sinus (+3 dB) |
| Commande + et -, Majuscule Z, pincer | zoom, tout le montage à l'écran |
| clic droit, Contrôle-clic | menu contextuel avec tout cela, plus nouvelle piste au-dessus ou en dessous, supprimer la piste |

Non faits : lecture arrière (J), outil Plage (R), marqueurs (M).

## Le clavier entre le script et la timeline

La timeline ne prend jamais le clavier d'elle-même : après un clic dedans, le
script le gardait et espace y écrivait un espace au lieu de lancer la lecture.
Le geste de la timeline retire donc le clavier au script dès le clic
(`commencer`, Timeline.swift). Cliquer ailleurs (bouton rouge, barre) le lui
laisse : pendant une prise, espace met alors le prompteur en pause ; après un
clic dans la timeline, espace arrête la prise. La touche se juge sur la fenêtre
de l'événement, pas sur `NSApp.keyWindow`. Le curseur du script se lit dans le
champ même quand il n'a plus le clavier : le prompteur repart de là.

Un clic simulé n'atteint pas le champ de texte d'une instance lancée depuis le
terminal : macOS refuse de l'activer, et un champ inactif ignore son premier clic.
`--essai-focus` donne donc le clavier au script directement.

## Une seule pile d'annulation

Commande Z défait la dernière action, qu'elle soit du texte ou du montage. Le
montage range ses gestes dans la pile de la fenêtre, celle que remplit déjà
l'éditeur de texte (`Projet.retenir`, Modele.swift) : l'ordre réel des actions
est respecté. Chaque geste retient l'état des pistes AVANT d'agir, et
l'annulation retient celui qu'elle quitte, ce qui donne Rétablir.

Les commandes Annuler et Rétablir du menu visent cette pile directement : après
un clic dans la timeline, aucun champ n'a le clavier, et une commande envoyée
« au premier répondeur » ne trouvait personne.

Sans `fr.lproj` dans le paquet, AppKit parle anglais : « Annuler Typing ».

## Modes de contrôle en ligne de commande

- `--essai-prise <secondes>` : démarre une vraie prise par le chemin de
  l'interface, l'arrête, et écrit le bilan au journal (tampons reçus, écrits,
  rejets et leur raison).
- `--essai-lecture <secondes>` : rejoue le montage depuis le début et écrit
  au journal, chaque seconde, la tête, le temps du lecteur et la crête du son
  qui sort. Placé après `--essai-prise`, il réécoute la prise qui vient d'être faite.
- `--essai-volume <dB>` : règle le premier clip et laisse son étiquette de
  volume affichée, pour la capture.
- `--essai-reglages` : ouvre le panneau des réglages.
- `--essai-timeline` : deux clips sélectionnés, des fondus, un clip désactivé.
- `--essai-defile <points>` : fait descendre les pistes, pour voir la règle rester en haut.
- `--essai-lame 3,6,8` : coupe le premier clip à ces instants, par de vrais
  clics, et écrit au journal les bornes des clips après chaque coupe.
- `--essai-annuler` : deux coupes, un déplacement, du texte tapé, puis
  Commande Z et Commande Majuscule Z par le menu, état noté à chaque étape.
  Les clics simulés ne portent que si macOS accepte d'activer l'instance.
- `--essai-focus` : script, clic dans la timeline, espace, et écrit au journal
  qui a le clavier et si la lecture tourne.
- `--autotest --sans-micro` : saute l'essai d'enregistrement, quand une autre
  application tient le micro.
- `--essai-envoyer` : Aide › Envoyer le journal, sur un presse-papier privé.
- `--essai-coller` : colle à la fin du script un passage noir en Times, venu d'ailleurs.
- `--essai-palette` : sélectionne la première ligne pour faire apparaître la
  palette de mise en forme.
- `--essai-format gras,taille3` : applique ces commandes à la sélection.
- `--capture <png> [secondes]` : photographie l'application, panneaux flottants
  compris. Ce mode ne prend pas le clavier : voler le focus enverrait les
  frappes de l'utilisateur au prompteur.

## Les minuteries du systeme ne tirent pas a l'heure

`Timer.scheduledTimer` depend de la boucle d'evenements et macOS le regroupe
avec d'autres pour economiser la batterie. Mesure sur cette application : un
battement regle sur 50 ms restait muet cinq secondes d'affilee puis rattrapait
d'un coup. Le chrono sautait de 2,2 s a 7,4 s, la forme d'onde avancait par
paquets de deux cents tranches, et le prompteur ne bougeait pas de la prise.
Rien ne plantait : l'application avait simplement l'air morte.

`Battement` (Battement.swift) utilise une source dispatch marquee `.strict`,
qui refuse ce regroupement. L'enregistreur et le lecteur prennent en plus un
jeton `ProcessInfo.beginActivity` le temps de leur travail.

Le banc d'essai compte les tirs sur une seconde : moins de quinze, c'est un
echec.

