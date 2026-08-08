// Renders the App Store creative assets as video.
//
// The captures are copied in first: Remotion serves images from `public/`, and the real
// screenshots live with the rest of the marketing sources rather than being duplicated
// into this folder by hand.
import {bundle} from '@remotion/bundler';
import {renderMedia, selectComposition} from '@remotion/renderer';
import {cpSync, existsSync, mkdirSync, readdirSync, rmSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const marketing = join(here, '..');
const locales = ['ko', 'en', 'ja', 'zh-Hans'];
const only = process.argv[2];

// ------------------------------------------------------------------ staging the captures
//
// `public/` is gitignored: the committed originals live in ../captures/<locale>/<device>/<name>.png
// and are copied in here at render time rather than duplicated into the repo twice. That means
// Nothing loads from staticFile() any more: the compositions that did — the screenshot cut of the
// search slot — are gone, and with them the block that mirrored the whole capture tree into public/.
// If an asset ever loads an image again, stage it HERE. A clean checkout renders public/ empty, and
// the failure is a video with missing pictures that nobody notices until they watch it.

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
  // The illustrated search-results video, in every language the listing ships.
  ...['ko', 'en', 'ja', 'zh-Hans'].map((locale) => ({
    id: `search-illustration-${locale}`,
    out: join(marketing, 'output', 'creative', locale, 'search-result.mp4'),
  })),
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
    // ------------------------------------------------------------------ the encode
    // Every setting here is answering something measured in the delivered MP4, not a preference.
    //
    // crf 14 (was 18, ~4.1 Mbps). At 4.1 Mbps for 3840x1646 rate control cannot carry sub-pixel
    // motion of fine high-contrast texture, so it froze it: the nest's silhouette was
    // BIT-IDENTICAL for runs of up to 13 consecutive frames and then caught up in a single 4-5px
    // jump, which turned the only slow motion in the piece into a stutter. The same shortage ate
    // the dither — detrended sky noise 1.24-1.57 LSB in the source PNG came out at 0.36-0.56, the
    // longest flat run on a scanline went from 4-8px to 91-124px, and what replaced it was a
    // correlated 8/16px macroblock quilt with a staircased light-shaft edge.
    //
    // imageFormat png. The intermediate frames were JPEG, which is lossy BEFORE the encoder ever
    // sees them: a cream gradient dithered at 1 LSB does not survive a JPEG round trip, so half
    // the banding was baked in at frame capture and no bitrate could have fixed it.
    //
    // muted. The file carried a pure-silence AAC track (silencedetect at -90 dB, silence from 0 to
    // 6.058667) costing 317 kb/s. Worse than the 240 KB: the audio stream was 6.058667s against a
    // video stream of exactly 6.000000s, and a looping player restarts on CONTAINER duration — so
    // frame 179 was held an extra 1.8 frames at every seam, a hitch in the exact seam every motion
    // in this composition is engineered around.
    //
    // colorSpace bt709. The stream was tagged yuvj420p / full range / bt470bg with transfer and
    // primaries 'unknown'; a player assuming bt709 at this resolution (most do) shifted the palette
    // warm by up to +3.9 R / -2.3 B.
    crf: 14,
    imageFormat: 'png',
    muted: true,
    enforceAudioTrack: false,
    colorSpace: 'bt709',
    x264Preset: 'slower',
    // -bf 0 and a short GOP are not exposed as options, and they are the other half of the judder
    // fix: the frozen runs lined up exactly with 1.5-8 kB B-frames sitting between ~100 kB
    // P-frames. No B-frames means every frame carries its own motion. -tune film keeps the encoder
    // from smoothing the strand texture into mush at a low CRF.
    ffmpegOverride: ({type, args}) =>
      type === 'stitcher'
        ? [...args.slice(0, -1), '-bf', '0', '-g', '20', '-tune', 'film', args[args.length - 1]]
        : args,
    outputLocation: out,
    concurrency: 2,
  });
}
console.log('done');
