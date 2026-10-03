#!/bin/bash
# Renders docs/*.png and docs/demo.gif from the app's real views with demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/obj docs
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" -o build/obj/screenshots \
  $(ls App/Sources/*.swift | grep -v '/App.swift$') tools/screenshots.swift
build/obj/screenshots docs
