# kit 各版改了什麼

最新的在上面。每一版寫了更新後要做什麼。看自己的版本：`kit --version`。
更新：`kit self-update`，再 `kit sync`；終端機程式整個關掉重開。
**每台跑 agent 的電腦或主機都要更新**（例如連到的 Linux），不然那台的 agent 用不到新功能。

## 0.8.0（2026-11-21）

更新後要做：每台 `kit self-update`（Windows 也要）。畫面程式要顯示資料夾的外掛：先確認 `kit api` 至少 1.13。

- 外掛可以只加到一個資料夾：`kit add --dir <資料夾> plugin <名字>`（`kit rm --dir …` 拿掉）。Claude 用它自己的 `--scope local` 裝（寫在 Claude 專案的 `.claude/settings.local.json`，git 不記；資料夾在 git repo 裡面時，整個 repo 開的 Claude 都有，kit 會說），omp 用它自己的 `--scope project` 裝（寫在那個資料夾的 `.omp/plugins/`）。kit 不改 git 有記錄的檔案：那種情況那個工具就不裝，kit 會說。
- Codex 只能整個帳號裝：在那個資料夾開的 Codex 沒有這個外掛，kit 加的時候會說；要 Codex 也有就 `kit add plugin <名字>`。
- `kit sync` 照常：來源換版本就在那個資料夾重裝；`kit uninstall` 也會拿掉。kit 在資料夾裝的外掛算 kit 的，不會被「只能透過 kit」擋掉。整個帳號的外掛跟以前一樣。
- `kit list --json --dir` 多了 `here.folder.plugins`：每個資料夾外掛哪些工具已經裝好、和「Codex 只能整個帳號裝」（`kit api` 1.13）。

## 0.7.5（2026-11-20）

更新後要做：每台 `kit self-update`（Windows 也要）。

- Claude 打 `/compact` 壓縮後，畫面程式（Herdr、手機 App）的 context 用量馬上變成壓縮後剩的量，不會一直停在壓縮前的數字（例如 91%）等到 Claude 下一次回話。數字來自壓縮紀錄裡「壓縮後剩多少」；Claude 一回話就換回狀態列給的數字。

## 0.7.4（2026-11-19）

更新後要做：Mac、Linux 上 `kit self-update`。Windows 不用（kit.ps1 本來就對）。

- Kit 面板的「方案用量（omp）」不會再一直停在很久以前的數字（例如「897 分鐘前的數字」）。kit 在背景問 `omp usage` 時如果中途被中斷，會留下一個裡面還有暫存檔的鎖；以前清舊鎖用的方法刪不掉有東西的資料夾，鎖就一直在，之後再也不問 omp。現在舊鎖（超過 2 分鐘）連裡面的東西一起清掉，下一次就會重新問。
- 已經卡住的電腦：更新後下一次打開面板（或 `kit usage`）就會自己恢復，不用做別的。

## 0.7.3（2026-11-18）

更新後要做：Linux 上 `kit self-update`，再 `kit sync`；之前 `kit add mcp` 時看到「free(): double free detected in tcache 2」的，再打一次 `kit add mcp <名字>`（例如 `kit add mcp codegraph`）和 `kit sync`。macOS、Windows 不用更新。

- Linux：awk 是 GNU Awk 5.2.1 的電腦（Debian、Ubuntu 預設的 awk，root 也一樣）不會再印「free(): double free detected in tcache 2」、「Aborted (core dumped)」。kit 讀 MCP 的 yaml 時，沒有網址（url）的 MCP 會讓這版 gawk 自己當掉，`kit add`、`kit sync`、`kit list`、`kit check` 每次都會碰到：MCP 的套件版本、要設的環境變數、`kit check` 找寫死的密碼都少算了。和 `~/.claude.json` 大小無關。mawk、BusyBox、macOS 的 awk 本來就沒事，輸出一字不差。
- `kit add mcp codegraph` 之後還是被擋（Claude 的 `deniedMcpServers` 還有它、`kit list --json` 的 blocked 還列著）：是 `~/.claude.json` 裡還有你自己加的同名 codegraph，kit 不動你自己的，所以照樣擋。先 `claude mcp remove codegraph -s user`，再 `kit sync`，就換成 kit 的、不再擋。

