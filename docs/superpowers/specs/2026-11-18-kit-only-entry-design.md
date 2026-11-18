# kit 是唯一入口：非公司的東西只能透過 kit 載入

日期：2026-11-18　狀態：已核准，實作在 0.7.0

## 為什麼

rule、skill、MCP、外掛現在可以從很多地方進來：agent 自己用 npx 裝、工具更新時自己放、手動複製。散在各處，沒辦法管理。
使用者要的是：**公司的東西照原樣不動；其他的一律只能透過 kit。**
「公司」指的是工具原廠（Anthropic、OpenAI）或公司管理員放的東西，不是指 kit 的團隊來源。

## 目標

- 判斷每個 skill、MCP、外掛是「公司的」還是「非公司的」。
- 公司的：kit 不收、不擋、不改，照原樣載入。
- 非公司的：不在 kit 清單上就不讓 Claude Code、Codex、omp 載入。
- 被擋下的東西在 Kit 面板列出來，提供「收進 kit」這條路。

## 不做的事

- 不刪檔案，也不搬檔案：只改各工具「載入什麼」的設定。理由：Claude 同步、Codex 更新會把東西放回來，搬檔案會一直來回拉扯，刪檔案也可能讓資料遺失。
- 這一版不碰需要 root 權限才能改的系統設定（Claude `managed-settings.json`、Codex `/etc/codex/requirements.toml`）。之後要擋得更死再另外做。
- 不把公司的東西收進 kit。

## 不能接受的結果（就算技術上做到也算失敗）

- 公司派發的東西被擋掉。
- kit 清單上的東西被擋掉。
- 使用者自己寫的設定（不是 kit 寫的那些項目）被蓋掉或消失。

## 怎麼判斷「公司的」

