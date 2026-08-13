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

`llmctl auth login` **只做本地非空检查**：只要 `config.json` 的 `web_token` 字段非空，它就在 ~2ms 内
空转返回并原样回显旧 token，从不向服务端验证。实测把签名尾部改成 `AAAAAA` 的失效 token 也照样空转。
所以 token 过期后 CLI 是死路，唯一出路是先清空该字段——或者由 app 自己走完授权。

### 步骤

1. `POST {api}/llm/api/cli/auth/session`，body `{"state":"<48 位 hex>"}`（state 由客户端生成）

   ```jsonc
   {"code":0,"data":{"state":"…","authorizeUrl":"https://llm-center.modelbest.co/cli-auth?state=…",
                     "expiresIn":300,"pollIntervalMs":1000}}
   ```

   **`authorizeUrl` 的 host 与 api host 不同**，必须原样使用服务端返回值，不得自行拼接。

2. 浏览器打开 `authorizeUrl`，用户用已有 SSO 会话确认。

3. **轮询必须是 GET 带 query**：`GET {api}/llm/api/cli/auth/poll?state=…`
   （同一路径用 POST 返回 **HTTP 500**。）

   ```jsonc
   {"code":0,"data":{"status":"pending","webToken":null,"appCode":null}}
   ```

### 成功判据：`webToken` 非空，而不是 status

**完成态实测（2026-08-06 真人授权）**：`{"status":"completed","webToken":"…","appCode":null}`。字面值是
`completed` —— 不是此前猜测的 `success`/`authorized`。这正说明按猜测的字符串匹配会把服务端真的发来的
token 丢掉。OpenUsage 以「`webToken` 非空」为唯一成功判据，无视 status 字面值；非 pending 且无 token 的
status 一律当失败。

**`appCode` 实测为 `null`**：字段在响应里存在，但值为空，因此 OpenUsage 不写 `app_code` 键。下面那条
配对风险因此在当前服务端行为下不成立（没有新 appCode 可错配），但字段既然存在，服务端将来发非空值时
仍按「poll 返回则写」处理。

**token 复用**：有效期内重复授权返回的是**同一个** token（两次实测尾部一致），不是每次新签。

### 写回 `config.json` 的约定

OpenUsage 用读-改-写：只设 `web_token`，`api` 仅在缺失时补写，`app_code` 仅在 poll 返回时写；
`access_key` / `model` / `env` 等 CLI 自有键**逐字保留**。写入走临时文件 + `fchmod 0600` + `rename`，
保证原子性与权限。

**未验证的配对风险**：若服务端把新 `webToken` 与新的 `appCode`/`sessionId` 绑定而 poll 未全部返回，
`llmctl` 可能拿到错配组合（OpenUsage 自身只用 `web_token`，不受影响）。2026-08-06 的真实授权实测里
`appCode` 为 `null`，且事后 `llmctl models list` exit 0，说明当前服务端行为下不成立。

**自动模式的首轮时序**：`hasCompletedFirstRefresh()` 读的是 `WidgetDataStore.lastRefreshAt`，它在
`refreshAll` **整批结束后**才盖章，而自动触发发生在单个 provider 的 `refresh()` 内部——所以开着
Auto Sign In 启动时，第一轮必然命中「no refresh pass has completed yet」这道闸，要等下一个刷新周期
（默认 5 分钟）才会自动弹。实测：14:02:28 被挡，14:07:32 触发。这符合「避免启动即抢焦点」的设计意图，
但延迟比预期长。

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
  默认手动点击；Settings → General 的 **Auto Sign In to LLMCenter** 打开后每个 app 会话自动弹一次
  （仅限 `authExpired`）。
- 实现：`Sources/OpenUsage/Providers/LLMCenter/`（AuthStore / AuthClient / Host / SignInService /
  UsageClient / UsageMapper / Provider）。
- 文档：`docs/providers/llmcenter.md`（用户向）。