## 0.7.2（2026-11-18）

更新後要做：`kit self-update`。

- `kit list --json`（Kit 面板）快很多：電腦很忙時（load 50～250）從 30～57 秒降到 10～23 秒，用的 CPU 時間約剩三分之一。每個 skill、規則不再各自重新讀來源清單、狀態檔、kit.yaml，也少開很多小程式。輸出一字不差。
- 不是 0.7.0 的擋下功能造成的：0.6.16 一樣要 40 秒。`blocked` 一直是讀 `kit sync` 存下的 blocked.tsv，`kit list --json` 不會重新掃各工具的設定（測試確認）。

## 0.7.1（2026-11-18）

更新後要做：Windows 上 `kit self-update`，再 `kit sync`。macOS、Linux 只有 git 設了 `core.autocrlf=true` 的要更新。

- Windows：用簽核版本（`kit init --approvals`）的電腦不會再一直說「核准紀錄的簽章不對」。兩個原因都修了：Git for Windows 預設（`core.autocrlf=true`）把 `approved.txt` 和簽章換成 CRLF 放出來，簽的是 LF，現在 kit 驗簽章、讀 serial 和版本時不看 CR（Mac、Linux 的 kit 也一樣改了）；Windows 內建的 ssh-keygen 從管線讀資料會讀錯，現在改成用 cmd 把檔案直接接到它的標準輸入。
- Windows：`kit agents --json` 遇到不是 git 的來源資料夾，不會再停在「fatal: not a git repository」（Windows PowerShell 把 git 的錯誤訊息當成錯誤）。`kit check --ci`、`kit self-update`、`kit collect` 裡的 git 也一樣。
- Windows：`kit check` 不會把捷徑（symlink）的規則多算一個「是空的」。
- Windows：從標準輸入貼 MCP 設定寫成 `kit new mcp --config --look`（`--config` 後面不寫檔案）。Windows PowerShell 傳不了單獨的 `-`，`--config -` 在 kit 開始前就出錯。

## 0.7.0（2026-11-18）

