# agentkit

`kit` 管理 AI 寫程式工具（Claude Code 等）的 rule、skill、MCP、工具權限，
以及把這四樣綁在一起的 agent。不用編譯、不用 root、不用 Python。

## 安裝

Linux / macOS（需要 bash、awk、git）：

    git clone <這個 repo 的網址> ~/src/agentkit
    sh ~/src/agentkit/unix/install.sh

macOS：同上。內建的 bash 3.2 和 awk 就夠，不用 Homebrew。
若還沒有 git，先打 `xcode-select --install`。PATH 會加進你的 shell 會讀的檔
（zsh → `~/.zshrc`，bash → `~/.bash_profile`）。

Windows（Windows PowerShell 5.1 內建就有，不用管理員權限）：

    git clone <這個 repo 的網址> %USERPROFILE%\src\agentkit
    powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\src\agentkit\windows\install.ps1

裝到 `%LOCALAPPDATA%\Programs\agentkit`，並加進你的 PATH（開新的終端機後生效）。
在 cmd 和 PowerShell 都是打 `kit`。

各版改了什麼：[docs/changes.md](docs/changes.md)。

## 使用

    kit init <團隊來源的網址>     第一次
    kit list [--json]             有哪些、在用哪些
    kit add skill <名字>          開始用（整個帳號：每個資料夾、每個 agent 都有）
    kit rm  skill <名字>          不用了
    kit add --dir <資料夾> skill <名字>   只加到這個資料夾（在這裡和子資料夾開的 agent 才有）
    kit rm  --dir <資料夾> skill <名字>
    kit run <agent> [--tool codex|omp]   開一個做好的 agent（預設 Claude）
    kit sync                      更新
    kit self-update               更新 kit 本身
    kit uninstall [--self]        移除

團隊的 kit.yaml 可以寫 `kit_version: 0.2.0`：kit 比這個舊的人，`kit sync` / `kit list` 會提醒一次去 `kit self-update`。

內容 repo 的 PR 自動檢查（Gitea Actions，Linux runner）：

    kit ci-template .gitea/workflows/kit-check.yaml

要在 repo 或組織設定 Actions 變數 `AGENTKIT_REPO`（agentkit repo 的 git 網址；私有的話再加 secret `AGENTKIT_TOKEN`），
並在分支保護把 `kit-check` 設成必須通過。細節看範本裡的註解。

kit 只改自己加的部分，而且只寫這台電腦有裝的工具：

