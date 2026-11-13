# kit 各版改了什麼

最新的在上面。每一版寫了更新後要做什麼。看自己的版本：`kit --version`。
更新：`kit self-update`，再 `kit sync`；終端機程式整個關掉重開。
**每台跑 agent 的電腦或主機都要更新**（例如連到的 Linux），不然那台的 agent 用不到新功能。

## 0.5.0（2026-11-13）

更新後要做：`kit self-update`、`kit sync`。

**貼上 MCP 設定**
- 新增 `kit new mcp [名字] --config <檔案|->`：把別人給的 MCP 設定（`{"mcpServers": …}` 這種 JSON、`claude mcp add …`、`codex mcp add …`、Codex 的 `config.toml`）存成檔案交給 kit，kit 寫成來源裡的 `mcp/<名字>.yaml`。設定裡有好幾個時，kit 列出名字請你選。
- `--look`：只看會寫成什麼，不寫（一行 JSON，給畫面程式用）。

**密碼、token 不進來源**
- 貼上時，像密碼或 token 的值（名字有 KEY、TOKEN、SECRET、PASSWORD、AUTH 這些的、`Authorization` header、`sk-`、`ghp_` 開頭的、網址裡的密碼……）自動換成 `${變數名}`，只告訴你變數名字，不印出值。
- `kit check`（所以 `kit push`）看到 mcp 的 yaml 裡直接寫著像密碼或 token 的值，就不讓過。
- `kit sync` 時這台電腦沒設的變數會提醒一次。

**網址的 MCP**
- mcp 的 yaml 可以寫 `type: http`（或 `sse`）、`url`、`headers`。Claude Code、omp 照寫；Codex 寫成 `url`、`bearer_token_env_var`、`env_http_headers`、`http_headers`。Codex 不能用 SSE，這種的不放進 Codex（說一次）。
- Codex 不會代換 `${…}`：env 裡同名的 `${X}` 改用 `env_vars` 直接傳過去；其他照字面放並說一次。

**MCP 的套件**
- 貼上時把 `npx 套件`、`uvx 套件` 固定在現在最新的版本（只有這裡會連網查版本）。
- 新增 `kit install-deps mcp <名字>`：把那個版本裝在 `~/.config/agentkit/mcp-deps/<名字>/`（跟 skill 的套件同樣的規則），之後每個工具直接跑裝好的那份，不用每次啟動時下載。沒裝的 `kit list` 會寫「每次啟動時下載」。
- `kit list` 的 `needs` 也列出 mcp 要的程式（node、uv、python、docker）。
- `kit new mcp <名字>`（不貼）產生的範本兩種寫法都有（跑程式、連網址）。

**給程式讀的介面（1.3）**：`kit api` 印 `1.3`。新增 `kit new mcp … --config … --look` 和錯誤 code `bad_config`、`several_servers`、`not_found`、`no_name`、`bad_name`、`exists`；`kit list --json` 的 mcp 多了 `type`、`vars`、`needs`、`packages`。要用的程式先確認 minor 至少是 3。

## 0.4.1（2026-11-13）

更新後要做：`kit self-update`。

**照訊息分組的檔案清單**
- `kit files --json` 多一個 `turns`：照你送出的每一則訊息分組（像 Claude Code 的 `/rewind`），每組有第幾則（`n`）、時間（`at`）、訊息的開頭（`text`，最多 30 個字）和那則訊息之後 agent 碰過的檔案。畫面程式可以列出「第 12 則 · 03:41 · 訊息開頭」，底下是那次動到的檔案。最新的在前，最多 30 則，每則最多 50 個檔案。Claude 的 sub-agent 碰的檔案照時間算進主對話的那一則；Codex、omp 也有。
- 這是 kit 第一次從紀錄裡拿出對話的字：只有每則訊息開頭最多 30 個字，其他的還是不拿。
- 沒有 `--json` 時印的清單沒變；`files` 也沒變。

**給程式讀的介面（1.2）**：`kit api` 印 `1.2`（`kit files` 新增 `turns`）。要用 `turns` 的程式先確認 minor 至少是 2。

## 0.4.0（2026-11-13）

更新後要做：`kit self-update`。

**agent 讀過、改過的檔案**
- 新增 `kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]`：從 agent 自己的紀錄檔列出它讀過、改過、新寫的檔案（新的在前，同一個檔案只列一次，最多 200 個）。Claude 連它的 sub-agent 一起看；Codex 只看得到 patch 改的檔案；omp 看它的 read／edit／write。`--git` 再加上 `git status` 有變動的檔案。只拿路徑，不讀出對話或檔案內容。
- 給畫面程式用（例如在 agent 窗格上跳出清單、點一下用編輯器打開）：`--json` 印一行 JSON，欄位見 README 的「給程式讀的介面」。

**給程式讀的介面（1.1）**：`kit api` 印 `1.1`（新增 `kit files`）。要用 `kit files` 的程式先確認 minor 至少是 1。

## 0.3.0（2026-11-13）

更新後要做：`kit self-update`、`kit sync`。用 Herdr 的 kit 面板的話，Herdr 的面板改由你的 Herdr 設定提供（看那邊的說明）。

**Herdr 的面板搬出 kit**
- Herdr 的 kit 面板（Kit 清單、Agents、每個窗格的 Kit 按鈕和 context 那格）搬出 kit：Herdr 的面板改由你的 Herdr 設定提供（看那邊的說明）。kit 裡不再有 Herdr 的東西。
- `kit herdr-panel install|uninstall` 拿掉了。
- 升級（`kit self-update`、重跑安裝）時，已經裝在 Herdr 裡的舊面板 kit 不會去動：不更新、也不刪，怎麼換掉看你的 Herdr 設定說明。kit 自己安裝資料夾裡舊版留下的 `herdr/` 會刪掉。

