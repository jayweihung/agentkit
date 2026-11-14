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
    kit place <agent> <資料夾> [--tool codex|omp]   這個資料夾就是那個 agent（在那裡開的就是它）
    kit sync                      更新
    kit sync --dry-run            先看 skill 會怎麼改（不動任何檔案），最後給一個雜湊
    kit sync --expect <雜湊>       照那份清單改；清單變了（來源更新、你又改了 skill）就什麼都不改
    kit self-update               更新 kit 本身
    kit status --json             這個帳號用哪一版：kit 和每個來源的 commit、核准的 commit（給程式讀）
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
| Codex | `~/.codex/AGENTS.md`（標記之間，內容直接放進去） | `~/.agents/skills/` | `~/.codex/config.toml`（標記之間） | MCP 工具 → `disabled_tools`；shell、改檔 → `~/.codex/hooks.json` 的 `kit codex-guard`（kit 0.6.7 起） |
| omp | `~/.omp/agent/AGENTS.md`（同上） | `~/.agents/skills/` | `~/.omp/agent/mcp.json` | `~/.omp/agent/hooks/pre/kit.js`（kit 0.6.7 起） |

Codex 自己新增的設定（例如信任某個資料夾的 `[projects."…"]`）會加在 `config.toml` 最後面、落進 kit 那段裡；kit 記得自己上次寫了什麼（`~/.config/agentkit/codex-block.toml`），`kit sync` 時把不是它寫的搬到那段外面，不會洗掉。改 JSON 前會留一份 `.kit-backup`。kit 放的 skill 你改過，kit 就不蓋、也不刪：`kit sync` 跳過它並提醒；`kit rm` 或 agent 不再要它時留著，之後歸你管；`kit sync --force` 會先把你改的那份搬到 `~/.config/agentkit/backups/skills/<名字>-<時間>/` 再換上新的。想先看清楚再動手：`kit sync --dry-run`（或 `kit sync --force --dry-run`）列出每個 skill 會新增、更新、拿掉、跳過、還是先備份再換，不改任何檔案（來源還是會先抓最新的，跟 `kit sync` 一樣），最後印一個雜湊；確定了打 `kit sync --expect <雜湊>`（有 `--force` 就兩次都加）。到時候 kit 重算一次，來源更新了或你又改了某個 skill、清單不一樣了，就什麼都不改（錯誤代碼 `plan-changed`），請你再看一次。只管 skill；rule、MCP 等照常更新。Claude 開啟時會在背景自動 `kit sync`（最多每 10 分鐘一次）。Codex、omp 也一樣（kit 0.6.7 起）：Codex 是 `~/.codex/hooks.json` 裡同樣的 hook（Codex 第一次看到新的 hook 要你信任：在 Codex 打 `/hooks`），omp 是 `~/.omp/agent/hooks/pre/kit.js`（kit 寫的檔，第一行有標記；同名的檔是你自己的就不動）。context 快滿時提醒寫 HANDOFF.md 的 hook（`kit handoff-hook`）Codex 也有，數字從它的對話檔讀；omp 還沒有。

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
| omp | ✅ | ✅ | ✅（一個暫時的 plugin 資料夾，`--plugin-dir`；工具名字前面多 `kit:`） | ✅（換成 omp 的工具名字） | ✅（一個暫時的 omp 擴充，`--extension`） |

### 一個資料夾就是一個 agent：`kit place`

    kit place reviewer ~/work/reviewer             以後在 ~/work/reviewer 打 claude，開的就是 reviewer
    kit place reviewer ~/work/reviewer --tool codex   打算用 Codex 開（提示也寫進 AGENTS.md）

- 建好那個資料夾（上一層要已經在；kit 只建最後一層），把 agent 的規則、skill、MCP 加到這個資料夾（跟 `kit add --dir` 一樣），
  提示寫進資料夾的 `CLAUDE.md`／`AGENTS.md` 的 kit 區塊，工具限制寫進資料夾的 `.claude/settings.local.json`。
  資料夾的 `.agentkit` 記著它是哪個 agent；`kit sync` 會照 agent 檔現在的樣子更新：提示、工具限制，
  還有 agent 的規則、skill、MCP（agent 檔新加的會放進來，拿掉的會拿掉）。
- 之後就是平常的 `claude`、`codex`、`omp`，不用 `kit run`。`kit add|rm --dir <資料夾> …` 只改這個資料夾，
  而且 `kit sync` 不會蓋掉：`.agentkit` 只記你改過的，`種類:名字` 是你另外加的，`not:種類:名字` 是你用 `kit rm --dir` 拿掉的 agent 的
  （agent 檔還有它也不會放回來，要再 `kit add --dir` 才回來）。agent 本身的規則、skill、MCP 不寫在 `.agentkit`，每次照 agent 檔放。
- agent 檔找不到或讀不懂（改了名字、來源不在、只用核准的版本時那一版沒有它、檔頭寫錯）：那個資料夾照上次的樣子不動
  （提示、工具限制、規則、skill、MCP 都留著；kit 留著上次 agent 檔的一份在 `~/.config/agentkit/placed/`），說一次，修好後 `kit sync` 就照常。
- 同一個 agent 再 place 一次：只同步，什麼都不會多。資料夾已經是別的 agent，或裡面已經有不是 kit place 放的東西：kit 不動它，直接說。
- 好幾個 agent 就是好幾個資料夾。`kit uninstall` 會把每個資料夾放的東西拿掉（`.agentkit` 也拿掉）。

工具做得到的不一樣（做不到的 kit 會說）：

| | rule + 提示 | skill | MCP | tools.only | tools.deny |
|---|---|---|---|---|---|
| Claude | ✅ | ✅ | ✅ | 改成把其他內建工具寫進 deny | ✅ |
| Codex | ✅ | ✅ | ✅ | 只管 shell（Bash）和改檔（Edit、Write） | MCP 工具、`Bash`、`Bash(...)`、`Edit`、`Write` |
| omp | ✅ | ✅ | ✅（資料夾的 `.mcp.json`；omp 只在這個資料夾本身開時讀，子資料夾裡開的讀不到） | ✅（`.omp/hooks/pre/kit.js`） | ✅（同一個檔） |

omp 的工具限制：kit 把 Claude 的工具名字換成 omp 做同樣事的工具（例如 Read → read，Bash → bash 和 eval，Grep → grep 和 ast_grep），
omp 要用被擋的工具時會被拒絕並說原因。tools.deny 的 `Bash(git push:*)` 這種寫法 omp 也照樣擋；別的工具的 `( )` 寫法（例如 `Read(./secret/**)`）omp 擋不到，kit 會說。
omp 只在這個資料夾本身開時讀 `.omp/hooks/pre/kit.js`（跟 `.mcp.json` 一樣），在子資料夾裡開的 omp 沒有這些限制。
團隊規定一定要擋的（required 的 deny）也寫進 `~/.omp/agent/hooks/pre/kit.js`，每個 omp 都擋。

Codex 的工具限制（kit 0.6.7 起）：Codex 要跑 shell 指令、要改檔案前，會先問 `~/.codex/hooks.json` 裡 kit 的 hook（`kit codex-guard`，在 Codex 打 `/hooks` 信任一次）。
kit 照 Claude 的寫法看：團隊規定一定要擋的、`kit place` 放的資料夾（在它或它的子資料夾裡開的 Codex）那個 agent 的、`kit run --tool codex` 那個 agent 的。
`Bash(git push:*)` 這種逐段比：指令在 `&&`、`||`、`;`、`|`、`&`、括號、反引號、換行切開，每一段從頭比（`cd x && git push` 也擋）。
Codex 改檔案是一個 patch：新增檔案算 `Write`，改、刪、搬檔案算 `Edit`。Codex 讀檔、找檔也是用 shell，所以 tools.only 沒有 `Bash` 的 agent 在 Codex 裡連檔案都不能讀；
Codex 其他的內建工具（例如搜尋網路、開子 agent）擋不到，`Read(./secret/**)` 這種別的工具的 `( )` 寫法也擋不到，kit 會說。MCP 的工具照樣寫進 `disabled_tools`。

