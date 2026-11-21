# 不用關就生效：kit 改了什麼，開著的 agent 都拿得到（設計＋審查）

2026-11-21。狀態：設計，還沒實測、還沒做。研究結果在 herdr-jay 的 HANDOFF.md「不用關就生效」。

## 為什麼

jay：「有辦法都解決嗎」。現在 kit 加／拿掉東西後，Herdr 的 Kit mod 會對開著的 agent 打 `/reload-plugins` 或送一段規則訊息，但還有幾種改動只能寫「要重開」「要開新對話」，要 jay 自己關掉再開，對話就斷了：

- Claude 的 MCP：kit 寫在 `~/.claude.json`，`/reload-plugins` 不會重讀它（現在的表卻寫成 reload，見下面「現有程式的問題」）。
- Codex 的 MCP、外掛：只有 `/new` 才重讀 `config.toml`，`/new` 會丟掉對話。
- omp 外掛裡的 hook、擴充、自訂工具：要重開程式才載入。
- MCP 要用的環境變數：程式開的時候就定了，什麼 reload 都拿不到。

## 目標／不做

目標
- 每一種 kit 改動，開著的 agent 都能拿到，**而且對話還在**（同一個 session 接回去）。
- 只在 agent 停下來（idle、done）、沒有背景工作、沒在等你回答時動它。
- 做不到就不動，照舊告訴你「要重開」，並給你一行可以直接打的指令。

不做
- 不在 agent 工作中、或在等你回答時做任何事。
- 不碰 root 的 agent、只能看的 agent、`claude -p`／`codex exec` 這種不是互動的程式。
- 不自己做「重開」以外的花樣（例如注入設定到跑著的程式）。
- Windows 這一輪不做，排在最後一步。

## 做法 1：kit 把 Claude 的 MCP 包成 kit 自己的本機外掛

kit 已經有自己的 marketplace（`$KIT_CONF/plugins`，名字 `kit`，外掛裝成 `<名字>@kit`，`plugin_market`／`plugin_install`，unix/kit:681-723）。所以不用新開 marketplace，只多一個外掛：

- `kit-mcp`：`$KIT_CONF/plugins/kit-mcp/.claude-plugin/plugin.json` ＋ `.mcp.json`（內容就是現在寫進 `~/.claude.json` 的那幾個 server，`mcp_json` 產生）。`plugin.json` 的 `version` 用內容的 cksum，每次改內容就是新版本，Claude 才會重新複製（要實測：Claude 對本機 marketplace 是複製到 cache 還是直接讀）。
- 安裝：`claude plugin marketplace update kit`、`claude plugin install kit-mcp@kit --scope user`（沒裝過）或 `claude plugin update kit-mcp@kit`（裝過）。之後開著的 Claude 打 `/reload-plugins` 就連上新的、斷掉拿掉的（要實測是否需要 `--force`）。
- `kit-mcp` 只給 Claude：omp 也讀 `.claude-plugin`，`sync_plugins` 給 omp／Codex 裝外掛時要跳過 `kit-mcp`，不然 omp 會同時從 `~/.omp/mcp.json` 和外掛各拿一份。

**搬家（已經寫進 `~/.claude.json` 的）**
1. 只搬 kit 的：`state.tsv` 裡 kind `mcp` 有記的名字。你自己寫的（沒記、或記在 `skipped`）一個都不動。
2. 你自己已經有同名的 server：照現在的規則跳過，不放進 `kit-mcp`（不然會同一個 server 跑兩份）。
3. 順序：先備份 `~/.claude.json`（照現有 `.kit-backup` 的做法）→ 寫 `kit-mcp` → 安裝 → `claude plugin list --json` 確認它是 enabled → **這時才**從 `~/.claude.json` 刪掉、state 改記 `mcp.plugin`。中間任何一步失敗就停在舊的寫法，下次 `kit sync` 再試。不會出現兩邊都沒有。
4. 搬家當下開著的 Claude：舊的 server 還連著，`/reload-plugins` 後會多一份外掛的，工具出現兩份，直到重開。所以搬家那次對 Claude 是「重開接回」（做法 2），不是 reload。

