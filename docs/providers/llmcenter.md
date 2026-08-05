# LLM Center

Tracks [LLM Center](https://llm-center.modelbest.cn) (ModelBest) usage from the platform's own
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

## Troubleshooting

- **"Not logged in to LLM Center"** — run `llmctl auth login` to sign in, then refresh.
- **"LLM Center login expired"** — the saved token was rejected (401/403). Run `llmctl auth login`
  again, then refresh.
- **Costs show `¥`** — LLM Center bills in CNY (人民币). OpenUsage renders yuan-denominated rows with
  `¥`; USD providers keep `$`.