更新後要做：`kit self-update`，再 `kit sync`，**看它列出擋下了什麼**。要用的收進 kit（下面）。Windows 版一樣（公司管理員的資料夾是 `C:\Program Files\ClaudeCode\`、`%ProgramData%\OpenAI\Codex\`）。

**公司的不動，其他的 skill、MCP、外掛只能透過 kit 載入。** 沒有開關，每個用 kit 的人、每台電腦都一樣。
- 從這版起，每次 `kit sync`（包括開 Claude、Codex、omp 時自動跑的那次）會讓 Claude Code、Codex、omp **不載入**不是 kit 放的、也不是公司的 skill、MCP、外掛。檔案不刪不搬，只改各工具「載入什麼」的設定。
- **會被擋的**：帳號裡自己裝的 skill（`~/.claude/skills/<名字>`、`~/.agents/skills`、`~/.codex/skills`、`~/.omp/agent/skills`，例如 `npx` 裝的）、自己加的 MCP（`~/.claude.json`、`~/.codex/config.toml`、omp 的 `mcp.json`）、從 marketplace 裝的外掛（官方的也算），和專案裡沒 commit 進 git 的 skill、`.mcp.json`。專案只看開工具時所在的那個、和 `kit add --dir`／`kit place` 過的。
- **不會擋的（公司的）**：Anthropic、OpenAI、omp 自己的（Claude 同步下來 `source` 是 anthropic 的 skill、claude.ai 的 connector、Codex 的 `~/.codex/skills/.system`）；公司管理員放的（要 root 的系統資料夾、Team／Enterprise 組織同步的 skill）；專案 commit 進 git 的。kit 放的當然也不擋。
- **被擋下的去哪裡看**：`kit sync` 擋下新的東西時列出來；全部在 Kit 面板、`kit list --json` 的 `blocked`（`kit api` 是 1.12）。
- **要繼續用**：收進自己的來源再加。有原本網址的：`kit collect <網址>`；沒有的：`kit new skill <名字> --from <資料夾>`；然後 `kit add skill <名字>`。原本的資料夾剛好是 kit 要放的地方（例如 `~/.claude/skills/<名字>`）時，kit 先備份到 `~/.config/agentkit/backups/skills/` 再換成 kit 的（以前是跳過）。
- 你自己寫的設定不會不見：kit 只拿掉它自己寫的那幾項，原本的值記著，收進 kit、`kit uninstall` 時放回去。各工具用的設定見 README「公司的不動，其他只能透過 kit」。

## 0.6.16（2026-11-18）

更新後要做：Windows 上 `kit self-update`，再 `kit sync`。macOS、Linux 不用。

- Windows：`kit sync` 不會再中途停在「當檔案已存在時，無法建立該檔案」。kit 換掉自己的記錄檔（`state.tsv`、`machine.yaml`、要顧的資料夾清單、等你的事、進度、狀態列的用量）時，以前是先刪舊檔再搬新檔；Windows Defender 剛好在掃舊檔時，刪除只是「排隊中」，搬新檔就失敗，還留下 `state.tsv.kit.<亂碼>` 暫存檔，嚴重時 `state.tsv` 不見。現在改用 Windows 的整檔替換（一步換過去，不先刪），換不了就複製過去。
- Windows：刪技能資料夾遇到「資料夾不是空的」（檔案還被掃描中）會等一下再試，不會刪一半、之後被當成「你改過的」。
- Windows：Codex 的工具限制（`tools.only`／`tools.deny`）、狀態列、交接提醒讀 Claude／Codex 給的資料時用 UTF-8。以前 Windows PowerShell 用主控台的編碼（中文 Windows 是 Big5）讀，資料夾名字有中文時路徑讀錯，Codex 的限制就沒套上。
- Windows：MCP 的 Python 環境正在被 Claude／Codex 用時，更新它會說「先關掉用這個 MCP 的 Claude／Codex 再試」，不是一串 .NET 錯誤。

## 0.6.15（2026-11-17）

更新後要做：`kit self-update`，再 `kit sync`。

- kit 不把 Python 的快取（`__pycache__` 資料夾、`.pyc`、`.pyo` 檔）當成技能的一部分。技能裡的 Python 程式跑過一次，Python 就會在旁邊寫這些檔；以前 `kit check`（`kit push` 前也會跑）每個都說「只能放文字檔」，什麼都送不出去，kit 也可能以為技能被手動改過。現在：
  - `kit check`、`kit push` 跳過它們：不擋、不送，也不列在「不會送」裡。
  - 不算改動：技能裡多了快取，`kit sync` 不會說「被手動改過」。
  - 不複製：kit 放技能、外掛（`kit sync`、`kit run`）、`kit new --from`、`kit update --from`、`kit collect` 都不帶它們。
  - 你資料夾裡的快取 kit 不刪，只是不管它。
- Windows 版一樣。

## 0.6.14（2026-11-16）

更新後要做：`kit self-update`，再 `kit sync`。

- 資料夾的 MCP（`kit add --dir`、`kit place`）開 Claude 就直接用，不再問「New MCP server found in this project」。以前 kit 只寫資料夾 `.claude/settings.local.json` 的 `enabledMcpjsonServers`，但 Claude 只在信任「這個資料夾本身」時才算數；只信任上層（例如家目錄）、資料夾又不是 git 時每次都問。現在 kit 也在 `~/.claude.json` 把這個資料夾設成信任（`projects["<資料夾>"].hasTrustDialogAccepted`），跟 Codex 那邊一樣。只給有 kit 放的 MCP 的資料夾；MCP 拿掉、`kit uninstall` 時改回原來的樣子。有人把信任關掉，下一次 `kit sync` 再打開並說一聲。`kit sync` 會補好已經放過的資料夾（例如 `~/gerrit`）。
- Codex：kit 放的 MCP（整個帳號的和資料夾的，`kit run` 也是）加上 `default_tools_approval_mode = "approve"`，叫它的工具不再每次問「Allow?」；團隊擋掉的工具照舊在 `disabled_tools`。開的時候本來就不問（kit 已經信任資料夾）。
- omp 不用改：開的時候和叫工具時本來就不問（`tools.approvalMode` 預設 `yolo`）。
- Windows 版一樣。

## 0.6.13（2026-11-16）

更新後要做：`kit self-update`，再 `kit sync`。

- MCP 的 `command`、`args` 裡的 `${HOME}`：kit 寫進各工具的設定（`~/.claude.json`、資料夾的 `.mcp.json`、omp 的 `mcp.json`、Codex 的 `config.toml`）時換成這台電腦的家目錄。omp、Codex 不會自己代換，以前照字面放進去，omp 開不起來（`MCP subprocess closed stdout before responding`）。`kit sync` 會改好已經放過的。Windows 換成使用者資料夾，`${USERPROFILE}` 也一樣換。其他的 `${變數}` 照原樣。
- 資料夾的 MCP 在 Claude 的 `/mcp` 被關掉（`.claude/settings.local.json` 的 `disabledMcpjsonServers`，比 `enabledMcpjsonServers` 優先）：`kit sync` 把 kit 放的那個拿出來、重新打開，並說一聲。
- Windows 版一樣。

## 0.6.12（2026-11-16）

更新後要做：`kit self-update`。

- `kit rm`：拿得掉只在某個資料夾清單裡的項目。整個帳號沒有、只有資料夾清單有時，會說是哪些資料夾，和要打的 `kit rm --dir <資料夾> …`。
- `kit push`：送外掛、`third_party.lock`、`descriptions-zh.txt` 時 commit 訊息不再是空的；刪掉的檔案也送得出去（以前 `git add` 一個不存在的檔案會整個失敗）。
- `kit list --json`：外掛多了 `parts`（裡面帶了哪些 skill、指令、agent、MCP，有沒有 hook）。`kit api` 是 1.11。Kit 面板的外掛那一列會寫「裡面有：6 個 skill（…）、hook」。
- Windows 版一樣。

## 0.6.11（2026-11-16）

更新後要做：`kit self-update`，再 `kit sync`。

- Codex 的 hook：kit 放進 `~/.codex/hooks.json` 的 hook（`kit sync --hook`、`handoff-hook`、`codex-guard`）新增或改過時，kit 先問 Codex 信任了沒有。已經信任就不再叫你打 `/hooks`；還沒信任才用 `kit pending` 提醒，你在 Codex 打 `/hooks` 信任之後，下一次 `kit sync` 收掉提醒。Windows 版一樣。

## 0.6.10（2026-11-15）

更新後要做：`kit self-update`。

- `kit used --pid <pid> [--json]`：那個 agent 這次對話用了哪些 skill、MCP，各幾次、最後一次在第幾則訊息之後。Claude、Codex、omp 都可以，Windows 版一樣。`kit api` 是 1.10。
- 畫面程式：Kit 面板「這個 agent 在用的」上面一行寫這次對話用了什麼，用過的那一列標「這次用了 N 次」，最後一則訊息之後用的再標「剛剛」。

## 0.6.9（2026-11-15）

更新後要做：`kit self-update`，再 `kit sync`。

**外掛（plugin）：跟原作者的裝法一樣，但從自己簽過的那份裝**
- `kit collect` 認得外掛（有 `.claude-plugin/plugin.json`）：整包收進 `plugins/<名字>/`，只收各家會讀的部分。`--skip` 拿掉不要的檔案（`plugin.json` 裡指到它的也拿掉），`third_party.lock` 記住，再收時照樣不收。
- `kit add plugin <名字>`、`kit rm plugin <名字>`：照 Claude、Codex、omp 自己裝外掛的方式裝到整個帳號，來源是 kit 在這台的外掛清單（`~/.config/agentkit/plugins`），不從原作者那邊裝，不自動更新。
- Codex 的外掛 hook：簽過的版本 kit 自己請 Codex 信任（Codex 算 hash、Codex 寫設定），不用再打 `/hooks`；沒簽的版本用 `kit pending` 提醒你。先裝後簽也行：簽好後下一次 `kit sync` 補做。簽章的那台（打過 `kit approve`）用它記住的核准紀錄和金鑰驗，不用另外設定。
- Windows 版的 kit 也讀核准紀錄了：`kit init … --approvals --signers`、只用簽過的版本、`kit status --json` 的 `approvals`／`approved`，跟 macOS、Linux 一樣。
- `kit list --json`：`kind` 多了 `plugin`，有 `needs`（hook 要的 node、python）。
- 畫面程式：Kit 面板多一個「外掛」分頁。
- 規則的說明：`kit list --json` 的 `description` 是規則檔第一行 `# ` 標題（以前是空的）。`kit new mcp` 的範本多一行 `description:`，寫這個 MCP 做什麼。
- 畫面程式：Kit 面板點一下 skill、規則、MCP、外掛那一列，展開完整說明，再點一下收起。
- 中文說明：`kit describe <種類> <名字> "<中文>"` 寫在來源的 `descriptions-zh.txt`，`kit list --json` 多了 `description_zh`，面板優先顯示中文（agent 還是讀原本的說明）。原本的說明改了就改回顯示原文，`kit describe --todo` 列出還沒翻的。`kit api` 是 1.9。
- `kit push` 也送收進來的外掛（`plugins/`）和 `descriptions-zh.txt`。

