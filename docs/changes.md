# kit 各版改了什麼

最新的在上面。每一版寫了更新後要做什麼。看自己的版本：`kit --version`。
更新：`kit self-update`，再 `kit sync`；終端機程式整個關掉重開。
**每台跑 agent 的電腦或主機都要更新**（例如連到的 Linux），不然那台的 agent 用不到新功能。

## 0.5.1（2026-11-13）

更新後要做：`kit self-update`。

**context 細項：工具不再顯示成「?」**
- 有些公司的 gateway 會把 Claude 回來的 JSON 欄位照字母排（`"id"` 在 `"type"` 前面）。以前 kit 以為 `"type"` 一定排第一個，結果「工具（呼叫＋結果，依工具）」全部變成「?」、次數 0，「怎麼省」也說「?」。現在不管欄位怎麼排都認得出工具名稱。
- agent 動過的檔案清單（Read、Write、Edit）也一樣，以前在這種 gateway 下會漏掉或對錯檔案。

## 0.5.0（2026-11-13）

更新後要做：`kit self-update`、`kit sync`。

**貼上 MCP 設定**
- 新增 `kit new mcp [名字] --config <檔案|->`：把別人給的 MCP 設定（`{"mcpServers": …}` 這種 JSON、`claude mcp add …`、`codex mcp add …`、Codex 的 `config.toml`）存成檔案交給 kit，kit 寫成來源裡的 `mcp/<名字>.yaml`。設定裡有好幾個時，kit 列出名字請你選。
- `--look`：只看會寫成什麼，不寫（一行 JSON，給畫面程式用）。

**密碼、token 不進來源**
- 貼上時，像密碼或 token 的值（名字有 KEY、TOKEN、SECRET、PASSWORD、PASSPHRASE、AUTH 這些的，或有一段是 PASS、PWD、PW 的（`DB_PASS`、`MYSQL_PWD`）、`Authorization` header、`sk-`、`ghp_` 開頭的、網址裡的密碼……）自動換成 `${變數名}`，只告訴你變數名字，不印出值。
- `${變數名:-預設}` 的預設像密碼或 token 也算：貼上時換成 `${變數名}`，`kit check` 不讓過。
- server 名字是數字開頭的（`1password`），變數名字前面加 `MCP_`（`MCP_1PASSWORD_TOKEN`），不會是不能用的變數名字。
- `kit check`（所以 `kit push`）看到 mcp 的 yaml 裡直接寫著像密碼或 token 的值，就不讓過。
- 「很長的亂碼」要大小寫和數字混得很亂才算：`--workspace=AcmeCorpProduction2024` 這種英文字接起來的不算。kit 還是看錯時，在 yaml 最上層寫 `not_secret: ["args[3]"]`（列出那幾欄），`kit check` 就不管那幾欄（見 README 的「MCP」）。
- `kit sync` 時這台電腦沒設的變數會提醒一次。

**網址的 MCP**
- mcp 的 yaml 可以寫 `type: http`（或 `sse`）、`url`、`headers`。Claude Code、omp 照寫；Codex 寫成 `url`、`bearer_token_env_var`、`env_http_headers`、`http_headers`。Codex 不能用 SSE，這種的不放進 Codex（說一次）。
- Codex 不會代換 `${…}`：env 裡同名的 `${X}` 改用 `env_vars` 直接傳過去；其他照字面放並說一次。

**MCP 的套件**
- 貼上時把 `npx 套件`、`uvx 套件` 固定在現在最新的版本（只有這裡會連網查版本）。npm 寫了範圍或標籤的（`套件@^1`、`套件@next`）固定在符合它的最新版本，並提醒你原本寫什麼、固定在哪一版；確切的版本照寫的。
- 新增 `kit install-deps mcp <名字>`：把那個版本裝在 `~/.config/agentkit/mcp-deps/<名字>/`（跟 skill 的套件同樣的規則），之後每個工具直接跑裝好的那份，不用每次啟動時下載。沒裝的 `kit list` 會寫「每次啟動時下載」。
- `kit list` 的 `needs` 也列出 mcp 要的程式（node、uv、python、docker）。
- `kit new mcp <名字>`（不貼）產生的範本兩種寫法都有（跑程式、連網址）。

