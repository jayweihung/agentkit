. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
W "$H/.config/agentkit/private-words.txt" "# mine`nTopSecretName`n"
# ---------- push: direct (kit.yaml): your own source, straight to every remote, no PR ----------
$D = Join-Path $T 'pushdirect'; $DW = Join-Path $D 'work'; $R1 = Join-Path $D 'one.git'; $R2 = Join-Path $D 'two.git'
& git -c init.defaultBranch=main init -q --bare $R1; & git -c init.defaultBranch=main init -q --bare $R2
& git -c init.defaultBranch=main init -q $DW
W "$DW/kit.yaml" "name: mine`npush: direct`nallowed_hosts: [gitea.example]`n"; W "$DW/rules/mine.md" "Mine.`n"
& git -C $DW config user.name tester; & git -C $DW config user.email me@home.example; & git -C $DW config core.autocrlf false
& git -C $DW add -A; & git -C $DW commit -qm init
& git -C $DW remote add one $R1; & git -C $DW remote add two $R2
& git -C $DW push -q one main 2>$null; & git -C $DW push -q two main 2>$null; & git -C $DW fetch -q one 2>$null; & git -C $DW fetch -q two 2>$null
Push-Location $DW
W "$DW/rules/mine.md" "Mine, changed.`n"; W "$DW/notes.txt" "not an item`n"
$dh0 = & git -C $DW rev-parse HEAD
W "$DW/kit.yaml" "name: mine`n"
Kit push --dry-run
Check 'push (pr, the default) without origin: stops and says to write push: direct' { $rc -ne 0 -and $out.Contains('沒有 origin') -and $out.Contains('push: direct') -and (& git -C $DW rev-parse HEAD) -eq $dh0 }
W "$DW/kit.yaml" "name: mine`npush: maybe`n"
Kit check .
Check 'check: push is pr or direct' { $rc -ne 0 -and $out.Contains('kit.yaml: push 只能是 pr 或 direct') }
& git -C $DW checkout -q -- kit.yaml
& git -C $DW config remote.one.pushurl https://evil.example/one.git
Kit push --dry-run
Check 'push direct: a push URL to a host not allowed stops it' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --unset remote.one.pushurl
& git -C $DW config 'url.https://evil.example/.pushInsteadOf' ($D + [IO.Path]::DirectorySeparatorChar)
Kit push --dry-run
Check 'push direct: pushInsteadOf to a host not allowed stops it' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --remove-section 'url.https://evil.example/'
& git -C $DW config 'url.evil.example:.pushInsteadOf' ($D + [IO.Path]::DirectorySeparatorChar)
Kit push --dry-run
Check 'push direct: pushInsteadOf to host:path (no user@) is a host too' { $rc -ne 0 -and $out.Contains('evil.example 不在允許的主機清單') }
& git -C $DW config --remove-section 'url.evil.example:'
Kit push --dry-run
Check 'push direct --dry-run: straight to the remotes, nothing sent' { $rc -eq 0 -and $out.Contains('push: direct') -and $out.Contains('one two') -and $out.Contains('rules/mine.md') -and (& git -C $DW rev-parse HEAD) -eq $dh0 -and (& git --git-dir=$R1 rev-parse main) -eq $dh0 }
Kit push
$dh1 = & git -C $DW rev-parse HEAD
Check 'push direct: commit on main, pushed to every remote' { $rc -eq 0 -and (& git --git-dir=$R1 rev-parse main) -eq $dh1 -and (& git --git-dir=$R2 rev-parse main) -eq $dh1 -and (& git -C $DW log -1 --format=%s) -eq 'kit: update rule:mine' -and (& git -C $DW symbolic-ref --short HEAD) -eq 'main' }
Check 'push direct: only the item is committed' { (& git -C $DW show --name-only --format= HEAD | Where-Object { $_ }) -eq 'rules/mine.md' -and "$(& git -C $DW status --porcelain)" -eq '?? notes.txt' }
& git -C $DW commit -q --allow-empty -m unpushed; W "$DW/rules/mine.md" "Mine, again.`n"; $dh2 = & git -C $DW rev-parse HEAD
Kit push
Check 'push direct: a commit not on a remote yet stops it, nothing committed' { $rc -ne 0 -and $out.Contains('還沒推到 one') -and (& git -C $DW rev-parse HEAD) -eq $dh2 -and (& git --git-dir=$R1 rev-parse main) -eq $dh1 }
& git -C $DW reset -q --soft HEAD~1
& git -c init.defaultBranch=main init -q --bare (Join-Path $D 'three.git'); & git -C $DW remote add three (Join-Path $D 'three.git')
Kit push
Check 'push direct: a remote without this branch stops it' { $rc -ne 0 -and $out.Contains('three 上沒有 main') -and (& git -C $DW rev-parse HEAD) -eq $dh1 }
& git -C $DW remote remove three
& git clone -q $R1 (Join-Path $D 'other') 2>$null; & git -C (Join-Path $D 'other') -c user.name=t -c user.email=t@t commit -q --allow-empty -m theirs; & git -C (Join-Path $D 'other') push -q origin HEAD:main 2>$null
Kit push
Check 'push direct: new commits on a remote stop it (pull first)' { $rc -ne 0 -and $out.Contains('git pull one main') -and "$(& git -C $DW status --porcelain rules)" -eq ' M rules/mine.md' }
& git -C $DW pull -q --no-rebase one main 2>&1 | Out-Null; & git -C $DW push -q two main 2>&1 | Out-Null; & git -C $DW fetch -q two 2>&1 | Out-Null
# kit.yaml goes along only when all that changed in it is collect_sources (kit collect --allow)
Add-Content -LiteralPath "$DW/kit.yaml" 'collect_sources: [example.com/a/b]'
Kit push
Check 'push direct: kit.yaml with only collect_sources changed goes along' { $rc -eq 0 -and ((@(& git -C $DW show --name-only --format= HEAD | Where-Object { $_ }) | Sort-Object) -join ' ') -eq 'kit.yaml rules/mine.md' }
W "$DW/rules/mine.md" "Mine, once more.`n"; Add-Content -LiteralPath "$DW/kit.yaml" 'maintainers: [me]'
Kit push
Check 'push direct: kit.yaml with other changes stays behind' { $rc -eq 0 -and "$(& git -C $DW show --name-only --format= HEAD)".Trim() -eq 'rules/mine.md' -and $out -match '不會送：kit.yaml' }
& git -C $DW checkout -q -- kit.yaml
# a commit hook says no: git's words are shown, and nothing is left staged
W "$DW/.git/hooks/pre-commit" "#!/bin/sh`necho 'hook: no thanks' >&2`nexit 1`n"; if (-not $OnWindows) { & chmod +x "$DW/.git/hooks/pre-commit" }
W "$DW/rules/mine.md" "Mine, blocked.`n"; $headBefore = "$(& git -C $DW rev-parse HEAD)".Trim()
Kit push
Check "push direct: a commit hook refusing: its words shown, nothing committed or left staged" { $rc -ne 0 -and $out -match 'hook: no thanks' -and "$(& git -C $DW rev-parse HEAD)".Trim() -eq $headBefore -and -not "$(& git -C $DW diff --cached --name-only)" -and "$(& git -C $DW status --porcelain rules)" -eq ' M rules/mine.md' }
Remove-Item -Force "$DW/.git/hooks/pre-commit"

