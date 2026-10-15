#!/bin/bash
# Fabrique Script Voice.app depuis les sources. Sans Xcode : swift build + bundle monte a la main.
# L'app est signee ad-hoc, ce qui suffit pour que macOS retienne l'autorisation du micro.
set -e
cd "$(dirname "$0")/.."
RACINE="$PWD"
CONFIG="${1:-debug}"

echo "Compilation ($CONFIG)..."
swift build -c "$CONFIG" --arch x86_64
BIN="$RACINE/.build/x86_64-apple-macosx/$CONFIG/ScriptVoice"

# La version release est universelle : Intel et puces Apple (M1 a M4), sans
# Rosetta. Le compilateur de cette machine Intel produit aussi l'arm64, et lipo
# reunit les deux en un seul executable. Le debug reste Intel seul : deux fois
# plus rapide a construire, et c'est la machine des essais.
if [ "$CONFIG" = "release" ]; then
    # dossier de travail a part : partage avec l'Intel, la description de
    # construction de l'un fait echouer l'autre (« command not registered »)
    swift build -c release --arch arm64 --scratch-path "$RACINE/.build/arm64"
    BIN_ARM="$(swift build -c release --arch arm64 --scratch-path "$RACINE/.build/arm64" --show-bin-path)/ScriptVoice"
    mkdir -p "$RACINE/.build/universel"
    lipo -create "$BIN" "$BIN_ARM" \
         -output "$RACINE/.build/universel/ScriptVoice"
    BIN="$RACINE/.build/universel/ScriptVoice"
fi

APP="$RACINE/dist/Script Voice.app"

rm -rf "$APP"
# fr.lproj : sans lui, AppKit parle anglais (« Annuler Typing » dans le menu).
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$BIN" "$APP/Contents/MacOS/ScriptVoice"
cp "$RACINE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$RACINE/Resources/ScriptVoice.icns" "$APP/Contents/Resources/ScriptVoice.icns"

# Signature ad-hoc : sans elle, macOS redemande l'acces au micro a chaque lancement.
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null

# Une archive prete a envoyer (WhatsApp, mail) : ditto garde la signature et
# les attributs du paquet, qu'un zip ordinaire peut abimer.
if [ "$CONFIG" = "release" ]; then
    rm -f "$RACINE/dist/Script Voice.zip"
    ditto -c -k --keepParent "$APP" "$RACINE/dist/Script Voice.zip"
    echo "Archive : $RACINE/dist/Script Voice.zip ($(lipo -archs "$APP/Contents/MacOS/ScriptVoice"))"
fi

echo "Pret : $APP"
