#!/bin/bash
# Builds and runs the test suite. Optional integration checks against a real server (nothing stored):
#   IMMICH_URL=https://immich.example.com IMMICH_API_KEY=... [IMMICH_DUPLICATE_FILE=photo-already-in-immich.jpg] Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/obj
swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" -o build/obj/tests \
  $(ls App/Sources/*.swift | grep -v '/App.swift$') Tests/Tests.swift
build/obj/tests