Claude 的 tools.only：Claude 之後新加的內建工具不在 kit 的清單裡，擋不到（要擋就寫進 tools.deny）。這件事放 agent 的人不會看到，寫 agent 檔的人跑 `kit check` 時會看到一行提醒。

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
- **在哪裡看到**：`kit tools`，和 `kit list --json` 裡每個 skill 的 `needs`（畫面程式可以拿來在 skill 下面顯示「⚠ 需要 Node.js 18 以上（這台沒有）［安裝］」，按了再跑 `kit install-tool`）。
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

## MCP

一個 MCP 是來源裡的一個 `mcp/<名字>.yaml`。兩種寫法：

    # 在這台電腦跑一個程式                  # 連到一個網址
    command: npx                            type: http          # 或 sse
    args:                                   url: https://mcp.example.com/mcp
      - -y                                  headers:
      - "@scope/server@1.2.3"                 Authorization: "Bearer ${MCP_TOKEN}"
    env:
      API_TOKEN: ${API_TOKEN}

**密碼、token 不放在來源裡**：寫成 `${變數名}`，值放在每台電腦自己的環境變數。`kit check`（所以 `kit push` 也是）看到像密碼或 token 的值直接寫在 mcp 的 yaml 裡就不讓過（只說是哪一欄，不印出值）。
`${變數名:-預設}` 的預設也算：預設像密碼或 token 也不讓過（貼上時換成 `${變數名}`）。

kit 看錯了（其實不是密碼，例如很長的 ID）：在那個 yaml 最上層寫 `not_secret`，列出是哪一欄（寫法跟 `kit check` 說的一樣），`kit check` 就不管那幾欄：

    command: npx
    args: [-y, "@acme/server@1.2.3", --workspace=Ab3dEf5GhIj7KlMn9PqRs1Tu]
    not_secret: ["args[3]"]          # env.名字、headers.名字、url、args[第幾個，從 1 算]
`kit sync` 時這台電腦沒設的變數會提醒一次（說名字）。

### 貼上設定

別人給的 MCP 設定（README 上的 JSON、`claude mcp add …` 那一行）不用自己改寫：存成檔案，kit 幫你轉成上面的 yaml。

    kit new mcp [名字] --config <檔案> [--to 來源]     （檔案寫 - 就從標準輸入讀）
    kit new mcp [名字] --config <檔案> --look          只看會寫成什麼，不寫（JSON，見「給程式讀的介面」）

看得懂的寫法：

- JSON：`{"mcpServers": {"名字": {...}}}`、`{"名字": {...}}`，或只有一個 server 的 `{...}`（`command`、`args`、`env`、`type`、`url`、`headers`）。
- `claude mcp add …`（`--transport stdio|http|sse`、`-e K=V`、`-H "K: V"`；`-s` 不管）、`codex mcp add 名字 [--env K=V] -- 程式 參數…`（`--url`、`--bearer-token-env-var` 也可以）。
- Codex 的 `config.toml`（`[mcp_servers.名字]` 那幾段）。

不寫名字時用設定裡的名字（改成小寫英文、數字和 `-`）。設定裡有好幾個 server 時，kit 列出它們的名字，請你寫要哪一個。

例一：跑一個程式（`gh.json`）

    {"mcpServers": {"github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                               "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "（你的 token）"}}}}

    $ kit new mcp --config gh.json
    已建立 mcp/github.yaml（在 team）
      env.GITHUB_PERSONAL_ACCESS_TOKEN 像是密碼或 token：檔案裡寫成 ${GITHUB_PERSONAL_ACCESS_TOKEN}（值沒有寫進去）
      每台電腦要先設定環境變數：GITHUB_PERSONAL_ACCESS_TOKEN
      套件 @modelcontextprotocol/server-github 固定在 2025.4.8 版。先裝好（不然每次啟動時下載）：kit install-deps mcp github

例二：連到一個網址（`notion.txt`）

    claude mcp add --transport http notion https://mcp.example.com/mcp -H "Authorization: Bearer xxxxxxxx"

    $ kit new mcp --config notion.txt
    已建立 mcp/notion.yaml（在 team）
      headers.Authorization 像是密碼或 token：檔案裡寫成 ${NOTION_TOKEN}（值沒有寫進去）

寫好後跟自己寫的一樣：`kit add mcp <名字>` 開始用，`kit push` 送出去。檔案裡的 token 換掉了，但貼上的原始檔案還在：用完記得刪掉。

**哪些算密碼或 token**（換成 `${…}`，報告只說變數名字，不印出值）：

- 名字裡有 `KEY`、`TOKEN`、`SECRET`、`PASSWORD`、`PASSWD`、`PASSPHRASE`、`AUTH`、`CREDENTIAL`、`COOKIE`、`SESSION`，或有一段（`_`、`-` 隔開或大寫開頭的一段）就是 `PAT`、`PASS`、`PWD`、`PW` 的 env、header、網址參數、`--參數=`（例如 `DB_PASS`、`MYSQL_PWD`；值是空的、`${…}`、true/false、數字、路徑的不算）。
- `${變數名:-預設}` 的預設：變數名字像上面那樣，或預設本身像 token（換成 `${變數名}`）。
- `Authorization`、`Cookie` header（`Bearer ` 這種開頭留著）。
- 看起來就是 token 的值：`sk-`、`ghp_`、`github_pat_`、`xox…-`、`AKIA`、`glpat-` 這類開頭，或很長的亂碼（20 個字以上、大小寫加數字而且混得很亂，或 32 個以上的十六進位）。
  英文字接起來的（像 `AcmeCorpProduction2024`）不算亂碼。
- 網址裡的密碼（`https://user:密碼@…`）、像 token 的路徑段。

變數名字：env 就用原本的名字；其他的是「server 名字＋欄位」，例如 `NOTION_TOKEN`、`WEB_API_KEY`（server 名字是數字開頭的，前面加 `MCP_`，例如 `MCP_1PASSWORD_TOKEN`）。

**每個工具怎麼用**：

| | 跑程式的 MCP | 網址的 MCP（http） | sse | `${變數}` |
|---|---|---|---|---|
| Claude Code | `command`、`args`、`env` | `type`、`url`、`headers` | ✅ | Claude 自己代換 |
| omp | 同上 | 同上 | ✅ | omp 自己代換 |
| Codex | `command`、`args`、`env` | `url`、`http_headers` | ✗（不放進 Codex，說一次） | 只有整個值：env 同名 → `env_vars`（直接傳過去）；`Authorization: Bearer ${X}` → `bearer_token_env_var`；header `${X}` → `env_http_headers`。其他地方的 `${…}` Codex 不會代換：照字面放進去並說一次（header 這樣的就不放）；網址裡有 `${…}` 的整個不放 |

### MCP 的套件（npx、uvx）

`npx 套件`、`uvx 套件` 每次啟動都可能下載最新版。所以：

- **貼上時固定版本**：沒寫版本的，kit 查現在最新的版本寫進去（npm：`npm view`；Python：PyPI 的 JSON，`KIT_PYPI_URL` 可以換）。這是 `kit new mcp --config` 唯一會連網的地方；查不到就不固定，提醒你。
  npm 寫了範圍或標籤的（`套件@^1`、`套件@next`）：固定在符合它的最新版本（`npm view "套件@^1" version`），並提醒你原本寫什麼、固定在哪一版；寫了確切版本的（`套件@1.2.3`）照寫的。
