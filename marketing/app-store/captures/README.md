# Source captures

Store raw, native-resolution app captures here before running the marketing renderer.

- `ko/ipad-13/`: iPad 13-inch captures at 2048 x 2732.
- Matching `ko`, `en`, `ja`, and `zh-Hans` captures let the renderer localize both the app UI and marketing copy.
- Run `make app-store-capture LOCALE=<locale> NAME=<capture-name>` after preparing each screen in Simulator.
- The renderer can still reuse a fallback capture when a `localizedSources` entry is omitted.

These images should contain only app UI. Headlines and account information must be reviewed before committing.