| 種類 | 判斷依據 |
|---|---|
| 工具原廠 | Claude：`~/.claude/skills/synced/<org>_<user>/manifest.json` 裡 `source` 是 `anthropic` 或 `anthropic-example`；程式內建的 skill（不在磁碟上）；claude.ai 帳號或組織的 connector（雲端 MCP，不在本機設定檔裡）。Codex：`~/.codex/skills/.system/`（有 `.codex-system-skills.marker`）。omp：它自己下載或內建的（例如 `~/.omp/agent/tools/yt-dlp`）。 |
| 公司管理員 | 需要 root 權限才能改的系統設定，以及那個資料夾裡的 skill：Claude `/Library/Application Support/ClaudeCode/`、`/etc/claude-code/`、Windows `C:\Program Files\ClaudeCode\`；Codex `/etc/codex/`、`%ProgramData%\OpenAI\Codex\`。Claude 同步的 skill 裡，`source` 不是 anthropic，而且那個 bucket 的 org 是 Team 或 Enterprise（`~/.claude.json` 的 `oauthAccount.organizationType`）。 |
| 公司專案 | 專案資料夾裡 commit 進 git 的 `.claude/skills`、`.agents/skills`、`.codex/skills`、`.omp/skills`、`.mcp.json`（`git ls-files` 有列）。 |

**我的判斷：從 marketplace 裝的外掛不算公司的。** 就算是 Anthropic 官方 marketplace 也一樣：那裡面也有第三方做的外掛，而且是使用者自己選了才裝，所以一律走 kit。

其餘都算非公司的，例如：帳號層的 `~/.claude/skills/<名字>`、`~/.agents/skills`、`~/.codex/skills/`（`.system` 除外）、`~/.omp/agent/skills`；帳號層自己加的 MCP、外掛；專案裡沒 commit 的。
kit 自己放的東西照 kit 現有的紀錄辨認，算「在清單上」。
以前 kit 放的、使用者 `kit rm` 時因為改過而留下來的 skill，不在清單上，會被擋下。這是使用者 rm 時本來就要的結果。這台目前沒有這種 skill 留在磁碟上。

## 做法（使用者選的：第一層，只改設定、不用 root）

每次 `kit sync`（包括開工具時的 `--hook`）：

1. 列出每個工具會讀到的 skill、MCP、外掛。
2. 每個分成三類：在 kit 清單上／公司的／其他。
3. 「其他」寫進各工具的關閉設定：

| 工具 | skill | MCP | 外掛 |
|---|---|---|---|
| Claude Code | 帳號層：`~/.claude/settings.json` 的 `skillOverrides: {"<名字>": "off"}`；專案層：寫進那個專案的 `.claude/settings.local.json`（Claude 本來就把這個檔案當成只在本機用、不 commit），帳號層的同名 skill 才不會被一起關掉 | 專案 `.mcp.json`：`disabledMcpjsonServers`；帳號層 `~/.claude.json` 的 `mcpServers`：拿掉之前，把整筆原本的內容一筆一筆記在 kit 自己的紀錄裡；之後收進 kit、判定為公司的或 `kit uninstall` 時，照原樣放回去 | `enabledPlugins: {"<外掛>": false}` |
| Codex | `~/.codex/config.toml` 的 `[[skills.config]] name="<名字>" enabled=false` | `[mcp_servers.<名字>] enabled=false` | `[plugins.<外掛>] enabled=false` |
| omp | `~/.omp/agent/config.yml` 的 `skills.ignoredSkills`（或 `disabledExtensions: skill:<名字>`） | `disabledExtensions`（MCP） | 外掛 enabled 開關 |

**實測過（2026-11-18，用暫時的 probe skill）：** 三個工具的 skill 關閉設定都有效。Claude `--settings '{"skillOverrides":{"x":"off"}}'`、Codex `-c 'skills.config=[{name="x",enabled=false}]'`、omp `--config` 疊上 `skills.ignoredSkills: [x]` 之後，模型都說看不到那個 skill；不加的時候看得到。MCP 和外掛的關閉設定還沒實測。

4. kit 在每個設定檔記下哪些項目是它寫的。下一次 sync 只改自己寫的那些；東西被收進 kit 或判定為公司的之後，就把對應的關閉設定拿掉。
5. Kit 面板列出「被擋下的」：名字、在哪、為什麼不是公司的，加上「收進 kit」按鈕。查得到原本網址、也有 LICENSE 的，用 `kit collect`；查不到的，用 `kit new --from <本機資料夾>`，在來源的說明裡記下它從哪裡來。只收進使用者自己的來源（`push: direct`），不收進團隊來源。這台的慣例是：別人寫的（有原本網址）收進 `agentkit-library`，需要時先把原作者加進它的 `collect_sources`；自己寫的、個人的收進自己的私人來源。
6. 要看哪些專案：開工具時 hook 所在的那個資料夾，加上 kit 已經知道的資料夾（`kit add --dir`、`kit place` 過的）。不去掃整台電腦。
7. 收進 kit 的東西，原本的位置剛好就是 kit 要放的地方時（例如 `~/.claude/skills/ui-ux-pro-max`）：先把舊的那份備份起來，再換成 kit 的，和 `kit sync --force` 一樣。這樣它就「在清單上」，不會被同名的關閉設定擋掉。

另外加一條 rule：agent 要裝 skill、MCP、外掛一律用 kit，不准直接 npx 或複製。這只是讓 agent 一開始就走對的路，真正擋住的是上面的設定。

**套用範圍（使用者決定）：每個用 kit 的人、每台電腦都一律開，沒有開關。** 因為同事 `kit self-update` 之後，自己裝的東西會被擋，所以：

- `docs/changes.md` 那一版要寫清楚會擋什麼、被擋的東西去哪裡看、怎麼收進 kit。
- 更新後第一次 `kit sync`，在終端機和 Kit 面板列出這次被擋下的東西。

## 已知的弱點

- agent 可以去改那些設定檔，要等下一次 `kit sync` 才會改回來。要完全杜絕就得做第二層（root 權限的系統設定）。
- 判斷「公司管理員派發的 Claude 同步 skill」靠 `source` 欄位和 org 類型。目前這台只看過 `anthropic`、`anthropic-example` 兩種值，其他值的實際樣子還沒看過。

## 第一批：把目前非公司的都收進 kit（使用者要求）

這台 2026-11-18 盤點，不是 kit 的、也不是公司的：

| 東西 | 在哪 | 處理 |
|---|---|---|
| `ui-ux-pro-max`、`banner-design`、`brand`、`design`、`design-system`、`slides`、`ui-styling`（npx 裝的 7 個 skill） | `~/.claude/skills/` | 把 `github.com/nextlevelbuilder/ui-ux-pro-max-skill`（MIT）加進 `agentkit-library` 的 `collect_sources`，用 `kit collect` 收進 `agentkit-library`，再加到整個帳號，由 kit 接手原本的資料夾（上面第 7 點） |
| nvim-jay 的 hook（PreToolUse、Stop、SubagentStart/Stop） | `~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.omp/agent/hooks/pre/nvim-jay.js` | kit 沒有單獨的 hook 種類，要包成 kit 外掛（skill、hook、MCP 一起）才收得進來；公司也在用，所以外掛放在 herdr-jay、從 GitHub 收（待定） |

MCP（只有 `kit-ping`）和外掛（只有 `ponytail@kit`）都已經是 kit 的。

## 動手前要先確認

實作的第一步：在三個工具現在的版本上，實際試過上面每一個關閉設定，確認會照文件寫的那樣生效。這些設定的名字和效果目前只查了官方文件，還沒實測。
