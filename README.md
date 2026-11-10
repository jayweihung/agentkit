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
    kit list                      有哪些、在用哪些
    kit add skill <名字>          開始用
    kit rm  skill <名字>          不用了
    kit run <agent> [--tool codex|omp]   開一個做好的 agent（預設 Claude）
    kit sync                      更新
    kit self-update               更新 kit 本身
    kit uninstall [--self]        移除

團隊的 kit.yaml 可以寫 `kit_version: 0.4.0`：kit 比這個舊的人，`kit sync` / `kit list` 會提醒一次去 `kit self-update`。

內容 repo 的 PR 自動檢查（Gitea Actions，Linux runner）：

    kit ci-template > .gitea/workflows/kit-check.yaml

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

## 把 kit 帶進公司的 git server

    kit export-self <新的資料夾> [--version 0.4.0+gitea.12]

只帶 git 有追蹤的檔案，拿掉 `.github/`、`README*`、`CHANGELOG*`，加上一份沒有網址的 `INSTALL.md`。
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

## 測試

    tests/json_test.sh
    tests/run.sh          在暫時的 HOME 裡跑，不會動到你的設定
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1    （Windows 版）
