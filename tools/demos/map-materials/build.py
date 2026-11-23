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
        didSet { if demoMaterial != oldValue { needsDisplay = true } }
    }
    private let sphereAtlas = RecommendationSphereAtlas()''')
replace_once('let images = sphereSprites[material(i).rawValue]', '''let images = sphereSprites[demoMaterial == .adaptive
                ? material(i).rawValue : (demoMaterial == .lens ? 0 : 1)]''')
# All navigation, depth and adaptive materials now come from the shipping app.
(out / 'RecommendationCanvas.swift').write_text(canvas)
(out / 'Navigation.swift').unlink(missing_ok=True)
for file in source.glob('*.swift'):
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
