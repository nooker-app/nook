/// The measured canvases and the part of each that is guaranteed to be shown.
///
/// Read off Apple's own template files rather than guessed:
/// `creative_assets-product_page_header_template-static.psd` is 3840x1646 with its art
/// safe area marked at 1645x659, and the search template is 3840x2560 with 2167x1029.
/// Both boxes are centred, and everything outside them is bleed the store may crop.
export const CANVAS = {
  header: {width: 3840, height: 1646, safe: {width: 1645, height: 659}},
  search: {width: 3840, height: 2560, safe: {width: 2167, height: 1029}},
} as const;

/// Nook's own colours: the icon is a nest of warm strands on paper-coloured light, and
/// the reader is warm paper too.
export const PALETTE = {
  paperTop: '#FFFCF3',
  paperMid: '#FBEFD4',
  paperLow: '#EED8A8',
  duskTop: '#FFF1DC',
  duskMid: '#F4DDB4',
  duskLow: '#E0B87E',
  ink: '#3A2412',
  inkSoft: '#6B5230',
  glow: '#FFF7E2',
  strands: [
    '#8A6A3F',
    '#5C3A18',
    '#C79A5B',
    '#6E5330',
    '#A8763C',
    '#7F6B48',
    '#4A3419',
    '#D9B278',
  ],
} as const;

/// The same nest every render: a fixed seed, so the art is deterministic the way the
/// screenshots are.
export const seeded = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 0xffffffff;
  };
};