| | rule | skill | MCP | 團隊禁用的工具 |
|---|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md`（標記之間，@ 引用） | `~/.claude/skills/` | `~/.claude.json` | `~/.claude/settings.json` 的 `permissions.deny` |
| Codex | `~/.codex/AGENTS.md`（標記之間，內容直接放進去） | `~/.agents/skills/` | `~/.codex/config.toml`（標記之間） | MCP 工具 → `disabled_tools` |
| omp | `~/.omp/agent/AGENTS.md`（同上） | `~/.agents/skills/` | `~/.omp/agent/mcp.json` | 不支援 |

改 JSON 前會留一份 `.kit-backup`。Claude 開啟時會在背景自動 `kit sync`（最多每 10 分鐘一次）。

**Claude 沒在存對話紀錄時提醒你**：在另一個 Claude 的終端機裡開的 Claude（例如 Claude 幫你開新視窗）會帶著 `CLAUDE_CODE_CHILD_SESSION=1`，
這樣它不寫對話紀錄，關掉後 `/resume` 找不回來。kit 的 SessionStart hook（就是上面那個自動同步）每次 Claude 開啟時會看
Claude 本身啟動時的環境（不是 hook 自己的，Claude 給每個 hook 都設了這個變數），是這種情況就在畫面上警告，也告訴 Claude 要先寫交接檔。
用 `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude` 開就會存（Mac／Linux：`env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude`）。

- Mac 用 `ps -E`、Linux 用 `/proc/<pid>/environ`。Windows 讀 `claude.exe` 的 PEB（不用編譯、不用管理員；要 64 位元的 PowerShell）；
  用 npm 裝的 Claude（行程名字是 `node`）找不到，就不檢查。讀不到一律不警告。
- 你自己已經有做同一件事的 hook（`~/.claude/settings.json` 裡有 `transcript-check` 這個字）時，kit 不再說一次。
  不要 kit 檢查：在 settings.json 的 `env` 加 `"KIT_TRANSCRIPT_CHECK": "0"`。
- Codex、omp 沒有這種情況：從別的 agent 裡開也照樣存（`~/.codex/sessions/`、`~/.omp/agent/sessions/`），
  只有你自己下 `codex exec --ephemeral`、`omp --no-session` 才不存，所以 kit 不替它們檢查。

`kit run <agent>` 只在這次啟動時帶入 agent 的東西，不改設定檔：

| | rule + 提示 | skill | MCP | tools.only | tools.deny |
|---|---|---|---|---|---|
| Claude | ✅ | ✅ | ✅ | ✅ | ✅ |
| Codex | ✅ | ✅（列在提示裡，用到時才讀） | ✅ | ✗ | 只限 MCP 工具 |
| omp | ✅ | ✅ | ✗（要用 `kit add mcp` 加到全域） | ✅ | ✗ |

## skill 需要的程式（node、python…）

有的 skill 要靠別的程式才能跑，例如 archify 要 Node.js 18 以上。kit 會自己看出來，缺了就幫你裝（你按了才裝）。

    kit tools                          kit 會裝哪些程式、這台有沒有、會用什麼指令裝
    kit install-tool node [--min 18]   裝 Node.js（太舊就升級）

- **怎麼看出來的**：`SKILL.md` 裡叫 agent 跑的指令（`node x.mjs`、`npx …`、`python3 x.py`、`pip install …`），`requirements.txt`／`pyproject.toml`，`package.json` 的 `engines.node`（最低版本）。也可以自己寫：`SKILL.md` 的 `requires: [node>=18]`，或來源 `kit.yaml` 的 `requires: {archify: [node>=18]}`（收來的 skill 不用改原作者的檔案）。
- **怎麼裝**：每個程式一個 `tools/<名字>.yaml`。kit 內建 node、python、git，**來源倉不能蓋過這三個**（同名的檔案不算數）；來源倉放別的名字，就多支援一個程式。

      name: node
      title: Node.js
      bin: [node]                     # 用來看版本的程式名
      install:
        mac: [brew node]
        windows: [winget OpenJS.NodeJS.LTS, scoop nodejs-lts]
        linux: [apt nodejs, brew node]   # apt 只有 root 用得到；沒有能用的就請你自己裝

  每個系統列「套件管理器 套件名」，kit 依序試這台能用的，一種裝失敗就換下一種。**只能寫這兩個字**：管理器只認 brew、apt、winget、scoop、pip，實際執行的指令是 kit 自己組的（例如 `brew install node`、太舊時 `brew upgrade node`），檔案裡寫別的指令會被略過。
  - 套件名只能是單純的名字：英文字母或數字開頭，不能有 `/`（所以不能是 brew 的 `使用者/tap/套件`、路徑或網址）；scoop 可以寫 `main/`、`extras/`、`versions/` 開頭。
  - pip 一律是 `python3 -m pip install --user --only-binary=:all: <套件>`：只裝現成的 wheel，套件的 `setup.py` 不會被執行。
  - winget 先用 `--scope user`（只裝給這個帳號）；那個套件沒有這種安裝程式時，kit 會說一聲再改成一般安裝。
- **怎麼看這台有沒有**：只看有配方的程式（沒有 `tools/<名字>.yaml` 的名字不會被執行），跑它的 `--version`，最多讀 4 KB、最多等 5 秒（`KIT_PROBE_WAIT` 可改）。Mac 沒裝 Command Line Tools 時，`/usr/bin/git`、`/usr/bin/python3` 只會跳出安裝視窗，kit 當作沒有。
- **在哪裡看到**：Herdr 的 Kit 清單，skill 下面會出現「⚠ 需要 Node.js 18 以上（這台沒有）［安裝］」。按「安裝」先顯示 kit 要執行的指令，按「確定安裝」才執行。
- 從網路收來的 skill 不會帶 `tools/` 進來：只有你自己倉裡、或團隊審過的 `tools/` 會用到。

### skill 自己的套件（npm install、pip install）

少數 skill 帶自己的程式，要先裝套件才能跑：`package.json` 有 `dependencies`（npm），或有 `requirements.txt`（Python）。kit 也會看出來，你按了才裝：

    kit install-deps <skill> [npm|pip]   裝這個 skill 的套件（不寫就兩種都裝）

    來源裡的 skill（不動）              kit 自己的資料夾
    skills/foo/package.json  ──複製──▶  ~/.config/agentkit/deps/foo/
    skills/foo/package-lock.json        ├─ npm ci --ignore-scripts --omit=dev
                                        └─ node_modules/
                                              ▲
    ~/.claude/skills/foo/node_modules ────────┘ 連過去（Windows 是 junction，不用管理員）
    ~/.agents/skills/foo/node_modules ────────┘
    ~/ai/.claude/skills/foo/node_modules ─────┘

- 有 `package-lock.json` 用 `npm ci`（照鎖好的版本），沒有才用 `npm install`。
- 一律加 `--ignore-scripts`：套件不能在安裝時跑它自己的程式。`--omit=dev`：只裝執行時要的，不裝開發用的套件。skill 帶的 `.npmrc` 不會用（不讓它換下載來源）。
- **只裝 npm registry 上的版本**：`package.json` 的 `dependencies`、`optionalDependencies`、`peerDependencies`、`overrides` 只能寫版本、版本範圍或標籤（像 `1.3.0`、`^2.0.0`、`latest`，或 `npm:別的名字@版本`）。寫 git、`github:`、`使用者/repo`、網址、`file:`、`link:`、`workspace:` 或路徑的，kit 整個不裝（npm 抓 git 套件時會跑它的程式，`--ignore-scripts` 也擋不住），清單上會寫是哪一個。
- 有 `package-lock.json` 時，每個套件都要是 registry 上的 `.tgz`（`https://registry.npmjs.org/`，或你自己 `~/.npmrc` 設的 `registry=`，要是 https）而且有 `integrity`，不能是連結。沒有 lock 時只看得到 `package.json` 直接列的套件：再往下的套件由 npm 從 registry 抓。
- 裝在 kit 自己的資料夾，不寫進來源（不會被 commit 或推上去）。每個放了這個 skill 的地方（帳號、資料夾、`kit run` 的 agent）都連到同一份。
- skill 更新後 `package.json`／`package-lock.json` 變了，就要再按一次「更新」；舊的套件不會連到新版上。
- 一次只有一個 kit 在裝（跟 `kit sync` 用同一把鎖）。先裝在旁邊一個新的資料夾，裝好才換上去：npm 失敗或你按 Ctrl-C，那個資料夾會刪掉，原本的不受影響。
- `kit uninstall` 會一起刪掉。要先有 Node.js：沒有的話先裝上面那一行的 Node.js。