- 它要的程式（`npx`→node、`uvx`→uv、`python`→python、`docker`→docker）列在 `kit list` 的 `needs`，跟 skill 一樣（node、python、git 以外的要有 `tools/<名字>.yaml`）。
- **你按了才裝**：`kit install-deps mcp <名字>` 把那個版本裝在 kit 自己的資料夾 `~/.config/agentkit/mcp-deps/<名字>/`（npm：`--ignore-scripts`，只能是 registry 上的套件；Python：自己的 venv、只裝 wheel，規則跟 skill 的套件一樣）。裝好後 `kit sync` 把每個工具的設定改成直接跑裝好的那份（npm：`node <套件的 bin>`；Python：venv 裡的程式），不再每次下載。
- 沒裝的照樣用 `npx`／`uvx`，`kit list` 會寫「每次啟動時下載」。`uvx --index-url …` 這種 kit 認不得的寫法不幫它裝。改了版本要再裝一次。

## agent 的 context 用了多少

    kit context --pid <agent 的 pid> [--tool claude|codex|omp] [--dir 資料夾]

印出 JSON：`used`（用了幾個 token）、`window`（上限）、`pct`（%）、`source`（從哪裡讀的）、`model`。給畫面程式在 agent 窗格上顯示「context 35% 139k/400k」這種數字用。只讀數字，不讀對話內容。

Claude 撞到方案的用量上限停下來（「You've hit your 5-hour limit · resets 12:10am」）、之後還沒有人叫它繼續時，多一個 `limit`：`{"until": <幾點恢復，Unix 毫秒>, "kind": "five_hour" | "seven_day" | …}`。kit 看的是它自己對話紀錄的最後（Claude Code 記下的 `usage_limit_reached` 和恢復時間）；之後它又回話、或有人打了字，就不算。畫面程式拿來提醒「撞到上限，幾點恢復」，時間到了可以替你打「繼續」。沒撞到時沒有這個欄位。Codex（kit 0.6.6 以上）看它對話檔裡最後一次的 `rate_limits`：寫著 `rate_limit_reached`（或工作區的 `…usage_limit_reached`）就是撞到了，`until` 是用得最滿的那個時段的重置時間，`kind` 依時段長短是 `five_hour`、`seven_day`、`monthly`（免費方案 30 天）；之後開始新的一輪、你打了字、或再一次 `rate_limits` 沒撞到，就不算。工作區額度（credits）用完沒有恢復時間，不算。omp 還沒有。

| agent | 從哪裡讀 | % 怎麼算 |
|---|---|---|
| Claude | kit 放的 statusLine 每次更新都把 Claude 自己的數字存在 `~/.config/agentkit/ctx/claude-<pid>.json`；沒有的話讀那個資料夾最新的對話紀錄 | Claude 自己的（`/context` 一樣的上限，`autoCompactWindow` 有設就用它） |
| Codex | 那個 Codex 程式開著的 rollout（用 `--no-daemon` 開的 Codex 會一直開著自己的對話檔，Herdr 就是這樣開；kit 用 `lsof` 或 `/proc` 看，Windows 看不到），否則那個資料夾最新的 `~/.codex/sessions/**/rollout-*.jsonl`；最後一次的 `last_token_usage` | 跟 Codex 畫面的「% context left」一樣：先扣掉它固定的 12000 |
| omp | 它的終端機指向的 session（`~/.omp/agent/terminal-sessions/<tty>`）；沒有終端機可對的（Windows：omp 用 tty 或終端機程式的變數認終端機，Herdr 裡兩個都沒有），找那個程式啟動前 1 分鐘到啟動後 5 分鐘建立、之後還在寫的那份；都沒有才用那個資料夾最新的 session；最後一個完成的回覆 | 跟 omp 頁尾一樣：再加上那之後的訊息（工具結果、你的下一句）：文字約 4 bytes 一個 token，一張圖約 1600 個 token（omp 自己畫面用的 `details` 不算，那不會送給模型）；上限用 omp 自己的模型清單 |

壓縮（compaction）過、還沒有新回覆時，用壓縮後的大小。Claude Code 自己產生的回覆（`"model":"<synthetic>"`，用量是 0）不算。估出來超過上限時 `pct` 寫 100。
紀錄檔可能有幾百 MB：kit 只讀最後 8 MB（`KIT_CTX_TAIL` 可改，單位 byte），那一段找不到需要的才整個讀。

**Claude 的 statusLine**：`kit sync` 會在 `~/.claude/settings.json` 加上 `statusLine`（執行 `kit statusline`），Claude 底下的狀態列會顯示「Opus 5.5 · context 35%（139k / 400k）」。你已經有自己的 statusLine 時 kit 不動它（只提醒一次），Claude 的用量改從對話紀錄估；Remote Control 的對話紀錄可能不即時。你把 kit 加的 statusLine 拿掉，kit 之後就不會再加回來（說一次）；要加回來打 `kit sync --force`。`kit uninstall` 會拿掉 kit 加的。

**context 快滿時先交接（Claude、Codex、omp）**：`kit sync` 也在 `~/.claude/settings.json` 加一個 `UserPromptSubmit` hook（`kit handoff-hook`）。context 到 80%、再到 90% 時，你下一句話送出去時各提醒 Claude 一次：先寫或更新專案資料夾的 `HANDOFF.md`（做完什麼、下一步、還沒解決的、怎麼驗證）、用 `kit note` 記一行進度，並跟你說 context 快滿了，可以開新的 agent 從 `HANDOFF.md` 和 `kit note --history` 接著做，或 `/compact`。用的是 kit statusLine 存的數字（只看一個小檔，很快）；你用自己的 statusLine 時就不會提醒。`/compact` 後掉回 80% 以下，之後再滿會再提醒。Codex（kit 0.6.7 起）也有：`~/.codex/hooks.json` 裡同樣的 hook，數字從 Codex 的對話檔（hook 給的 `transcript_path`）讀，照 Codex 自己的算法。omp（kit 0.6.7 起）也有：kit 的 hook 模組（`~/.omp/agent/hooks/pre/kit.js`）在你每次送出一句話前跑同一個 hook，數字從 omp 的 session 檔讀，提醒放在那一輪給模型的訊息裡（畫面上不顯示）。`kit uninstall` 會拿掉。

### context 細項：token 用在哪裡

    kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] --detail [--fresh]

像 Claude Code 的 `/context`，印出一行 JSON（`kit.ps1` 印的一模一樣），給畫面程式顯示細項用。

- 上面那幾個欄位（`used` 是即時的總數），加上 `at`（什麼時候問的）、`exact`（分類是不是工具自己算的）、`session`、`compact_at`（自動壓縮的點）、`commands`（這個工具的壓縮、清空指令：Claude `/compact`（可帶文字）、`/clear`；Codex `/compact`（不帶文字）、`/new`；omp `/compact`（可帶文字）、`/new`）、`note`、`error`。
- `categories`：各分類（系統提示、系統工具、MCP 工具、記憶檔／指示檔、Skills、對話訊息、壓縮後的摘要……），每個有 `tokens`、`kind`（`used`；`deferred` 延後載入，不佔空間；`buffer` 自動壓縮保留區；`free` 可用空間）、`est`（是不是估算）。
- `groups`：可以展開的清單（記憶檔、Skills、MCP 依伺服器（裡面再分工具）、對話內容依種類、工具依名稱（呼叫＋結果）、附加內容依種類、自訂 agents、斜線指令），多的在前。
- 同一個 pid 的答案留 60 秒（`KIT_CTX_DETAIL_TTL`，秒），`--fresh` 重新問。一般的 `kit context`（沒有 `--detail`）沒有變，一樣只讀數字。

