#!/bin/sh
# Builds the web app's note editor on its own (web/dist/embed) and copies it into the app, where
# Files shows .md notes in it (see Assistant/NoteEditor.swift). Run after changing the editor.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
web="$here/../web"
[ -d "$web/node_modules" ] || (cd "$web" && npm ci)
(cd "$web" && npm run -s build:embed)
rm -rf "$here/Assistant/Editor"
cp -R "$web/dist/embed" "$here/Assistant/Editor"
echo "Copied the editor into Assistant/Editor ($(du -sh "$here/Assistant/Editor" | cut -f1))."
