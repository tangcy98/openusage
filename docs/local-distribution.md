# Local Distribution (Un-notarized Builds)

How to package this fork of OpenUsage into a DMG you can hand to colleagues, and what a recipient needs
on their Mac for the **LLM Center** quota rows to show real numbers.

This path exists because the fork carries an in-house provider and is built without an Apple Developer
Program membership. It is not how the public OpenUsage releases are made — those are Developer
ID-signed and notarized by `script/release.sh`.

## Building the DMG

```bash
script/build_local_dmg.sh
```

The DMG lands in `dist/OpenUsage-<version>.dmg`. Options:

| Env | Default | What it does |
|---|---|---|
| `OPENUSAGE_VERSION` | `0.7.7-local` | Version string shown in the app's footer and About. |
| `UNIVERSAL=1` | off | Also build the Intel (x86_64) slice. Leave off for an Apple Silicon-only team — it's much faster. |
| `BUNDLE_ID` | `com.robinebers.openusage.local` | Its own bundle id, so this build can sit beside an official OpenUsage without the two sharing settings. |

How this build differs from a public release:

- **Ad-hoc signed, not notarized.** Recipients have to clear the quarantine flag once (below).
- **No hardened runtime.** It's a notarization requirement, and it would block an ad-hoc-signed app from
  loading its own bundled Sparkle framework (library validation demands a shared Team ID, which an
  ad-hoc signature doesn't have).
- **No iCloud Sync.** That capability needs a provisioning profile from a paid account. Everything else
  — every provider, the menu bar, notifications, the CLI — works normally; only the iCloud Sync setting
  reports unavailable.
- **No auto-update.** Deliberate: this build carries providers the public appcast's builds don't, so it
  must never update itself into the upstream app. Ship a new DMG instead.

## Installing (what to tell recipients)

1. Open the DMG and drag **OpenUsage** to **Applications**.
2. Run this once in Terminal — macOS otherwise refuses to open an un-notarized app:

   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenUsage.app
   ```

3. Launch OpenUsage from Applications. It lives in the menu bar (no Dock icon).

If step 2 is skipped, macOS shows *"OpenUsage is damaged and can't be opened"* or *"cannot be opened
because the developer cannot be verified"*. On recent macOS the right-click → **Open** trick no longer
works reliably for ad-hoc builds; the `xattr` command is the dependable route. An alternative is
**System Settings → Privacy & Security → Open Anyway** right after the first blocked launch.

Requires macOS 15 or later.

## What a recipient needs for LLM Center to show their quota

The app reads each person's own credentials off their own Mac — nothing is baked into the DMG, and the
build carries no account of yours. For the LLM Center rows to populate, a recipient needs all three:

1. **The `llmctl` CLI, logged in.**

   ```bash
   llmctl auth login
   ```

   This writes `~/Library/Application Support/llmctl/config.json` containing the API base URL and their
   personal token. OpenUsage reads that file directly and never invokes `llmctl`, so it picks up a
   fresh or rotated login on the next refresh. Without this file the provider reports
   *"Not logged in to LLM Center"*.

2. **Network reachability to the LLM Center API host** (`https://llm-center.ali.modelbest.co`) — it's on
   the internal network, so they need to be on the office network or VPN. Off-network, the rows show a
   connection error rather than stale numbers.

3. **An LLM Center account with a department membership and a monthly quota.** The quota meter comes
   from their own row in the department member list. An account not attached to a department has no
   quota to display.

Everything is per-user: two people running the same DMG each see their own numbers.

### Quick check

```bash
cat ~/Library/Application\ Support/llmctl/config.json    # should show "api" and "web_token"
curl -sS -o /dev/null -w '%{http_code}\n' https://llm-center.ali.modelbest.co   # should not hang/fail
```

Then open OpenUsage and hit Refresh. See [LLM Center](providers/llmcenter.md) for the metric-by-metric
detail and its troubleshooting list.

## Other providers

Nothing about this packaging changes how the other providers find credentials — Claude, Codex, Cursor
and the rest still read the logins already on the recipient's Mac. A fresh install only turns on the
providers it detects, so a colleague who doesn't use, say, Cursor simply won't see it.