| agent | 細項從哪裡來 | 準不準 |
|---|---|---|
| Claude | 對它的 session 跑一次 `claude -p --resume <session> --no-session-persistence`，問 Claude Code 自己的 `get_context_usage`（`/context` 用的那個）：所有 hook 關掉（`--settings '{"disableAllHooks":true}'`）、不寫對話紀錄、不叫模型（不花錢），在 agent 的資料夾跑，最多 30 秒（`KIT_CTX_PROBE_TIMEOUT`；`KIT_CTX_PROBE=0` 不問）。session 依序找：kit 的 statusLine 存的、`~/.claude/sessions/<pid>.json`、`~/.claude/daemon/roster.json`（只讀 pid、replPid、sessionId、cwd）、那個資料夾在程式啟動後改過的最新對話紀錄；id 只能有英數字、`_`、`-` | 分類是 Claude Code 自己算的。總數用即時的；這次問不到的差額（剛加進來的、這個 session 之後才連上的 MCP）列成「其他／自上次更新以來」。對話內容、工具、附加內容的細項從對話紀錄估（大小 ÷ 4，一張圖約 1600，最後一次壓縮之前的不算），照比例對到 Claude 的數字。問不到（太舊、PATH 上沒有、逾時）時整份改成估算，`error` 寫原因 |
| Codex | 它的 rollout 檔：base instructions、AGENTS.md、skills 清單、工具（依命名空間）、MCP（看到的、延後載入的、設定裡有但沒看到的）、訊息、工具呼叫和結果、壓縮摘要 | 總數是 Codex 自己記的；各部分用大小 ÷ 4 估，照比例對到總數（`est: true`）。AGENTS.md 從 git 根目錄往下找 |
| omp | session 檔，加上 omp 會讀的指示檔、skills、MCP 設定（照 omp 自己的規則，實測過：帳號只讀一份（`~/.omp/agent/AGENTS.md` 優先，別的工具帳號層的檔要在 omp 設定 `enabledProviders` 才讀）；每一層資料夾只讀一份，依序 `.omp/AGENTS.md`（最近一個有東西的 `.omp`）、`.claude/CLAUDE.md`（只看開的那層）、`.agents/AGENTS.md`、`AGENTS.md`、`CLAUDE.md`；`RULES.md`；不讀 `.claude/rules/`） | 總數和「系統工具」是 omp 自己記的（context 快照）；其他估算，照比例對到總數。指示檔和 skills 照現在的檔案估 |

對話內容只拿來算大小，不印出、不存；問 Claude Code 時它回的帳號資料不留。問的那一次不寫對話紀錄，但 Claude Code 啟動時照常會更新它自己的東西（例如 plugins 的快取，或在 `~/.claude/projects/<資料夾>/` 建一個空的 `memory/`）。紀錄檔超過 32 MB 時只讀第一行和最後 32 MB（`KIT_CTX_DETAIL_TAIL`，byte）。

## 方案用了多少：`kit usage`

    kit usage

一行 JSON，這個帳號的訂閱方案用了多少、幾點重置：

    {"claude": {"at": 1794673527000, "windows": [{"id": "five_hour", "pct": 41, "minutes": 300, "resets_at": 1794700000000},
                                                 {"id": "seven_day", "pct": 12, "minutes": 10080, "resets_at": 1795000000000}]},
     "codex": {"at": null, "windows": [{"id": "primary", "pct": 3, "minutes": 43200, "resets_at": 1796913312000}]}}

- Claude：kit 的狀態列（`kit sync` 放的 statusLine）每次更新時 Claude Code 會給它用量（5 小時、每週），kit 存在 `~/.config/agentkit/ctx/claude-usage.json`，`at` 是存的時間。用 API key、Bedrock 這類沒有方案上限的，或你用自己的 statusLine 時，是 `null`。
- Codex：最新那份 `~/.codex/sessions/**/rollout-*.jsonl` 最後一次的 `rate_limits`（`primary`、`secondary`，`minutes` 是那個時段多長）。
- omp（kit 0.6.7 起）：`"omp": {"anthropic": U, "openai-codex": U, …}`，`omp usage --json` 對每個登入的服務回報的（`id` 是 omp 的名字去掉服務名：`5h`、`7d`、`7d:fable`、`primary`）。問一次要幾秒、要連網，所以 kit 存在 `~/.config/agentkit/ctx/omp-usage.json`，超過 5 分鐘就在背景再問一次：`kit usage` 印的是存著的（第一次還沒問到時是 `null`）。只留數字，不留帳號、email。沒裝 omp 時是 `null`。
- `pct` 是用掉幾 %，`resets_at` 是重置的時間（Unix 毫秒）。`resets_at` 已經過了的，那個時段重新算了，`pct` 是之前的數字。
- 只讀數字，不讀對話內容。Windows 版一樣。

## agent 讀過、改過的檔案

    kit files --pid <agent 的 pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] [--json]

列出那個 agent 讀過（`read`）、改過（`edit`）、新寫（`write`）的檔案，最新的在前面，同一個檔案只列一次（看最後一次碰它），最多 200 個。
給畫面程式做「這個 agent 碰過哪些檔案」的清單、點一下用編輯器打開（`--json`）；沒有 `--json` 時印給人看的清單。
`--pid`、`--tool`、`--dir` 跟 `kit context` 一樣（沒給 `--tool` 就從程式看出來，沒給 `--dir` 就用它現在的資料夾）。

- 從 agent 自己的紀錄檔讀，只拿路徑（`--json` 的 `turns` 另外拿你每則訊息開頭最多 30 個字），不印也不存其他對話內容或檔案內容。紀錄檔只讀最後 8 MB（`KIT_CTX_TAIL`）。
- `--json` 另外照你送出的每一則訊息分組（`turns`：那則訊息之後 agent 碰過的檔案，像 Claude Code 的 `/rewind`），見「給程式讀的介面」。
- Claude：它的對話紀錄，加上它的 sub-agent 的（`<session>/subagents/*.jsonl`），照紀錄裡的時間排在一起。`Read`、`Edit`／`MultiEdit`／`NotebookEdit`、`Write`。
- Codex：它的 patch 改了哪些檔案（新增的算 `write`，改、刪、搬的算 `edit`）。Codex 是用 shell 讀檔案的，看不出讀了什麼，所以沒有 `read`。
- omp：它的 `read`、`edit`、`write` 工具（`read` 的 `:行號` 拿掉；`skill://` 這類不是檔案的不算）。
- 相對路徑接在 agent 的資料夾後面。檔案已經不在的：讀過的不列，寫過、改過的還是列（`exists: false`）。
- `--git`：再加上那個資料夾所在的 git repo 裡 `git status` 有變動的檔案（標 `git`，排在後面，已經列過的不重複，只列還在的檔案；改名的列新名字）。不是 git repo 就不加。

## agent 寫自己做到哪：`kit note`

    kit note "改好 parser；下一步跑整套測試"     agent 在自己的 shell 跑：記下一兩行進度
    kit note                                   印出現在寫的（寫之前先看，還有用的留下）
    kit note --history [--dir 資料夾]          這個資料夾最近的進度，新的在前，最多 20 則（包括已經關掉的 agent）
    kit note --clear                           清掉自己的
    kit note --pid <pid> [--json]              某個 agent 現在寫的（畫面程式用）

同時開好幾個 agent 時，每個 agent 自己寫一行「剛做了什麼、下一步」，畫面程式（例如終端機每一格的標題列）就能顯示它做到哪；重開或交接時，新的 agent 先看 `kit note --history`。教 agent 什麼時候寫要靠一條 rule（例如來源裡的 `progress-note`）。