**工具名字會變（最大的副作用）**
外掛的 MCP 工具名字是 `mcp__plugin_kit-mcp_<server>__<tool>`（要實測確認），不是 `mcp__<server>__<tool>`。會影響：
- 團隊的 deny（`required_deny`，unix/kit:931、1405、1458）：kit 要兩種名字都寫進 `permissions.deny`，不然團隊禁的工具**會變成能用**。這條不能省。
- 你自己在 settings 寫的 allow：會再問一次。kit 可以照樣幫你多寫一份新名字（只對 kit 管的 server）。
- 「用了幾次」（unix/kit:4042-4082 的 `umcp`）、context 的工具分類（unix/kit:3265、3293）、Herdr 的「拿掉」（context.js `removal` 的 `^mcp__`）都要認新的前綴。

**資料夾的 MCP（`kit add --dir`）**：這一輪不動，照舊寫 `.mcp.json` ＋ `settings.local.json` 的 `enabledMcpjsonServers` ＋ 信任（unix/kit:1692、1808）。開著的 agent 用做法 2 重開接回。以後真的需要，再做「每個 MCP 一個外掛 `mcp-<名字>@kit`，資料夾用 `--scope local` 裝」。

**環境變數（MCP vars）**：`.mcp.json` 裡照舊只放 `${VAR}`，不放值。值是 Claude 程式開的時候的環境，所以 `/reload-plugins` 拿不到新設的變數。`mcp_vars_warn` 的話改成「設好之後，要從有這個變數的 shell 重開」；Herdr 看到缺變數就不自動重開（重開也一樣缺）。另外：來源裡如果直接寫了 token，`~/.claude.json` 是 600，但外掛 cache 預設別的帳號讀得到 → `kit-mcp` 資料夾 `chmod 700`，並對看起來像 token 的值警告。

**`kit uninstall`**：先 `claude plugin uninstall kit-mcp@kit`，再走現有的「沒東西了就移掉 marketplace」（unix/kit:4919-4920）。你自己的 server 不動。

**`claude plugin` 沒有或太舊**：`claude plugin marketplace add` 跑不了（舊版、或沒裝 claude）→ 繼續寫 `~/.claude.json`（現在的做法），`kit list --json` 多一個欄位 `claude_mcp: "plugin" | "json"`，Herdr 照它決定 Claude 的 MCP 是 reload 還是重開接回。後端說，前端照著畫。

**`kit run`**：不變，照舊用暫時的 `--mcp-config`。

**Windows（kit.ps1）**：同樣的做法，放最後一步。

## 做法 2：Herdr 在 agent 停下來時「重開並接回同一段對話」

分工照 jay 的規則（前端只畫、資料和算法在後端）：

- **kit 算**（新指令，名字暫定 `kit relaunch-plan --pid <pid> --tool <工具> --json`，在 agent 那台跑）：找 session id、確認對話檔在、從原本的指令算出接回的指令。回 `{ ok, id, transcript, cwd, cmd: [...], why }`；`ok:false` 時 `why` 是給人看的原因。
- **Herdr Kit mod 做**：判斷時機、問你、打字、等、顯示結果。

**找 session id**（kit 做）
- Claude：`~/.claude/sessions/<pid>.json` 的 `sessionId`（有 `CLAUDE_CONFIG_DIR` 時在那裡），對話檔 `~/.claude/projects/<cwd 轉成的名字>/<id>.jsonl` 要存在、不是空的。
- Codex：`lsof -p <pid>`（Linux 讀 `/proc/<pid>/fd`）找開著的 `~/.codex/sessions/…/rollout-*-<uuid>.jsonl`。找不到就算了，**不用 `--last`**（同一個資料夾開兩個 Codex 會接錯）。
- omp：同樣用開著的檔案找 `~/.omp/agent/sessions/--<cwd>--/<ts>_<id>.jsonl`；不用 `-c`，理由同上。
- 對話檔不在（例如 Claude 是帶著 `CLAUDE_CODE_CHILD_SESSION` 開的，沒有存對話）→ `ok:false`，不重開。這是**不丟對話**的關鍵檢查，一定在關掉之前做。

