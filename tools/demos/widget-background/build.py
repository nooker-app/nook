#!/usr/bin/env python3
"""Build an isolated WidgetKit background experiment; never a release input."""

import argparse
import plistlib
from pathlib import Path
import subprocess


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=Path("/tmp/nook-glass-widget-demo"))
parser.add_argument("--identity", default="-", help="Signing identity for local widget registration")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
source = Path(__file__).resolve().parent
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
sdk = Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
framework = root / "Frameworks/WidgetKit.framework"
run("/usr/bin/python3", repo / "tools/prepare-widget-host-sdk.py", "--sdk", sdk,
    "--output", framework.parent)
# Additional experiment only: distinguish a transparent background preference
# from transparent widget host chrome. Never part of the production SDK overlay.
for interface in (framework / "Modules/WidgetKit.swiftmodule").glob("*.swiftinterface"):
    with interface.open("a") as output:
        output.write("\nextension SwiftUI.WidgetConfiguration {\n"
                     "    @_weakLinked nonisolated public func backgroundStyle(_ style: WidgetKit.WidgetBackgroundStyle) -> some SwiftUI.WidgetConfiguration\n}\n")

app = root / "Nook Glass Lab.app"
extension = app / "Contents/PlugIns/GlassLabWidgets.appex"
for bundle, name, identifier, kind in [
    (app, "Nook Glass Lab", "com.tim.nook.glasslab", "APPL"),
    (extension, "GlassLabWidgets", "com.tim.nook.glasslab.widgets", "XPC!"),
]:
    (bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    info = {
        "CFBundleExecutable": name,
        "CFBundleIdentifier": identifier,
        "CFBundleName": name,
        "CFBundleDisplayName": "Nook Glass Lab",
        "CFBundlePackageType": kind,
        "CFBundleShortVersionString": "1.2",
        "CFBundleVersion": "10",
        "LSMinimumSystemVersion": "26.0",
    }
    if kind == "XPC!":
        info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
    else:
        info["NSPrincipalClass"] = "NSApplication"
        info["NSHighResolutionCapable"] = True
        info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["nookglasslab"]}]
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

# Reuse the production content instead of approximating its layout. Keep the
# provider, bundle, URLs and data entirely separate from the installed app.
widget_source = (repo / "NookWidget/NookWidget.swift").read_text()
content = widget_source[widget_source.index("extension NookWidgetCollection {"):]
content = content.split("#Preview(")[0]
content = """import SwiftUI
import WidgetKit
struct NookEntry: TimelineEntry {
    let date: Date
    let snapshot: NookWidgetSnapshot
    var isPlaceholder = false
}
""" + content
(root / "ProductionContent.swift").write_text(content)
for filename, original in [
    ("WidgetShared.swift", repo / "Nook/WidgetShared.swift"),
    ("WidgetSnapshot.swift", repo / "NookKit/Sources/NookKit/WidgetSnapshot.swift"),
]:
    (root / filename).write_text(original.read_text().replace('"nook"', '"nookglasslab"'))

compile_args = ["xcrun", "swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos26.0",
                "-sdk", sdk, "-module-cache-path", root / "module-cache"]
run(*compile_args, "-F", root / "Frameworks", "-application-extension",
    "-module-name", "GlassLabWidgets", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
    source / "Widgets.swift", source / "StackedContent.swift", repo / "NookWidget/NookWidgetHostBackground.swift",
    root / "ProductionContent.swift", root / "WidgetShared.swift",
    root / "WidgetSnapshot.swift", "-o", extension / "Contents/MacOS/GlassLabWidgets")
run(*compile_args, source / "App.swift", source / "StackedContent.swift", "-o", app / "Contents/MacOS/Nook Glass Lab")

entitlements = root / "Lab.entitlements"
entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
for bundle in [extension, app]:
    run("codesign", "--force", "--sign", args.identity, "--timestamp=none", "--options", "runtime",
        "--entitlements", entitlements, bundle)
run("codesign", "--verify", "--deep", "--strict", app)
print(app)