- kit 從自己往上找 agent 的程式（`claude`、`codex`、`omp`，或叫這個名字的程式），記在那個程式名下：`~/.config/agentkit/notes/<pid>`。找不到就失敗（`no-agent`），要寫別的程式的用 `--pid`。
- 最多兩行（第一行寫動作和下一步，第二行選用寫目標），最多 1000 bytes；tab 變空格，每行頭尾空白去掉，空行拿掉。
- 那個程式結束後，它的進度在下一次有人寫的時候清掉；歷史（`notes/history.tsv`，最多留 500 則）還在，照資料夾找。程式編號被別的程式拿去用時（啟動時間不同），不會顯示舊的。
- Codex 的沙箱不讓它跑 `ps`，也只准寫幾個地方：kit 在 Codex 的 `config.toml`（kit 管的那段）加上 `[sandbox_workspace_write] writable_roots = ["~/.config/agentkit/notes"]`（只多這一個資料夾），沙箱裡的 `kit note` 改記在那個對話名下（`CODEX_THREAD_ID`，`notes/codex-<id>`，一週後清掉）。畫面程式用 Codex 的程式編號問時，kit 照那個資料夾最新的 Codex 紀錄找到對話編號。你的 `config.toml` 已經有自己的 `sandbox_workspace_write` 時 kit 不動它，說一次請你自己加；加了之後已經開著的 Codex 要重開。

## 在等你同意的事：`kit pending`

    kit pending add "要你同意：裝伺服器的 core 0001" [--id 名字]   agent 或服務在等你時記一筆
    kit pending done <名字>                                     等到了：拿掉
    kit pending                                                 列出這個帳號在等你的事

agent 停下來等你點頭（例如要你同意才能裝、才能上線）時，自己記一筆；畫面程式從 `kit status --json` 的 `pending`（`kind` 是 `"owner"`）讀到，提醒你去那個 agent 回答。你不用在每個窗格之間找誰在等你。

- 記在 kit 往上找到的 agent（`claude`、`codex`、`omp`）名下：那個 agent 結束，這一筆就不算了（下一次 `kit pending`、`kit pending add` 時清掉）。`--pid` 指定別的程式；`--keep`（或上面沒有 agent，例如服務、排程）留到 `kit pending done`。
- `--id`：自己取名字（英數字、`.`、`_`、`-`，最多 64 個字），之後用它拿掉；同一個名字再記一次是更新那句話，等的時間從第一次算。沒給就自動取一個，`kit pending add` 會印出來。
- 一句話，最多 300 bytes。存在 `~/.config/agentkit/notes/pending/`（在 notes 裡，Codex 的沙箱也寫得進去）。
- 畫面程式問不到的帳號（例如伺服器上的 root）把 `kit status --json` 寫到你讀得到的檔案時，裡面就有它的 `pending`。

## 給程式讀的介面

kit 本身只有指令。想用按的（例如在終端機程式裡加一個 kit 面板），那個程式跑下面這些指令。**這一節是唯一的清單**：沒列在這裡的輸出（給人看的字）隨時會改，程式不要去解析。
kit 不附任何畫面程式，那些程式的裝法看它們自己的說明。

### 版本：`kit api`

    kit api        →  1.6

印一行 `major.minor`。major 加一＝不相容的改變（欄位拿掉或改意思、錯誤 code 改意思）；minor 加一＝新增欄位或指令（舊程式照樣讀得懂）。
畫面程式先跑它：major 不是自己認得的（或指令不存在＝很舊的 kit），就請使用者更新 kit 或畫面程式。這一節寫的就是 1.7（1.1：1.0 加上 `kit files`，要用它的程式先確認 minor 至少是 1；1.2：`kit files` 加上 `turns`，要用它的程式先確認 minor 至少是 2；1.3：`kit new mcp --config … --look`、`kit place … --json`、`kit list --json` 的 mcp 多了 `type`、`vars`、`needs`、`packages`，`here.folder` 多了 `agent`，要用的程式先確認 minor 至少是 3；1.4：`kit note`，要用它的程式先確認 minor 至少是 4；1.5：`kit note` 的 JSON 多了 `session`，`pid` 可能是 `null`；1.6：`kit status --json` 多了 `pending`，`kit pending`；1.7：`kit usage`，`kit context` 撞到用量上限時多了 `limit`）。
`kit status --json`（1.3 起）：要用它的程式先確認 minor 至少是 3。

### 共同規則

- 下面的 JSON 指令：stdout **只有** JSON；給人看的字（進度、警告、kit check 的問題）都在 stderr，可以照原樣顯示給人看。
- 成功：exit 0。失敗：exit 不是 0，stdout 一行

      {"error": {"code": "not_init", "message": "還沒設定：先打  kit init <網址或資料夾>"}}

  `message` 是給人看的（跟 stderr 上的一樣），程式只看 `code`：

  | code | 意思 |
  |---|---|
  | `usage` | 參數不對 |
  | `not_init` | 還沒 `kit init` |
  | `busy` | 另一個 kit 正在跑（等一下再試） |
  | `no_source` | `--to` 找不到那個來源或資料夾 |
  | `not_git` | 來源不是 git repo |
  | `check_failed` | `kit check` 有問題（細節在 stderr），什麼都沒送 |
  | `no_git_identity` | git 還沒設名字和信箱 |
  | `author_not_allowed` | git 信箱不是 `author_domains` 的網域 |
  | `bad_push_mode` | `kit.yaml` 的 `push` 不是 `pr` 或 `direct` |
  | `no_origin` | `push: pr` 的來源沒有 origin |
  | `no_remote` | `push: direct` 的來源沒有 remote |
  | `not_on_branch` | `push: direct`：現在不在分支上 |
  | `out_of_sync` | `push: direct`：本機和 remote 不一致（有沒推的 commit、remote 有新的、remote 沒有這個分支） |
  | `host_not_allowed` | 主機不在 `allowed_hosts` |
  | `push_failed` | commit 或 push 失敗（`push: direct` 時 commit 可能已經在本機） |
  | `not_maintainer` | `collect` 只有維護者能用 |
  | `not_allowed` | `collect`：作者不在 `collect_sources` |
  | `download_failed` | `collect`：下載失敗 |
  | `no_skill` | `collect`：找不到 `SKILL.md` |
  | `bad_config` | `new mcp --config`：看不懂貼上的設定（或有 kit 不收的東西，`message` 說是什麼） |
  | `several_servers` | `new mcp --config`：設定裡有好幾個 server，要寫名字；錯誤裡多一個 `"servers": ["名字", …]` |
  | `not_found` | `new mcp --config`：寫的名字不在設定裡；一樣有 `"servers"` |
  | `no_name` | `new mcp --config`：設定裡沒有名字（只有一個 `{...}`），要寫名字 |
  | `bad_name` | `new mcp --config`：名字只能用小寫英文、數字和 `-` |
  | `exists` | `new mcp --config`（不加 `--look`）：已經有這個名字的 mcp |
  | `no_agent` | `place`：來源裡沒有這個 agent |
  | `no_parent` | `place`：資料夾的上一層不在（kit 只建最後一層） |
  | `other_agent` | `place`：那個資料夾已經是別的 agent |
  | `not_empty` | `place`：那個資料夾已經有東西，不是 `kit place` 放的 |
  | `bad_dir` | `place`：不是資料夾，或不能放在那裡（例如家目錄） |
  | `error` | 其他 |

  之後可能加新的 code（minor 加一）：不認得的 code 當作 `error`。
- 字串照 JSON 規則跳脫；路徑是這台電腦的寫法。欄位順序固定，但程式應該照名字讀。
- 來源資料夾（`dir`）是解開捷徑後的實際路徑（Mac 的 `/tmp/x` 會是 `/private/tmp/x`；Windows 也解開 junction 和 subst 的磁碟機）。程式拿自己的路徑來比時，先一樣解開。

