#!/bin/sh
# Builds the shared core (core/, the assistant-core submodule) for this Mac and puts it where the
# app links it: Generated/AssistantCore.xcframework (the library, with its C header and module) and
# Generated/AssistantCore.swift (UniFFI's bindings). Run by the build (see project.yml).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cd "$here/core"
cargo build --release --lib --target aarch64-apple-darwin
# Bindings from a build for this machine (the release library is stripped of what UniFFI reads).
cargo build --lib
out="$here/Generated"
tmp=$(mktemp -d)
cargo run --bin uniffi-bindgen -- generate --library target/debug/libassistant_core.dylib --language swift --no-format --out-dir "$tmp"
mkdir -p "$tmp/headers"
mv "$tmp/AssistantCoreFFI.h" "$tmp/headers/"
# The module the bindings import, as a framework's headers name it.
mv "$tmp/AssistantCoreFFI.modulemap" "$tmp/headers/module.modulemap"
rm -rf "$out/AssistantCore.xcframework"
mkdir -p "$out"
xcodebuild -quiet -create-xcframework -library target/aarch64-apple-darwin/release/libassistant_core.a -headers "$tmp/headers" -output "$out/AssistantCore.xcframework"
cp "$tmp/AssistantCore.swift" "$out/AssistantCore.swift"
rm -rf "$tmp"