**給程式讀的介面（1.0）**：README 的「給程式讀的介面」是唯一的清單（指令、欄位、錯誤 code）。
- 新增 `kit api`：印 `major.minor`（現在 `1.0`）。不相容的改變 major 加一，新增欄位或指令 minor 加一。
- 新增 `kit push --json`（可以加 `--dry-run`）：一行 JSON 寫會送（或送了）哪些檔案、沒送的檔案、commit 訊息、分支、PR 要合進哪裡、推到哪些 remote、PR 的網址。
- `kit list --json`：每個來源多 `changed`（`kit push` 會送的檔案），每個項目多 `changed`（`kit push` 會送它）。畫面程式不用再自己跑 git。
- `kit list --json`、`kit agents --json`、`kit push --json`、`kit collect --look`：stdout 只有 JSON，給人看的字都在 stderr；失敗時 stdout 是 `{"error": {"code": ..., "message": ...}}`（例如還沒 `kit init` 是 `not_init`）。
- `kit help` 列出 `kit collect ... --look` 和 `kit list --json --dir ... --pid ...`。

**其他**
- `json.awk`（和 `kit.ps1` 裡對應的部分）拿掉只給 Herdr 版面用的操作（`rmwhere`、`addnear`、`addbefore`、`swapwhere`、`rmholder`、`rowaround`、`unrow`）。
- Windows：`kit push` 判斷哪些檔案要送時分大小寫，跟 Mac／Linux 一樣（`Rules/x.md` 不算 rule）。
- 來源資料夾一律用解開捷徑後的路徑（symlink；Windows 也解開 junction 和 subst 的磁碟機）：`kit init` 存的，和 `kit push`、`kit check`、`kit new`、`kit update` 拿來比的，都是同一個。修好：在 Mac 上用經過捷徑的路徑（例如 `/tmp/...`，其實是 `/private/tmp/...`）`kit init` 的來源，`kit push`、`kit check` 會把它算成兩個、說名字重複。以前這樣 init 的不用重來，升級後就好；CLAUDE.md 裡引用規則的路徑也跟著改成解開後的（`kit sync` 自己會改）。

## 0.2.0（2026-11-12）

更新後要做：`kit self-update`、`kit sync`、Herdr 整個關掉重開。

**context：agent 的 context 用了多少、用在哪裡**
- `kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾]`：印出用了多少（JSON）。Claude Code、Codex、omp 都可以。
- `kit context ... --detail`：像 Claude Code 的 `/context`，分類列出 token 用在哪裡（系統提示、工具、MCP、記憶檔、Skills、對話內容……）。Claude 的數字是問 Claude Code 自己的（不花錢、不叫模型、不跑 hook、不寫對話紀錄）；Codex、omp 用它們自己記的總數，各類是估的。
- `kit statusline`：`kit sync` 會在 Claude 底下的狀態列放「context 35%（139k / 400k）」。你已經有自己的 statusLine 時 kit 不動它。
- Herdr：每個 agent 窗格上方，Kit 按鈕右邊多一格 `context 35% 139k/400k`；按一下跳出細項視窗，可以看清單、拿掉 kit 管的 skill／規則／MCP、壓縮（`/compact`）、清空重來（`/clear`、`/new`）。（之後搬出 kit，見「下一版」。）

**skill 需要的程式和套件**
- `kit tools`、`kit install-tool <程式> [--min 版本]`：skill 要的 node、python、git 這台沒有或太舊時，告訴你，也可以一鍵安裝。
- `kit install-deps <skill> [npm|pip]`：skill 自己要的 npm 或 Python 套件，裝在 kit 自己的資料夾（Python 用 skill 自己的 venv），不跑套件的安裝程式。
- Herdr 的 Kit 清單：缺的程式或套件會出現「⚠ 需要…［安裝］」，先顯示要執行的指令，確定才裝。

**資料夾自己的規則、skill、MCP**
- `kit add/rm --dir <資料夾> ...`：只加到（或拿掉）那個資料夾的；在資料夾開的 agent 才會讀到。Herdr 的 Kit 清單在資料夾裡的 agent 上，只改那個資料夾。

**Claude 開啟時檢查有沒有在存對話紀錄**
- 從另一個 Claude 裡開的 Claude（例如用 Herdr 的 `hc` 開新分頁）會帶著 `CLAUDE_CODE_CHILD_SESSION=1`，這樣的 Claude **不存對話紀錄**，關掉後 `/resume` 找不回來。kit 在 Claude 開啟時檢查，遇到就跳警告。
- 正確開法：Mac、Linux `env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude`；Windows（PowerShell）`$env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='1'; claude`。
- Windows 讀不到時不警告（例如 npm 裝的 Claude）。Codex、omp 不會這樣，不檢查。不想要：設 `KIT_TRANSCRIPT_CHECK=0`。

## 0.1.0（2026-11-11 以前）

第一版：`init`、`sync`、`list`、`add`、`rm`、`run`（Claude、Codex、omp）、`new`、`diff`、`update`、`check`、`push`、`collect`、`outdated`、`export-self`、`ci-template`、`self-update`、`uninstall`、簽名核准（`kit approve`），以及 Herdr 的 Kit 面板（`kit herdr-panel install`）。
