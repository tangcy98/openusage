# LLMCenter（llm-center.modelbest.co）API 参考

> 面向 agent 的协议参考：访问、鉴权、接口、坑位。内容来自 2026-08-05 对真实账号的实测逆向
> （`llmctl` CLI 行为、官网 SPA JS 反查、curl 直连探测），并已落地为 OpenUsage 的
> `LLMCenterProvider` 实现。未确认项标注了状态。

## 概览

- **平台**：面壁智能（ModelBest）的 LLM 用量/费用中心，官网 `https://llm-center.modelbest.co`。
- **配套 CLI**：`llmctl`（Go，v0.1.0，`LLMC-ANC-0.1` 协议），是官方唯一文档化的访问方式。
- **前端**：SPA（`/assets/index-bYn18TUE.js` + 懒加载 chunk），路由含 `/usage`、`/usage/billing`、
  `/stability`、`/cli-guide` 等；各页面数据接口拆在 `api-*.js` 模块里。

## 鉴权

**凭证位置（macOS，`llmctl auth login` 后写入）**：

```jsonc
// ~/Library/Application Support/llmctl/config.json
{ "api": "https://llm-center.modelbest.co", "web_token": "<347 字符 Rosefinch bearer token>" }
```

- 请求头：`Authorization: Bearer <web_token>` + `Content-Type: application/json`。
- **凭证获取**：`llmctl auth login`（浏览器授权；无头环境 `LLMCTL_NO_BROWSER=1` 或 `--no-open`
  时打印授权 URL，在任何设备打开完成后回填）。
- `llmctl` 支持的环境变量（GUI 应用不继承 shell 环境，故 OpenUsage 只读配置文件）：
  `LLM_CENTER_API_URL`、`LLM_CENTER_WEB_TOKEN`、`LLM_CENTER_API_KEY`。
- **注意**：`config.json` 的 `web_token` 是 CLI 登录身份，**与浏览器登录身份可能不同**（见"坑位"）。

## 网络特性（实测）

- **域名现状（2026-08-09 实测）**：只有 `llm-center.modelbest.co` 可用（内网 `30.100.0.4`，未登录 401，
  带 token 四个接口全 200）。外网入口 `llm-center.modelbest.cn` 已关闭（解析到华为云 WAF，任何路径恒
  **HTTP 418「访问被拦截」**）；`llm-center.ali.modelbest.co` 全站 404（含根路径），此前的
  「301 跳转到主域名」行为已不存在。
- OpenUsage 用 `LLMCenterHost` 做**退役域名迁移**：读凭证时把已知死掉的 host 换成存活的那个，并 WARN
  记录；写回 `config.json` 时顺手修复磁盘上的陈旧值（`llmctl` 自己永远不会改）。不认识的 host 原样放行。
- **间歇性超时**：同一端点有时 0.17s 秒回、有时 20s+ 无响应（`llmctl logs list` 也复现过）。
  请求必须设超时（建议 ≥20s）并容忍失败重试。
- **大窗口查询不稳定**：窗口越大越易超时（14 天+ 实测超时；月窗口配大 pageSize 必超时）。
  小窗口（≤3 天，≤600 行）稳定 ~3s 返回。

## 核心接口：调用日志 `POST {api}/llm/api/call-log/list`

**这是 llmctl token 唯一确认可用的数据接口**，每条记录 = 一次 LLM 调用，含 tokens 与平台已算好的价格。

请求体：

```jsonc
{
  "startTime": "2026-08-05T12:00:00.000Z",   // ISO8601 UTC，含毫秒；缺时间戳报"开始时间不能为空"
  "endTime":   "2026-08-06T12:00:00.000Z",
  "page": 1,
  "pageSize": 500
}
```

响应封套：

```jsonc
{ "code": 0, "message": "success", "data": { "total": 416, "data": [ /* record */ ] } }
```

### 关键限制（实测，易踩坑）