### `kit list --json [--dir 資料夾] [--pid 程式編號]`

    {
      "kit": "0.4.0",
      "sources": [
        {"name": "team", "source": "<網址或資料夾>", "dir": "<clone 的資料夾>", "push": "pr", "changed": ["rules/a.md", "skills/b/SKILL.md"]}],
      "tools": ["claude", "codex", "omp"],
      "items": [
        {"kind": "skill", "name": "b", "status": "used", "new": false, "changed": true, "source": "team", "description": "…", "path": "<檔案>",
         "needs": [{"tool": "node", "title": "Node.js", "min": "18", "have": "", "ok": false, "install": "<要跑的指令>"}],
         "packages": [{"kind": "npm", "ok": false, "had": false, "install": "<要跑的指令>", "bad": ""}]}],
      "kit_version_wanted": ""
    }

- `sources[].push`：`pr`（送出要開 PR）或 `direct`（直接推）。`sources[].changed`：`kit push --to <name>` 會送的檔案（相對來源資料夾，`/` 分隔；改過的 rule、skill、mcp、agent、`third_party.lock`，加上只改了 `collect_sources` 的 `kit.yaml`）；沒有就是 `[]`，不是 git repo 也是 `[]`。
- `items[].kind`：`rule`、`skill`、`mcp`、`agent`。`status`：`required`（團隊必備）、`used`、`unused`、`agent`。`new`：還沒在 `kit list` 看過。`changed`：`kit push` 會送它（skill：它資料夾裡任何一個檔案）。
- `needs`、`packages` 只有 skill 和 mcp 有。skill 的 `packages` 沒有要裝的就不出現，見「skill 需要的程式」。
- mcp（1.3 起）一定有：`"type"`（`stdio`、`http`、`sse`）、`"vars": [{"name": "GITHUB_TOKEN", "set": false}]`（它要的環境變數，這台電腦有沒有設）、`"needs"`（同 skill）、`"packages"`：沒有套件是 `[]`，有的話一個
  `{"kind": "npm", "package": "@scope/server", "version": "1.2.3", "ok": false, "had": false, "install": "<要跑的指令>", "bad": ""}`（`kind` 是 `npm` 或 `pip`；`ok`：裝好了，設定會直接跑裝好的；`bad` 不是空的就是 kit 不幫它裝的原因，它照樣在啟動時下載）。按「安裝」跑 `kit install-deps mcp <名字>`。
- `--dir`：多一個 `"here": {"dir", "user", "agent", "folder": {"dir", "why", "items", "agent"}, "items": [{"scope", "kind", "name", "path", "tools", "description"}]}`，在那個資料夾開的 agent 另外會讀到的；資料夾不在時有 `"error"`。`--pid`：`here.agent` 是 `kit run` 在那裡開的 agent（`{"name", "source", "rules", "skills", "mcp"}`），不是就 `null`。`here.folder.agent`（1.3 起）：那個資料夾是 `kit place` 放的 agent 時是它的名字，不是就 `null`；這時 `here.folder.items` 是 agent 的規則、skill、MCP（不含用 `kit rm --dir` 拿掉的）再加上另外加的。

### `kit agents --json`

    {"kit": "0.4.0", "tools": ["claude"], "available": {"rule": [...], "skill": [...], "mcp": [...]},
     "agents": [{"name", "description", "source", "path", "git", "rules", "skills", "mcp", "tools_only", "tools_deny", "prompt"}]}

`git`：`new`（還沒 commit）、`changed`（改過）、`""`（沒改）、`no-git`。

### `kit push [--to 來源] [--dry-run] --json`

一行：

    {"source": "team", "dir": "<來源資料夾>", "push": "pr", "dry_run": true,
     "files": ["skills/b/SKILL.md"], "skipped": ["notes.txt"], "commit": "kit: update skill:b",
     "branch": "kit/b-20261113", "into": "main", "remotes": ["origin"],
     "sent": false, "pr_url": null, "compare_url": "https://gitea.example/acme/team/compare/main...kit/b-20261113"}

- `files`：要送（或送了）的檔案；`[]`＝沒有要送的（這時 `commit`、`branch`、`into` 是 `null`，`remotes` 是 `[]`）。`skipped`：改了但不會送的檔案。
- `push: "pr"`：`branch` 是新開的 `kit/...` 分支，`into` 是 PR 要合進的分支，`remotes` 是 `["origin"]`。`pr_url`：自動開好的 PR（沒有 token 或沒開成就是 `null`）；`compare_url`：自己開 PR 的網址（不知道 Gitea 在哪就是 `null`）。送出後改的檔案移到那個分支，PR 合併、`kit sync` 後才回來。
- `push: "direct"`：`branch` 是現在的分支，`into`、`pr_url`、`compare_url` 是 `null`，`remotes` 是會推過去的每個 remote。
- `sent`：真的 commit 並推出去了（`--dry-run` 一定是 `false`）。
- 沒有 `--to`：在有 `kit.yaml` 的資料夾裡就是它，不然是第一個來源。要送前先 `--dry-run --json` 給人確認，再不帶 `--dry-run` 送；兩次的 `files` 不一樣就表示中間有人改過。

### `kit collect <網址> --look [--path 資料夾] [--ref 分支] [--to 來源]`

    {"source", "dir", "push", "url", "id", "commit", "allowed", "can_allow",
     "skills": [{"path", "name", "valid", "description", "license", "scripts", "skipped", "exists", "dest"}]}

只下載來看、什麼都不寫。`allowed`：作者在 `collect_sources`；`can_allow`：不在，但自己的來源可以用 `--allow` 加。`exists`：`collected`（之前收過）、`own`（自己寫的同名 skill）、`""`。

### `kit new mcp [名字] --config <檔案|-> [--to 來源] --look`（1.3 起）

一行：

    {"name": "github", "source": "team", "path": "<會寫的檔案>", "exists": false, "type": "stdio",
     "yaml": "# 用 kit new mcp --config …\ncommand: npx\n…",
     "secrets": [{"where": "env.GITHUB_PERSONAL_ACCESS_TOKEN", "var": "GITHUB_PERSONAL_ACCESS_TOKEN"}],
     "vars": ["GITHUB_PERSONAL_ACCESS_TOKEN"], "requires": ["node"],
     "packages": [{"kind": "npm", "package": "@modelcontextprotocol/server-github", "version": "2025.4.8", "bad": ""}],
     "warnings": []}

- 什麼都不寫。貼上的內容放在檔案裡給 kit（`-`：從標準輸入讀），kit 不會印出、不會存下任何值，只有變數名字。
- `yaml`：會寫進 `path` 的內容（整個檔案）。`exists`：已經有這個名字的 mcp（`path` 就是它）；這時不加 `--look` 會失敗（`exists`）。
- `secrets`：換成 `${var}` 的值在哪裡（`env.名字`、`headers.名字`、`url`、`args[第幾個，從 1 算]`）。`vars`：它要的環境變數（`${名字}`，有 `:-預設` 的不算）。`requires`：它要的程式（`node`、`uv`、`python`、`docker`）。
- `packages`：`version` 是空的表示沒固定（查不到最新版本，`warnings` 會說）；`bad` 不是空的就是 kit 不幫它裝的原因。
- `warnings`：給人看的字（略過的設定、npm 的範圍或標籤固定在哪一版等）。
- 錯誤看上面的表（`bad_config`、`several_servers`、`not_found`、`no_name`、`bad_name`、`usage`、`not_init`、`no_source`）。`several_servers` 時讓人選一個，再帶名字跑一次。
- 寫進去：同樣的指令拿掉 `--look`（動作類指令）。

### `kit place <agent> <資料夾> [--tool claude|codex|omp] --json`（1.3 起）

一行：

    {"dir": "<資料夾>", "agent": "reviewer", "tool": "codex", "command": ["codex"],
     "warnings": ["Codex 沒有 kit 擋得到、跟 WebSearch 一樣的工具：tools.deny 的這條不套用"]}

