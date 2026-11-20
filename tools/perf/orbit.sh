#!/usr/bin/env bash
set -euo pipefail
# Real production canvas and projection, with deterministic metadata fixtures.
# Opens a foreground native benchmark window, runs 260 frames, then exits.
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nook-orbit.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cp "$root/NookKit/Sources/NookKit/RecommendationMap/RecommendationCanvas.swift" "$scratch/Canvas.swift"
cp "$root/NookKit/Sources/NookKit/RecommendationMap/RecommendationOrbit.swift" "$scratch/Orbit.swift"
cp "$root/NookKit/Sources/NookKit/RecommendationMap/RecommendationSphere.swift" "$scratch/Sphere.swift"
cp "$root/tools/perf/orbit/"*.swift "$scratch/"
xcrun swiftc -O -D DEBUG -parse-as-library "$scratch/"*.swift -o "$scratch/OrbitBench"
"$scratch/OrbitBench"
