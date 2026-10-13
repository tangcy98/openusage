# LLMCenter

Tracks [LLMCenter](https://llm-center.modelbest.co) (ModelBest) usage from the platform's own
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

LLMCenter sits first on the dashboard by default. Its Today and Yesterday spend also feeds the
cross-provider [Total Spend](../dashboard.md#total-spend) ring, converted from yuan to dollars at the
current exchange rate — which is why its slice counts as an estimate there.

Every figure comes from the platform's own APIs (`/llm/api/usage/statistics`,
`/llm/api/department/{deptId}/members`, `/llm/api/usage/user-model-details`) with the personal scope
the site's 个人额度 view uses — no per-call summation and no pricing. The only derived number is
Today's soft daily quota, which is the monthly quota divided by the current month's day count.

## Where credentials come from

Click **Sign In to LLMCenter** on the card. OpenUsage opens LLMCenter's authorization page in your
browser; confirm there and it saves the token to
`~/Library/Application Support/llmctl/config.json`. Nothing else is needed — no CLI, no pasting a
token, no editing files by hand.

That path is shared with the `llmctl` CLI, so if you happen to use it, both keep working off one
login. Anything else in that file — your access key, model, and environment settings — is left
untouched whenever OpenUsage writes it. A token rotated by any means is picked up on the next refresh.

LLMCenter has retired hosts before, and a saved login keeps pointing at the address it was made
against. OpenUsage redirects the hosts it knows are gone (`llm-center.modelbest.cn` and the
`…ali.modelbest.*` pair) to the live `llm-center.modelbest.co`, and repairs the recorded value the next
time it writes the file. A host it doesn't recognize is left exactly as written.

## Staying signed in

LLMCenter's access token only lasts about an hour. Signing in also saves a longer-lived **refresh
token** next to it, and OpenUsage uses that to get a new access token a few minutes before the old one
runs out — no browser, no click. In normal use you sign in once and the card keeps updating. The same
renewal kicks in if LLMCenter turns a token down early.

The browser comes back only when the refresh token itself is no longer accepted (it expired or was
revoked). A momentary network or server problem while renewing is *not* treated as an expired login: the
card shows a connection error instead and tries again on the next refresh.

If you also use `llmctl`, the two share the login. When `llmctl` renews it first, OpenUsage notices the
newer token in the file and uses it. A login saved by an older `llmctl` or an older OpenUsage build has no
refresh token, so it behaves as before until you sign in once more.

## Signing in from the app

The **Sign In to LLMCenter** button appears on the card whenever there's no usable login — the first
time you use the provider, and again if the saved login can no longer be renewed. Click it, confirm in
the browser, and the card reloads on its own.

The card is on from the first launch even though you haven't signed in yet — that's deliberate, since
the button is how you sign in. Turn the provider off in Customize and it stays off. See
[Which Providers Are On](../provider-enablement.md).

Sign-in happens on click by default. Set **Auto Sign In to LLMCenter** in Settings → General to an
interval (e.g., 5 minutes, 1 hour) and OpenUsage starts a timer when it discovers an expired login — if
the login is still expired when the timer fires, the browser opens automatically. Manual refresh (via the
dashboard's refresh button or a provider-level refresh) opens the browser immediately, bypassing the
delay. The timer is canceled if the login recovers from any source (manual sign-in, external `llmctl`
update) before it fires. If an automatic attempt fails, the app won't retry until either the app restarts
or a refresh succeeds. The **Never** setting (the default) means sign-in is always manual.

The API host is on the internal network, so a refresh needs the office network or VPN. Handing this
build to a colleague? See [Local distribution](../local-distribution.md) for the full list of what they
need on their Mac.

LLMCenter is excluded from **Share Anonymous Usage** entirely — the provider id, its metrics, and its
refresh counts are never sent, whatever that setting says. See [Privacy](../privacy.md).

## Under the hood

- `GET {api}/llm/api/department/my` — the user's department membership (`userId`, `deptId`).
- `GET {api}/llm/api/department/{deptId}/members` — every member's monthly quota row; the user's own
  row (`effectiveQuota`, `spentAmount`) supplies the This Month meter. The billing-reconciliation
  endpoints (`/llm/api/billing/…`) are admin-only and return 403 for this login.
- `POST {api}/llm/api/usage/statistics` with `scope: "PERSONAL"`, `freeUser: 1` — the official daily
  cost/tokens for Today and Yesterday.
- `POST {api}/llm/api/usage/user-model-details` — the per-model cost rows behind the hover breakdown
  on Today, This Month, and Yesterday, and the month-to-date Usage Trend chart.
- `POST {oidc_token_endpoint}` with `grant_type=refresh_token` — the silent renewal described above.
  The endpoint and client id are saved in `config.json` at sign-in (`oidc_*`), the same keys `llmctl` uses.
- `POST {api}/llm/api/cli/auth/session` and `GET {api}/llm/api/cli/auth/poll?state=…` — the browser
  authorization the Sign In button drives. Neither needs an existing credential, which is what lets it
  serve as both the first sign-in and the recovery path. See
  [the protocol notes](../research/llm-center-api.md).

## Troubleshooting

- **"Not signed in to LLMCenter"** — click **Sign In to LLMCenter** on the card.
- **"LLMCenter login expired"** — the saved token was rejected (401/403) and couldn't be renewed
  from the refresh token. Click **Sign In to LLM Center** on the card; you shouldn't see this hourly.
  If you do, the sign-in response carried no refresh token — check the log for
  `sign-in response carried no refresh token`.
- **HTTP 404 or 418 on every metric** — the API host in `config.json` is no longer serving. OpenUsage
  already redirects the hosts it knows are retired (`llm-center.modelbest.cn`, the `…ali.modelbest.*`
  pair) to the live one, so this only appears for a host it has never seen. Point `api` at a reachable
  LLMCenter deployment and refresh; the token itself is unaffected.
- **Costs show `¥`** — LLMCenter bills in CNY (人民币). OpenUsage renders yuan-denominated rows with
  `¥`; USD providers keep `$`.