- `dir`：資料夾（解開捷徑後的實際路徑）。`command`：在 `dir` 裡跑這個，開的就是那個 agent（就是 `claude`、`codex` 或 `omp`）。
- `warnings`：給人看的字（這個工具做不到的、找不到的規則等），也印在 stderr。
- 錯誤看上面的表（`usage`、`not_init`、`busy`、`no_agent`、`no_parent`、`other_agent`、`not_empty`、`bad_dir`）。
- 是動作類指令：會改檔案，跟 `kit add` 一樣要拿 kit 的鎖（`busy`）。

### `kit context --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--detail [--fresh]]`

一行 JSON，欄位見上面「agent 的 context 用了多少」和「context 細項」。找不到資料不算失敗：`used`、`window`、`pct` 是 `null`（`--detail` 時另外有字串 `error` 寫原因）。參數不對時印給人看的字、exit 不是 0（不是上面的錯誤 JSON）。

### `kit files --pid <pid> [--tool claude|codex|omp] [--dir 資料夾] [--git] --json`（1.1 起；`turns` 1.2 起）

一行：

    {"tool": "claude", "log": "<紀錄檔>", "dir": "<agent 的資料夾>",
     "files": [{"path": "/work/app/src/main.py", "tag": "edit", "exists": true},
               {"path": "/work/app/README.md", "tag": "read", "exists": true}],
     "turns": [{"n": 12, "at": "2026-11-13T03:41:07Z", "text": "登入頁的錯誤訊息改成中文",
                "files": [{"path": "/work/app/src/main.py", "tag": "edit", "exists": true}]},
               {"n": 11, "at": "2026-11-13T03:20:45Z", "text": "先看一下 README",
                "files": [{"path": "/work/app/README.md", "tag": "read", "exists": true}]}]}

- `tool`：`claude`、`codex`、`omp`（看不出來是 `""`，不認得的照 `--tool` 寫的）。`log`：讀的紀錄檔（Claude：主對話的那個；找不到是 `""`）。`dir`：agent 的資料夾（`--dir`，或它現在的資料夾）。
- `files`：最新的在前面，同一個路徑只有一個（看最後一次碰它），最多 200 個（含 `--git` 加的）。`path` 是絕對路徑；有磁碟機代號的（Windows）寫成 `C:/x/y`（`/`，代號照紀錄裡的寫法），比對時不分大小寫。
- `tag`：`read`（讀過）、`edit`（改過；Codex 刪掉、搬走的也算）、`write`（整個寫、新增）、`git`（`--git` 加的，`git status` 有變動）。之後可能加新的 tag（minor 加一）：不認得的當作 `edit`。
- `exists`：現在是不是一個檔案。不在的只會是 `edit` 或 `write`（讀過但不在的、`git` 的不列）。
- `turns`（1.2 起，在 `files` 後面、`note` 前面）：照人送出的每一則訊息分組（像 Claude Code 的 `/rewind`）：那則訊息之後、下一則之前 agent 碰過的檔案。最新的一則在前面；只列有檔案的，最多 30 則，每則最多 50 個檔案（新的在前，同一個路徑一個，看那一則裡最後一次碰它；`exists` 跟 `files` 一樣，讀過但不在的不列）。`--git` 加的不在這裡（只在 `files`）。
  - `n`：第幾則，從 kit 讀到的那段紀錄裡最早的一則算 1。紀錄檔只讀了後面（`KIT_CTX_TAIL`）時，讀到的第一則訊息之前碰的檔案自成一組：`n` 是 `0`、`at` 和 `text` 是 `""`，排在最後。
  - `at`：那則訊息在紀錄裡的時間，換成 UTC 的 `YYYY-MM-DDTHH:MM:SSZ`（沒有小數）；紀錄裡沒有就是 `""`。
  - `text`：那則訊息的開頭：連在一起的空白（含換行、tab）變成一個空格，控制字元拿掉，頭尾空白去掉，最多 30 個字（字，不是 byte），截掉的話後面加 `…`。開頭的 `<system-reminder>…</system-reminder>` 跳過。`<hc from="X">…</hc>`（用 hc 從別的終端機傳來的）寫成 `hc X：` 再接內容的開頭（`</hc>` 拿掉），整個一樣最多 30 個字。照 JSON 規則跳脫。
  - 哪些算「人送出的訊息」：Claude：主對話紀錄裡有文字的使用者訊息；工具結果、`isMeta`、`isCompactSummary`（壓縮後的摘要）、斜線指令和它們的輸出（`<command-name>`、`<command-message>`、`<local-command-stdout>`、`<local-command-caveat>`、`Caveat:`）、`[Request interrupted…`、背景工作的通知（`<task-notification>`）、`!` 指令（`<bash-input>` 等）、只有圖片的都不算。sub-agent 自己收到的指示不算；sub-agent 碰的檔案算在「那個時間點（含同一刻）之前最後一則」主對話訊息那組。Codex：`user_message` 事件和 `UserMessage` 項目（同一則兩種都寫的版本算一則；它自己的指示、環境資訊不算）。omp：它的使用者訊息。
  - `text` 是 kit 第一個從紀錄裡拿出「說了什麼」的欄位：只有每則訊息開頭這最多 30 個字，其他的對話內容還是不拿、不印、不存。
- 找不到紀錄檔（或不認得那種 agent）不算失敗：`files` 是 `[]`（`--git` 的照樣有）、`turns` 是 `[]`、`log` 是 `""`，最後另外有 `"note"`（給人看的原因）。
- 參數不對：exit 1，`{"error": {"code": "usage", ...}}`。

### `kit note --pid <pid> --json`（1.4 起）

那個 agent 現在寫的進度（`kit note`），一行：

    {"pid": 4321, "session": null, "tool": "claude", "dir": "/home/me/proj", "at": 1794641193, "text": "改好 parser；下一步跑測試\n目標：修 #12"}

- `text`：一或兩行（`\n` 分開）；沒寫過、那個程式已經結束後被清掉、或程式編號換了人用：`text`、`tool`、`dir`、`at` 都是 `null`（exit 0）。
- `session`（1.5 起）：Codex 在沙箱裡寫的（記在對話名下）是那個對話的編號，其他是 `null`。`--history` 裡這種的 `pid` 是 `null`。
- `at`：寫的時間（Unix 秒）。`dir`：寫的時候那個程式的資料夾（Windows 是 kit 跑的資料夾）。
- `kit note --history --json [--dir 資料夾]`：`{"dir": "...", "notes": [上面那種，新的在前，最多 20 則]}`。
- 參數不對：`usage`；寫的時候：找不到 agent `no-agent`、太長或超過兩行 `too-long`、寫不進去（Codex 的沙箱還沒開放）`no-write`。

### `kit status --json`（1.3 起）

這個帳號用的是哪一版：kit 的版本和 api、kit 本身和每個來源現在在哪個 commit，用核准紀錄的帳號再加上核准的 commit。
給畫面程式顯示「每台、每個帳號用哪一版，是不是核准的那一版」。

    {
      "kit": "0.4.1",
      "api": "1.2",
      "user": "alice",
      "at": 1763000000,
      "self": {"name": "agentkit", "commit": "<40 字的 commit>", "approved": "<40 字的 commit>"},
      "approvals": {"serial": 7, "used": 7, "valid": true},
      "pending": [
        {"kind": "sign", "name": "team", "what": "team 有 3 個新 commit 等核准", "commits": 3, "head": "<40 字的 commit>", "since": 1763000000000, "machine": "server"},
        {"kind": "owner", "id": "core-0001", "what": "要你同意：裝伺服器的 core 0001", "since": 1763000300000, "machine": "server", "dir": "/srv/app", "pid": 4242}
      ],
      "sources": [
        {"name": "team", "source": "<網址或資料夾>", "dir": "<clone 的資料夾>", "commit": "<40 字的 commit>", "approved": "<40 字的 commit>"}
      ]
    }

