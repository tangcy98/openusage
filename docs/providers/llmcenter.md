# LLM Center

Tracks [LLM Center](https://llm-center.modelbest.co) (ModelBest) usage from the platform's own
accounting: the monthly member quota, today's spend against a soft daily quota, and yesterday's spend.
Hover any spend row for the official per-model breakdown.

## What it tracks

| Metric | Meaning |
|---|---|
| Today | Today's official spend against a **soft daily quota** (monthly quota ÷ days in the current month), ¥ |
| This Month | The official monthly quota meter: spend against your member quota (¥), with remaining |
| Yesterday | Yesterday's official spend (¥) and tokens |
| Usage Trend | Daily ¥ spend from the start of the current month to today |

Hover Today, This Month, or Yesterday for that period's official per-model spend breakdown.

Today and This Month are starred into the menu bar by default, stacked as a pair. Whether the strip
shows the amount ("¥150 / ¥1K") or the share of the quota ("15%"), and whether it shows spend or
remaining, follow the global **Menu Bar Values** and **Show Usage As** settings — see
[Menu Bar](../menu-bar.md).

LLM Center sits first on the dashboard by default. Its Today and Yesterday spend also feeds the
cross-provider [Total Spend](../dashboard.md#total-spend) ring, converted from yuan to dollars at the
current exchange rate — which is why its slice counts as an estimate there.

Every figure comes from the platform's own APIs (`/llm/api/usage/statistics`,
`/llm/api/department/{deptId}/members`, `/llm/api/usage/user-model-details`) with the personal scope
the site's 个人额度 view uses — no per-call summation and no pricing. The only derived number is
Today's soft daily quota, which is the monthly quota divided by the current month's day count.

## Where credentials come from

Log in with the `llmctl` CLI once:

```bash
llmctl auth login
```

That writes `~/Library/Application Support/llmctl/config.json` with the API base URL and the
Rosefinch bearer token. OpenUsage reads that file directly (it never calls out to `llmctl`), so the
provider shows up on the dashboard automatically after login and a rotated token is picked up on the
next refresh.

LLM Center has retired hosts before, and `llmctl` never revises the one it recorded — so an old login
would keep pointing at a dead address with no way to fix it but hand-editing JSON. OpenUsage redirects
the hosts it knows are gone (`llm-center.modelbest.cn` and the `…ali.modelbest.*` pair) to the live
`llm-center.modelbest.co`, and repairs the recorded value the next time it writes the file. A host it
doesn't recognize is left exactly as written.

## Signing in from the app

When the saved token expires, the LLM Center card grows a **Sign In to LLM Center** button. Click it and
OpenUsage opens the same authorization page the CLI uses; confirm in the browser and the app writes the
new token back into `config.json`, so `llmctl` and OpenUsage keep sharing one login. Everything else in
that file — your access key, model, and environment settings — is left untouched.

This exists because `llmctl auth login` cannot recover from an expired token: it treats any non-empty
`web_token` as "already signed in" and returns without ever asking the server, so re-running it does
nothing. The button is the way back in.

Two limits worth knowing:

- **The first login still needs the CLI.** `llmctl auth login` is what records the API host in
  `config.json`, and OpenUsage will not guess one. On a machine that has never logged in, the card says
  so instead of offering the button.
- **Sign-in happens on click by default.** Turn on **Auto Sign In to LLM Center** in Settings → General
  and OpenUsage opens the browser by itself the first time it finds the login expired — at most once per
  launch, so a dead session can't throw a window at you every refresh. It also skips the very first
  refresh after launch, so a login that's already expired when you start the app opens the browser one
  refresh cycle later rather than the instant you log in.

The API host is on the internal network, so a refresh needs the office network or VPN. Handing this
build to a colleague? See [Local distribution](../local-distribution.md) for the full list of what they
need on their Mac.

## Under the hood

- `GET {api}/llm/api/department/my` — the user's department membership (`userId`, `deptId`).
- `GET {api}/llm/api/department/{deptId}/members` — every member's monthly quota row; the user's own
  row (`effectiveQuota`, `spentAmount`) supplies the This Month meter. The billing-reconciliation
  endpoints (`/llm/api/billing/…`) are admin-only and return 403 for this login.
- `POST {api}/llm/api/usage/statistics` with `scope: "PERSONAL"`, `freeUser: 1` — the official daily
  cost/tokens for Today and Yesterday.
- `POST {api}/llm/api/usage/user-model-details` — the per-model cost rows behind the hover breakdown
  on Today, This Month, and Yesterday, and the month-to-date Usage Trend chart.
- `POST {api}/llm/api/cli/auth/session` and `GET {api}/llm/api/cli/auth/poll?state=…` — the CLI
  authorization the in-app Sign In button drives. Neither needs an existing credential, which is what
  makes them a recovery path. See [the protocol notes](../research/llm-center-api.md).

## Troubleshooting

- **"Not logged in to LLM Center"** — run `llmctl auth login` to sign in, then refresh.
- **"LLM Center login expired"** — the saved token was rejected (401/403). Click **Sign In to LLM
  Center** on the card. Re-running `llmctl auth login` will not help: it stops at the non-empty token
  already on disk without checking it with the server.
- **HTTP 404 or 418 on every metric** — the API host in `config.json` is no longer serving. OpenUsage
  already redirects the hosts it knows are retired (`llm-center.modelbest.cn`, the `…ali.modelbest.*`
  pair) to the live one, so this only appears for a host it has never seen. Point `api` at a reachable
  LLM Center deployment and refresh; the token itself is unaffected.
- **Costs show `¥`** — LLM Center bills in CNY (人民币). OpenUsage renders yuan-denominated rows with
  `¥`; USD providers keep `$`.