| 限制 | 实测结果 |
|---|---|
| **`page` 参数被忽略** | `page=1` 与 `page=2` 返回**完全相同**的首页数据 |
| **单响应行数封顶** | 返回 `min(total, pageSize)` 行；`pageSize` 越大越易超时（500/600/700 均可，1000+ 超时） |
| **窗口越大越易超时** | 月窗口必超时；7 天 ~616 行 + pageSize 700 可全量；14 天+ 不稳定 |

**结论：取全量必须"按天分块 + 按 `responseId` 去重"**——每天一个请求（个人 key 单日实测 ~200 条，
远低于封顶），合并时去重（重叠窗口会重复）。OpenUsage 的 `LLMCenterUsageClient` 已按此实现
（按天分块、并发 6、`responseId` 去重）。

### 记录字段

```
时间:     callTime（本地时间 "yyyy-MM-dd'T'HH:mm:ss"，无时区！）
身份:     userName, apiName, deptName, appTitle, providerId, providerName, oneapiRequestId,
          responseId, conversationId, sessionId, sessionSeq
tokens:   promptTokens, completionTokens, totalTokens,
          cacheCreationTokens, cacheReadTokens, cacheTokens,
          audioInputTokens, audioOutputTokens
价格:     inputPrice, normalInputPrice, outputPrice,
          cacheCreationPrice, cacheReadPrice, audioInputPrice, audioOutputPrice
状态:     status（"1"=成功）, statusDesc, failReason, failReasonDesc,
          fallbackAttempt, routeAttemptId
耗时:     callDuration, firstResponseDuration
```

### 花费计算

- 币种是**人民币（¥）**，各 price 字段是**每条调用已算好的金额**（非单价），无需本地定价估算。
- 单次调用花费 = `inputPrice + outputPrice + cacheCreationPrice + cacheReadPrice + audioInputPrice + audioOutputPrice`。
- 只统计 `status == "1"`（成功）的调用；失败调用有价格字段但不应计入。
- 日分桶按**本地日历日**（`callTime` 是本地时间，无时区后缀）。
- 单日量级参考：~200 调用/天、数百万 tokens、几十元人民币。

## 其他接口（官网前端在用，但 llmctl token 均返回 0/空/500）

从 SPA 的 `api-*.js` 反查到的端点。**注意：这些接口对 llmctl 的 web_token 全部返回空数据或 500**
（`statistics` 恒 0、`user-model-details` 空列表、`cost-trend`/`billing/monthly` 500）——要么需要
额外权限/身份，要么 llmctl 与浏览器登录不是同一身份。若要对齐官网数字，需浏览器身份或对应权限。

| 端点 | 方法/参数 | 说明 |
|---|---|---|
| `/llm/api/usage/statistics` | POST `{startDate,endDate}`（`yyyy-MM-dd`） | 汇总 `totalCost/totalTokens/totalCalls/successRate/activeUserCount/activeModelCount/projectCost/personalCost` |
| `/llm/api/usage/user-model-details` | POST `{startDate,endDate,page,pageSize,userName?,statisticsDomain?}` | 服务端按日聚合明细（`aggregationType:"DAY"`） |
| `/llm/api/usage/cost-trend` | GET | 费用趋势 |
| `/llm/api/usage/ranking/{channel-model\|channel\|model\|project\|user}` | 排行 | |
| `/llm/api/usage/filter-options`、`/llm/api/usage/visible-teams` | 筛选项 | |
| `/llm/api/billing/monthly`（+ `{id}/summary\|channel-details\|project-details\|free-quota-details\|recharges\|export\|generate`） | 月度账单（另一套口径） | |
| `/llm/api/billing/channel-recharge/*` | 通道充值 | |
| `/llm/api/channel/*`、`/llm/api/app/visible-scope-options` | 通道/范围管理 | |
| `/llm/api/department`、`/llm/api/team-dept-mapping` | 团队/部门 | |
| `/api/admin/*`（如 `sys-user/queryAll`） | 管理端（需管理员） | |