**原本的指令**：不用 `ps`，`hc get <位址>` 已經有 `foreground.argv`、`foreground.cwd`、`foreground.pid`，也有終端機自己的 `argv`、`keep`。遠端機器一樣用 `hc get machine/t7`。kit 從 argv 算新指令：
- 拿掉：位置參數（開頭給的那段話，不拿掉會再送一次任務）、舊的 `--resume`／`-r`／`--continue`／`-c`／`--session-id`／`resume` 子指令。
- 加上：`claude … --resume <id>`、`codex resume <id> …`（選項放子指令後面）、`omp … --resume <id>`。
- 其餘旗標原樣保留（`--model`、`--permission-mode`、`--add-dir`、`--plugin-dir`、`-c key=val` …）。遇到認不得、可能吃一個值的旗標 → `ok:false`，不猜。
- `-p`／`--print`、`codex exec` → `ok:false`（不是互動的）。
- `kit run` 開的（`$KIT_CONF/run/<pid>` 有記號，或 argv 是 kit）：暫時的 `--mcp-config`、`--plugin-dir` 那些檔在程式結束時就被刪了（unix/kit:4830），所以**不能照抄**，改成 `kit run <名字> --tool <工具> --resume <id>`（kit run 會把多的參數接在後面；Codex 的 `resume` 放在 kit 的 `-c` 後面要實測）。
- 環境變數：從同一個 shell 再開，shell 的環境還在；只有「寫在同一行的 `X=1 claude`」會丟。Claude 一律加 `env -u CLAUDE_CODE_CHILD_SESSION`（不然新的對話不存檔）。

**什麼時候做**（Herdr，全部都要成立，任一不成立就繼續排隊）
1. 狀態 idle 或 done，`agents.busy` 沒有它（背景工作），`hc get` 的 `records` 沒有 working 的子 agent，Claude 的 `sessions/<pid>.json` 的 `status` 不是 busy。
2. 不是在等你回答（blocked 之類）；沒有排隊中或進行中的 `/compact`（`compactLive`）。
3. 不是 root 的、只能看的（`here.user` 有值，或 Kit 視窗是唯讀的那種）。
4. 程式結束後終端機會留下 shell：終端機的 `argv` 是 Herdr 的 shell 包裝（`…; exec "$0" -li`），或 `keep` 是 true。不然程式一關分頁就沒了 → 不做。
5. 輸入框是空的：`hc read` 最後一行沒有你打到一半的字。你正在那一格打字（它是 focused 而且最近有按鍵）就等。
6. 沒有被關掉自動重開（見下面「不要自動」）。
7. kit 那邊 `relaunch-plan` 回 `ok:true`，而且 MCP 要的環境變數都在。

**怎麼關、怎麼開**
1. `hc send` 打結束指令：Claude `/exit`、Codex `/quit`、omp `/exit`（omp、Codex 的要實測）。**不用 Ctrl+C、不用 kill**。
2. 等 `foreground` 變回 shell，最多 20 秒。沒變 → 停手，什麼都不再打，通知你「沒關掉，沒動它」。
3. 打 `cd <cwd> && <新指令>`（照 shell 種類引號；pwsh 用 `Set-Location`；路徑有空白、中文都要引號）。
4. 等 `foreground` 變回那個工具、狀態變 idle，最多 60 秒；`hc read` 看有沒有「No conversation found」之類的字。
5. 成功：通知「t1p 已重開並接回對話」。失敗：留在 shell，通知你，內容是那一行可以直接貼的指令。**不重試**（重試可能開出一段新的空對話）。