Python 的做法一樣，只是裝在每個 skill 自己的 venv（`~/.config/agentkit/pydeps/<skill>/venv`），skill 的資料夾裡連一個 `.venv` 過去：

- 指令：`python3 -m venv venv`，再用那個 venv 的 python 跑 `-m pip install --only-binary=:all: --no-input -r requirements.txt`。
- `--only-binary=:all:`：只裝現成的 wheel，不從原始碼編譯，所以套件的 `setup.py` 不會被執行。沒有 wheel 的套件會裝失敗，要自己處理。
- `requirements.txt` 只能寫套件名、版本和條件（像 `requests==2.32.0`、`rich[jupyter]>=13 ; python_version >= "3.9"`）。條件（`;` 後面）只能有條件會用到的字：英數字、`_ . < > = ! ~ ( )`、引號和空白。有 `-r`、`-e`、`--index-url`、網址這類寫法，或任何地方有 ` -` 開頭的選項（條件後面也算），kit 整個不裝，清單上會寫第幾行有問題。
- 重裝時舊的 venv 先留著，裝好才刪；pip 失敗或你按 Ctrl-C，舊的會放回去。
- 有 venv 之後，kit 在帳號的 CLAUDE.md／AGENTS.md（Claude、Codex、omp）的 kit 區塊多寫一行，請 agent 用 skill 資料夾裡的 `.venv/bin/python`（Windows：`.venv\Scripts\python.exe`）執行那個 skill 的程式，不要自己再 pip install。只有帳號加了、kit 也幫它裝好 venv 的 skill 才會寫；資料夾自己的（`--dir`）CLAUDE.md／AGENTS.md 不寫這行，所以 `kit rm --dir`、`kit uninstall` 之後資料夾和原本一模一樣。`kit run` 的 agent 有這種 skill 時，提示裡也有這行。
- Debian/Ubuntu 沒有 venv 時，要先裝 `python3-venv`（kit 會說）。

