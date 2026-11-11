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

團隊的 kit.yaml 可以寫 `kit_version: 0.4.0`：kit 比這個舊的人，`kit sync` / `kit list` 會提醒一次去 `kit self-update`。

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
- **怎麼裝**：每個程式一個 `tools/<名字>.yaml`。kit 內建 node、python、git；來源倉放同名的檔案會蓋過內建的，放新的就多支援一個程式。

      name: node
      title: Node.js
      bin: [node]                     # 用來看版本的程式名
      install:
        mac: [brew node]
        windows: [winget OpenJS.NodeJS.LTS, scoop nodejs-lts]
        linux: [apt nodejs, brew node]   # apt 只有 root 用得到；沒有能用的就請你自己裝

  每個系統列「套件管理器 套件名」，kit 依序用這台第一個能用的。**只能寫這兩個字**：管理器只認 brew、apt、winget、scoop、pip，實際執行的指令是 kit 自己組的（例如 `brew install node`、太舊時 `brew upgrade node`），檔案裡寫別的指令會被略過。
- **在哪裡看到**：Herdr 的 Kit 清單，skill 下面會出現「⚠ 需要 Node.js 18 以上（這台沒有）［安裝］」。按「安裝」先顯示 kit 要執行的指令，按「確定安裝」才執行。
- 從網路收來的 skill 不會帶 `tools/` 進來：只有你自己倉裡、或團隊審過的 `tools/` 會用到。

### skill 自己的套件（npm install、pip install）

少數 skill 帶自己的程式，要先裝套件才能跑：`package.json` 有 `dependencies`（npm），或有 `requirements.txt`（Python）。kit 也會看出來，你按了才裝：

    kit install-deps <skill> [npm|pip]   裝這個 skill 的套件（不寫就兩種都裝）

    來源裡的 skill（不動）              kit 自己的資料夾
    skills/foo/package.json  ──複製──▶  ~/.config/agentkit/deps/foo/
    skills/foo/package-lock.json        ├─ npm ci --ignore-scripts
                                        └─ node_modules/
                                              ▲
    ~/.claude/skills/foo/node_modules ────────┘ 連過去（Windows 是 junction，不用管理員）
    ~/.agents/skills/foo/node_modules ────────┘
    ~/ai/.claude/skills/foo/node_modules ─────┘

- 有 `package-lock.json` 用 `npm ci`（照鎖好的版本），沒有才用 `npm install`。
- 一律加 `--ignore-scripts`：套件不能在安裝時跑它自己的程式。skill 帶的 `.npmrc` 不會用（不讓它換下載來源）。
- 裝在 kit 自己的資料夾，不寫進來源（不會被 commit 或推上去）。每個放了這個 skill 的地方（帳號、資料夾、`kit run` 的 agent）都連到同一份。
- skill 更新後 `package.json`／`package-lock.json` 變了，就要再按一次「更新」；舊的套件不會連到新版上。
- `kit uninstall` 會一起刪掉。要先有 Node.js：沒有的話先裝上面那一行的 Node.js。

Python 的做法一樣，只是裝在每個 skill 自己的 venv（`~/.config/agentkit/pydeps/<skill>/venv`），skill 的資料夾裡連一個 `.venv` 過去：

- 指令：`python3 -m venv venv`，再用那個 venv 的 python 跑 `-m pip install --only-binary=:all: --no-input -r requirements.txt`。
- `--only-binary=:all:`：只裝現成的 wheel，不從原始碼編譯，所以套件的 `setup.py` 不會被執行。沒有 wheel 的套件會裝失敗，要自己處理。
- `requirements.txt` 只能寫套件名、版本和條件（像 `requests==2.32.0`、`rich[jupyter]>=13 ; python_version >= "3.9"`）。有 `-r`、`-e`、`--index-url`、網址這類寫法，kit 整個不裝，清單上會寫第幾行有問題。
- 有 venv 之後，kit 在 CLAUDE.md／AGENTS.md 的 kit 區塊多寫一行，請 agent 用 skill 資料夾裡的 `.venv/bin/python`（Windows：`.venv\Scripts\python.exe`）執行那個 skill 的程式，不要自己再 pip install。
- Debian/Ubuntu 沒有 venv 時，要先裝 `python3-venv`（kit 會說）。

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

    kit export-self <新的資料夾> [--version 0.4.0+gitea.12]

只帶 git 有追蹤的檔案，拿掉 `.github/`、`README*`、`CHANGELOG*`、`LICENSE*`，加上一份沒有網址的 `INSTALL.md`。
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
