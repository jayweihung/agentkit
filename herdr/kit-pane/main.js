// A pane's header with kit's button: what this agent uses (rules, skills, MCP), one click to see it.
// `kit herdr-panel install` puts it in the layout in place of Herdr's own pane header ("mod": "pane"),
// and `kit herdr-panel uninstall` puts Herdr's back. Like Herdr's header it shows the program's icon, the
// name, the folder and the agent's status, with split / zoom / close on hover (always laid out, shown only on
// hover, so nothing in the header moves). Props from the app: { pane, terminal }.
//
// This header is the one place that asks kit about an agent (mods can't share code, so they share data):
//   kit list --json --dir <its folder> --pid <its process>      on the pane's machine
// and keeps the answer in shared state for the kit popup (mod "kit", role "pane") to show:
//   kit.pane.v1        key -> { text, level, counts, news, started, at, busy }   the button's words
//   kit.pane.data.v1   key -> what kit list said (only for panes that still exist)
//   kit.pane.want      key -> when someone asked for a fresh look (the popup's ⟳, after adding / taking off)
// key = "<machine>|<folder>|<terminal>" (machine empty for this computer).
// It also shows how full the agent's context is, from
//   kit context --pid <the agent's process> --tool <claude|codex|omp> --dir <its folder>
// kept in kit.ctx.v1 (key -> { used, window, pct, at, busy, started, unsupported }), asked again every 15 s while it
// works. A failed ask keeps the numbers it had; a kit without kit context (an older one) is asked again in 10 minutes.
//
// Role "context" (props { role, target }): the popup the context chip opens, where the tokens go, like Claude
// Code's own /context:  kit context ... --detail [--fresh]  on the agent's machine (kit keeps it a minute; ⟳ asks
// again). Its buttons type the tool's own command into that agent (hc send, only while it waits: idle or done):
// 壓縮 (/compact, with what to keep where the tool takes it) and 清空重來 (Claude /clear, Codex and omp /new), each
// confirmed first; 拿掉 takes off what kit manages (the Kit popup's kit rm), 開檔 opens a memory / instruction file
// in kit's editor window (this computer only), 複製 copies the summary.
import { View, div, svg, image } from "gpui-kit";
import { h_flex, v_flex, InputState, Input, TextView } from "gpui-base";
import { panes, spaces, agents, props, run, theme, home, exec, hc, shared, setShared, appHome, readTextFile, window, openOverlay, closeOverlay, notify, settings } from "herdr";

