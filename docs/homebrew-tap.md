# Homebrew tap setup

Nook ships a Homebrew **cask** through a custom tap so people can install it with:

```sh
brew install --cask nooker-app/tap/nook
```

The release workflow (`.github/workflows/release.yml`) generates the cask
(`Casks/nook.rb`) on every published release — filling in the version and the
DMG's SHA-256 — and pushes it to the tap repository. This is a **one-time
setup**; after it's in place, releases keep the cask up to date automatically.

## One-time setup

1. **Create the tap repository.** A Homebrew tap must be a repo named
   `homebrew-<tap>`. Create a public repo **`nooker-app/homebrew-tap`** (empty is
   fine — the workflow creates `Casks/nook.rb`). Users reference it as
   `nooker-app/tap`.

2. **Add a write deploy key to the tap.** A deploy key is scoped to the single
   repo, so it's cleaner than an account-wide token. Generate a keypair:

   ```sh
   ssh-keygen -t ed25519 -f homebrew-tap-deploy -N "" -C "nook-cask-publish"
   ```

   Then in **`nooker-app/homebrew-tap`** → Settings → Deploy keys → **Add deploy
   key**: paste the contents of `homebrew-tap-deploy.pub` and **check "Allow
   write access"**.

3. **Add the private key as a secret on this repo.** In `nooker-app/nook` →
   Settings → Secrets and variables → Actions → **New repository secret**:
   - Name: `HOMEBREW_TAP_DEPLOY_KEY`
   - Value: the full contents of `homebrew-tap-deploy` (the **private** key,
     including the `-----BEGIN/END OPENSSH PRIVATE KEY-----` lines)

   Delete the local key files afterward. Without this secret the cask-publish
   step logs a message and skips, so releases still succeed.

   (A fine-grained PAT with Contents: write would also work, but then the
   workflow would need to clone over HTTPS instead of SSH.)

4. **Cut a release** (push a `vX.Y.Z` tag). The workflow publishes the DMG, then
   writes `Casks/nook.rb` into the tap and pushes it.

## Notes

- **Signed and notarized since 0.1.51.** Quarantine no longer needs explaining,
  so the cask carries no `caveats`: a cask install opens like any other app. Do
  not reinstate the `--no-quarantine` advice that the ad-hoc builds needed. It
  would teach people to disable a check that now passes. Notarization is also the
  prerequisite for submitting to the official `homebrew/cask` tap.
- **Updates.** The cask sets `auto_updates true` because the app updates itself
  via Sparkle, so `brew upgrade` deliberately leaves an installed copy alone.
  `brew upgrade --cask --greedy nook` overrides that, which is only worth doing
  if Sparkle is broken.
- **Minimum macOS.** The cask declares `depends_on macos: :tahoe` (`macos:`
  compares with `>=`, so that reads as Tahoe or newer). Without it Homebrew
  installs onto an older macOS and the mismatch surfaces as an app that will not
  open, which is a worse error than a refused install.
- **Style.** `brew style Casks/nook.rb`, run from a clone of the tap, checks the
  generated cask. The template in `release.yml` is kept at zero offences, so a
  new offence means the template changed and not that the tool got stricter.
- **Uninstall.** `brew uninstall --cask nook`; `brew uninstall --zap --cask nook`
  also removes preferences/caches. Zap never touches your chosen sync folder —
  that's your data.