## 0.6.8（2026-11-15）

更新後要做：`kit self-update`，再 `kit sync`。

**收別人的 skill：同一個 repo 只下載一次**
- `kit outdated --json`：每個收來的 skill 原作者有沒有新版、連不連得到（`latest`／`new`／`unreachable`），畫面程式拿它一天查一次、標出來。
- `kit add skill a b c`、`kit rm skill a b c`：一次加（拿掉）好幾個；有一個名字不對就整個不做。`--dir` 還是一次一個。
- `kit collect` 可以直接貼瀏覽器上的網址（例如 `https://git.example.org/作者/repo/tree/main/skills/tdd`）：拆成 repo、分支和資料夾。之前會說找不到 repo。
- `kit collect` 下載的東西照 commit 留 60 分鐘（`~/.config/agentkit/cache/collect`）。`--look` 看過再一個一個收、一次收好幾個，都不再每個重新下載；原作者有新 commit 就重新下載（先用 `git ls-remote` 問）。

**簽章少打字**
- `kit approve` 記住上次用的核准紀錄和金鑰：之後打 `kit approve <來源的 clone>... --push` 就好，`--push` 連推一起做。
- `kit list --json` 多一個 `sign`：這台電腦簽過的核准紀錄、serial、核准了哪些 commit。畫面程式拿它說「已經簽了，等那台同步」。