const CACHE = "kit.pane.v1", DATA = "kit.pane.data.v1", WANT = "kit.pane.want", CTX = "kit.ctx.v1";
const CTX_STALE = 15000, CTX_IDLE = 60000;   // how often to ask how full the context is: working / not
const CTX_OLD_KIT = 600000;                  // a kit without kit context: ask again after 10 minutes (it may be updated)
const STALE = 60000, LOAD_TTL = 90000;   // look again after a minute; a load longer than this is taken as lost
const BUSY = "kit.busy", REPO = "kit.data.v2", EDITORS = "kit.editors";   // the kit panel's (one kit action at a time)
const SHORT = 120000;
const CTX_W = 480, CTX_H = 640, CHIP_W = 154;   // the context popup; the context chip (one width: the header never moves)
const isWindows = () => window()?.platform === "windows";
const slash = (p) => String(p ?? "").replace(/\\/g, "/");
const clean = (s) => String(s).split("\n").map((l) => l.replace(/^kit[:：]\s?/, "")).join("\n").trim();
const fs = () => Number(settings().ui_font_size) || 13;
const stop = (_e, cx) => cx.stop_propagation();
const spin = (size, color) => svg("mods/workspace-chrome/spinner.svg").size(size).flex_none().text_color(color).spin(900);
const waiting = (t, z, text) => h_flex().gap(6).items_center().text_color(t.dim).child(spin(z - 1, t.dim)).child(text);
// Copying (the same in every kit mod, and the same as the gerrit mod's): blocks of text (kit's messages, errors,
// notes) are selectable — drag over them, then Cmd/Ctrl+C; a right-click on a single value (a name, a path, a
// number) copies it and says 已複製. Left clicks are untouched.
// Leading spaces and tabs kept visible (text wraps, so they'd collapse).
const keepIndent = (l) => String(l ?? "").replace(/^[ \t]+/, (m) => m.replace(/\t/g, "    ").replace(/ /g, "\u00a0"));
// Plain text as a selectable TextView: every line kept (a Markdown hard break: an HTML <br> inside a <p> is lost),
// nothing in it read as markup (every ASCII punctuation mark escaped). Its press is stopped, so selecting text in a
// window never drags the window.
const mdLines = (text) => String(text ?? "").replace(/\r/g, "").split("\n")
  .map((l) => keepIndent(l.replace(/[\\`*_{}[\]<>()#+\-.!|~$&:"'@^=?%,;\/]/g, "\\$&")) || "\u00a0").join("\\\n");
const textBlock = (id, text) => div().on_mouse_down("left", stop).child(TextView.markdown(id, mdLines(text)).selectable(true));
// on_mouse_down("right", copyOn(value))
const copyOn = (value) => (_e, cx) => {
  const text = String(value ?? "");
  if (!text) return;
  cx.stop_propagation();
  cx.write_to_clipboard(text);
  notify({ title: "已複製", body: text.length > 120 ? `${text.slice(0, 120)}…` : text, level: "success", timeout: 1500 });
};
const copyOnRight = (el, value) => el.on_mouse_down("right", copyOn(value));

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}
function folder(cwd) {
  const c = slash(cwd), h = slash(home());
  if (!c) return "";
  return c === h ? "~" : h && c.startsWith(h + "/") ? "~" + c.slice(h.length) : c;
}
// where a pane lives: its machine (its space's), and the key its answers are kept under
function placeOf(p) {
  const sp = spaces().find((s) => (s.tabs ?? []).some((t) => t.id === p.tab));
  const machine = sp?.machine ?? null;
  return { machine, space: sp?.id ?? null, key: `${machine ?? ""}|${p.cwd ?? ""}|${p.terminal}` };
}
const agentPanes = () => panes().filter((p) => p.terminal && p.program?.agent);
// only the keys of panes that still exist (each folder change makes a new key)
function pruned(obj) {
  const live = new Set(agentPanes().map((p) => placeOf(p).key));
  return Object.fromEntries(Object.entries(obj ?? {}).filter(([k]) => live.has(k)));
}

// how to run kit: here as kit herdr-panel install wrote it (mods/kit/config.json), on another machine from its PATH
const REMOTE_SH = ["sh", "-c", 'command -v kit >/dev/null 2>&1 && exec kit "$@"; exec "$HOME/.local/bin/kit" "$@"', "kit"];
async function kitHere() {
  const text = await readTextFile(`${slash(appHome())}/mods/kit/config.json`).catch(() => null);
  let c = {};
  try { c = text ? JSON.parse(text) : {}; } catch { c = {}; }
  const kit = Array.isArray(c.kit) && c.kit.length ? c.kit.map(String) : [isWindows() ? "kit.cmd" : "kit"];
  const env = c.env && typeof c.env === "object" ? Object.entries(c.env).map(([k, v]) => `${k}=${v}`) : [];
  return env.length && !isWindows() ? ["/usr/bin/env", ...env, ...kit] : kit;
}
async function runKit(machine, args) {
  const ways = machine ? [REMOTE_SH, ["kit.cmd"]] : [await kitHere()];
  let last = "";
  for (const argv of ways) {
    let r;
    try { r = await exec(argv[0], [...argv.slice(1), ...args], { timeout: 60000, on: machine }); }
    catch (e) { last = String(e?.message ?? e); continue; }   // couldn't start it that way (no sh there): the next way
    // a shell that found no kit (127; 9009 on Windows): the next way; anything else is kit's own answer
    if (machine && argv === REMOTE_SH && (r.code === 127 || r.code === 9009)) { last = String(r.stderr ?? ""); continue; }
    return { code: r.code, out: String(r.stdout ?? ""), err: String(r.stderr ?? "") };
  }
  return { code: -1, out: "", err: machine ? `連不到 ${machine}，或那台沒裝 kit${last ? `（${clean(last)}）` : ""}` : `沒辦法執行 kit：${last}` };
}
// kit list for one agent; never this computer's list in place of another machine's
async function loadAgent(machine, cwd, term) {
  const args = ["list", "--json"];
  if (cwd) args.push("--dir", cwd);
  const g = term ? await hc(["get", term, "--json"]).catch(() => null) : null;
  try { const pid = JSON.parse(g?.stdout ?? "{}").pid; if (pid) args.push("--pid", String(pid)); } catch {}
  let r = await runKit(machine, args);
  // an older kit without --dir / --pid: ask again without them
  if (r.code > 0 && /--dir|--pid|用法/.test(r.err)) r = await runKit(machine, ["list", "--json"]);
  const at = Date.now();
  if (r.code !== 0) return { error: clean(r.err || r.out) || `kit list 失敗（${r.code}）`, machine, at };
  try { return { ...JSON.parse(r.out), machine, at }; }
  catch { return { error: "kit list --json 的輸出讀不懂（那台的 kit 太舊？在那台打 kit self-update）", machine, at }; }
}
// the button's words: how many rules / skills / MCP this agent reads (kit's for the account, its folder's own,
// and the set kit run started it with), each name counted once
function summary(d) {
  if (!d) return { text: "…", level: "dim" };
  if (d.error) return { text: "出錯了", level: "bad", why: d.error };
  if (d.here?.user) return { text: `${d.here.user} 唯讀`, level: "dim" };
  const names = { rule: new Set(), skill: new Set(), mcp: new Set() };
  for (const i of d.items ?? []) if ((i.status === "used" || i.status === "required") && names[i.kind]) names[i.kind].add(i.name);
  for (const i of d.here?.items ?? []) names[i.kind]?.add(`${i.scope}:${i.path ?? i.name}`);
  const ag = d.here?.agent;
  if (ag) for (const [k, key] of [["rule", "rules"], ["skill", "skills"], ["mcp", "mcp"]]) for (const n of ag[key] ?? []) names[k].add(n);
  const news = (d.items ?? []).filter((i) => i.new && i.kind !== "agent").length;
  const counts = [["規則", names.rule.size], ["skill", names.skill.size], ["MCP", names.mcp.size]];
  return { text: counts.map(([l, n]) => `${l} ${n}`).join(" · "), level: news ? "new" : "ok", news, counts, agent: ag?.name ?? null };
}


// ---- what the context window runs, sends and says (nothing from Herdr in here: tests/run.sh runs it with node) ----
const TOOLS = { "claude-code": "claude", claude: "claude", codex: "codex", omp: "omp", pi: "omp" };
// which tool an agent pane runs: what the agent reported (claude-code, codex, pi), else the program table's key
function toolOf(app, key) { return TOOLS[String(app ?? "").toLowerCase()] ?? TOOLS[String(key ?? "").toLowerCase()] ?? null; }
// kit context's arguments: --detail for the window (where the tokens go), --fresh for its ⟳
function ctxArgs(pid, tool, cwd, detail = false, fresh = false) {
  const a = ["context", "--pid", String(pid)];
  if (tool) a.push("--tool", tool);
  if (cwd) a.push("--dir", cwd);
  if (detail) a.push("--detail");
  if (detail && fresh) a.push("--fresh");
  return a;
}
// the line typed into the agent: its tool's own command (kit context --detail names it); what to keep goes after
// /compact only where the tool takes it, on one line
function sendText(cmds, what, keep) {
  const c = cmds ?? {};
  if (what === "clear") return c.clear ? String(c.clear) : null;
  if (what !== "compact" || !c.compact) return null;
  const k = String(keep ?? "").replace(/\s+/g, " ").trim();
  return k && c.with_text ? `${c.compact} ${k}` : String(c.compact);
}
// hc send, only to an agent that waits for you: idle (--if idle: hc refuses if it started working meanwhile) or done
// (it finished while nobody looked; hc's --if knows only idle and working). Never while it works or needs you.
function sendArgs(addr, status, text) {
  if (!addr || !text) return null;
  if (status === "idle") return ["send", "--if", "idle", addr, text];
  if (status === "done") return ["send", addr, text];
  return null;
}
// what kit can take off for a line of the window (kit list --json of that agent), the Kit popup's rule: an agent in a
// folder only changes that folder (kit rm --dir), one in the home folder the account; a required one never.
// -> { args, kind, name, where, dir } | { required: true, ... } | null
function removal(list, group, name, path) {
  const kind = group === "skills" ? "skill" : group === "mcp" ? "mcp" : group === "memory" || group === "instructions" ? "rule" : null;
  if (!kind || !list || list.error || list.here?.user) return null;
  const norm = (p) => String(p ?? "").replace(/\\/g, "/");
  const n = kind === "mcp" ? String(name ?? "").replace(/^mcp__/, "") : String(name ?? "");
  const it = (list.items ?? []).find((i) => i.kind === kind && (kind === "rule" ? Boolean(path) && norm(i.path) === norm(path) : i.name === n));
  if (!it) return null;
  const f = list.here?.folder, inDir = (f?.items ?? []).includes(`${kind}:${it.name}`);
  if (it.status === "required") return { required: true, kind, name: it.name };
  if (f && !f.why) return inDir ? { args: ["rm", "--dir", f.dir, kind, it.name], kind, name: it.name, where: "folder", dir: f.dir } : null;
  if (it.status === "used") return { args: ["rm", kind, it.name], kind, name: it.name, where: "account" };
  return null;
}
const num = (n) => String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
const kfmt = (n) => {
  const v = Number(n) || 0;
  if (v >= 1000000) return `${(v / 1000000).toFixed(2).replace(/\.?0+$/, "")}M`;
  return v >= 1000 ? `${(v / 1000).toFixed(v >= 100000 ? 0 : 1)}k` : String(Math.round(v));
};
// 怎麼省: only what the numbers show. canRemove(group, name): kit can take it off here
function ctxTips(d, canRemove = (_group, _name) => false) {
  const tips = [], used = Number(d?.used) || 0, win = Number(d?.window) || 0, c = d?.commands ?? {};
  if (!used) return tips;
  const cat = (id) => Number((d.categories ?? []).find((x) => x.id === id)?.tokens) || 0;
  const items = (id) => ((d.groups ?? []).find((g) => g.id === id)?.items ?? []).filter((i) => i.tokens != null).sort((a, b) => b.tokens - a.tokens);
  const share = (n) => `${Math.round((n / used) * 100)}%`;
  const at = Number(d.compact_at) || 0;
  if ((at && used >= at * 0.8) || (win && used >= win * 0.7))
    tips.push(`快滿了${at ? `（到 ${kfmt(at)} 會自動壓縮）` : ""}：告一段落時按下面的「壓縮」${c.with_text ? "（可以寫要保留什麼）" : ""}；要換別的事做，就「清空重來」。`);
  const tool = items("tool_results")[0];
  if (tool && tool.tokens >= 5000 && tool.tokens >= used * 0.2)
    tips.push(`「${tool.name}」的呼叫和結果約 ${kfmt(tool.tokens)}（${share(tool.tokens)}）：請它只拿需要的部分（只讀需要的行、先搜尋再讀、輸出很長時只看頭尾），或這段做完就壓縮。`);
  const att = items("attachments")[0];
  if (att && att.tokens >= 3000 && att.tokens >= used * 0.1)
    tips.push(`附加內容「${att.name}」約 ${kfmt(att.tokens)}（${share(att.tokens)}）：這是 Claude Code 自己加進對話的（例如 hook 的輸出、提到的檔案）。`);
  const mcp = cat("mcp_tools");
  if (mcp >= 5000 && mcp >= used * 0.05) {
    const mine = items("mcp").filter((i) => canRemove("mcp", i.name)).map((i) => i.name);
    tips.push(`MCP 工具的說明佔了 ${kfmt(mcp)}（${share(mcp)}）：${mine.length ? `用不到的（${mine.join("、")}）可以在下面「MCP」拿掉` : "用不到的 MCP 伺服器可以關掉"}，開新的對話就省下來。`);
  }
  const sk = cat("skills");
  if (sk >= 3000 && sk >= used * 0.03) {
    const mine = items("skills").filter((i) => canRemove("skills", i.name)).slice(0, 5).map((i) => i.name);
    tips.push(`Skills 的清單佔了 ${kfmt(sk)}（${share(sk)}）：${mine.length ? `用不到的（例如 ${mine.join("、")}）可以在下面拿掉` : "用不到的 skill 可以拿掉"}。`);
  }
  const mem = [...items("memory"), ...items("instructions")].sort((a, b) => b.tokens - a.tokens)[0];
  if (mem && mem.tokens >= 2000)
    tips.push(`${mem.name} 有 ${kfmt(mem.tokens)}，每次對話都整份讀進來：不常用的內容可以搬到 skill（用到才讀）。`);
  const other = cat("other");
  if (d.tool === "claude" && other >= 5000 && other >= used * 0.2)
    tips.push(`有 ${kfmt(other)} 這次分不出細項（剛剛才加進來的，或這個 session 之後才連上的 MCP）：等一下按 ⟳ 再看。`);
  return tips;
}
// the 複製 text: the numbers as the window shows them
function summaryText(d, title, where) {
  if (!d) return "";
  const w = Number(d.window) || 0, pc = (n) => (w ? `（${((n / w) * 100).toFixed(1)}%）` : "");
  const lines = [`${title || "agent"} 的 context${where ? ` · ${where}` : ""}`,
    `已使用 ${d.pct ?? "?"}% · ${num(d.used)} / ${d.window != null ? num(d.window) : "?"} tokens${d.model ? ` · ${d.model}` : ""}${d.exact ? "" : "（細項是估算）"}`];
  for (const c of d.categories ?? []) lines.push(c.kind === "deferred" ? `  ${c.name}：用到才載入（${num(c.tokens)}）` : `  ${c.name}：${c.est ? "≈" : ""}${num(c.tokens)}${pc(c.tokens)}`);
  for (const g of d.groups ?? []) {
    const it = g.items ?? [];
    lines.push(`${g.name}${g.tokens != null ? `：${g.est ? "≈" : ""}${num(g.tokens)}` : ""}`);
    for (const i of it.slice(0, 20)) lines.push(`  ${i.name}${i.tokens != null ? `：${num(i.tokens)}` : ""}${i.note ? `（${i.note}）` : ""}`);
    if (it.length > 20) lines.push(`  …還有 ${it.length - 20} 個`);
  }
  if (d.compact_at) lines.push(`距自動壓縮還有 ${num(Math.max(0, d.compact_at - (d.used ?? 0)))}`);
  return lines.join("\n");
}
// ---- end ----

// how full an agent's context is: kit context on the agent's machine, for its foreground process.
// { numbers }, or { unsupported: true } (a kit without kit context), or null (this ask failed)
async function agentPid(term) {
  const g = term ? await hc(["get", term, "--json"]).catch(() => null) : null;
  try { const j = JSON.parse(g?.stdout ?? "{}"); return j.foreground?.pid ?? j.pid ?? null; } catch { return null; }
}
async function loadContext(machine, cwd, term, tool) {
  const pid = await agentPid(term);
  if (!pid) return null;
  const r = await runKit(machine, ctxArgs(pid, tool, cwd));
  if (r.code > 0 && /沒有這個指令/.test(r.err)) return { unsupported: true };
  if (r.code !== 0) return null;
  try { const d = JSON.parse(r.out); return d && typeof d === "object" ? d : null; } catch { return null; }
}
const kNum = (n) => (n >= 1000000 ? `${+(n / 1000000).toFixed(n % 1000000 ? 1 : 0)}M` : `${Math.round(n / 1000)}k`);
// a category's color in the bar and its dot
function catColor(t, id) {
  return ({ system_prompt: t.ansi4, system_tools: t.ansi6, mcp_tools: t.ansi2, mcp_instructions: t.ansi2, memory_files: t.ansi3,
    instructions: t.ansi3, skills: t.ansi5, custom_agents: t.ansi1, slash_commands: t.ansi1, messages: t.accent, compaction: t.done,
    other: t.dim })[id] ?? t.dim;
}
const ago = (at) => { const s = Math.max(0, Math.round(Date.now() / 1000 - Number(at || 0))); return s < 60 ? `${s} 秒前` : `${Math.round(s / 60)} 分鐘前`; };

export default class KitPane extends View {
  init(_p, cx) {
    if (props()?.role === "context") return this.initContext(cx);
    this.hovered = false;
    // leftovers of older panels
    for (const k of ["kit.data.v1", "kit.target"]) if (shared(k) != null) setShared(k, null);
    cx.timer.every(1500, (cx) => this.tick(cx));
    this.tick(cx);
  }

  async close(_cx) {
    if (this.role !== "context") return;
    this.endBusy();
    this.keep?.release();
    this.keep = null;
  }

  me() { return panes().find((p) => p.pane === props()?.pane); }

  // ask kit when there is no answer, it is a minute old, or someone asked for a fresh one; one ask at a time per agent
  tick(cx) {
    const p = this.me();
    if (!p?.terminal || !p.program?.agent) return;
    this.tickContext(p, cx);
    const w = placeOf(p), c = (shared(CACHE) ?? {})[w.key], want = (shared(WANT) ?? {})[w.key] ?? 0;
    if (c?.busy && Date.now() - (c.started ?? 0) < LOAD_TTL) return;
    if (c && !c.busy && Date.now() - c.at < STALE && (c.started ?? 0) >= want) return;
    const started = Date.now();
    setShared(CACHE, { ...pruned(shared(CACHE)), [w.key]: { ...summary(null), ...(c ?? {}), busy: true, started } });
    cx.spawn(async (cx) => {
      let d;
      try { d = await loadAgent(w.machine, p.cwd, p.terminal); }
      catch (e) { d = { error: String(e?.message ?? e), machine: w.machine, at: Date.now() }; }
      setShared(DATA, { ...pruned(shared(DATA)), [w.key]: d });
      setShared(CACHE, { ...pruned(shared(CACHE)), [w.key]: { ...summary(d), started, at: Date.now(), busy: false } });
      cx.notify();
    });
  }

  // ask how full the context is: every 15 s while the agent works (and once when it stops), else every minute;
  // a kit without kit context only every 10 minutes
  tickContext(p, cx) {
    const w = placeOf(p), all = shared(CTX) ?? {}, c = all[w.key];
    if (c?.busy && Date.now() - (c.started ?? 0) < LOAD_TTL) return;
    const age = Date.now() - (c?.at ?? 0), moved = c && c.status !== p.status;
    if (c?.unsupported && age < CTX_OLD_KIT) return;
    if (c && !c.unsupported && !moved && age < (p.status === "working" ? CTX_STALE : CTX_IDLE)) return;
    const started = Date.now();
    setShared(CTX, { ...pruned(all), [w.key]: { ...(c ?? {}), busy: true, started, status: p.status } });
    cx.spawn(async (cx) => {
      let d = null;
      try { d = await loadContext(w.machine, p.cwd, p.terminal, toolOf(p.app, p.program?.key)); } catch {}
      // a failed ask (no answer, kit busy, the machine away) keeps the numbers it had: only when it asked changes
      const before = (shared(CTX) ?? {})[w.key] ?? c ?? {};
      const now = d?.unsupported ? { unsupported: true } : d ? { ...d, unsupported: false } : { ...before };
      setShared(CTX, { ...pruned(shared(CTX)), [w.key]: { ...now, busy: false, started, at: Date.now(), status: p.status } });
      cx.notify();
    });
  }

  // [context 35% 139k/400k]: like the Kit chip, one width whatever it says (the header never moves); yellow from
  // 70 %, red from 90 %; a click opens where the tokens go, a right-click copies the numbers
  contextChip(t, p) {
    const c = (shared(CTX) ?? {})[placeOf(p).key];
    const has = c && (c.pct != null || c.used != null);
    const pct = has && c.pct != null ? Math.min(100, c.pct) : null;
    const color = pct == null ? t.dim : pct >= 90 ? t.blocked : pct >= 70 ? t.working : t.foreground;
    const nums = has ? (c.window ? `${kNum(c.used ?? 0)}/${kNum(c.window)}` : kNum(c.used ?? 0)) : !c || c.busy ? "…" : "—";
    const chip = h_flex().id(`kit-ctx-${p.pane}`).flex_none().w(CHIP_W).h(22).pl(2).pr(6).gap(5).items_center().rounded(6)
      .bg(t.surface).border_1().border_color(pct != null && pct >= 90 ? t.blocked : t.border).text_size(11).cursor_pointer()
      .hover((st) => st.bg(t.hover).border_color(t.accent))
      .on_mouse_down("left", stop)
      .on_click((_e, cx) => { cx.stop_propagation(); this.openContext(p); }).tooltip("context 用了多少，按一下看細項")
      .child(div().h(16).px(5).flex().flex_none().items_center().rounded(4).bg(t.raised).font_semibold().text_color(t.foreground).child("context"))
      .when(pct != null, (el) => el.child(div().flex_none().font_semibold().text_color(color).child(`${pct}%`)))
      .child(div().min_w(0).truncate().text_color(t.dim).child(nums));
    return has ? copyOnRight(chip, `${pct != null ? `${pct}% ` : ""}${c.used ?? ""}${c.window ? ` / ${c.window}` : ""}`) : chip;
  }

  openContext(p) {
    const w = placeOf(p);
    const target = { key: w.key, pane: p.pane, term: p.terminal, machine: w.machine, cwd: p.cwd ?? null, tool: toolOf(p.app, p.program?.key),
      title: ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || "", program: p.program ?? null };
    openOverlay({ mod: "kit-pane", props: { role: "context", target }, kind: "popup", width: CTX_W, height: CTX_H });
  }

  // split / zoom / close: always laid out (so nothing moves), seen and clickable only while the header is hovered
  button(t, id, name, command, args, live) {
    const b = div().id(id).flex_none().p(3).rounded(4).text_color(t.dim).child(svg(`mods/pane/${name}.svg`).size(14));
    if (!live) return b.invisible();
    return b.hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => { cx.stop_propagation(); run(command, args); });
  }

  kitButton(t, p) {
    const w = placeOf(p), c = (shared(CACHE) ?? {})[w.key];
    const s = c?.text ? c : summary(null);
    const color = s.level === "bad" ? t.blocked : t.dim;
    // [kit | 規則 1  skill 3  MCP 1]: the word kit says what it is, the numbers stand out from their labels
    const body = s.counts
      ? s.counts.map(([label, n]) => h_flex().gap(3).items_center()
        .child(div().text_color(t.dim).child(label))
        .child(div().font_semibold().text_color(n ? t.foreground : t.dim).child(String(n))))
      : [div().text_color(color).child(s.text)];
    return h_flex().id(`kit-btn-${p.pane}`).flex_none().h(22).pl(2).pr(8).gap(7).items_center().rounded(6)
      .bg(t.surface).border_1().border_color(s.level === "bad" ? t.blocked : t.border).text_size(11)
      .hover((st) => st.bg(t.hover).border_color(t.accent))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => {
        cx.stop_propagation();
        const target = { key: w.key, term: p.terminal, machine: w.machine, space: w.space, cwd: p.cwd ?? null,
          title: ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || "", program: p.program ?? null };
        openOverlay({ mod: "kit", props: { role: "pane", target }, kind: "popup", width: 440, height: 560 });
      })
      .child(div().h(16).px(5).flex().items_center().rounded(4).bg(t.raised).font_semibold().text_color(t.foreground).child("Kit"))
      .when(Boolean(s.agent), (el) => el.child(div().text_color(t.accent).child(s.agent)))
      .children(body)
      .when(Boolean(s.news), (el) => el.child(div().px(4).rounded(4).bg(t.done).text_color(t.background).child(`${s.news} 新`)));
  }

  render(cx) {
    if (this.role === "context") return this.renderContext(cx);
    const t = theme(), p = this.me();
    if (!p) return div();
    const name = ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || p.program?.name || "shell";
    const pic = icon(p.program, 14, t.dim), st = p.status, pane = p.pane, agent = Boolean(p.terminal && p.program?.agent), live = this.hovered;
    // the status in a small box of one width (a red "!" for Needs you, a dot when done, else nothing): the header never moves
    const status = div().flex_none().w(16).h(22).flex().items_center().justify_center()
      .when(st === "blocked", (el) => el.child(div().flex_none().size(14).flex().items_center().justify_center().rounded(7).bg(t.blocked)
        .text_size(10).font_bold().text_color(t.background).tooltip("Needs you：在等你回答").child("!")))
      .when(st === "done", (el) => el.child(div().size(7).flex_none().rounded(4).bg(t.done)));
    return h_flex().id(`kit-pane-head-${pane}`).size_full().px(10).gap(8).items_center()
      .bg(t.background).border_b(1).border_color(t.border).text_size(12)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(div().flex_none().truncate().max_w(260).font_medium().text_color(t.foreground).child(name))
      .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(folder(p.cwd)))
      .when(agent, (el) => el.child(this.kitButton(t, p)).child(this.contextChip(t, p)))
      .child(status)
      .child(h_flex().flex_none().gap(2).items_center()
        .child(this.button(t, `kph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }, live))
        .child(this.button(t, `kph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }, live))
        .child(this.button(t, `kph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }, live))
        .child(this.button(t, `kph-x-${pane}`, "close", "pane.close", { pane }, live)));
  }

  // ---------- the context popup (role "context") ----------
  initContext(cx) {
    this.role = "context";
    this.target = props()?.target ?? {};
    this.d = null;          // kit context --detail's answer
    this.err = null;        // why the last ask failed (an older answer stays)
    this.loading = false;
    this.open = { msgs: true };   // which lists are open (group id, "group|name")
    this.more = {};         // lists shown in full
    this.ask = null;        // what waits for 確定: "compact", "clear", "clear2", "rm:<group>|<name>"
    this.msg = null;        // { ok, text } after a button
    this.sending = false;
    this.mine = false;      // this window holds kit.busy
    this.keep = InputState.new({ placeholder: "壓縮時要保留什麼（可空白）" });
    this.keep.on("submit", (_e, cx) => this.send("compact", cx));
    this.loadDetail(false, cx);
    cx.timer.every(2000, (cx) => cx.notify());   // the agent's status (which buttons work) and "n 秒前"
  }

  paneNow() { return panes().find((p) => p.pane === this.target.pane) ?? null; }
  agentNow() { try { return (agents() ?? []).find((a) => a.pane === this.target.pane) ?? null; } catch { return null; } }
  statusNow() { return this.agentNow()?.status ?? this.paneNow()?.status ?? null; }
  addrNow() { return this.agentNow()?.address ?? this.paneNow()?.terminal ?? this.target.term ?? null; }
  kitList() { return (shared(DATA) ?? {})[this.target.key] ?? null; }
  get busy() { const b = shared(BUSY); return b && typeof b === "object" && Date.now() - (b.at ?? 0) < (b.ttl ?? 0) ? b.label : null; }
  startBusy(label, ttl) {
    if (this.busy) return false;
    const id = `${Date.now()}-${Math.random()}`;
    setShared(BUSY, { label, at: Date.now(), ttl, id });
    this.mine = id;
    return true;
  }
  endBusy() { if (this.mine && shared(BUSY)?.id === this.mine) setShared(BUSY, null); this.mine = false; }

  loadDetail(fresh, cx) {
    if (this.loading) return;
    this.loading = true;
    this.err = null;
    const tg = this.target, seq = (this.seq = (this.seq ?? 0) + 1);
    cx.spawn(async (cx) => {
      let d = null, err = null;
      try {
        const p = this.paneNow(), pid = await agentPid(p?.terminal ?? tg.term);
        if (!pid) err = "找不到這個 agent 的程式（它可能已經關掉了）。";
        else {
          const r = await runKit(tg.machine ?? null, ctxArgs(pid, tg.tool, p?.cwd ?? tg.cwd, true, fresh));
          if (r.code !== 0) err = /沒有這個指令|用法|--detail/.test(r.err) ? `${tg.machine ?? "這台電腦"} 的 kit 太舊，沒有 context 細項：在那台打  kit self-update`
            : clean(r.err || r.out) || `kit context 失敗（${r.code}）`;
          else {
            try { d = JSON.parse(r.out); } catch { d = null; }
            if (!d || !Array.isArray(d.categories)) { d = null; err = "kit context --detail 的輸出讀不懂（kit 太舊？打 kit self-update）"; }
          }
        }
      } catch (e) { err = String(e?.message ?? e); }
      if (seq === this.seq) { if (d) this.d = d; this.err = err; this.loading = false; }
      cx.notify();
    });
  }

  // 壓縮 / 清空重來: the tool's own command, typed into this agent by hc send, only while it waits for you
  send(what, cx) {
    if (this.sending) return;
    const text = sendText(this.d?.commands, what, what === "compact" ? this.keep?.value() : "");
    const args = sendArgs(this.addrNow(), this.statusNow(), text);
    this.ask = null;
    if (!args) { this.msg = { ok: false, text: "沒送出：要等 agent 停下來（閒置或剛做完）才能送。" }; cx.notify(); return; }
    this.sending = true;
    this.msg = null;
    cx.notify();
    cx.spawn(async (cx) => {
      let err = null;
      try { const r = await hc(args); if (r?.code !== 0) err = String(r?.stderr || r?.stdout || `exit ${r?.code}`).trim().slice(0, 300); }
      catch (e) { err = String(e?.message ?? e); }
      this.sending = false;
      if (err) this.msg = { ok: false, text: `沒送出：${err}` };
      else {
        this.msg = { ok: true, text: what === "compact" ? `已送出 ${text}。壓縮要一點時間，好了按 ⟳ 再看。` : `已送出 ${text}：這段對話清掉了，按 ⟳ 再看。` };
        this.keep?.set_value("");
      }
      cx.notify();
    });
  }

  // 拿掉: kit rm (--dir for the folder's), as the Kit popup does; it counts from the agent's next conversation
  remove(rm, cx) {
    if (!rm?.args || !this.startBusy(`拿掉 ${rm.name}`, SHORT)) return;
    this.ask = null;
    this.msg = null;
    cx.notify();
    const tg = this.target, clear = this.d?.commands?.clear || "/clear";
    cx.spawn(async (cx) => {
      try {
        const r = await runKit(tg.machine ?? null, rm.args);
        const where = rm.where === "folder" ? ` ${folder(rm.dir)} ` : "整個帳號";
        this.msg = r.code === 0
          ? { ok: true, text: [`已從${where}拿掉 ${rm.name}。這個 agent 要清空重來（${clear}）或重開才不會再讀它。`, clean(r.err)].filter(Boolean).join("\n") }
          : { ok: false, text: `沒拿掉 ${rm.name}：${clean(r.err || r.out) || `失敗（${r.code}）`}` };
      } catch (e) {
        this.msg = { ok: false, text: `沒拿掉 ${rm.name}：${e?.message ?? e}` };
      } finally {
        this.endBusy();
        // every Kit button on that machine looks again (kit list), and the repository when it is this computer
        const m = tg.machine ?? "", now = Date.now(), want = { ...(shared(WANT) ?? {}) };
        for (const k of Object.keys(shared(CACHE) ?? {})) if (k.split("|")[0] === m) want[k] = now;
        setShared(WANT, want);
        const repo = shared(REPO);
        if (repo && !tg.machine) setShared(REPO, { ...repo, at: 0 });
        cx.notify();
      }
    });
  }

  // 開檔: a memory / instruction file in kit's editor window (this computer's files only)
  openFile(g, it, cx) {
    const path = it.path, open = (shared(EDITORS) ?? {})[path];
    if (open?.dirty && Date.now() - (open.at ?? 0) < 120000) {
      this.msg = { ok: false, text: "這個檔案已經開在大視窗裡，還沒存檔：先去那裡存檔或關掉。" };
      cx.notify();
      return;
    }
    const name = slash(path).split("/").pop() || path;
    openOverlay({ mod: "kit", kind: "window", key: `kit-editor:${path}`, width: 0.7, height: 0.85,
      props: { role: "editor", item: { path, name, kind: "file", plain: true, source: [g.name, it.note].filter(Boolean).join(" · "), rel: folder(path) } } });
  }

  copySummary(cx) {
    const tg = this.target, text = summaryText(this.d, tg.title, [tg.machine ?? "這台電腦", folder(tg.cwd)].filter(Boolean).join(" · "));
    if (!text) return;
    cx.write_to_clipboard(text);
    notify({ title: "已複製", body: "context 的細項", level: "success", timeout: 1500 });
  }

  btn(t, z, id, label, { kind, on, off, small } = {}) {
    const bg = off ? t.raised : kind === "primary" ? t.solid : kind === "danger" ? t.ansi1 : t.raised;
    const fg = off ? t.dim : kind === "primary" ? t.solid_foreground : kind === "danger" ? t.background : t.foreground;
    return div().id(id).h(small ? 22 : 28).px(small ? 8 : 12).flex().flex_none().items_center().justify_center().rounded(6)
      .text_size(small ? z - 2 : z - 1).font_semibold().bg(bg).text_color(fg)
      .when(!off, (el) => el.cursor_pointer().hover((st) => st.opacity(0.85)).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); on?.(cx); }))
      .child(label);
  }

  renderContext(_cx) {
    const t = theme(), z = fs(), d = this.d, p = this.paneNow();
    const root = v_flex().id("ctx-root").size_full().h(CTX_H).rounded(8).bg(t.surface).text_size(z).text_color(t.foreground)
      .child(this.ctxHeader(t, z));
    if (this.msg) root.child(this.ctxMessage(t, z));
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(12).py(10).gap(10);
    if (!p) body.child(div().text_color(t.dim).child("這個 agent 已經關掉了。"));
    if (this.err) body.child(v_flex().p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked)
      .child(textBlock("ctx-err", d ? `沒更新到（下面是上一次的）：${this.err}` : this.err)));
    if (!d) {
      if (!this.err) body.child(waiting(t, z, this.target.tool === "claude" ? "正在問 Claude Code（最多 30 秒）…" : "讀取中…"));
      return root.child(body);
    }
    body.child(this.ctxTop(t, z, d));
    if (d.error) body.child(v_flex().p(8).rounded(6).bg(t.raised).text_size(z - 1.5).text_color(t.working)
      .child(textBlock("ctx-derr", d.categories?.length ? `${d.error}\n所以下面是估算的。` : d.error)));
    if (d.categories?.length) body.child(this.ctxBar(t, d)).child(this.ctxCats(t, z, d));
    const list = this.kitList(), can = (g, name) => Boolean(removal(list, g, name)?.args);
    const tips = ctxTips(d, can);
    if (tips.length) body.child(v_flex().gap(4).p(8).rounded(6).bg(t.raised)
      .child(div().font_semibold().child("怎麼省"))
      .children(tips.map((x, i) => h_flex().gap(6).items_start().text_size(z - 1.5)
        .child(div().flex_none().text_color(t.dim).child("•"))
        .child(div().flex_1().min_w(0).child(textBlock(`ctx-tip-${i}`, x))))));
    for (const g of d.groups ?? []) body.child(this.ctxGroup(t, z, g, list));
    if (d.note) body.child(div().text_size(z - 2.5).text_color(t.dim).child(textBlock("ctx-note", `${d.note}${d.exact ? "" : "\n≈ 是估算的數字。"}`)));
    return root.child(body).child(this.ctxFooter(t, z, d));
  }

  ctxHeader(t, z) {
    const tg = this.target, pic = icon(tg.program, 18, t.foreground);
    const where = [tg.machine ?? "這台電腦", folder(tg.cwd)].filter(Boolean).join(" · ");
    return h_flex().flex_none().px(10).py(8).gap(6).items_center().border_b(1).border_color(t.border)
      .child(div().size(32).flex_none().rounded(16).bg(t.raised).flex().items_center().justify_center().child(pic ?? div().text_color(t.dim).child("•")))
      .child(v_flex().flex_1().min_w(0)
        .child(copyOnRight(div().truncate().font_semibold().child(`${tg.title || "agent"} 的 context`), tg.title || "agent"))
        .child(copyOnRight(div().truncate().text_size(z - 1.5).text_color(t.dim).child(where), tg.cwd ?? where)))
      .child(this.btn(t, z, "ctx-copy", "複製", { small: true, off: !this.d, on: (cx) => this.copySummary(cx) }))
      .child(this.btn(t, z, "ctx-reload", this.loading ? spin(z - 2, t.dim) : "⟳", { small: true, off: this.loading, on: (cx) => this.loadDetail(true, cx) }))
      .child(this.btn(t, z, "ctx-close", "✕", { small: true, on: () => closeOverlay(props()?.overlay) }));
  }

  ctxMessage(t, z) {
    const m = this.msg;
    return h_flex().flex_none().mx(10).mt(8).p(8).gap(8).items_start().rounded(6).bg(t.raised).border_1().border_color(m.ok ? t.border : t.blocked)
      .child(div().flex_1().min_w(0).text_size(z - 1).text_color(m.ok ? t.foreground : t.blocked).child(textBlock("ctx-msg", m.text)))
      .child(div().id("ctx-msg-x").flex_none().px(4).cursor_pointer().text_color(t.dim).hover((s) => s.text_color(t.foreground))
        .on_mouse_down("left", stop).on_click((_e, cx) => { this.msg = null; cx.notify(); }).child("✕"));
  }

  // 已使用 61% · 243k / 400k, and whose count it is
  ctxTop(t, z, d) {
    const pct = d.pct == null ? null : Math.min(100, d.pct);
    const color = pct == null ? t.foreground : pct >= 90 ? t.blocked : pct >= 70 ? t.working : t.foreground;
    const how = d.exact ? (d.tool === "claude" ? "Claude Code 自己算的" : "精確") : d.tool === "codex" ? "總數是 Codex 記的，細項估算" : d.tool === "omp" ? "總數是 omp 記的，細項估算" : "估算";
    return v_flex().gap(2)
      .child(h_flex().gap(6).items_end()
        .child(div().text_color(t.dim).child("已使用"))
        .child(copyOnRight(div().text_size(z + 8).font_semibold().text_color(color).child(pct == null ? "—" : `${pct}%`), pct == null ? "" : `${pct}%`))
        .child(copyOnRight(div().pb(2).font_semibold().child(`· ${num(d.used)} / ${d.window != null ? num(d.window) : "?"}`), `${d.used ?? ""} / ${d.window ?? ""}`)))
      .child(div().text_size(z - 2).text_color(t.dim).child([d.model, how, d.at ? ago(d.at) : ""].filter(Boolean).join(" · ")));
  }

  // the stacked bar: what is used (by category), then what is free, Claude's auto-compact reserve at the end
  ctxBar(t, d) {
    const w = Number(d.window) || Number(d.used) || 1;
    const bar = h_flex().h(10).w_full().rounded(5).overflow_hidden().bg(t.raised);
    let left = 100;
    const seg = (c, color) => {
      const pc = Math.min(left, ((Number(c.tokens) || 0) / w) * 100);
      if (pc <= 0.05) return;
      left -= pc;
      bar.child(div().h(10).flex_none().w(`${+pc.toFixed(3)}%`).bg(color));
    };
    const cats = d.categories ?? [];
    for (const c of cats) if (c.kind === "used") seg(c, catColor(t, c.id));
    const buf = cats.find((c) => c.kind === "buffer");
    bar.child(div().flex_1());
    if (buf) seg(buf, t.border);
    return bar;
  }

  ctxCats(t, z, d) {
    const w = Number(d.window) || 0, list = v_flex().gap(3);
    for (const c of d.categories ?? []) {
      const deferred = c.kind === "deferred", free = c.kind === "free", buffer = c.kind === "buffer";
      const dot = div().size(9).flex_none().rounded(5);
      if (deferred) dot.border_1().border_color(t.dim);
      else if (free) dot.bg(t.raised).border_1().border_color(t.border);
      else dot.bg(buffer ? t.border : catColor(t, c.id));
      list.child(h_flex().gap(8).items_center().text_size(z - 1)
        .child(dot)
        .child(div().flex_1().min_w(0).truncate().text_color(deferred || free ? t.dim : t.foreground).child(deferred ? `${c.name} · 用到才載入（${kfmt(c.tokens)}）` : c.name))
        .child(copyOnRight(div().flex_none().w(70).text_right().text_color(deferred ? t.dim : t.foreground).child(deferred ? "—" : `${c.est ? "≈" : ""}${kfmt(c.tokens)}`), String(c.tokens)))
        .child(div().flex_none().w(48).text_right().text_color(t.dim).child(deferred || !w ? "—" : `${((c.tokens / w) * 100).toFixed(1)}%`)));
    }
    return list;
  }

  // one list (memory files, skills, MCP by server, what was said by kind and by tool, …): click to open; most first
  ctxGroup(t, z, g, list) {
    const items = g.items ?? [], open = Boolean(this.open[g.id]);
    const head = h_flex().id(`g-${g.id}`).gap(6).items_center().cursor_pointer().on_mouse_down("left", stop)
      .on_click((_e, cx) => { this.open[g.id] = !open; cx.notify(); })
      .child(div().w(12).text_color(t.dim).child(open ? "▾" : "▸"))
      .child(div().flex_1().min_w(0).truncate().font_semibold().child(`${g.name}（${items.length}）`))
      .child(div().flex_none().text_color(t.dim).child(g.tokens == null ? "" : `${g.est ? "≈" : ""}${kfmt(g.tokens)}`));
    if (!open) return head;
    const shown = this.more[g.id] ? items : items.slice(0, 40);
    const rows = v_flex().gap(1).pl(12).children(shown.map((it) => this.ctxItem(t, z, g, it, `${g.id}|${it.name}`, 0, list)));
    if (shown.length < items.length) rows.child(div().id(`more-${g.id}`).px(4).py(2).cursor_pointer().text_size(z - 1.5).text_color(t.accent)
      .on_mouse_down("left", stop).on_click((_e, cx) => { this.more[g.id] = true; cx.notify(); }).child(`還有 ${items.length - shown.length} 個…`));
    return v_flex().gap(4).child(head).child(rows);
  }

  ctxItem(t, z, g, it, key, depth, list) {
    const kids = it.items ?? [], open = Boolean(this.open[key]);
    const rm = depth === 0 ? removal(list, g.id, it.name, it.path) : null;
    const canOpen = depth === 0 && Boolean(it.path) && (g.id === "memory" || g.id === "instructions") && !this.target.machine;
    const asking = this.ask === `rm:${key}`, est = g.est ? "≈" : "";
    const row = h_flex().id(`it-${key}`).gap(6).items_center().px(4).py(2).rounded(4).hover((s) => s.bg(t.hover)).text_size(z - 1);
    if (kids.length) row.cursor_pointer().on_mouse_down("left", stop).on_click((_e, cx) => { this.open[key] = !open; cx.notify(); });
    row.child(div().w(10).flex_none().text_color(t.dim).child(kids.length ? (open ? "▾" : "▸") : ""))
      .child(v_flex().flex_1().min_w(0)
        .child(copyOnRight(div().truncate().child(it.name), it.path || it.name))
        .when(Boolean(it.note), (el) => el.child(copyOnRight(div().truncate().text_size(z - 2.5).text_color(t.dim).child(it.note), it.note))))
      .child(copyOnRight(div().flex_none().text_color(t.dim).child(it.tokens == null ? "" : `${est}${kfmt(it.tokens)}`), it.tokens == null ? "" : String(it.tokens)));
    if (canOpen) row.child(this.btn(t, z, `open-${key}`, "開檔", { small: true, on: (cx) => this.openFile(g, it, cx) }));
    if (rm?.required) row.child(div().flex_none().text_size(z - 2.5).text_color(t.dim).child("團隊必備"));
    else if (rm?.args && !asking) row.child(this.btn(t, z, `rm-${key}`, "拿掉", { small: true, off: Boolean(this.busy), on: (cx) => { this.ask = `rm:${key}`; cx.notify(); } }));
    const out = v_flex().gap(1).child(row);
    if (asking) out.child(v_flex().ml(16).p(6).gap(6).rounded(6).bg(t.raised).text_size(z - 1.5)
      .child(textBlock(`rm-ask-${key}`, rm.where === "folder" ? `從 ${folder(rm.dir)} 拿掉 ${rm.name}？（kit rm --dir）` : `從整個帳號拿掉 ${rm.name}？（kit rm：每個資料夾的 agent 都不會再有）`))
      .child(h_flex().gap(6)
        .child(this.btn(t, z, `rm-yes-${key}`, "確定拿掉", { small: true, kind: "danger", off: Boolean(this.busy), on: (cx) => this.remove(rm, cx) }))
        .child(this.btn(t, z, `rm-no-${key}`, "取消", { small: true, on: (cx) => { this.ask = null; cx.notify(); } }))));
    if (open && kids.length) out.child(v_flex().pl(14).gap(1).children(kids.map((k) => this.ctxItem(t, z, g, k, `${key}|${k.name}`, depth + 1, list))));
    return out;
  }

  // how far to the auto-compaction, and 壓縮 / 清空重來 (each asks first; only while the agent waits for you)
  ctxFooter(t, z, d) {
    const st = this.statusNow(), ready = (st === "idle" || st === "done") && !this.sending, c = d.commands ?? {};
    const used = Number(d.used) || 0, at = Number(d.compact_at) || 0;
    const left = at ? Math.max(0, at - used) : d.window ? Math.max(0, d.window - used) : null;
    const line = at ? `距自動壓縮還有 ${kfmt(left)}（到 ${kfmt(at)} 會自動壓縮）` : left != null ? `還有 ${kfmt(left)} 可用` : "";
    const foot = v_flex().flex_none().px(12).py(8).gap(6).border_t(1).border_color(t.border);
    if (line) foot.child(copyOnRight(div().text_size(z - 1).text_color(t.dim).child(line), String(left)));
    const why = this.sending ? "送出中…" : st === "working" ? "它在工作中：停下來才能按" : st === "blocked" ? "它在等你回答：先處理它" : !st ? "看不到它的狀態" : "";
    const cancel = this.btn(t, z, "ask-no", "取消", { small: true, on: (cx) => { this.ask = null; cx.notify(); } });
    if (this.ask === "compact") {
      foot.child(div().font_semibold().child("確定壓縮？"));
      if (c.with_text) foot.child(Input.new(this.keep).h(28).px(8).rounded(6).border_1().border_color(t.accent).bg(t.background).text_size(z - 1).text_color(t.foreground));
      else foot.child(div().text_size(z - 2).text_color(t.dim).child(`${c.compact} 在這裡不能帶文字，會照它自己的方式壓縮。`));
      return foot.child(h_flex().gap(6).items_center()
        .child(this.btn(t, z, "compact-yes", "確定壓縮", { small: true, kind: "primary", off: !ready, on: (cx) => this.send("compact", cx) }))
        .child(cancel).child(div().flex_1().text_size(z - 2).text_color(t.dim).child(why)));
    }
    if (this.ask === "clear" || this.ask === "clear2") {
      const second = this.ask === "clear2";
      foot.child(div().text_size(z - 1).text_color(t.ansi1).child(textBlock(`clear-ask-${second}`, second
        ? `再確認一次：會送出 ${c.clear}，這段對話就回不來了。`
        : "會清掉這段對話的內容，確定？")));
      return foot.child(h_flex().gap(6).items_center()
        .child(this.btn(t, z, "clear-yes", second ? "清空重來" : "確定", { small: true, kind: "danger", off: !ready,
          on: (cx) => { if (second) this.send("clear", cx); else { this.ask = "clear2"; cx.notify(); } } }))
        .child(cancel).child(div().flex_1().text_size(z - 2).text_color(t.dim).child(why)));
    }
    return foot.child(h_flex().gap(6).items_center()
      .child(this.btn(t, z, "compact", this.sending ? "送出中…" : "壓縮", { small: true, off: !ready || !c.compact,
        on: (cx) => { this.ask = "compact"; if (c.with_text) this.keep?.focus(); cx.notify(); } }))
      .child(this.btn(t, z, "clear", "清空重來", { small: true, kind: "danger", off: !ready || !c.clear, on: (cx) => { this.ask = "clear"; cx.notify(); } }))
      .child(div().flex_1().min_w(0).truncate().text_size(z - 2).text_color(t.dim)
        .child(why || (c.compact ? `會打 ${c.compact} 或 ${c.clear} 到這個 agent` : ""))));
  }
}
