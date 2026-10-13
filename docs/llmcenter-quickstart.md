# OpenUsage 使用指南（查看 LLMCenter 个人额度）

OpenUsage 是一个 macOS 菜单栏小工具，可以直接在菜单栏上看到你的 LLMCenter（面壁智能）个人额度用了多少、还剩多少。

**运行环境要求：macOS 15 或更高版本。**

---

## 一、安装

1. 打开 `.dmg`，把 **OpenUsage** 拖到 **应用程序（Applications）**。

2. 打开「终端」，执行下面这行命令（**必做**）：

   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenUsage.app
   ```

   这个 App 没有经过 Apple 公证，不执行这一步，macOS 会提示 *"OpenUsage 已损坏"* 或 *"无法验证开发者"* 而拒绝打开。

3. 从「应用程序」启动 OpenUsage。它只在**菜单栏**显示，Dock 里不会有图标。

> 如果忘了第 2 步导致被拦截，也可以在**系统设置 → 隐私与安全性**里点「仍要打开」。

---

## 二、登录 LLMCenter

OpenUsage 读取的是你自己电脑上的登录信息，DMG 里**不包含任何人的账号**。首次使用时，LLMCenter 卡片会直接出现（不需要事先登录过），上面有 **Sign In to LLMCenter** 按钮——点一下，浏览器里确认授权即可，**不需要装任何命令行工具**。

授权成功后，登录信息写入本机的 `~/Library/Application Support/llmctl/config.json`，token 本身只有约 1 小时有效期，但登录时会同时保存一个长期有效的 refresh token，OpenUsage 会在到期前自动换新，**平时不需要再点登录**。只有 refresh token 也失效时，才需要再点一次 **Sign In to LLMCenter**。

> 这个路径和 `llmctl` CLI 共用。如果你本来就在用它，两边共享同一份登录；OpenUsage 写入时不会动文件里属于它的其他字段（access key、model、env）。

> LLMCenter 换过域名。老配置里的 `llm-center.modelbest.cn`（外网入口，已关闭）和 `…ali.modelbest.*` 会被 OpenUsage 自动切到内网的 `llm-center.modelbest.co`，不需要你手动改配置文件。

**还需要满足：**

- **能访问 LLMCenter 内网**——需要连公司网络或 VPN。断网时会显示连接错误，而不是旧数据。
- **账号已加入部门并有月度额度**——额度数字取自你在部门成员列表里的那一行。没有归属部门的账号没有额度可显示。

登录完成后卡片会自动刷新，不用手动点 **Refresh**。

---

## 三、你会看到什么

菜单栏上默认叠放两行：

```
¥120 / ¥225      ← 今日消耗 / 今日软额度
¥3.2K / ¥7K      ← 本月消耗 / 本月额度
```

点开菜单栏图标，LLMCenter 卡片（默认排在最上方）包含：

| 行 | 含义 |
|---|---|
| **Today** | 今日消耗，对比**软性日额度**（月额度 ÷ 当月天数） |
| **This Month** | 本月消耗，对比你的月度额度 |
| **Yesterday** | 昨日消耗与 token 数 |
| **Usage Trend** | 本月每日消耗折线图 |

把鼠标悬停在 Today / This Month / Yesterday 上，可以看到**分模型的消耗明细**。

**几个可调的地方**（点菜单栏图标 → 齿轮 **Settings**）：

- **Menu Bar Values**：菜单栏显示具体金额（`¥120 / ¥225`）还是百分比（`53%`）。
- **Show Usage As**：显示**已用**还是**剩余**。
- 点 **Customize** 可以增删菜单栏上钉住的指标、调整卡片顺序。

---

## 四、其他 AI 服务

这个 App 同时支持 Claude、Codex、Cursor 等。它会自动检测你电脑上**已有的**登录，检测到哪个就显示哪个——你没用过的服务不会出现。不需要额外配置。

顶部的 **Total Spend** 圆环图汇总各家花费。LLMCenter 的人民币金额会按当前汇率折算成美元后计入，所以它的那一份会标注为估算值。

---

## 五、常见问题

| 提示 | 怎么办 |
|---|---|
| **"OpenUsage 已损坏"** | 没执行安装第 2 步的 `xattr` 命令 |
| **"Not signed in to LLMCenter"** | 点卡片上的 **Sign In to LLMCenter**，在浏览器里确认即可 |
| **"LLMCenter login expired"** | 自动续期也失败了，点 **Sign In to LLMCenter** 重新授权即可 |
| **每个指标都报 HTTP 404 / 418** | 配置文件里的 `api` 地址已失效。已知的旧地址（`llm-center.modelbest.cn`、`…ali.modelbest.*`）App 会自动切到可用地址；若仍报错说明是个没见过的地址，手动改成可访问的即可，token 不用换 |
| **连接错误 / 数字不更新** | 检查是否连着公司网络或 VPN |
| **有额度但显示不出来** | 确认账号已归属部门且分配了月度额度 |

自查命令：

```bash
# 应当输出包含 "api" 和 "web_token" 的内容
cat ~/Library/Application\ Support/llmctl/config.json

# 用配置文件里的那个 api 地址探测（不要写死域名——地址是会变的）。
# 401 说明地址有效、只是没带 token；404 说明这个地址已经不服务了，需要换。
API=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/llmctl/config.json")))["api"])')
curl -sS -o /dev/null -w '%{http_code}\n' "$API"
```

---

## 六、说明

- **不会自动更新。** 这个版本包含公开版没有的内网 provider，因此刻意关闭了自动更新——有新版本会直接发新的 DMG 给你。
- **不支持 iCloud 同步**（该功能需要付费开发者账号的配置文件）。其余功能均正常。
- **数据不出本机。** 额度数字直接向 LLMCenter 的接口查询，凭证只在你自己的电脑上读取。
- **每个人看到的是自己的数据。** 同一个 DMG，不同人打开显示各自的额度。