# ---------- a source set up through a link (on macOS /tmp is really /private/tmp; on Windows a junction): still one source ----------
if (-not (Links-Follow)) { [Console]::WriteLine('skipped: a source through a link (a junction made here cannot be followed: RedirectionGuard)') }
else {
$hSave = $H; Set-Home (Join-Path $T 'home-linked')
$LK = Join-Path $T 'pd-link'; [void](New-Item -ItemType $(if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $LK -Target $D)
$LW = Join-Path $LK 'work'
$DWP = if ($OnWindows) { (Get-Item -LiteralPath $DW -Force).FullName.TrimEnd('\', '/') } else { "$(& /bin/sh -c 'cd "$1" && pwd -P' sh $DW)".Trim() }
$DWJ = $DWP.Replace('\', '\\')
$LM = Join-Path $H '.config/agentkit/machine.yaml'; $LS = Join-Path $H '.config/agentkit/state.tsv'
Kit init $LW
Check 'init through a link: the source is kept with links resolved' { $rc -eq 0 -and (ReadT $LM).Contains("  - $DWP`n") }
Push-Location $LW
KitJ push --dry-run --json
Check 'init through a link, push in the link: one source, not two' { $rc -eq 0 -and $out.StartsWith("{`"source`": `"work`", `"dir`": `"$DWJ`", `"push`": `"direct`", `"dry_run`": true, `"files`": [`"rules/mine.md`"], ") }
Kit check
Check 'check in a source opened through a link: no name twice' { $rc -eq 0 -and $out.Contains('沒問題（1 個來源）') }
Pop-Location
Push-Location $T
KitJ push --to $LW --dry-run --json
Check 'push --to a folder through a link: the same one source' { $rc -eq 0 -and $out.Contains("`"dir`": `"$DWJ`", ") }
Pop-Location
# upgrading: kit before 0.3.0 kept the folder as typed (the link)
W $LM ((ReadT $LM).Replace("  - $DWP`n", "  - $LW`n"))
KitJ push --dry-run --json
Check 'upgrade: a source kept as a link still counts once' { (ReadT $LM).Contains("  - $LW`n") -and $rc -eq 0 -and $out.Contains("`"dir`": `"$DWJ`", ") }
Push-Location $LW
Kit check
Check 'upgrade: check with a source kept as a link: no name twice' { $rc -eq 0 -and $out.Contains('沒問題（1 個來源）') }
Pop-Location
W "$T/linked.md" "Linked.`n"
Kit new rule linked --from "$T/linked.md" --to $LW
Check 'kit new --from through a link: remembered under the folder with links resolved' { (ReadT $LS).Contains("from`trule:linked@$DWP`t") }
W $LS ((ReadT $LS).Replace("from`trule:linked@$DWP`t", "from`trule:linked@$LW`t"))
W "$T/linked.md" "Linked, newer.`n"
Kit update rule linked --from "$T/linked.md" --to $LW
Check 'upgrade: kit update finds what kit new remembered under the link' { (ReadT $LS).Contains("from`trule:linked@$LW`t") -and $rc -eq 0 -and (ReadT "$DW/rules/linked.md").Contains('Linked, newer') }
Remove-Item -Force "$DW/rules/linked.md"
Set-Home $hSave
}
Pop-Location

} finally { Done }
