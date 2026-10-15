# Script Voice

Un seul écran pour écrire sa voix off, la lire au prompteur, l'enregistrer et la monter.
Application macOS native, entièrement hors ligne : aucun compte, aucun serveur, aucune base
de données. Un projet est un dossier sur le disque.

## Ce que ça fait

- Un éditeur de script à gauche, le support en PDF à droite, la timeline en bas.
  Les trois cloisons se déplacent à la souris.
- Le prompteur part du mot où se trouve le curseur. Tout ce qui est déjà dit
  reste surligné, la frontière avance au fil de la lecture : c'est elle qu'on
  suit des yeux. Espace met en pause, les flèches haut et bas rattrapent.
- Le script se met en forme : sélectionner du texte fait apparaître une palette
  avec gras, italique, souligné et quatre tailles. Les tailles sont relatives au
  corps de texte, donc un titre reste un titre quand on change la taille générale.
  Mêmes commandes au clavier dans le menu Format.
- L'enregistrement vise le micro choisi, avec gain réglable et vumètre à segments.
  La prise s'allonge dans la timeline pendant qu'on parle, avec sa forme d'onde.
- La timeline reprend les outils des logiciels de montage : sélection (A), lame de rasoir (B),
  élaguer (T), main (H). Les prises se déplacent, se coupent et se suppriment.
- Export en WAV 24 bits, MP3 ou M4A.

## Construire

```bash
bash tools/build.sh          # produit dist/Script Voice.app (Intel)
bash tools/build.sh release  # application universelle, Intel et puces Apple,
                             # et dist/Script Voice.zip prêt à envoyer
```

Aucune dépendance : Swift et les Command Line Tools suffisent. L'application est
signée ad-hoc, ce qui permet à macOS de retenir l'autorisation du micro.

## Installer sans construire

Chaque version publiée a son archive `Script Voice.zip` dans les Releases du
dépôt. L'application n'est pas signée par un développeur Apple : au premier
lancement, macOS refuse de l'ouvrir. Il faut alors aller dans Réglages Système ›
Confidentialité et sécurité, puis cliquer « Ouvrir quand même ». Elle tourne en
natif sur les Mac Intel comme sur les puces Apple, à partir de macOS 14.

## Un projet sur le disque

```
MonProjet.scriptvoice/
    projet.json     le script, sa mise en forme, les pistes, les réglages, le PDF
    prises/         un fichier WAV par prise, jamais modifié
```

Couper un clip ne touche pas au fichier : seules deux bornes changent dans
`projet.json`. Les prises d'origine restent intactes.

## Les deux autorisations de macOS

Au premier lancement, le système demande l'accès au micro : il faut l'accorder,
sinon l'enregistrement renvoie une erreur. Et la première fois qu'un PDF rangé
dans Documents, Bureau ou Téléchargements est ouvert, macOS demande aussi
l'autorisation d'accéder à ce dossier. Sans elle, la colonne du PDF reste vide.

## Quand quelque chose se passe mal

L'application tient un journal dans `~/Library/Logs/Script Voice/journal.txt` :
lancements, ouvertures de projet, prises, exports, erreurs, et la pile d'appels
complète en cas de plantage. Le menu Aide donne quatre commandes : envoyer le
journal (il est copié comme un fichier, Commande V dans une messagerie le joint
au message), l'ouvrir dans le Finder (Commande L), copier un diagnostic complet
dans le presse-papier (Commande D) et vider le journal.

Le diagnostic contient la version, le modèle de Mac, la version de macOS, la
liste des entrées audio et les quatre-vingts dernières lignes du journal. C'est
ce qu'il faut coller pour qu'un problème soit compréhensible sans être devant
la machine.

## Le banc d'essai

```bash
"dist/Script Voice.app/Contents/MacOS/ScriptVoice" --autotest
```

Plus de cent vingt vérifications sur le montage, le disque, l'export, le prompteur,
les entrées audio, l'enregistrement et la lecture. Chacune dit ce qu'elle
attendait et ce qu'elle a obtenu. Un blocage est traité comme un échec : le banc
se coupe au bout de quatre-vingt-dix secondes plutôt que d'attendre sans fin.

```bash
"dist/Script Voice.app/Contents/MacOS/ScriptVoice" --essai-plantage
```

Provoque une erreur fatale pour vérifier que le journal en garde la trace.

## En ligne de commande

```bash
"dist/Script Voice.app/Contents/MacOS/ScriptVoice" --ouvrir /chemin/Projet.scriptvoice
"dist/Script Voice.app/Contents/MacOS/ScriptVoice" --ouvrir <projet> --exporter sortie.mp3
"dist/Script Voice.app/Contents/MacOS/ScriptVoice" --capture image.png 4
```

La dernière commande photographie la fenêtre après quatre secondes : c'est ainsi
qu'on relit une mise en page sans dépendre de l'autorisation d'enregistrement d'écran.

## Licence

Script Voice est un logiciel libre, publié sous la licence GNU GPL version 3
(voir `LICENSE`). Vous pouvez l'utiliser, l'étudier, le modifier et le
redistribuer ; toute version modifiée que vous distribuez doit l'être sous la
même licence, avec son code source.