**等你同意的事：找得到是哪一格**
- `kit pending add` 多記 agent 和它上面的程式（`kit status --json` 的 `up`），畫面程式拿它找 agent 在哪個終端機。用 `sudo` 開的（例如 root 的服務）也找得到。

## 0.6.7（2026-11-15）

更新後要做：`kit self-update`，再 `kit sync`。用 Codex 的話，下次開 Codex 打 `/hooks` 信任 kit 的 hook。

**omp 也拿得到 agent 的 MCP**
- `kit place … --tool omp`：資料夾的 `.mcp.json`（kit 本來就會寫）omp 也會讀（在這個資料夾本身開時；子資料夾裡開的讀不到），不再說「omp 只讀整個帳號的 MCP」。
- `kit run … --tool omp`：agent 的 MCP 放在一個暫時的 plugin 資料夾，用 `--plugin-dir` 給 omp（工具名字前面多 `kit:`）。

**Codex、omp 開啟時也會自動 `kit sync`**
- Codex：`~/.codex/hooks.json` 加上跟 Claude 一樣的 SessionStart hook，和 context 快滿時提醒寫 HANDOFF.md 的 hook（數字從 Codex 的對話檔讀）。Codex 要你在 `/hooks` 信任一次。
- omp：`~/.omp/agent/hooks/pre/kit.js`，每次開 session 在背景跑 `kit sync --hook`。
- omp 的 hook 模組也在你每次送出一句話前檢查 context：快滿時（80%、90% 各一次）提醒它先寫 HANDOFF.md、記 `kit note`，跟 Claude、Codex 一樣。
- `kit uninstall` 會拿掉這些。

