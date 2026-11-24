#!/usr/bin/env python3
"""Check weak imports and widget construction with and without the host API."""

from pathlib import Path
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[1]
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="nook-widget-host-check-") as temporary:
    for missing in [False, True]:
        root = Path(temporary) / ("missing" if missing else "available")
        frameworks = root / "Frameworks"
        subprocess.run(["/usr/bin/python3", str(repo / "tools/prepare-widget-host-sdk.py"),
                        "--sdk", sdk, "--output", str(frameworks)], check=True)
        sources = []
        for relative in ["NookWidget/NookWidget.swift", "NookWidget/NookWidgetHostBackground.swift",
                         "Nook/WidgetShared.swift", "NookKit/Sources/NookKit/WidgetSnapshot.swift",
                         "NookKit/Sources/NookKit/WidgetRuntime.swift"]:
            target = root / Path(relative).name
            target.write_text((repo / relative).read_text().split("#Preview(")[0])
            sources.append(str(target))

        if missing:
            # Preserve the mangled identifier's length but point both imports
            # and the runtime gate at symbols absent from the real framework.
            # A strong import or eager private opaque metadata lookup now fails.
            for path in [*frameworks.rglob("*.swiftinterface"), *frameworks.rglob("*.tbd"),
                         root / "NookWidgetHostBackground.swift"]:
                path.write_text(path.read_text().replace("preferredBackgroundStyle", "missingxxBackgroundStyle"))

        main = root / "Check.swift"
        main.write_text("""import SwiftUI
import WidgetKit
@main struct Check {
    @MainActor static func main() {
        precondition(NookWidgetHostBackground.isAvailable == EXPECTED)
        // Exercise the real public body metadata and fallback background. The
        // private opaque result must not escape into any stored configuration.
        print(type(of: NookWidget().body))
        print(type(of: NookLatestWidget().body))
        print(type(of: NookRecommendedWidget().body))
        print(type(of: NookRecentlyReadWidget().body))
        _ = NookWidgetBackground().body
        print("Host API available: \\(NookWidgetHostBackground.isAvailable)")
    }
}
""".replace("EXPECTED", "false" if missing else "true"))
        binary = root / "check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", "-swift-version", "6",
                        "-target", "arm64-apple-macos26.0", "-F", str(frameworks),
                        "-module-cache-path", str(root / "module-cache"), *sources, str(main),
                        "-o", str(binary)], check=True)
        imports = subprocess.check_output(["xcrun", "dyld_info", "-imports", str(binary)], text=True)
        private_imports = [line for line in imports.splitlines()
                           if "BackgroundStyle" in line]
        if len(private_imports) < 4 or any("[weak-import]" not in line for line in private_imports):
            raise SystemExit("Expected four weak private imports: " + "\n".join(private_imports))
        subprocess.run([str(binary)], check=True)
        print("PASS:", "missing API fallback construction" if missing else "available API construction")

# This validates launch/linking/body construction. Actual WidgetKit archive and
# compositing verification is separate; a standalone executable cannot prove it.
