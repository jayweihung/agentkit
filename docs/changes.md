# kit 各版改了什麼

最新的在上面。每一版寫了更新後要做什麼。看自己的版本：`kit --version`。
更新：`kit self-update`，再 `kit sync`；終端機程式整個關掉重開。
**每台跑 agent 的電腦或主機都要更新**（例如連到的 Linux），不然那台的 agent 用不到新功能。

## 下一版（還沒發佈）

更新後要做：`kit self-update`、`kit sync`。用 Herdr 的 kit 面板的話，Herdr 的面板改由你的 Herdr 設定提供（看那邊的說明）。

**Herdr 的面板搬出 kit**
- Herdr 的 kit 面板（Kit 清單、Agents、每個窗格的 Kit 按鈕和 context 那格）搬出 kit：Herdr 的面板改由你的 Herdr 設定提供（看那邊的說明）。kit 裡不再有 Herdr 的東西。
- `kit herdr-panel install|uninstall` 拿掉了。
- 升級（`kit self-update`、重跑安裝）時，已經裝在 Herdr 裡的舊面板 kit 不會去動：不更新、也不刪，怎麼換掉看你的 Herdr 設定說明。kit 自己安裝資料夾裡舊版留下的 `herdr/` 會刪掉。
- 新增 `kit api`：印一行整數（現在是 `1`）。給畫面程式確認看得懂 kit 的輸出（`kit list --json`、`kit agents --json`、`kit context`、`kit collect --look`）；輸出格式不相容地改變時才加一。
- `json.awk`（和 `kit.ps1` 裡對應的部分）拿掉只給 Herdr 版面用的操作（`rmwhere`、`addnear`、`addbefore`、`swapwhere`、`rmholder`、`rowaround`、`unrow`）。

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