## agent 的 context 用了多少

    kit context --pid <agent 的 pid> [--tool claude|codex|omp] [--dir 資料夾]

印出 JSON：`used`（用了幾個 token）、`window`（上限）、`pct`（%）、`source`（從哪裡讀的）、`model`。Herdr 每個 agent 窗格上方的「context 35% 139k/400k」就是它（70% 以上變黃、90% 以上變紅）。只讀數字，不讀對話內容。

| agent | 從哪裡讀 | % 怎麼算 |
|---|---|---|
| Claude | kit 放的 statusLine 每次更新都把 Claude 自己的數字存在 `~/.config/agentkit/ctx/claude-<pid>.json`；沒有的話讀那個資料夾最新的對話紀錄 | Claude 自己的（`/context` 一樣的上限，`autoCompactWindow` 有設就用它） |
| Codex | 那個資料夾最新的 `~/.codex/sessions/**/rollout-*.jsonl`，最後一次的 `last_token_usage` | 跟 Codex 畫面的「% context left」一樣：先扣掉它固定的 12000 |
| omp | 它的終端機指向的 session（`~/.omp/agent/terminal-sessions/<tty>`），或那個資料夾最新的 session；最後一個完成的回覆 | 跟 omp 頁尾一樣：再加上那之後的訊息（工具結果、你的下一句）：文字約 4 bytes 一個 token，一張圖約 1600 個 token（omp 自己畫面用的 `details` 不算，那不會送給模型）；上限用 omp 自己的模型清單 |

壓縮（compaction）過、還沒有新回覆時，用壓縮後的大小。Claude Code 自己產生的回覆（`"model":"<synthetic>"`，用量是 0）不算。估出來超過上限時 `pct` 寫 100。
紀錄檔可能有幾百 MB：kit 只讀最後 8 MB（`KIT_CTX_TAIL` 可改，單位 byte），那一段找不到需要的才整個讀。

**Claude 的 statusLine**：`kit sync` 會在 `~/.claude/settings.json` 加上 `statusLine`（執行 `kit statusline`），Claude 底下的狀態列會顯示「Opus 5.5 · context 35%（139k / 400k）」。你已經有自己的 statusLine 時 kit 不動它（只提醒一次），Claude 的用量改從對話紀錄估；Remote Control 的對話紀錄可能不即時。你把 kit 加的 statusLine 拿掉，kit 之後就不會再加回來（說一次）；要加回來打 `kit sync --force`。`kit uninstall` 會拿掉 kit 加的。

### context 細項：token 用在哪裡

    kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] --detail [--fresh]

像 Claude Code 的 `/context`，印出一行 JSON（`kit.ps1` 印的一模一樣）。Herdr 裡按窗格上方的 context 那格看到的就是它（見 [docs/herdr.md](docs/herdr.md)）。

