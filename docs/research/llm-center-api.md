# LLM Center（llm-center.modelbest.cn）API 参考

> 面向 agent 的协议参考：访问、鉴权、接口、坑位。内容来自 2026-08-05 对真实账号的实测逆向
> （`llmctl` CLI 行为、官网 SPA JS 反查、curl 直连探测），并已落地为 OpenUsage 的
> `LLMCenterProvider` 实现。未确认项标注了状态。

## 概览

- **平台**：面壁智能（ModelBest）的 LLM 用量/费用中心，官网 `https://llm-center.modelbest.cn`。
- **配套 CLI**：`llmctl`（Go，v0.1.0，`LLMC-ANC-0.1` 协议），是官方唯一文档化的访问方式。
- **前端**：SPA（`/assets/index-bYn18TUE.js` + 懒加载 chunk），路由含 `/usage`、`/usage/billing`、
  `/stability`、`/cli-guide` 等；各页面数据接口拆在 `api-*.js` 模块里。

## 鉴权

**凭证位置（macOS，`llmctl auth login` 后写入）**：

```jsonc
// ~/Library/Application Support/llmctl/config.json
{ "api": "https://llm-center.ali.modelbest.co", "web_token": "<347 字符 Rosefinch bearer token>" }
```

- 请求头：`Authorization: Bearer <web_token>` + `Content-Type: application/json`。
- **凭证获取**：`llmctl auth login`（浏览器授权；无头环境 `LLMCTL_NO_BROWSER=1` 或 `--no-open`
  时打印授权 URL，在任何设备打开完成后回填）。
- `llmctl` 支持的环境变量（GUI 应用不继承 shell 环境，故 OpenUsage 只读配置文件）：
  `LLM_CENTER_API_URL`、`LLM_CENTER_WEB_TOKEN`、`LLM_CENTER_API_KEY`。
- **注意**：`config.json` 的 `web_token` 是 CLI 登录身份，**与浏览器登录身份可能不同**（见"坑位"）。

## 网络特性（实测）

- 域名解析到内网地址（`30.100.0.x`）；`llm-center.ali.modelbest.co` 301 → `llm-center.modelbest.co`，
  两者 API 路径都可用。
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

## OpenUsage 集成现状

- Provider：id `llmcenter`，显示名 "LLM Center"，图标 `llmcenter.svg`（官方 logo）。
- 指标：Today / This Month（自然月）/ Yesterday / Usage Trend（月内每日 tokens），全部 ¥。
- 凭证：读 `~/Library/Application Support/llmctl/config.json`，无手动输入；`hasLocalCredentials()`
  探该文件，首次启动自动启用。
- 实现：`Sources/OpenUsage/Providers/LLMCenter/`（AuthStore / UsageClient / UsageMapper / Provider）。
- 文档：`docs/providers/llmcenter.md`（用户向）。
