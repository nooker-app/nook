// Bundle once, render many stills. `npx remotion still` re-bundles per frame (~40s each), which makes
// a twenty-frame contact sheet a thirteen-minute job; this makes it one bundle plus the frames.
//
//   node src/probes/frames.mjs <composition-id> <outdir> <frame> [frame ...]
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';
import {mkdirSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const [id, outDir, ...frames] = process.argv.slice(2);

const serveUrl = await bundle({
  entryPoint: join(here, 'src', 'index.ts'),
  publicDir: join(here, 'public'),
});
const composition = await selectComposition({serveUrl, id});
mkdirSync(outDir, {recursive: true});

for (const f of frames) {
  const output = join(outDir, `f${String(f).padStart(4, '0')}.png`);
  await renderStill({composition, serveUrl, output, frame: Number(f), imageFormat: 'png', overwrite: true});
  console.log(output);
}