**狀態存在一個地方**：沿用 `reload/<位址>` 這一筆（一個 agent 只有一筆），多一個欄位 `relaunch: { state: "queued" | "quitting" | "starting", plan, at }`。Herdr 重開、或跟遠端斷線再連上時，看到停在 `quitting`／`starting` 的就不再自動做，改成通知你目前的狀況和那一行指令。

**問你**：一次 kit 改動問一次，不是每個 agent 問一次。Kit 的訊息那一行寫「t1p（Codex）、t96（omp）要重開才拿得到新的 MCP：[停下來時重開並接回] [我自己來]」，下面一行小字：「接回後，這次對話裡給過的『這次都允許』要再給一次；背景跑的東西不會被關（有背景工作會等它做完）」。

**不要自動**：每個終端機可以掛一個 label `hc label <t> kit.relaunch=off`（存在 core，換電腦、重開 Herdr 都還在）。Agent 的 Kit 視窗有一個開關改它。

**你會看到**：分頁標題旁「排隊重開（停下來就做）」→「重開中…」→ 通知「已接回」或「沒接回：請打 …」。

## 新的 RELOAD 表

值：`none` 自己會讀到；`reload` 打 `/reload-plugins`；`tell` 送規則訊息（現在 `ruleText` 那條特別路線，放進表裡）；`relaunch` 停下來時重開並接回；做不到 relaunch 時退回「要重開」的提示＋那一行指令。

| 工具 | skill | plugin | mcp | rule | MCP 的環境變數 |
|---|---|---|---|---|---|
| claude | none | reload | reload（`claude_mcp` 是 json 時：relaunch）；資料夾的：relaunch | tell | relaunch |
| omp | reload | relaunch（裡面有 hook／擴充／工具時；只有 skill 時 reload） | reload | tell | relaunch |
| codex | none | relaunch | relaunch | none | relaunch |

```js
export const RELOAD = {
  claude: { skill: "none", plugin: "reload", mcp: "reload", "mcp.dir": "relaunch", rule: "tell", var: "relaunch" },
  omp: { skill: "reload", plugin: "relaunch", "plugin.skills": "reload", mcp: "reload", rule: "tell", var: "relaunch" },
  codex: { skill: "none", plugin: "relaunch", mcp: "relaunch", rule: "none", var: "relaunch" },
};
```
`claude.mcp` 照 `kit list --json` 的 `claude_mcp` 決定（json → relaunch）；`plugin.skills` 照 kit 回報的外掛內容（kit 已經知道外掛裡有什麼）。`new`、`restart` 兩個值拿掉。

## 風險與對策

| 風險 | 會怎樣 | 對策 |
|---|---|---|
| 關掉後接不回 | 對話斷掉，jay 要自己找 id | 關之前先確認 session id 和對話檔在；接回失敗不重試，留 shell ＋給一行指令 |
| 背景工作被關掉 | 跑到一半的 build、子 agent 沒了 | `agents.busy`、`records`、`sessions/<pid>.json` 的 status 都要是閒的才做 |
| 打字打進你的草稿 | `/exit` 接在你打一半的字後面送出 | 輸入框不是空的、你正在那格打字就不做（現在的 reload／規則訊息也有這個問題） |
| 原本開頭那句話又送一次 | 同一個任務做兩次 | 新指令拿掉位置參數；認不得的旗標就不做 |
| 團隊禁的 MCP 工具變能用 | 外掛的工具名字不一樣，deny 對不到 | 兩種名字都寫進 deny；這步沒做好不能上線 |
| kit run 開的接回壞掉 | 暫時檔已經刪了 | 改用 `kit run <名字> --tool … --resume <id>` |
| 遠端斷線在中間 | 停在 shell，對話沒接回 | 狀態存在 `reload/<位址>`；連回後不再自動做，通知你那一行指令 |
| root、只能看的 agent | 收到 jay 帳號的改動訊息、甚至被重開 | 依 `here.user` 排除；這也是現在就有的問題（見下面） |
| 同一個 agent 排了好幾件 | `/reload-plugins`、規則訊息打進 shell | 一個 agent 一筆；有 relaunch 時丟掉排隊的 `/reload-plugins`（重開就全讀了），規則訊息也不送（接回時會讀新的 CLAUDE.md／AGENTS.md，要實測）；`/compact` 先做完才重開 |
| 接回後跟原本不完全一樣 | 「這次都允許」、中途換的 model、`/add-dir`、Remote Control 連線不見；程式會換成新版本 | 問你那一行就寫清楚；Remote Control 開著的不自動做（Claude sessions 檔有 `bridgeSessionId`）→ 歸到要 jay 決定的 |
| Windows | 沒有 lsof；shell 包裝不同 | 這輪不做；之後 Claude 先做（sessions 檔 Windows 一樣有），Codex／omp 用 rollout 檔的 cwd＋時間對 |
| 環境變數缺 | 重開了一樣連不上 | 缺變數就不自動重開，只提示去設定 |

