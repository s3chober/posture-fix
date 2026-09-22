#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/posture-analyzer-tests"

swiftc \
    "$ROOT/Sources/PostureFix/PostureAnalyzer.swift" \
    "$ROOT/Tests/PostureAnalyzerTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