- 上面那幾個欄位（`used` 是即時的總數），加上 `at`（什麼時候問的）、`exact`（分類是不是工具自己算的）、`session`、`compact_at`（自動壓縮的點）、`commands`（這個工具的壓縮、清空指令：Claude `/compact`（可帶文字）、`/clear`；Codex `/compact`（不帶文字）、`/new`；omp `/compact`（可帶文字）、`/new`）、`note`、`error`。
- `categories`：各分類（系統提示、系統工具、MCP 工具、記憶檔／指示檔、Skills、對話訊息、壓縮後的摘要……），每個有 `tokens`、`kind`（`used`；`deferred` 延後載入，不佔空間；`buffer` 自動壓縮保留區；`free` 可用空間）、`est`（是不是估算）。
- `groups`：可以展開的清單（記憶檔、Skills、MCP 依伺服器（裡面再分工具）、對話內容依種類、工具依名稱（呼叫＋結果）、附加內容依種類、自訂 agents、斜線指令），多的在前。
- 同一個 pid 的答案留 60 秒（`KIT_CTX_DETAIL_TTL`，秒），`--fresh` 重新問。窗格上每 15 秒的一般 `kit context` 沒有變，一樣只讀數字。

| agent | 細項從哪裡來 | 準不準 |
|---|---|---|
| Claude | 對它的 session 跑一次 `claude -p --resume <session> --no-session-persistence`，問 Claude Code 自己的 `get_context_usage`（`/context` 用的那個）：所有 hook 關掉（`--settings '{"disableAllHooks":true}'`）、不寫對話紀錄、不叫模型（不花錢），在 agent 的資料夾跑，最多 30 秒（`KIT_CTX_PROBE_TIMEOUT`；`KIT_CTX_PROBE=0` 不問）。session 依序找：kit 的 statusLine 存的、`~/.claude/sessions/<pid>.json`、`~/.claude/daemon/roster.json`（只讀 pid、replPid、sessionId、cwd）、那個資料夾在程式啟動後改過的最新對話紀錄；id 只能有英數字、`_`、`-` | 分類是 Claude Code 自己算的。總數用即時的；這次問不到的差額（剛加進來的、這個 session 之後才連上的 MCP）列成「其他／自上次更新以來」。對話內容、工具、附加內容的細項從對話紀錄估（大小 ÷ 4，一張圖約 1600，最後一次壓縮之前的不算），照比例對到 Claude 的數字。問不到（太舊、PATH 上沒有、逾時）時整份改成估算，`error` 寫原因 |
| Codex | 它的 rollout 檔：base instructions、AGENTS.md、skills 清單、工具（依命名空間）、MCP（看到的、延後載入的、設定裡有但沒看到的）、訊息、工具呼叫和結果、壓縮摘要 | 總數是 Codex 自己記的；各部分用大小 ÷ 4 估，照比例對到總數（`est: true`）。AGENTS.md 從 git 根目錄往下找 |
| omp | session 檔，加上 omp 會讀的指示檔、skills、MCP 設定 | 總數和「系統工具」是 omp 自己記的（context 快照）；其他估算，照比例對到總數。指示檔和 skills 照現在的檔案估 |

對話內容只拿來算大小，不印出、不存；問 Claude Code 時它回的帳號資料不留。問的那一次不寫對話紀錄，但 Claude Code 啟動時照常會更新它自己的東西（例如 plugins 的快取，或在 `~/.claude/projects/<資料夾>/` 建一個空的 `memory/`）。紀錄檔超過 32 MB 時只讀第一行和最後 32 MB（`KIT_CTX_DETAIL_TAIL`，byte）。

## Herdr 的 kit 面板

不想打指令的話，可以在 Herdr 裡用（Windows、Mac、Linux 都一樣）：

- **每個 agent 視窗上的 Kit 按鈕**：這個 agent 在用哪些規則、skill、MCP，加上或拿掉。
- **上排的 Kit（倉庫）**：看、改、新增規則、skill、MCP，改好按清單上面黃色那條的「送出」（`kit push`）。
- **上排的 Agents**：kit 做好的 agent 用了哪些東西，用 Claude、Codex 或 omp 開起來。

    kit herdr-panel install       裝進 Herdr
    kit herdr-panel uninstall     拿掉，Herdr 回到原本的樣子

畫面和每顆按鈕的說明（附示意圖）：[docs/herdr.md](docs/herdr.md)。
面板讀的是 `kit list --json`、`kit agents --json`（給程式讀的 JSON：來源、每個項目的種類、名字、狀態、說明、檔案位置、是不是新的）。

