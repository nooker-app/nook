#!/usr/bin/env python3
"""Build an isolated native material study from the real canvas and cached graph."""
import argparse, json, pathlib, plistlib, shutil, subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--library', required=True, type=pathlib.Path)
parser.add_argument('--graph', required=True, type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('/tmp/nook-glass-demo'))
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[3]
source = pathlib.Path(__file__).resolve().parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
app = out / 'Nook Glass Study.app'
resources = app / 'Contents/Resources'
executable = app / 'Contents/MacOS/NookGlassStudy'
resources.mkdir(parents=True, exist_ok=True)
executable.parent.mkdir(parents=True, exist_ok=True)
lib = json.loads(args.library.read_text())
graph = plistlib.loads(args.graph.read_bytes())
feeds = {f['id']: f['title'] for f in lib['feeds']}
articles = sorted(lib['articles'], key=lambda a: a['publishedAt'], reverse=True)
nodes = []
for a in articles:
    if a['id'] not in graph['positions']:
        continue
    pos = graph['positions'][a['id']]
    nodes.append(dict(id=a['id'], title=a['title'], summary=a.get('summary', ''),
                      source=feeds.get(a['feedID'], 'RSS'), url=a['url'],
                      x=pos['point'][0], y=pos['point'][1], cluster=pos['clusterID']))
ids = {n['id'] for n in nodes}
edges = [dict(a=e['a'], b=e['b']) for e in graph['edges'] if e['a'] in ids and e['b'] in ids]
if not nodes:
    raise SystemExit('The library and graph have no matching articles.')
(resources / 'graph.json').write_text(json.dumps(dict(nodes=nodes, edges=edges)))
for filename in ['RecommendationCanvas.swift', 'RecommendationOrbit.swift', 'RecommendationSphere.swift']:
    shutil.copy2(root / 'NookKit/Sources/NookKit/RecommendationMap' / filename, out / filename)
shutil.copy2(root / 'NookKit/Sources/NookKit/NookTheme.swift', out / 'NookTheme.swift')
canvas = (out / 'RecommendationCanvas.swift').read_text()
def replace_once(old, new):
    global canvas
    if canvas.count(old) != 1:
        raise SystemExit('The production canvas changed; review the demo injection: ' + old[:80])
    canvas = canvas.replace(old, new, 1)
replace_once('    private let sphereAtlas = RecommendationSphereAtlas()', '''    var demoMaterial = DemoMaterial.adaptive {
        didSet { if demoMaterial != oldValue { sphereSprites.removeAll(); needsDisplay = true } }
    }
    private var demoLensSprites: [CGImage] = []
    private var demoHaloSprites: [CGImage] = []
    var onDemoOverview: ((DemoOverviewSnapshot) -> Void)?
    private var demoNavigationBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private var demoOverviewPoints: [CGPoint] = []
    private var demoOverviewQueued = false
    private var demoOverviewPublished = 0.0
    private var demoLastWheel = 0.0
    private var demoCameraHistory: [DemoCameraPosition] = []
    private let glassAtlas = DemoGlassAtlas()
    private let sphereAtlas = RecommendationSphereAtlas()''')
replace_once('sphereSprites = sphereAtlas.palette(groupColors, dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)', '''let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            demoLensSprites = glassAtlas.images(material: .lens, dark: dark)
            demoHaloSprites = glassAtlas.images(material: .halo, dark: dark)
            sphereSprites = demoMaterial == .original
                ? sphereAtlas.palette(groupColors, dark: dark)
                : groupColors.map { _ in glassAtlas.images(material: demoMaterial, dark: dark) }''')
replace_once('guard images.indices.contains(style.blurLevel) else { continue }', '''let focus = demoMaterial == .original ? style.blurLevel
                : Int((pow(1 - style.proximity, 2) * 11).rounded())
            guard images.indices.contains(focus) else { continue }''')
replace_once('context.setAlpha(alpha(i) * style.opacity * (ready ? 1 : 0.18))', '''let materialOpacity = demoMaterial == .original ? style.opacity : 0.34 + style.proximity * 0.66
            context.setAlpha(alpha(i) * materialOpacity * (ready ? 1 : 0.18))''')