## 現有程式的問題（順手看到的）

1. herdr-app/mods/kit/context.js:98 — `claude.mcp: "reload"`，但 kit 把 Claude 的 MCP 寫在 `~/.claude.json`，`/reload-plugins` 不重讀它，畫面卻寫「已重新載入」。做法 1 之前先改成提示「要重開」。
2. herdr-app/mods/kit/common.js:297-298 — `reloadOne` 遇到 agent 在等時直接 `setShared(key, null)` 再只送這次的字：之前排隊、還沒送的（例如工作中排的規則訊息，或那格不在畫面上所以 `tickCompact` 沒跑）就被丟掉了。應該先把排隊的 texts 和這次的合起來一起送。
3. herdr-app/mods/kit/header.js:326-328 — 排隊的東西只在那個 agent 的標題列有畫的時候才送（`tickCompact` 掛在 header 的 render）。不在畫面上的分頁可能排到 30 分鐘逾時都沒送。
4. herdr-app/mods/kit/common.js:271-276、context.js:124-128 — `reloadTargets` 只看機器和資料夾，不看帳號：在伺服器上用一般帳號改 kit，同台 root 的 agent 也會收到 `/reload-plugins` 和「請先讀 /home/<使用者>/…」。要排除 `here.user` 有值的。
5. herdr-app/mods/kit/common.js:306 — `reloadNext` 連續 `hc send` 不等前一個做完：omp 的 `/reload-plugins` 要重連 MCP，規則訊息可能在它還在 reload 時打進去。影響小，順手加一個 `hc wait`。
6. herdr-app/mods/kit/context.js:58-60 — `sendArgs` 只看狀態，不看輸入框有沒有你打到一半的字（上面風險表第 3 條，`/compact`、「清空重來」、reload 都受影響）。

## 要 jay 決定的

1. **Claude 的 MCP 要不要搬成外掛（做法 1）？** 好處：不用重開，背景工作、「這次都允許」都留著。壞處：工具名字變了（deny、allow、統計都要跟著改）、搬家複雜、`/reload-plugins` 連 MCP 還沒實測。
   建議：**先做做法 2（重開接回，四種情況一次解決），做法 1 等實測過 `/reload-plugins` 真的會連上、而且名字的事都處理好再做。**
2. **要不要問？問幾次？** 建議：每次 kit 改動問一次（列出會重開的 agent），加一個「以後都直接做」的選項，記在後端（kit 設定），不是每個 agent 問。
3. **Remote Control（手機連著）的 agent 要不要自動重開？** 建議：不要，只提示；手機那邊會斷線。
4. **omp 外掛只有 skill 時也重開嗎？** 建議：不要，只有 hook／擴充／工具才重開，其餘 reload。

## 分步驟