**Codex：同一個資料夾開兩個，也認得出是哪一個**
- `kit context`、`kit files`：先看那個 Codex 程式開著哪一份對話檔（Herdr 用 `--no-daemon` 開的 Codex 一直開著它；kit 用 `lsof`／`/proc`），看不到才照舊用那個資料夾最新的一份。Windows 看不到程式開著的檔，照舊。

**omp：Windows 上找對話、面板列的檔、context 細項、方案用量**
- 沒有終端機可對的 omp（Windows 在 Herdr 裡就是這樣）：找那個程式啟動前後建立、之後還在寫的那份對話，不再只抓資料夾最新的。（Windows 上還沒實測。）
- `kit list --json --dir`（Kit 面板「這個資料夾另外會讀到的」）：照 omp 自己的規則標誰讀得到（實測過）：每一層資料夾 omp 只讀一份指示檔（`.omp/AGENTS.md` > `.claude/CLAUDE.md` > `.agents/AGENTS.md` > `AGENTS.md` > `CLAUDE.md`），`.claude/skills` 往上找，`.claude/rules/` 不讀。新列出 `.agents/AGENTS.md`、`.agents/skills`（Codex 和 omp）、最近一個 `.omp` 的 `RULES.md` 和 skills、`mcp.json`、`.omp/mcp.json`、`.codex/config.toml` 裡你自己的 MCP，和帳號的 `~/.agents/skills`、`~/.omp/agent/skills`、`RULES.md`、`mcp.json`。
- `kit context --detail`（omp）：指示檔、skills、MCP 照上面的規則估；`~/.claude/CLAUDE.md`、`~/.claude/skills` 不再算進去（omp 預設不讀）。
- `kit usage` 多一個 `omp`：`omp usage` 回報的各服務用量（anthropic、openai-codex…），kit 在背景每 5 分鐘問一次，只留數字。
- omp 的 context 上限：不再套用 Claude Code `settings.json` 的 `autoCompactWindow`（omp 不讀它），只看 omp 自己的模型清單，沒有才用 kit 的猜測。

**Codex 也照 agent 的工具限制（shell 和改檔）**
- `~/.codex/hooks.json` 多一個 PreToolUse hook（`kit codex-guard`）：Codex 跑 shell 指令、改檔案前問 kit，照團隊規定、`kit place` 放的資料夾（和子資料夾）的 agent、`kit run --tool codex` 的 agent 的 tools.only、tools.deny 擋（`Bash`、`Bash(git push:*)`、`Edit`、`Write`）。實測過 Codex 0.167 會照它的回答擋下來。
- `Bash(...)` 逐段比：`cd x && git push`、`$(git push)` 也擋。omp 的 hook 模組也改成一樣。
- Codex 其他的內建工具、別的工具的 `( )` 寫法擋不到，kit 會說。新的 hook 要在 Codex 打 `/hooks` 信任一次。

**omp 也照 agent 的工具限制（tools.only、tools.deny）**
- `kit place … --tool omp`：限制寫進資料夾的 `.omp/hooks/pre/kit.js`；`kit run … --tool omp`：`--tools` 只開 agent 要的工具，deny 用一個暫時的 `--extension`。
- 團隊規定一定要擋的（required 的 deny），寫進 `~/.omp/agent/hooks/pre/kit.js`，每個 omp 都擋。
- Claude 的工具名字換成 omp 的（Read → read、Bash → bash 和 eval…）。`Bash(git push:*)` 這種照擋；別的工具 `( )` 的寫法 omp 擋不到，kit 會說。

**自己私人的來源可以寫私密字（`private: true`）**
- 來源的 `kit.yaml` 寫 `private: true`（這個來源永遠不公開，例如只推到自己私人主機的）：`kit check` 不再拿 `~/.config/agentkit/private-words.txt` 查它的內容和檔名，送出不會被「有不該公開的字」擋下。沒寫的照舊查；`kit export-self` 一樣會查。
- Windows（kit.ps1）：私密字清單只有一個字時，`kit check` 不會再出錯。

## 0.6.6（2026-11-15）

更新後要做：`kit self-update`。kit api 還是 1.7。

