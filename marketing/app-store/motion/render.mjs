// Renders the App Store creative assets as video.
//
// The captures are copied in first: Remotion serves images from `public/`, and the real
// screenshots live with the rest of the marketing sources rather than being duplicated
// into this folder by hand.
import {bundle} from '@remotion/bundler';
import {renderMedia, selectComposition} from '@remotion/renderer';
import {cpSync, mkdirSync, rmSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const marketing = join(here, '..');
const locales = ['ko', 'en', 'ja', 'zh-Hans'];
const only = process.argv[2];

rmSync(join(here, 'public'), {recursive: true, force: true});
mkdirSync(join(here, 'public', 'captures'), {recursive: true});
for (const locale of locales) {
  cpSync(
    join(marketing, 'captures', locale, 'iphone-6.9', '03-reader.png'),
    join(here, 'public', 'captures', `${locale}.png`)
  );
}

console.log('bundling…');
const serveUrl = await bundle({
  entryPoint: join(here, 'src', 'index.ts'),
  publicDir: join(here, 'public'),
});

const compositions = [
  ...['ios', 'ipados'].map((platform) => ({
    id: `header-${platform}`,
    out: join(marketing, 'output', 'creative', 'shared', platform, 'product-page-header.mp4'),
  })),
  ...['ios', 'ipados'].flatMap((platform) =>
    locales.map((locale) => ({
      id: `search-${platform}-${locale}`,
      out: join(marketing, 'output', 'creative', locale, platform, 'search-result.mp4'),
    }))
  ),
];

for (const {id, out} of compositions) {
  if (only && !id.includes(only)) continue;
  const composition = await selectComposition({serveUrl, id});
  mkdirSync(dirname(out), {recursive: true});
  console.log(`rendering ${id} → ${out}`);
  await renderMedia({
    composition,
    serveUrl,
    codec: 'h264',
    // The store plays these muted and on repeat; quality matters more than file size for a
    // 6-second loop.
    crf: 18,
    outputLocation: out,
    concurrency: 2,
  });
}
console.log('done');
