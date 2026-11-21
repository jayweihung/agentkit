#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
snap() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3); }
# ---------- signed approvals (root uses only versions signed on the Mac) ----------
SA="$T/signed"; mkdir -p "$SA"
ssh-keygen -q -t ed25519 -N '' -C approver -f "$SA/key"
printf 'jay namespaces="agentkit" %s\n' "$(cat "$SA/key.pub")" > "$SA/allowed_signers"
ssh-keygen -q -t ed25519 -N '' -C mallory -f "$SA/badkey"
mkdir -p "$SA/work/srcA/rules"; echo "Approved rule v1." > "$SA/work/srcA/rules/ar.md"; printf 'name: srcA\nrequired:\n  rules: [ar]\n' > "$SA/work/srcA/kit.yaml"
( cd "$SA/work/srcA" && git init -q && git config user.name t && git config user.email t@t && git add -A && git commit -qm v1 && git clone -q --bare . "$SA/srcA.git" && git remote add origin "$SA/srcA.git" && git fetch -q origin )
mkdir -p "$SA/appr-work"; ( cd "$SA/appr-work" && git init -q && git config user.name t && git config user.email t@t && git commit -q --allow-empty -m start && git clone -q --bare . "$SA/approvals.git" && git remote add origin "$SA/approvals.git" )
out=$(kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes 2>&1); rc=$?
check "approve signs and commits" '[ $rc -eq 0 ] && [ -f "$SA/appr-work/approved.txt.sig" ] && grep -q "^serial: 1$" "$SA/appr-work/approved.txt" && grep -q "^srcA " "$SA/appr-work/approved.txt"'
git -C "$SA/appr-work" push -q origin HEAD:master 2>/dev/null || git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null
RH="$T/roothome"; mkdir -p "$RH"
rk() { HOME="$RH" AGENTKIT_CONFIG="$RH/.config/agentkit" AGENTKIT_SOURCES="$RH/agentkit" "$KIT" "$@"; }
out=$(rk init "file://$SA/srcA.git" --approvals "file://$SA/approvals.git" --signers "$SA/allowed_signers" 2>&1); rc=$?
v1=$(git -C "$SA/work/srcA" rev-parse HEAD)
check "signed init uses the approved commit" '[ $rc -eq 0 ] && [ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v1" ] && grep -q "ar.md" "$RH/.claude/CLAUDE.md"'
check "machine.yaml keeps approvals and signers" 'grep -q "^approvals: file://" "$RH/.config/agentkit/machine.yaml" && grep -q "^signers: " "$RH/.config/agentkit/machine.yaml"'
( cd "$SA/work/srcA" && echo "Unapproved v2." > rules/ar.md && git commit -qam v2 && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "unapproved new commit is not used" '[ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v1" ] && grep -q "v1" "$RH/agentkit/srcA/rules/ar.md"'
rk add skill nothing >/dev/null 2>&1
check "add/rm keep the approvals setting" 'grep -q "^approvals: " "$RH/.config/agentkit/machine.yaml"'
out=$(kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes 2>&1)
check "approve shows what changed" 'echo "$out" | grep -q "v2" && echo "$out" | grep -q "rules/ar.md"'
cp "$SA/appr-work/approved.txt" "$SA/appr1.txt.v2"; git -C "$SA/appr-work" show HEAD~1:approved.txt > "$SA/old.txt"; git -C "$SA/appr-work" show HEAD~1:approved.txt.sig > "$SA/old.sig"
git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null
out=$(rk sync 2>&1)
check "approved v2 is used after approve" '[ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$(git -C "$SA/work/srcA" rev-parse HEAD)" ] && echo "$out" | grep -q 換到核准的版本'
# someone with write access to the approvals repo but without the key
( cd "$SA/appr-work" && printf '# x\nserial: 9\nsrcA %s\n' "$v1" > approved.txt && git commit -qam forged && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "edited list without a new signature is refused" 'echo "$out" | grep -q 簽章不對 && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
( cd "$SA/appr-work" && rm -f approved.txt.sig && ssh-keygen -Y sign -q -f "$SA/badkey" -n agentkit approved.txt && git add -A && git commit -qm forged2 && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "list signed by another key is refused" 'echo "$out" | grep -q 簽章不對 && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
( cd "$SA/appr-work" && cp "$SA/old.txt" approved.txt && cp "$SA/old.sig" approved.txt.sig && git add -A && git commit -qm replay && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "an older signed list (serial 1) cannot roll back" 'echo "$out" | grep -q "比上次用的舊" && grep -q "Unapproved v2" "$RH/agentkit/srcA/rules/ar.md"'
echo "local edit" >> "$RH/agentkit/srcA/rules/ar.md"
( cd "$SA/appr-work" && git checkout -q HEAD~3 -- approved.txt approved.txt.sig && git commit -qm restore && git push -q origin HEAD 2>/dev/null )
out=$(rk sync 2>&1)
check "local edits in the clone are reset to the approved commit" '! grep -q "local edit" "$RH/agentkit/srcA/rules/ar.md"'
# status --json with approvals: only the approvals clone that is here already (never pulled), nothing written
v2=$(git -C "$SA/work/srcA" rev-parse HEAD)
kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes >/dev/null 2>&1; git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null   # serial 3, not pulled here
snap "$RH" > "$T/rst.snap"
out=$(rk status --json 2>/dev/null); rc=$?
check "status --json with approvals: serial, used, valid; the approved commit next to the one in use" '[ $rc -eq 0 ] && echo "$out" | grep -qxF "  \"approvals\": {\"serial\": 2, \"used\": 2, \"valid\": true}," &&
    echo "$out" | grep -qxF "    {\"name\": \"srcA\", \"source\": \"file://$SA/srcA.git\", \"dir\": \"$RH/agentkit/srcA\", \"commit\": \"$v2\", \"approved\": \"$v2\"}"'
check "status --json with approvals: nothing fetched or written" 'snap "$RH" | cmp -s - "$T/rst.snap"'
check "status --json with approvals: nothing waits for the signer (the remote is at the approved commit)" 'echo "$out" | grep -qxF "  \"pending\": [],"'
echo "srcB 0123456789012345678901234567890123456789" >> "$RH/agentkit/.approvals/approved.txt"
out=$(rk status --json 2>/dev/null); rc=$?
check "status --json: an edited approved.txt is not valid, no approved commits" '[ $rc -eq 0 ] && echo "$out" | grep -qxF "  \"approvals\": {\"serial\": 2, \"used\": 2, \"valid\": false}," &&
    echo "$out" | grep -qxF "    {\"name\": \"srcA\", \"source\": \"file://$SA/srcA.git\", \"dir\": \"$RH/agentkit/srcA\", \"commit\": \"$v2\", \"approved\": null}"'
git -C "$RH/agentkit/.approvals" checkout -q -- approved.txt
NC="$T/noclone"; mkdir -p "$NC/conf"; cp "$RH/.config/agentkit/machine.yaml" "$NC/conf/"
out=$(HOME="$RH" AGENTKIT_CONFIG="$NC/conf" AGENTKIT_SOURCES="$NC/src" "$KIT" status --json 2>/dev/null); rc=$?
check "status --json: no approvals clone yet: not valid, none made" '[ $rc -eq 0 ] && echo "$out" | grep -qxF "  \"approvals\": {\"serial\": null, \"used\": null, \"valid\": false}," &&
    echo "$out" | grep -qxF "    {\"name\": \"srcA\", \"source\": \"file://$SA/srcA.git\", \"dir\": \"$NC/src/srcA\", \"commit\": null, \"approved\": null}" && [ ! -e "$NC/src" ] && [ "$(ls "$NC/conf")" = machine.yaml ]'
if [ -n "$PWSH" ]; then
    rk status --json 2>/dev/null | grep -v '"at":' > "$T/bst"
    HOME="$RH" AGENTKIT_CONFIG="$RH/.config/agentkit" AGENTKIT_SOURCES="$RH/agentkit" kps status --json 2>/dev/null | tr -d '\r' | grep -v '"at":' > "$T/pst"; rc=${PIPESTATUS[0]}
    check "status --json with approvals: kit.ps1 says the same as unix/kit (serial, used, valid, approved)" '[ $rc -eq 0 ] && grep -qxF "  \"approvals\": {\"serial\": 2, \"used\": 2, \"valid\": true}," "$T/pst" && diff "$T/bst" "$T/pst"'
fi
# a new commit on the source, fetched by kit sync but not approved: kit status says it waits for the signer
( cd "$SA/work/srcA" && echo "v3, not approved yet." > rules/ar.md && git commit -qam v3 && git push -q origin HEAD 2>/dev/null )
rk sync >/dev/null 2>&1; v3=$(git -C "$SA/work/srcA" rev-parse HEAD)
out=$(rk status --json 2>/dev/null); rc=$?
check "status --json: a new commit kit sync fetched but nobody approved waits for the signer (pending, kind sign)" '[ $rc -eq 0 ] && [ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v2" ] &&
    printf "%s" "$out" | python3 -c "import json,sys;p=json.load(sys.stdin)[\"pending\"];assert len(p)==1 and p[0][\"kind\"]==\"sign\" and p[0][\"name\"]==\"srcA\" and p[0][\"commits\"]==1 and p[0][\"head\"]==sys.argv[1] and p[0][\"what\"]==\"srcA 有 1 個新 commit 等核准\" and p[0][\"since\"]>1e12 and p[0][\"machine\"]" "$v3"'
kit approve "$SA/appr-work" "$SA/work/srcA" --key "$SA/key" --yes >/dev/null 2>&1; git -C "$SA/appr-work" push -q origin HEAD 2>/dev/null; rk sync >/dev/null 2>&1
out=$(rk status --json 2>/dev/null)
check "status --json: approved and synced: nothing pending" 'echo "$out" | grep -qxF "  \"pending\": []," && [ "$(git -C "$RH/agentkit/srcA" rev-parse HEAD)" = "$v3" ]'
out=$(HOME="$RH" AGENTKIT_CONFIG="$RH/.config/agentkit" AGENTKIT_SOURCES="$RH/agentkit2" "$KIT" init "file://$SA/srcA.git" --approvals "$SA/nowhere" --signers "$SA/allowed_signers" 2>&1); rc=$?
check "signed init without a valid list stops" '[ $rc -ne 0 ] && [ ! -e "$RH/agentkit2/srcA/rules" ]'
# the approvals repo and key are remembered: kit approve <clone> --push; kit list --json says what this computer signs
( cd "$SA/work/srcA" && echo "v4." > rules/ar.md && git commit -qam v4 && git push -q origin HEAD 2>/dev/null )
out=$(kit approve "$SA/work/srcA" --yes --push 2>&1); rc=$?
check "approve <clone>: the approvals repo and key of last time; --push pushes it" '[ $rc -eq 0 ] && echo "$out" | grep -q 推上去了 &&
    [ "$(git -C "$SA/approvals.git" show HEAD:approved.txt | awk "\$1 == \"srcA\" { print \$2 }")" = "$(git -C "$SA/work/srcA" rev-parse HEAD)" ]'
out=$(kit approve 2>&1); rc=$?
check "approve with no clone: usage" '[ $rc -ne 0 ] && echo "$out" | grep -q 用法'
SC="$T/signconf"; mkdir -p "$SC"; cp "$HOME/.config/agentkit/state.tsv" "$SC/"   # (this HOME has no kit init: its own config, the same state)
AGENTKIT_CONFIG="$SC" AGENTKIT_SOURCES="$T/signsrc" kit init "$SA/work/srcA" >/dev/null 2>&1
out=$(AGENTKIT_CONFIG="$SC" AGENTKIT_SOURCES="$T/signsrc" kit list --json 2>/dev/null)
check "list --json: sign, the approvals this computer signs with" 'printf "%s" "$out" | python3 -c "import json,sys;s=json.load(sys.stdin)[\"sign\"];assert s[\"approvals\"].endswith(\"/appr-work\") and s[\"serial\"]>=4 and s[\"approved\"]==[{\"name\":\"srcA\",\"commit\":\"$(git -C "$SA/work/srcA" rev-parse HEAD)\"}], s"'

finish
