. (Join-Path $PSScriptRoot "../lib.ps1")
try {
# what this section needs that the old one-file run.ps1 had done before it
Kit init $TEAM
W "$H/.config/agentkit/private-words.txt" "# mine`nTopSecretName`n"
# ---------- push (local bare repo as origin, fake Gitea on localhost) ----------
$Py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $Py) { [Console]::WriteLine('skip: push tests need python for the fake Gitea') } else {
$P = Join-Path $T 'push'; $W = Join-Path $P 'work'; $ORIGIN = Join-Path $P 'remote/acme/team.git'; $DAY = Get-Date -Format yyyyMMdd
[void](New-Item -ItemType Directory -Force -Path (Join-Path $P 'remote/acme'))
& git -c init.defaultBranch=main init -q --bare $ORIGIN
& git -c init.defaultBranch=main init -q $W
W "$W/kit.yaml" "name: team`nallowed_hosts: [gitea.example, 127.0.0.1]`nauthor_domains: [corp.example]`n"
W "$W/rules/base.md" "Be kind.`n"
& git -C $W config user.name tester; & git -C $W config user.email me@corp.example
& git -C $W add -A; & git -C $W commit -qm init; & git -C $W remote add origin $ORIGIN
& git -C $W push -q origin main 2>$null; & git -C $W fetch -q origin 2>$null; & git -C $W remote set-head origin main
W "$P/fake-gitea" @'
import http.server, json, sys
port_file, log_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log_file, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body.decode("utf-8"))}) + "\n")
        out = json.dumps({"number": 1, "html_url": "http://127.0.0.1/acme/team/pulls/1"}).encode()
        self.send_response(201); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
