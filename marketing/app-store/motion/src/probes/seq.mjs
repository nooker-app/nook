// Render EVERY frame of a composition as a PNG sequence at a reduced scale, so consecutive-frame
// differences can be measured across the whole timeline instead of around the cuts someone guessed at.
//
//   node src/probes/seq.mjs <composition-id> <outdir> [scale]
import {bundle} from '@remotion/bundler';
import {renderFrames, selectComposition} from '@remotion/renderer';
import {mkdirSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const [id, outDir, scale = '0.4'] = process.argv.slice(2);

const serveUrl = await bundle({entryPoint: join(here, 'src', 'index.ts'), publicDir: join(here, 'public')});
const composition = await selectComposition({serveUrl, id});
mkdirSync(outDir, {recursive: true});

await renderFrames({
  composition,
  serveUrl,
  outputDir: outDir,
  imageFormat: 'png',
  scale: Number(scale),
  concurrency: 6,
  onStart: () => undefined,
  onFrameUpdate: (f) => (f % 100 === 0 ? console.log('frame', f) : undefined),
});
console.log('done', outDir);
