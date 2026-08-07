import {Config} from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setOverwriteOutput(true);
// The assets are 4K-wide; a low concurrency keeps memory sane on a laptop.
Config.setConcurrency(2);