## CLI 授权协议（`llmctl auth login` 逆向，2026-08-06）

> 这是 OpenUsage「应用内登录」绿色通道的依据。协议通过把 `LLM_CENTER_API_URL` 指向本地抓包服务器、
> 捕获 `llmctl` 的真实请求确认。三个步骤**都不需要任何现有凭据**，这正是它能作为过期恢复路径的原因。

### 为什么必须由 app 自己做

> 以下是 `llmctl` 0.1.0 的行为。0.2.14 的帮助文本写明 `auth login` 在「access / refresh 元数据不完整」时才走
> 浏览器授权，`--force` 可强制重授权，并保存 `refresh_token`（见下文「Token 寿命与静默续期」）。0.2.14 对
> 「元数据齐全但服务端已拒绝」的情形是否仍空转，**未重新实测**。

`llmctl auth login` **只做本地非空检查**：只要 `config.json` 的 `web_token` 字段非空，它就在 ~2ms 内
空转返回并原样回显旧 token，从不向服务端验证。实测把签名尾部改成 `AAAAAA` 的失效 token 也照样空转。
所以 token 过期后 CLI 是死路，唯一出路是先清空该字段——或者由 app 自己走完授权。

### 步骤（OIDC + PKCE，2026-09-17 起）

> **协议已在 2026-09-17 前后变更。** 旧的两段式（只发 `state`，poll 直接返回 `webToken`）已被服务端
> 拒绝：`auth/session` 返回 `{"code":400,"message":"当前服务仅支持 llmctl 0.2.12 及以上版本，请先升级
> CLI"}`，浏览器永远不会打开。**这句文案描述的是协议版本（是否带 PKCE），不是本机是否装了 llmctl。**
> 已实测：只要 body 带 `codeChallenge`，即使用 curl 的默认 User-Agent 也返回 `code:0`；不带则 400。

1. 客户端生成 PKCE 对：`verifier` = 32 字节 CSPRNG 的 base64url（43 字符，RFC 7636 下限），
   `challenge` = `BASE64URL(SHA256(ASCII(verifier)))`。

   `state` 必须带 `llmctl_` 前缀（前缀 + 48 位 hex）。**这是独立于 PKCE 的第二道校验**：漏掉前缀时服务端
   返回 `{"code":400,"message":"OIDC CLI state 必须以 llmctl_ 开头"}`，即使 `codeChallenge` 正确也一样被拒。

   `POST {api}/llm/api/cli/auth/session`，body：

   ```jsonc
   {"state":"llmctl_<48 位 hex>","codeChallenge":"<43 字符 base64url>",
    "oidcRedirectUri":"https://llm-center.modelbest.co/auth/callback"}
   ```

   ```jsonc
   {"code":0,"data":{"state":"…",
     "authorizeUrl":"https://iam.modelbest.co/api/admin/oauth2/authorize?…&code_challenge=…&code_challenge_method=S256",
     "expiresIn":300,"pollIntervalMs":1000,
     "tokenEndpoint":"https://iam.modelbest.co/api/admin/oauth2/token",
     "clientId":"997fee45c3212e4881db5bb01edc5a21",
     "redirectUri":"https://llm-center.modelbest.co/auth/callback"}}
   ```

   **`authorizeUrl` 与 `tokenEndpoint` 都在 `iam.modelbest.co`，与 api host 不同**，必须原样使用服务端返回
   值，不得自行拼接。`clientId` / `redirectUri` 同样以服务端返回为准。

2. 浏览器打开 `authorizeUrl`，用户用已有 SSO 会话确认。

3. **轮询必须是 GET 带 query**：`GET {api}/llm/api/cli/auth/poll?state=…`
   （同一路径用 POST 返回 **HTTP 500**。）

   ```jsonc
   {"code":0,"data":{"status":"pending","authorizationCode":null,"error":null,"errorDescription":null}}
   ```

