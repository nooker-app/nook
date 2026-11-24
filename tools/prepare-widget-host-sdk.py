#!/usr/bin/env python3
"""Expose weak-linked host blur declarations to the macOS widget target only."""

import argparse
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sdk", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
source = args.sdk / "System/Library/Frameworks/WidgetKit.framework"
destination = args.output / "WidgetKit.framework"

# Never edit the installed SDK or embed this copy. Its linker stub still points
# to Apple's system framework. Declaration changes belong in DerivedData only.
if destination.resolve().is_relative_to(args.sdk.resolve()):
    raise SystemExit("The widget overlay must be outside the installed SDK")
files = [
    "WidgetKit.tbd",
    "Headers/WidgetKit.h",
    "Headers/WGWidgetDefines.h",
    "Modules/module.modulemap",
    "Modules/WidgetKit.swiftmodule/arm64e-apple-macos.swiftinterface",
    "Modules/WidgetKit.swiftmodule/x86_64-apple-macos.swiftinterface",
]
for relative in files:
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((source / "Versions/A" / relative).read_bytes())

declarations = """
// Nook's optional host blur request. Weak imports plus the runtime symbol gate
// in NookWidgetHostBackground keep an absent private API off the fallback path.
@_weakLinked public enum WidgetBackgroundStyle {
    case transparent
    case blur
    case opaque
}
extension SwiftUI.WidgetConfiguration {
    @_weakLinked nonisolated public func preferredBackgroundStyle(_ style: WidgetKit.WidgetBackgroundStyle) -> some SwiftUI.WidgetConfiguration
}
"""
interfaces = list((destination / "Modules/WidgetKit.swiftmodule").glob("*.swiftinterface"))
if not interfaces:
    raise SystemExit("WidgetKit Swift interfaces are missing from this SDK")
for interface in interfaces:
    original = interface.read_text()
    if "preferredBackgroundStyle" in original or "enum WidgetBackgroundStyle" in original:
        raise SystemExit("WidgetKit background declarations changed; review the optional host bridge")
    interface.write_text(original + declarations)