replace_once('context.draw(images[style.blurLevel], in:', 'context.draw(images[focus], in:')
replace_once('let images = sphereSprites[colorGroups[i]]', '''let images = demoMaterial == .adaptive
                ? (adjacency[i].isEmpty ? demoLensSprites : demoHaloSprites)
                : sphereSprites[colorGroups[i]]''')
replace_once('projectionDirty = false\n    }', 'projectionDirty = false\n        demoRefreshNavigationGeometry()\n    }')
replace_once('private func tick(){', 'private func tick(){\n        defer { demoConstrainNavigation(); demoPublishOverview() }')
replace_once('override func draw(_ dirtyRect:NSRect){', 'override func draw(_ dirtyRect:NSRect){\n        defer { demoPublishOverview() }')
replace_once('override func mouseDown(with event:NSEvent){', 'override func mouseDown(with event:NSEvent){demoRememberCamera();')
replace_once('override func mouseDragged(with event:NSEvent){', 'override func mouseDragged(with event:NSEvent){defer { demoConstrainNavigation() };')
replace_once('override func mouseUp(with event:NSEvent){', 'override func mouseUp(with event:NSEvent){defer { demoConstrainNavigation() };')
replace_once('override func scrollWheel(with event:NSEvent){', '''override func scrollWheel(with event:NSEvent){
        defer { demoConstrainNavigation(); demoPublishOverview() }
        let now = CACurrentMediaTime()
        if event.phase == .began || event.phase.isEmpty && event.momentumPhase.isEmpty && now-demoLastWheel > 0.35 { demoRememberCamera() }
        demoLastWheel = now
''')
replace_once('override func magnify(with event:NSEvent){', '''override func magnify(with event:NSEvent){
        defer { demoConstrainNavigation(); demoPublishOverview() }
        if event.phase == .began { demoRememberCamera() }
''')
replace_once('override func keyDown(with event:NSEvent){', '''override func keyDown(with event:NSEvent){
        defer { demoConstrainNavigation(); demoPublishOverview() }
        if event.keyCode == 3 { demoFocus(); return }
        if event.keyCode == 29 || event.keyCode == 115 { demoFit(); return }
        if event.keyCode == 51 { demoBack(); return }
''')
replace_once('min(2.5,max(0.018,zoom*factor))', 'min(min(2.5,demoFitZoom*12),max(demoFitZoom*0.8,zoom*factor))')
replace_once('let scale = min((bounds.width-100)/box.width,(bounds.height-140)/box.height)', 'let scale = demoFitZoom')
replace_once('case 53:fit(animated:true);default:', 'case 53:demoFit();default:')
replace_once('var labels = zoom >= 0.45 ?', 'var labels = zoom >= demoFitZoom * 2.5 ?')
replace_once('if zoom>=0.55 || over || active && !force {', 'if (spatial ? zoom >= demoFitZoom * 2.5 : zoom >= 0.55) || over || active && !force {')
# Keep selected outlines in the same palette as the material.
start = canvas.index('    private func drawNode(')
end = canvas.index('    private func requestLabels(', start)
node = canvas[start:end]
node = node.replace('let active=i==selected,over=i==hovered', 'let active=i==selected,over=i==hovered\n        let markerColor = spatial && demoMaterial != .original ? NSColor(NookTheme.accent) : colors[i]')
node = node.replace('colors[i].withAlphaComponent', 'markerColor.withAlphaComponent')
canvas = canvas[:start] + node + canvas[end:]
# Production projection and depth ordering remain intact. The navigation hooks
# and material changes only affect this copy.
(out / 'RecommendationCanvas.swift').write_text(canvas + '\n' + (source / 'Navigation.swift').read_text())
for file in source.glob('*.swift'):
    if file.name == 'Navigation.swift':
        continue
    shutil.copy2(file, out / file.name)
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='com.nooker.map-material-study', CFBundleName='Nook Glass Study',
        CFBundleExecutable='NookGlassStudy', CFBundlePackageType='APPL', NSHighResolutionCapable=True,
        LSMinimumSystemVersion='26.0'), file)
subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'DEBUG', '-parse-as-library',
                '-target', 'arm64-apple-macos26.0', *map(str, sorted(out.glob('*.swift'))),
                '-o', str(executable)], check=True, cwd=root)
print(app)
print(f'{len(nodes)} real articles / {len(edges)} cached connections; no library writes')
