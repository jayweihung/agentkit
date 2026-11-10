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
    kit add skill <名字>          開始用
    kit rm  skill <名字>          不用了
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

## Herdr 的 kit 面板

不想打指令的話，可以在 Herdr 裡用面板：看到所有的 rule、skill、MCP、agent（團隊必備／在用／新的／沒用），
按一下加上、拿掉、同步，agent 按「開啟」會在新分頁用 `kit run` 開（有裝 Codex、omp 的話可以選）。

    kit herdr-panel install       裝進 Herdr（mods/kit），在上排加一顆 kit 按鈕
    kit herdr-panel uninstall     拿掉

改版面前會留一份 `layouts/<版面>.json.kit-backup-<時間>`。Herdr 內建的版面（main 等）不能改：
面板會先出現在右邊，按面板上的「放進上排」會複製一份版面再放進去。
面板讀的是 `kit list --json`（給程式讀的 JSON：kit 版本、來源、每個項目的種類、名字、狀態、說明、是不是新的）。

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
    kit push [--dry-run]          檢查後開分支、push、在 Gitea 開 PR

`kit push` 只送改過的 rule、skill、mcp、agent，只 push `kit/...` 分支，不動 main。
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