**這個帳號用哪一版：`kit status --json`**
- 新增 `kit status --json`：印 kit 的版本和 api、帳號名稱、時間、kit 本身和每個來源現在的 commit；用核准紀錄的帳號（例如 root）再加上核准紀錄的 serial、簽章對不對、每個的核准 commit。畫面程式（例如每台、每個帳號一格的面板）比 `commit` 和 `approved`，就知道是不是在用核准的那一版。欄位見 README 的「給程式讀的介面」。
- 只讀這台已經有的：不連網、什麼都不寫、不拿鎖。畫面程式不能直接問的帳號（root）可以自己跑 `kit status --json > <檔案>`，畫面程式讀那個檔案。
- Windows 版：一樣的指令、一樣的輸出，只是沒有核准紀錄：`approvals`、`approved` 一律是 `null`。

**一個資料夾就是一個 agent：`kit place`**
- 新增 `kit place <agent> <資料夾> [--tool claude|codex|omp] [--json]`：建好資料夾，放進 agent 的規則、skill、MCP（跟 `kit add --dir` 一樣），提示寫進資料夾的 `CLAUDE.md`／`AGENTS.md`，工具限制寫進資料夾的 `.claude/settings.local.json`。之後在那裡開的 `claude`、`codex`、`omp` 就是那個 agent；`kit add|rm --dir` 只改這個資料夾，`kit sync` 照 agent 檔更新。
- `kit sync` 照 agent 檔放它的規則、skill、MCP：agent 檔新加的放進來，拿掉的拿掉。`.agentkit` 只記你改過的：`種類:名字` 是你另外加的，`not:種類:名字` 是你用 `kit rm --dir` 拿掉的 agent 的（不會被放回來，再 `kit add --dir` 才回來）。
- agent 檔找不到或讀不懂（改了名字、來源不在、核准的版本沒有它）：資料夾照上次的樣子不動（提示、工具限制、MCP 都留著），說一次。
- 你自己已經有的 deny（帳號的 `settings.json`、資料夾的 `settings.local.json`）kit 不算成它的，之後也不會拿掉。
- 同一個 agent 再 place 一次只同步；別的 agent 的資料夾、或已經有別的東西的資料夾不動。Codex 不能只開某些工具、只能禁用 MCP 的工具，omp 在資料夾裡不能限制工具、只讀整個帳號的 MCP：做不到的會說。
- `kit list --json --dir` 的 `here.folder` 多了 `agent`（`kit place` 放的 agent 的名字，不是就 `null`）；這種資料夾的 `here.folder.items` 也列出 agent 的規則、skill、MCP（不含你拿掉的）。

**其他**
- `kit new` 失敗就是失敗：`--to` 找不到、檔案寫不進去時 exit 不是 0，`--look` 時 stdout 只有錯誤的 JSON（之前會再印一行，或說「已建立」）。
- Windows：`kit new mcp --config -` 用 UTF-8 讀標準輸入（Windows PowerShell 5.1 之前用主控台的字碼頁，中文會壞）；查 PyPI 前先開 TLS 1.2；名字只把 A-Z 變小寫（跟 Mac／Linux 一樣）。

**給程式讀的介面（1.3）**：`kit api` 印 `1.3`。新增 `kit status --json`、`kit new mcp … --config … --look`、`kit place … --json` 和錯誤 code `bad_config`、`several_servers`、`not_found`、`no_name`、`bad_name`、`exists`、`no_agent`、`no_parent`、`other_agent`、`not_empty`、`bad_dir`；`here.folder.agent`；`kit list --json` 的 mcp 多了 `type`、`vars`、`needs`、`packages`。要用的程式先確認 minor 至少是 3。

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