4. 拿到 code 后**换 token**：`POST {tokenEndpoint}`，`application/x-www-form-urlencoded`：

   ```
   grant_type=authorization_code&code=<authorizationCode>
     &code_verifier=<verifier>&client_id=<clientId>&redirect_uri=<redirectUri>
   ```

   响应是**扁平 OAuth**（不再包 `data`），token 字段为 `web_token`（兼容 `access_token`），
   另有 `expires_in` / `refresh_token`。

### 成功判据：`authorizationCode` 非空，而不是 status

服务端不再直接下发 token —— poll 转发的是 OIDC 的 `authorizationCode`，需要第 4 步用 PKCE verifier
换取。OpenUsage 以「`authorizationCode` 非空」为唯一成功判据，无视 status 字面值；非 pending 且无 code
的 status 一律当失败。若服务端改发 OAuth 错误（`error` / `errorDescription`），同样视为终止失败。

### 写回 `config.json` 的约定

OpenUsage 用读-改-写：设 `web_token`，`api` 仅在缺失时补写，`app_code` 仅在换 token 返回时写；
`access_key` / `model` / `env` 等 CLI 自有键**逐字保留**。写入走临时文件 + `fchmod 0600` + `rename`，
保证原子性与权限。

token 的**配套键必须和 `web_token` 一起写**（`llmctl` 0.2.x 读的是同一批键）：

| 键 | 登录（授权码换 token） | 续期（refresh grant） |
|---|---|---|
| `refresh_token` | 写服务端返回值；**没返回就删掉旧的** | 返回了轮换值就替换，没返回就保留原值 |
| `token_expires_at` | `now + expires_in`（无则取 JWT `exp`，都没有就删） | 同左 |
| `oidc_token_endpoint` / `oidc_client_id` / `oidc_redirect_uri` | 写本次 session 返回的值 | 不动 |

只换 `web_token` 而留着旧的 `refresh_token` / `token_expires_at` 会得到一个自相矛盾的文件：CLI 看到
过期的 `token_expires_at` 就会拿旧 refresh token 去续期，再把刚写好的 `web_token` 覆盖掉。

## Token 寿命与静默续期（2026-10-13）

- `web_token` 是 IAM 签发的 JWT，`exp - iat = 3600`，**固定 1 小时**，客户端无法延长。授权 URL 的 scope 是
  `openid profile email roles dept`，没有 `offline_access`，但 `llmctl` 0.2.14 的登录流程要求响应里必须有
  `refresh_token`（缺了报 `OIDC token response missing refresh_token`），说明服务端照发。
- 此前 OpenUsage 的 `exchangeAuthorizationCode` 只取 token、丢弃 `refresh_token` / `expires_in`，所以每小时必然
  走一次浏览器授权（日志里 10:31、11:37、12:37、13:39 逐小时出现 `login expired` → `sign-in complete`）。
- 现在改为：登录时保存 `refresh_token` 与 `oidc_*`；每次 `refresh()` 前若 token 剩余 ≤ 5 分钟（以 JWT `exp` 为准，
  `token_expires_at` 仅作不透明 token 的兜底，因为别的程序换 token 时它会过期），向 `oidc_token_endpoint` 发
  `grant_type=refresh_token&refresh_token=…&client_id=…`（form-urlencoded）；服务端 401 时也会被动续期一次并重试。
- 失败分类：4xx → refresh token 已死（走原有「过期 → 登录」路径）；408/429/5xx/网络错误 → **不算过期**，
  卡片显示连接错误，下次刷新再试（否则一次网络抖动就会弹浏览器）。
- 与 `llmctl` 共用文件的竞态：refresh token 若被服务端轮换，两边同时续期会让一方的 refresh token 作废。
  收到 4xx 后会先重读磁盘，如果 `web_token` / `refresh_token` 已被别的进程换新，就直接采用，不进入登录。
- **待实测**：refresh grant 的真实响应（是否轮换 `refresh_token`、是否带 `expires_in`、refresh token 自身寿命）
  尚未在真实服务端观察过；实现按 OAuth 标准并对「不轮换 / 无 `expires_in`」都做了兼容。