**`kit context` 也會說 Codex 撞到用量上限、幾點恢復**
- Codex 撞到方案的上限停下來、還沒繼續時，跟 Claude 一樣多一個 `limit`。kit 看的是它對話檔裡最後一次的用量（`rate_limit_reached`）。
- `kind` 多一種 `monthly`（Codex 免費方案是 30 天一個時段）。工作區額度用完沒有恢復時間，不算。

**`kit context --detail` 對很長的 Claude 對話快一倍**
- 很長的對話（幾百 MB）以前要 7 秒左右，現在約 3.5 秒，數字一樣。
- 問 Claude Code 各部分用量和讀對話檔改成同時做；只讀最後一次壓縮之後的部分，用位元組搜尋找起點（macOS 上不再用很慢的 `tail -c`）。Windows（kit.ps1）也一樣。

## 0.6.5（2026-11-15）

更新後要做：`kit self-update`。kit api 變成 1.7。

**看方案用了多少：`kit usage`**
- 印出 Claude 和 Codex 這個帳號 5 小時、每週的用量（%）和幾點重置。Claude 的是 kit 狀態列每次更新時存下來的（要 kit 的 statusLine），Codex 的從它最新的對話檔讀。
- 畫面程式（Herdr）拿來顯示用量。

**`kit context` 會說 Claude 撞到用量上限、幾點恢復**
- Claude 撞到上限停下來、還沒人叫它繼續時，多一個 `limit`（`until`：幾點恢復，`kind`：哪一種上限）。Herdr 拿來提醒你，時間到了替你打「繼續」。
- 沒撞到時跟以前一樣，沒有這個欄位。

## 0.6.4（2026-11-14）

更新後要做：`kit self-update`。kit api 還是 1.6。

**`kit context` 不會再拿到同一個資料夾裡別的 Claude 的數字**
- 沒有 kit 狀態列的 Claude（例如關掉 hook 的），以前直接讀那個資料夾裡最新的對話紀錄；兩個 Claude 在同一個資料夾，就會拿到另一個的模型和 context %（Herdr 標題列、關係圖卡片跟著錯）。
- 現在先照 `~/.claude/sessions/<pid>.json` 找它自己的那一份，找不到才用最新的。

## 0.6.3（2026-11-14）

更新後要做：`kit self-update`。kit api 變成 1.6。

**`kit status --json` 多了 `pending`：在等你的事**
- 等簽章：用核准紀錄的帳號（例如 root），來源上次 `kit sync` 抓到的新 commit 還沒核准，就列在 `pending`（`kind: "sign"`，「X 有 N 個新 commit 等核准」、從什麼時候開始等）。簽章還是在 Mac 親手做。
- 等你同意：新指令 `kit pending add "要你同意：…" [--id 名字]`，agent 或服務在等你點頭時記一筆，`kit pending done <名字>` 拿掉，`kit pending` 列出來。列在 `pending`（`kind: "owner"`）；記的 agent 結束了就不列。
- 畫面程式（Herdr 的關係分頁）拿來提醒「等你簽」「等你同意」。root 這種畫面程式問不到的帳號，寫給你讀的 `kit status --json` 檔案裡就有。
- 沒有在等的是 `[]`。

## 0.6.2（2026-11-14）

更新後要做：`kit self-update`、`kit sync`（Claude 的 `settings.json` 會多一個 `UserPromptSubmit` hook）。kit api 還是 1.5。

**先看 skill 會怎麼改：`kit sync --dry-run`**
- 列出每個 skill 會新增、更新、拿掉、跳過（你改過的、不是 kit 放的），或先備份再換（`--force`），不改任何檔案，最後給一個雜湊。
- `kit sync --expect <雜湊>`：kit 重算一次，清單一樣才動手；中間來源更新了、或你又改了某個 skill，就什麼都不改，請你再看一次（錯誤代碼 `plan-changed`）。
- 只管 skill；rule、MCP 等照常更新。

**context 快滿時先交接（Claude）**
- context 到 80%、90% 時各提醒 Claude 一次：先寫 `HANDOFF.md`、`kit note` 記進度，再跟你說可以換新的 agent 接手或 `/compact`。
- 要有 kit 的 statusLine（用它存的數字）。Codex、omp 沒有這種 hook。

