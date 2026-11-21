. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
# ---------- uninstall ----------
Kit add skill gerrit-review; Kit add mcp gerrit
Kit uninstall
Check 'uninstall restores CLAUDE.md' { (ReadT "$H/.claude/CLAUDE.md") -eq "# My notes`nBe brief.`n" }
Check 'uninstall removes kit skills' { -not (Test-Path "$H/.claude/skills/gerrit-review") -and (Test-Path "$H/.claude/skills/my-own/SKILL.md") }
Check 'uninstall removes only kit deny' { (Flat (JGet $settings 'permissions.deny')) -eq '["Bash(rm-rf:*)"]' }
Check 'uninstall removes hook' { -not (ReadT $settings).Contains('sync --hook') }
Check 'uninstall: claude.json byte-identical' { SameBytes "$H/.claude.json" "$T/claude.json.orig" }
W "$T/s.orig" "{`n  `"model`": `"opus`",`n  `"hooks`": {`n    `"SessionStart`": [`n      {`n        `"hooks`": [`n          {`n            `"type`": `"command`",`n            `"command`": `"my-hook`"`n          }`n        ]`n      }`n    ]`n  }`n}`n"
Copy-Item "$T/s.orig" $settings -Force
Kit init $TEAM
Check 'user hook kept next to kit hook' { $v = JGet $settings 'hooks.SessionStart'; $v.Contains('my-hook') -and $v.Contains('sync --hook') }
Kit uninstall
Check 'settings.json byte-identical after init+uninstall' { SameBytes "$T/s.orig" $settings }

} finally { Done }