0. **實測**（不寫程式，在測試帳號或用完即丟的 agent）：`/reload-plugins` 會不會連上外掛新加的 MCP、要不要 `--force`；外掛 MCP 工具的名字；三個工具的結束指令；`claude --resume` 接回後 session id 是否不變、會不會重讀 CLAUDE.md；`codex resume <id>` 前面放 `-c` 行不行；`kit run … --resume <id>`。
1. 修上面「現有程式的問題」1、2、4（小改，加測試到 tests/kit/run.js）。
2. kit：`kit relaunch-plan`（unix），加測試到 tests/run.sh（各種 argv：開頭一句話、kit run、`-p`、舊的 `--resume`）。
3. Herdr：本機的重開接回（Claude、Codex、omp），問一次、label 關掉、狀態欄位、通知。新的 RELOAD 表。
4. Herdr：遠端機器（`hc get machine/t7`、`hc exec --on`），斷線後的處理。
5. kit：做法 1（如果 jay 同意），先在一台試，`claude_mcp` 欄位讓 Herdr 知道。
6. Windows：kit.ps1 的 `relaunch-plan`、做法 1；Herdr 的 Windows shell 包裝。兩份文件（docs/kit.md、kit 的 README）一起更新。

## 重開接回時使用者看到什麼（2026-11-21 jay 同意）

- 事前：右上角通知「<agent>（<工具>）要重開才讀得到新的 <種類>：等它這一輪做完，自動關掉再接回同一個對話」，按鈕：好／以後都直接做／這次不要。「以後都直接做」記在後端。
- 過程中：Herdr 在那一格蓋一層提示「套用 kit 的改動中… 關掉 → 接回同一個對話」，蓋住程式結束又啟動的閃動，接回、程式畫面出來才拿掉。
- 事後：通知「<agent> 已接回同一個對話，新的 <種類> 已經可以用」（幾秒後消失），標題列短暫顯示「已接回」。
- 接不回：遮罩改成紅字「接不回」，附可以複製的接回指令和「在這格重試」，對話紀錄在磁碟上不會丟。
- 不重開：在做事、等人回覆、輸入框有草稿時先等（標「等它停下來」）；手機遠端連著的那格只提示，不自動做（手機之後另外設計）。

## 第 0 步實測結果（2026-11-21，Mac）

| | Claude 2.1.330 | Codex 0.169 | omp 18.18.6 |
|---|---|---|---|
| 從外面找 session id | `~/.claude/sessions/<pid>.json`，一開就有 | `lsof` 找不到（rollout 檔由共用的 app-server 開著）；改用畫面：`/status` 的 `Session:` 行，或 `/quit` 後印的 `codex resume <id>` | `lsof` 可以，但要第一句話之後才開檔；資料夾名稱不一定是 `--cwd--` 格式 |
| 關掉 | `/exit`＋Enter（先出選單） | `/quit`（只斷開，daemon 裡的工作會繼續跑：一定要先確認閒著） | `/exit` |
| 關掉後畫面印的接回指令 | `claude <原本旗標> --resume <id>` | `codex resume <id>` | `omp --resume <id>` |
| 接回同一段、同一個 id | 是 | 是 | 是 |
| 接回後重讀規則 | 是 | 是 | 是 |
| 關＋開 | 約 5 秒 | 約 2 秒 | 約 4 秒 |

- 結論：最穩的做法是送關掉指令後，**讀畫面上工具自己印的接回指令**再執行，三個工具都會印，Claude 還帶上原本的旗標。找 id 只拿來核對。
- Codex 每次開會跳「有新版」選單，接回後要先 Esc，不然之後送的字會進選單。
- omp 關掉後留下 `~/.omp/run/session-owners/<id>.lock`，不影響接回。
- Claude 在 `/private/tmp/claude-*` 底下不讀資料夾的 CLAUDE.md（它自己的暫存區）。
- 沒測：Ctrl+C／Ctrl+D 關、`kit run` 開的 agent、別台機器、Windows。
