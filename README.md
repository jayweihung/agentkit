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
    kit run <agent>               開一個做好的 agent
    kit sync                      更新
    kit self-update               更新 kit 本身
    kit uninstall [--self]        移除

kit 只改自己加的部分，而且只寫這台電腦有裝的工具：

| | rule | skill | MCP | 團隊禁用的工具 |
|---|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md`（標記之間，@ 引用） | `~/.claude/skills/` | `~/.claude.json` | `~/.claude/settings.json` 的 `permissions.deny` |
| Codex | `~/.codex/AGENTS.md`（標記之間，內容直接放進去） | `~/.agents/skills/` | `~/.codex/config.toml`（標記之間） | MCP 工具 → `disabled_tools` |
| omp | `~/.omp/agent/AGENTS.md`（同上） | `~/.agents/skills/` | `~/.omp/agent/mcp.json` | 不支援 |

改 JSON 前會留一份 `.kit-backup`。Claude 開啟時會在背景自動 `kit sync`（最多每 10 分鐘一次）。
`kit run <agent>` 目前只支援 Claude。

## 測試

    tests/json_test.sh
    tests/run.sh          在暫時的 HOME 裡跑，不會動到你的設定
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1    （Windows 版）