## 把 kit 帶進公司的 git server

    kit export-self <新的資料夾> [--version 0.2.0+gitea.1]

只帶 git 有追蹤的檔案，拿掉 `.github/`、`CHANGELOG*`、`LICENSE*`，加上一份沒有網址的 `INSTALL.md`（第一次用就照 `docs/company.md` 做）。
README 會一起帶過去（它就是使用說明），跟其他檔案一樣要過下面的檢查。
有 GitHub 的字、不該公開的字（`~/.config/agentkit/private-words.txt` 和來源裡的 `private-words.txt`）
或非文字檔就失敗，並刪掉輸出資料夾。成功後把資料夾內容 commit 到公司的 repo，訊息只寫 `kit <版本>`。

## 送內容到 Gitea

寫內容的人（在團隊來源的 clone 裡）：

    kit new skill <名字> [--from 本機資料夾]   新增
    kit update <名字> --from 本機資料夾       更新
    kit check                     送出前檢查
    kit push [--to 來源] [--dry-run]   檢查後開分支、push、在 Gitea 開 PR

收別人寫好的 skill（例如 GitHub 上的）：

    kit collect <原作者 repo 網址> [--to 來源]   收進來（帶原作者的 LICENSE，記在 third_party.lock）
    kit outdated                             看原作者有沒有新版
    kit collect <名字>                        再收一次＝整份換成新版

- 沒給 `--path` 時：repo 最外層有 `SKILL.md` 就收它；不然 repo 裡只有一個 `SKILL.md` 就收那個資料夾；有好幾個就列出來讓你用 `--path` 選。
- 只收 `kit.yaml` 的 `collect_sources` 裡的作者。自己的來源（`push: direct`）可以加 `--allow`，收的時候一起把作者加進清單；團隊來源要維護者改清單。
  `kit push` 平常不送 `kit.yaml`；但它只改了 `collect_sources` 時（`--allow` 加的）會一起送。
- `--look`：只下載來看、什麼都不寫，用 JSON 列出找到的 skill、授權、會執行的檔案（Herdr 面板的「下載看看」用它）。
- 沒有 LICENSE 的不收；只收文字檔，不收捷徑、圖片和 `.github/` 這類資料夾。

`kit push` 只送改過的 rule、skill、mcp、agent，只 push `kit/...` 分支，不動 main。
來源的 `kit.yaml` 寫 `push: direct`（只有自己用的來源）時，改成直接 commit 到現在的分支、推到它所有的 remote，不開 PR。
不寫就是 `push: pr`。團隊的來源一定要用 `push: pr`。
檢查（`kit check`、`author_domains`、`allowed_hosts`）有一項不過就什麼都不送。
要自動開 PR 就放 Gitea token：環境變數 `KIT_GITEA_TOKEN`，或檔案
`~/.config/agentkit/gitea-token`（`chmod 600`）。沒有 token 時會印出網址讓你自己開。

## 只用核准過的版本（給 root 這類帳號）

有些帳號（例如 root）不應該自動照著來源走：來源是別的帳號可以改的。這種帳號用：

    kit init <來源>... --approvals <核准紀錄的 repo> --signers <allowed_signers 檔>

kit 只會用 `approved.txt` 裡寫的 commit，而且 `approved.txt` 要有對的 ssh 簽章（namespace `agentkit`），
`serial` 不能比上次用的小（不能退回舊的核准）。沒核准的新 commit、被改過的清單都不會用。
`kit self-update` 也只會換到核准的 kit 版本。

核准的人在自己的電腦上（金鑰只放這裡）：

    kit approve <核准紀錄的 clone> <來源的 clone>... --key <ssh 金鑰>
    git -C <核准紀錄的 clone> push

它會列出每個來源從上次核准到現在改了什麼，問你要不要核准，再簽章、commit。
（目前只有 Linux／Mac 版有這個功能。）

## 測試

    tests/json_test.sh
    tests/run.sh          在暫時的 HOME 裡跑，不會動到你的設定
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1    （Windows 版）