- `kit`：kit 的版本（跟 `kit --version` 一樣）。`api`：`kit api` 印的（字串）。`user`：帳號名稱。`at`：印出來的時間（Unix 秒數，整數）：畫面程式讀的是存下來的檔案時，看它就知道有多舊。
- `self`：kit 本身的 clone（安裝時記下、`kit self-update` 更新的那個）。`name`：它 origin 網址的 repo 名字（沒有 origin 就是資料夾的名字），也就是 `approved.txt` 裡用的名字。`commit`：它現在的 commit（完整 40 字），不是 git repo 就是 `null`。不知道 kit 從哪個 clone 裝的（沒用安裝程式裝）時，整個 `self` 是 `null`。
- `approvals`：這個帳號沒用核准紀錄（`kit init` 沒給 `--approvals`）就是 `null`。有用的話：
  - `serial`：本機那份 `approved.txt` 的 serial（沒有檔案或不是數字是 `null`）。
  - `used`：kit 上次換版本時用的 serial（還沒換過是 `null`）。
  - `valid`：`approved.txt` 的簽章是對的（用 signers 檔驗，跟 `kit sync` 一樣）。檔案不在、簽章不對都是 `false`。只看簽章：`serial` 比 `used` 小的清單 kit 也不會用，畫面程式要自己比。
- `pending`（1.6 起）：在等人處理的事，沒有就是 `[]`。現在只有一種：
  - `kind` 是 `"sign"`：用核准紀錄的帳號，某個來源（或 kit 本身）上次 `kit sync` 抓到的遠端最新 commit，比 `approved.txt` 核准的新，在等簽核的人簽。`name`：來源名字（`approved.txt` 用的）；`what`：給人看的一句話；`commits`：還沒核准的 commit 數；`head`：遠端最新的 commit；`since`：最早那個還沒核准的 commit 的時間（Unix 毫秒）；`machine`：這台的主機名稱。從來沒核准過的來源，`what` 是「X 還沒核准過」。
  - 只在核准清單有效（`valid` 是 `true`）時算；跟其他欄位一樣不連網，看的是上次 `kit sync` 抓到的。簽章還是在簽核的電腦上親手做（`kit approve`），畫面程式只顯示。
  - 沒用核准紀錄的帳號、Windows 版：沒有 `"sign"`。
  - `kind` 是 `"owner"`：agent 或服務用 `kit pending add` 記的、在等你同意的事（上面「在等你同意的事」）。`id`：`kit pending done` 用的名字；`what`：那句話；`since`：第一次記的時間（Unix 毫秒）；`machine`：這台的主機名稱；`dir`：記的 agent 所在的資料夾（`--keep` 時是跑指令的資料夾）；`pid`：記在哪個程式名下，`--keep` 時 `null`。記的 agent 已經結束的不列。Windows 版也有。
  - 之後可能多別的 `kind`，畫面程式看不懂的 `kind` 照 `what` 顯示就好。
- `sources`：跟 `kit list --json` 的 `sources` 同樣順序，同樣的 `name`、`source`、`dir`；沒有來源時是 `[]`。`commit`：那個資料夾現在的 commit，不是 git repo（或還沒 clone）就是 `null`。
- `approved`（`self` 和每個來源都有）：`approved.txt` 裡那個名字的 commit。只有 `valid` 是 `true` 才有；沒用核准紀錄、簽章不對、清單裡沒有這個名字都是 `null`。`commit` 和 `approved` 一樣＝在用核准的那一版。
- 只讀這台已經有的：**不連網**（不 clone、不 pull、不 fetch；核准紀錄也只看上次 `kit sync` 拿到的那份，所以不一定是遠端最新的），**什麼都不寫**，也不等別的 kit 跑完（不拿鎖）。
- 還沒 `kit init` 也能跑：`sources` 是 `[]`、`approvals` 是 `null`，exit 0。
- 畫面程式不能直接問的帳號（例如 root）：讓那個帳號自己跑 `kit status --json > <檔案>`（例如定時跑），畫面程式讀那個檔案。輸出本身是完整的，不用再問別的。
- Windows 版的 kit 沒有核准紀錄的功能：`approvals` 和每個 `approved` 一律是 `null`（machine.yaml 有設 `approvals` 時，stderr 會說）。
- 參數不對（沒有 `--json` 也算）：exit 1，`{"error": {"code": "usage", ...}}`。

### 動作類指令

這些印給人看的字（不要解析），程式只看 exit code（0＝成功），失敗時把 stdout、stderr 顯示給人看：

    kit add|rm [--dir 資料夾] rule|skill|mcp <名字>
    kit agent <名字> add|rm rule|skill|mcp <東西>
    kit new rule|skill|mcp|agent <名字> [--to 來源]
    kit new mcp [名字] --config <檔案|-> [--to 來源]
    kit sync [--force] [--dry-run | --expect <雜湊>]   （--expect 清單變了：exit 1，錯誤代碼 plan-changed）
    kit run <agent> [--tool codex|omp]
    kit place <agent> <資料夾> [--tool claude|codex|omp]   （要結果的話加 --json，見上面）
    kit install-tool <程式名> [--min 版本]
    kit install-deps <skill> [npm|pip]
    kit install-deps mcp <名字>
    kit collect <網址> --to 來源 [--path 資料夾] [--allow]
    kit push --to 來源                    （要結果的話加 --json，見上面）

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

收別人寫好的 skill（例如開源專案裡的；公司內只能從 `allowed_hosts` 列的主機收）：

    kit collect <原作者 repo 網址> [--to 來源]   收進來（帶原作者的 LICENSE，記在 third_party.lock）
    kit outdated                             看原作者有沒有新版
    kit collect <名字>                        再收一次＝整份換成新版

- 沒給 `--path` 時：repo 最外層有 `SKILL.md` 就收它；不然 repo 裡只有一個 `SKILL.md` 就收那個資料夾；有好幾個就列出來讓你用 `--path` 選。
- 只收 `kit.yaml` 的 `collect_sources` 裡的作者。自己的來源（`push: direct`）可以加 `--allow`，收的時候一起把作者加進清單；團隊來源要維護者改清單。
  `kit push` 平常不送 `kit.yaml`；但它只改了 `collect_sources` 時（`--allow` 加的）會一起送。
- 網址的主機要在 `allowed_hosts` 裡（收進來的來源自己有列就看它的，沒列就看所有來源的；都沒列就不限）。`file:///` 是本機的資料夾，不算主機。
- `--look`：只下載來看、什麼都不寫，用 JSON 列出找到的 skill、授權、會執行的檔案（見「給程式讀的介面」）。
  只下載 `kit collect` 真的能收的：主機要在 `allowed_hosts`，作者要在 `collect_sources`，或是自己的來源可以用 `--allow` 加的；團隊來源不在清單的作者，直接說不能收，不下載。
- 沒有 LICENSE 的不收；只收文字檔，不收捷徑、圖片和 `.github/` 這類資料夾。

`kit push` 只送改過的 rule、skill、mcp、agent，只 push `kit/...` 分支，不動 main。
來源的 `kit.yaml` 寫 `push: direct`（只有自己用的來源）時，改成直接 commit 到現在的分支、推到它所有的 remote，不開 PR。
不寫就是 `push: pr`。團隊的來源一定要用 `push: pr`。
只有自己、永遠不會公開的來源，`kit.yaml` 可以再寫 `private: true`：`kit check`（所以 `kit push` 也是）就不查這個來源裡不該公開的字
（內容和檔名），它本來就會寫到那些私人的名字。其他檢查照做；`kit export-self` 照查。會公開、或有一天可能公開的來源不要寫。
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

看一個帳號現在用的是不是核准的版本（不連網、不改東西）：`kit status --json`，比每個 `commit` 和 `approved`（見「給程式讀的介面」）。

## 測試

    tests/json_test.sh
    tests/run.sh          在暫時的 HOME 裡跑，不會動到你的設定
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1    （Windows 版）
