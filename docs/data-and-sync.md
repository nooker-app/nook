# Data ownership and sync

Nook is folder-first. Pick any folder — in iCloud Drive, Dropbox, Google Drive, OneDrive, Syncthing, another cloud provider, or no cloud at all — and Nook keeps its portable library files there.

## Transport and merge are separate

A folder provider transports files. Nook does not implement an iCloud Drive replacement and does not operate a sync server.

Once files arrive on a device, Nook scans and merges them. Each device writes only its own shards, and CRDT registers resolve concurrent mutable state. This avoids the shared-file race where two devices load the same JSON document, edit different fields, and whichever saves last erases the other edit.

## Folder layout

```text
YourSyncFolder/
├── NookLibrary.json        # legacy v1 input; current Nook never writes it
├── NookContent.json        # legacy v1 body input; current Nook never writes it
├── .nook/
│   ├── content/
│   │   └── <deviceID>.json # feed/article metadata CRDT
│   ├── bodies/
│   │   └── <deviceID>.json # bounded, regenerable article-body cache
│   └── state/
│       └── <deviceID>.json # read/starred/folder/filter/category state CRDT
├── Icons/                  # cached feed favicons
└── Posts/                  # Nook Plus only; absent unless you publish
    └── <handle>/
        ├── .nook-owner     # the DID this directory belongs to
        └── <slug>.md       # one published post, front matter + Markdown
```

The app also maintains a SQLite database in its Application Support container. That database transactionally accumulates observed registers, notification receipts, and a publish outbox. It is a disposable local replica and cache, not another source of truth.

## Conflict behavior

- Content metadata and mutable user state are separate CRDTs.
- Every device writes only its own file in each shard directory.
- Incoming registers merge by hybrid logical clock using last-writer-wins registers.
- Article membership is grow-only; a shrinking, missing, corrupt, partial, or older peer file is never interpreted as deletion.
- Only an explicit feed tombstone removes a feed and its articles.
- Delayed, duplicated, or out-of-order cloud deliveries are safe to scan repeatedly.
- File presenter events and modification dates are wake-up hints; every wake performs an idempotent rescan.

This does not prevent the cloud provider itself from delaying a file. It ensures that when files arrive, one device does not silently replace another device's unrelated changes.

## Published posts in the folder

`Posts/` exists only if you use Nook Plus. Everything else in the folder is a CRDT the devices merge; this directory is not. It is a mirror of your AT Protocol repository, which is where your publications and articles actually live, so it is written from the records and can be rebuilt from them at any time.

- Every published post is one Markdown file named after its address, with front matter carrying the title, slug, summary, publication date, and public URL.
- Editing a file does not publish the change. Nook detects it and offers to publish it; until you accept, the published post is unchanged. Discarding restores the file from the record.
- Deleting a file does not unpublish the post. The record still exists, so the file is written again. Unpublishing is done from the post's row in Publishing settings.
- Deleting the post does remove the file, which is how a deletion reaches the folder.

Each account's directory records the owner's DID in `.nook-owner`, and Nook never writes to or deletes from a directory owned by a different account. This matters because a sync folder can be shared: two accounts, or one account signed out and another signed in, would otherwise see each other's posts as files "no repository accounts for". The DID is the test rather than the directory name, so renaming a handle does not orphan a mirror and reusing a name does not capture one.

Nook will not overwrite or delete a file you changed. A file is recognised as an untouched copy by a fingerprint written into its front matter, so a hand-edited file — including one you renamed — is always kept and reported instead, even when the post it came from has since been deleted on another device.

Drafts are not here. They stay in this device's Application Support container, because a draft is unfinished and putting it in the sync folder would push it to every device the folder reaches.

## What syncs

The selected folder carries:

- Feed and article metadata
- Feed bodies and regenerable extracted body cache
- Read and starred state
- Seen state used to suppress cross-device duplicate notifications
- Folders and per-feed preferences
- Filters and category definitions
- Manual, keyword, and AI category assignments
- Feed deletions represented as tombstones

Some settings intentionally remain device-local, including notification authorization, background scheduling, downloaded offline copies, visual reading preferences, translation-provider selection, and the Gemini API key.

The Gemini key uses this device's Keychain with a device-only accessibility class. It is not stored in the sync folder, `UserDefaults`, backups, or iCloud Keychain.

## Legacy v1 migration

`NookLibrary.json` and `NookContent.json` are read-only legacy inputs. Current versions:

- Add-import previously unseen v1 feed and article IDs, including unresolved conflict copies.
- Never let an older v1 payload overwrite v2 content.
- Never interpret a shrinking legacy file as a deletion.
- Never write or resolve the legacy files.

On the first v2 run, legacy folders, feed placement, read flags, and stars are copied into missing state registers before the new snapshot is shown. Existing shard edits are not overwritten, and migration is marked complete only after the state shard is durably written.

A v1 device can still experience its original shared-file race until it is upgraded. Once every device uses v2, no Nook process writes a shared content file.

## Moving or leaving

- To change cloud providers, move the sync folder and point each Nook installation at the new location.
- To move subscriptions to another reader, export OPML.
- OPML contains subscriptions and folders, not Nook-specific article state, bodies, filters, or categories.
- The per-device JSON shards remain the authoritative Nook library; the SQLite replica can be rebuilt from them.
- `Posts/` is not authoritative and needs no migration: your publications and articles are records in your own AT Protocol repository, and the files are written from them again wherever you point Nook next.
