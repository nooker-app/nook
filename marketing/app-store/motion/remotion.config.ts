import {Config} from '@remotion/cli/config';

// PNG and not JPEG. The intermediate frames are what the encoder is handed, so a lossy
// intermediate discards the sky's 1-LSB dither before any bitrate decision can protect it — and
// measured, that was half of the banding in the delivered header. It costs render time and nothing
// else.
Config.setVideoImageFormat('png');
Config.setOverwriteOutput(true);
// The assets are 4K-wide; a low concurrency keeps memory sane on a laptop.
Config.setConcurrency(2);

// ------------------------------------------------------------------ the encode
// These are duplicated in render.mjs on purpose and the duplication is load-bearing: the
// programmatic renderer (@remotion/renderer, which render.mjs uses) does NOT read this file, and
// the CLI does not read render.mjs. A one-off `npx remotion render` has to produce the same file
// the build does, because that is the file anyone reviews. Every value is justified in render.mjs.
Config.setCrf(14);
Config.setMuted(true);
Config.setEnforceAudioTrack(false);
Config.setColorSpace('bt709');
Config.setX264Preset('slower');
Config.overrideFfmpegCommand(({type, args}) =>
  type === 'stitcher'
    ? [...args.slice(0, -1), '-bf', '0', '-g', '20', '-tune', 'film', args[args.length - 1]]
    : args
);