## 0.6.1（2026-11-14）

更新後要做：`kit self-update`、`kit sync`（Codex 的 `config.toml` 會多一段 `[sandbox_workspace_write]`），開著的 Codex 重開。kit api 變成 1.5。

**Codex 在沙箱裡也能 `kit note`**
- Codex 的沙箱不讓它看其他程式（`ps`），也不准寫 `~/.config/agentkit`，所以 0.6.0 的 `kit note` 在 Codex 裡會說「找不到上面的 agent」。
- 現在：kit 在 Codex 的設定加上 `writable_roots`（只開放 `~/.config/agentkit/notes` 這一個資料夾），沙箱裡的 `kit note` 記在那個 Codex 對話名下；畫面程式用 Codex 的程式編號問，照樣找得到。
- 你自己的 `config.toml` 已經有 `sandbox_workspace_write` 的話，kit 不動它，說一次請你自己加。
- 給程式讀：`kit note` 的 JSON 多了 `session`（Codex 對話編號），`--history` 裡這種的 `pid` 是 `null`。

**Codex 自己加的設定不再被 kit 洗掉**
- Codex 新增設定（例如你按「信任這個資料夾」時的 `[projects."…"]`）會加在 `config.toml` 最後面，剛好落在 kit 管的那段裡，以前下次 `kit sync` 就把它洗掉，Codex 又問一次。
- 現在 kit 記得自己上次寫了什麼（`~/.config/agentkit/codex-block.toml`），不是它寫的就搬到那段外面，說一聲。第一次更新時 kit 還沒記錄，只認 `[projects."…"]` 是 Codex 的。`kit uninstall` 也會留著這些。

## 0.6.0（2026-11-14）

更新後要做：`kit self-update`；想讓 agent 自己寫進度，要有一條教它什麼時候寫的 rule：來源裡有 `progress-note` 的話 `kit add rule progress-note`。kit api 變成 1.4。

**agent 寫自己做到哪：`kit note`**
- agent 在自己的 shell 跑 `kit note "剛做了什麼；下一步"`，kit 記在那個 agent 名下。同時開好幾個 agent 時，畫面程式（例如終端機每一格的標題列）可以顯示每個做到哪。
- `kit note` 不帶文字：印出現在寫的。`kit note --history`：這個資料夾最近的進度（包括已經關掉的 agent），重開或交接時先看。
- 給程式讀：`kit note --pid <pid> --json`（README「給程式讀的介面」）。
- Claude、Codex、omp 都可以；Codex 的沙箱可能不讓它寫 `~/.config/agentkit`。

## 0.5.3（2026-11-14）

更新後要做：`kit self-update`。

**你改過的 skill 不會被刪掉**
- 以前 `kit rm`、或 agent 不再要某個 skill 時，kit 直接刪掉那個資料夾，你改過的也一起刪。現在你改過的會留著，說一次「沒有刪」，之後 kit 不再管它，不要了自己刪。
- `kit sync --force` 蓋掉你改過的 skill 前，先把你那份搬到 `~/.config/agentkit/backups/skills/<名字>-<時間>/`（不在 skills 資料夾裡，agent 不會讀到），畫面會說備份在哪。
- 沒改過的照舊：直接更新、直接刪。

## 0.5.2（2026-11-13）

更新後要做：`kit self-update`、`kit sync`（放過 agent 的資料夾會重寫 Claude 的工具限制）。

**把 agent 放到資料夾（kit place）**
- 放好之後不再顯示「Claude 的設定沒有『只開這些工具』……」這行：放 agent 的人對它什麼都不能做。改成寫 agent 檔的人跑 `kit check`（`kit push` 也會跑）時看到一行提醒，不算問題。Codex、omp 真的不套用的限制照樣會說。
- Claude 的工具限制不再寫 `MultiEdit`：新的 Claude Code 沒有這個工具，每次開都會警告「Deny rule MultiEdit matches no tool」。有這個工具的舊版 Claude，擋 `Edit` 就會一起擋它。

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