'@
W "$P/req.log" ''
$fake = Start-Process -FilePath $Py -ArgumentList @('-I', "`"$P/fake-gitea`"", "`"$P/port`"", "`"$P/req.log`"") -PassThru -NoNewWindow
for ($i = 0; $i -lt 120 -and -not ((Test-Path "$P/port") -and (Get-Item "$P/port").Length -gt 0); $i++) { Start-Sleep -Milliseconds 500 }
$env:KIT_GITEA_API = "http://127.0.0.1:$((ReadT "$P/port").Trim())/api/v1"; Remove-Item env:KIT_GITEA_TOKEN -ErrorAction SilentlyContinue
$WebBase = $env:KIT_GITEA_API -replace '/api/v1$', ''
function RemoteHeads { (@(& git --git-dir=$ORIGIN for-each-ref '--format=%(refname:short)' refs/heads) | Sort-Object) -join ' ' }
function LastReq { $l = @((ReadT "$P/req.log").Split("`n") | Where-Object { $_ }); if ($l.Count -eq 0) { return $null }; $l[$l.Count - 1] | ConvertFrom-Json }
function KitBranches { @(& git -C $W branch --list 'kit/*').Count }
try {
Push-Location $W
Kit push
Check 'push: nothing to send' { $rc -eq 0 -and $out.Contains('沒有要送的') }
$WJ = ("$(& $Exe -NoProfile -Command '(Get-Location).ProviderPath')").Replace('\', '\\')   # as a new kit sees this folder
KitJ push --dry-run --json
Check 'push --json: nothing to send, in JSON' { $rc -eq 0 -and $out -ceq "{`"source`": `"$(Split-Path -Leaf $W)`", `"dir`": `"$WJ`", `"push`": `"pr`", `"dry_run`": true, `"files`": [], `"skipped`": [], `"commit`": null, `"branch`": null, `"into`": null, `"remotes`": [], `"sent`": false, `"pr_url`": null, `"compare_url`": null}" }
Kit new skill pfoo
$head0 = (& git -C $W rev-parse HEAD)
Kit push --dry-run
Check 'push --dry-run lists files and branch, sends nothing' { $rc -eq 0 -and $out.Contains('skills/pfoo/SKILL.md') -and $out.Contains("kit/pfoo-$DAY") -and (& git -C $W rev-parse HEAD) -eq $head0 -and (KitBranches) -eq 0 -and (RemoteHeads) -eq 'main' }
KitJ push --dry-run --json
Check 'push --dry-run --json: files, commit, branch, where the PR goes; nothing else on stdout' { $rc -eq 0 -and $out -ceq "{`"source`": `"$(Split-Path -Leaf $W)`", `"dir`": `"$WJ`", `"push`": `"pr`", `"dry_run`": true, `"files`": [`"skills/pfoo/SKILL.md`"], `"skipped`": [], `"commit`": `"kit: add skill:pfoo`", `"branch`": `"kit/pfoo-$DAY`", `"into`": `"main`", `"remotes`": [`"origin`"], `"sent`": false, `"pr_url`": null, `"compare_url`": `"$WebBase/acme/team/compare/main...kit/pfoo-$DAY`"}" }
$pj = $out
[void](New-Item -ItemType Directory -Force -Path "$W/skills/pfoo/scripts/__pycache__"); [IO.File]::WriteAllBytes("$W/skills/pfoo/scripts/__pycache__/x.cpython-314.pyc", [byte[]]@(0, 1, 2))
KitJ push --dry-run --json
Check 'push: Python caches in a skill are not sent, not listed as left out, do not stop kit check' { $rc -eq 0 -and $out -ceq $pj }
Remove-Item -LiteralPath "$W/skills/pfoo/scripts" -Recurse -Force
[IO.File]::AppendAllText("$W/skills/pfoo/SKILL.md", "TopSecretName here`n")
Kit push
Check 'push: check problem stops, nothing sent' { $rc -ne 0 -and $out.Contains('什麼都沒送') -and (KitBranches) -eq 0 -and (RemoteHeads) -eq 'main' }
KitJ push --dry-run --json
Check 'push --json: a check problem is error check_failed' { $rc -ne 0 -and $out -ceq '{"error": {"code": "check_failed", "message": "kit check 有問題，什麼都沒送（改好再 kit push）"}}' }
W "$W/skills/pfoo/SKILL.md" "---`nname: pfoo`ndescription: p`n---`nok`n"
& git -C $W config user.email me@home.example
Kit push
Check 'push: author domain must be company' { $rc -ne 0 -and $out.Contains('不是公司網域') -and (RemoteHeads) -eq 'main' }
& git -C $W config user.email me@corp.example
& git -C $W remote set-url origin https://public-git.example/acme/team.git
Kit push
Check 'push: origin host not allowed' { $rc -ne 0 -and $out.Contains('public-git.example 不在允許的主機清單') -and (RemoteHeads) -eq 'main' }
& git -C $W remote set-url origin $ORIGIN
W "$W/notes.txt" "local only`n"; & git -C $W add notes.txt; & git -C $W commit -qm 'local only'   # an unpushed commit on main
Kit push
Check 'push: no token -> compare URL' { $rc -eq 0 -and $out.Contains("開 PR：$WebBase/acme/team/compare/main...kit/pfoo-$DAY") }
Check 'push: only the kit branch is pushed' { (RemoteHeads) -eq "kit/pfoo-$DAY main" -and (& git --git-dir=$ORIGIN rev-parse main) -eq $head0 }
Check 'push: commit has only the item, message' { (& git --git-dir=$ORIGIN log -1 '--format=%s' "kit/pfoo-$DAY") -eq 'kit: add skill:pfoo' -and "$(& git --git-dir=$ORIGIN diff --name-only main "kit/pfoo-$DAY")" -eq 'skills/pfoo/SKILL.md' }
Check 'push: back on main, no PR request' { (& git -C $W symbolic-ref --short HEAD) -eq 'main' -and $null -eq (LastReq) }
W "$W/rules/base.md" "Be kinder.`n"; Kit new rule pnew; W "$W/rules/pnew.md" "x`n"
$env:KIT_GITEA_TOKEN = 'fake-tok-123'; Kit push; Remove-Item env:KIT_GITEA_TOKEN
$req = LastReq
Check 'push: PR opened, URL printed' { $rc -eq 0 -and $out.Contains('已開 PR：http://127.0.0.1/acme/team/pulls/1') }
Check 'push: PR request path, token header, head/base' { $req.path -eq '/api/v1/repos/acme/team/pulls' -and $req.auth -eq 'token fake-tok-123' -and $req.body.head -eq "kit/base-pnew-$DAY" -and $req.body.base -eq 'main' }
Check 'push: PR title is the commit message, body in UTF-8' { $req.body.title -eq 'kit: add rule:pnew; update rule:base' -and $req.body.body.Contains('由 kit push 送出') }
Check 'push: token never printed' { -not $out.Contains('fake-tok') }
W "$H/.config/agentkit/gitea-token" "file-tok-456`n"
if (-not $OnWindows) { & chmod 644 "$H/.config/agentkit/gitea-token" }
Kit new skill pfoo; W "$W/skills/pfoo/SKILL.md" "---`nname: pfoo`ndescription: p`n---`nagain`n"
Kit push
Check 'push: same branch name taken -> -2' { $rc -eq 0 -and (RemoteHeads).Contains("kit/pfoo-$DAY-2") }
Check 'push: token file used, never printed' { (LastReq).auth -eq 'token file-tok-456' -and -not $out.Contains('file-tok') }
if (-not $OnWindows) { Check 'push: loose token file permission warned' { $out.Contains('chmod 600') } }
Remove-Item -LiteralPath "$H/.config/agentkit/gitea-token" -Force
Pop-Location
} finally {
    Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
    Remove-Item env:KIT_GITEA_API, env:KIT_GITEA_TOKEN -ErrorAction SilentlyContinue
}
}

} finally { Done }