**自动模式的首轮时序**：`hasCompletedFirstRefresh()` 读的是 `WidgetDataStore.lastRefreshAt`，它在
`refreshAll` **整批结束后**才盖章，而自动触发发生在单个 provider 的 `refresh()` 内部——所以启动时，
第一轮必然命中「no refresh pass has completed yet」这道闸，要等下一个刷新周期（默认 5 分钟）才会
检查是否触发。实测：14:02:28 被挡，14:07:32 触发。这符合「避免启动即抢焦点」的设计意图，但延迟比预期长。

## 坑位总结

1. **不要翻页**：`page` 被忽略，翻页会拿到完全相同的重复数据 → 金额翻倍（OpenUsage 曾因此出现
   Yesterday 恰好 ×2 的 bug）。
2. **不要大窗口**：月窗口/大 pageSize 会超时；按天分块是唯一可靠取全量的方式。
3. **只认 `status == "1"`**：失败调用不计入花费。
4. **时间是本地时间**：`callTime` 无时区后缀，按本地日历日分桶；请求的 `startTime/endTime` 用
   UTC ISO8601（含毫秒）。
5. **人民币**：金额是 ¥，不是 $；OpenUsage 用 `MetricKind.yuan` 渲染。
6. **官网统计 ≠ call-log**：官网 UI 的数字来自权限/身份受限的统计端点，与 call-log 逐条求和口径
   可能不同；对齐前先确认两边身份一致。
7. **间歇超时**：端点偶发 20s+ 无响应，需超时 + 重试 + 失败降级（保留上次成功数据）。
8. **`llmctl auth login` 无法重登**：见「CLI 授权协议」——它只查本地字段非空，不验证服务端。
9. **api 地址会失效，且 CLI 不会修**：`llmctl` 把首次登录时的 host 写进 `config.json` 后再不更新，
   所以域名一退役，老配置就是死的——症状是每个指标报 HTTP 404 或 418 而非 401。2026-08-09 实测：
   `.cn` 外网入口关闭（WAF 恒 418）、`…ali.modelbest.co` 全站 404，只剩 `llm-center.modelbest.co`。
   OpenUsage 用 `LLMCenterHost` 迁移已知退役 host（读时替换 + 写回时修复磁盘值），token 不必重换；
   没见过的 host 不动，避免把用户自己的部署悄悄重定向走。

## OpenUsage 集成现状

- Provider：id `llmcenter`，显示名 "LLMCenter"，图标 `llmcenter.svg`（官方 logo）。
- 指标：Today / This Month（自然月）/ Yesterday / Usage Trend（月内每日 tokens），全部 ¥。
- 凭证：读写 `~/Library/Application Support/llmctl/config.json`，无手动输入；`hasLocalCredentials()`
  探该文件，首次启动自动启用。该路径与 `llmctl` 共用，但 OpenUsage 不依赖它——写入时保留文件里
  不属于自己的键。
- 应用内登录：没有可用登录时（`ErrorCategory.notLoggedIn` 或 `authExpired`）卡片出现 Sign In 行，
  走上面的 CLI 授权协议拿 token 写回同一个文件。**首次登录同样走这条路，不需要 `llmctl`**：
  `config.json` 缺 `api` 时回退到 `LLMCenterHost.live`（授权协议三步都不需要既有凭据）。
  默认手动点击；Settings → General 的 **Auto Sign In to LLMCenter** 可设置间隔（如 5min、1h），
  过期后启动计时器，到期时自动弹浏览器（仅限 `authExpired`）。手动刷新立即触发，无视延迟。
  计时器期间如果凭证恢复则取消。失败后需 app 重启或刷新成功才会再试。
- 实现：`Sources/OpenUsage/Providers/LLMCenter/`（AuthStore / AuthClient / Host / SignInService /
  UsageClient / UsageMapper / Provider）。
- 文档：`docs/providers/llmcenter.md`（用户向）。
