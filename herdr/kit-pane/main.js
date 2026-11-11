// A pane's header with kit's button: what this agent uses (rules, skills, MCP), one click to see it.
// `kit herdr-panel install` puts it in the layout in place of Herdr's own pane header ("mod": "pane"),
// and `kit herdr-panel uninstall` puts Herdr's back. Like Herdr's header it shows the program's icon, the
// name, the folder and the agent's status, with split / zoom / close on hover. Props from the app: { pane, terminal }.
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
// kept in kit.ctx.v1 (key -> { used, window, pct, at, busy, started }), asked again every 15 s while it works.
import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, spaces, props, run, theme, home, exec, hc, shared, setShared, appHome, readTextFile, window, openOverlay } from "herdr";

const CACHE = "kit.pane.v1", DATA = "kit.pane.data.v1", WANT = "kit.pane.want", CTX = "kit.ctx.v1";
const CTX_STALE = 15000, CTX_IDLE = 60000;   // how often to ask how full the context is: working / not
const STALE = 60000, LOAD_TTL = 90000;   // look again after a minute; a load longer than this is taken as lost
const isWindows = () => window()?.platform === "windows";
const slash = (p) => String(p ?? "").replace(/\\/g, "/");
const clean = (s) => String(s).split("\n").map((l) => l.replace(/^kit[:：]\s?/, "")).join("\n").trim();

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

// how full an agent's context is: kit context on the agent's machine, for its foreground process
const TOOLS = { "claude-code": "claude", claude: "claude", codex: "codex", omp: "omp", pi: "omp" };
async function loadContext(machine, cwd, term, agent) {
  const g = await hc(["get", term, "--json"]).catch(() => null);
  let pid = null;
  try { const j = JSON.parse(g?.stdout ?? "{}"); pid = j.foreground?.pid ?? j.pid ?? null; } catch {}
  if (!pid) return null;
  const args = ["context", "--pid", String(pid)];
  const tool = TOOLS[String(agent ?? "").toLowerCase()];
  if (tool) args.push("--tool", tool);
  if (cwd) args.push("--dir", cwd);
  const r = await runKit(machine, args);
  if (r.code !== 0) return null;   // an older kit without kit context: show nothing
  try { return JSON.parse(r.out); } catch { return null; }
}
const kNum = (n) => (n >= 1000000 ? `${+(n / 1000000).toFixed(n % 1000000 ? 1 : 0)}M` : `${Math.round(n / 1000)}k`);

export default class KitPane extends View {
  init(_p, cx) {
    this.hovered = false;
    // leftovers of older panels
    for (const k of ["kit.data.v1", "kit.target"]) if (shared(k) != null) setShared(k, null);
    cx.timer.every(1500, (cx) => this.tick(cx));
    this.tick(cx);
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

  // ask how full the context is: every 15 s while the agent works (and once when it stops), else every minute
  tickContext(p, cx) {
    const w = placeOf(p), all = shared(CTX) ?? {}, c = all[w.key];
    if (c?.busy && Date.now() - (c.started ?? 0) < LOAD_TTL) return;
    const age = Date.now() - (c?.at ?? 0), moved = c && c.status !== p.status;
    if (c && !moved && age < (p.status === "working" ? CTX_STALE : CTX_IDLE)) return;
    const started = Date.now();
    setShared(CTX, { ...pruned(all), [w.key]: { ...(c ?? {}), busy: true, started, status: p.status } });
    cx.spawn(async (cx) => {
      let d = null;
      try { d = await loadContext(w.machine, p.cwd, p.terminal, p.program?.agent); } catch {}
      setShared(CTX, { ...pruned(shared(CTX)), [w.key]: { ...(d ?? {}), busy: false, started, at: Date.now(), status: p.status } });
      cx.notify();
    });
  }

  // [context 35% 139k/400k]: how much of the agent's context window is used; yellow from 70 %, red from 90 %
  contextBadge(t, p) {
    const c = (shared(CTX) ?? {})[placeOf(p).key];
    if (c?.pct == null && c?.used == null) return null;
    const pct = c.pct, color = pct == null ? t.dim : pct >= 90 ? t.blocked : pct >= 70 ? t.working : t.dim;
    return h_flex().id(`kit-ctx-${p.pane}`).flex_none().gap(4).items_center().text_size(11)
      .child(div().text_color(t.dim).child("context"))
      .when(pct != null, (el) => el.child(div().font_semibold().text_color(pct >= 70 ? color : t.foreground).child(`${pct}%`)))
      .child(div().text_color(t.dim).child(c.window ? `${kNum(c.used ?? 0)}/${kNum(c.window)}` : kNum(c.used ?? 0)));
  }

  button(t, id, name, command, args) {
    return div().id(id).p(3).rounded(4).text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => { cx.stop_propagation(); run(command, args); })
      .child(svg(`mods/pane/${name}.svg`).size(14));
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
    const t = theme(), p = this.me();
    if (!p) return div();
    const name = ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || p.program?.name || "shell";
    const pic = icon(p.program, 14, t.dim), st = p.status, pane = p.pane;
    return h_flex().id(`kit-pane-head-${pane}`).size_full().px(10).gap(8).items_center()
      .bg(t.background).border_b(1).border_color(t.border).text_size(12)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(div().flex_none().truncate().max_w(260).font_medium().text_color(t.foreground).child(name))
      .child(div().flex_1().truncate().text_color(t.dim).child(folder(p.cwd)))
      .when(Boolean(p.terminal && p.program?.agent), (el) => el.child(this.kitButton(t, p)))
      .when(Boolean(p.terminal && p.program?.agent && this.contextBadge(t, p)), (el) => el.child(this.contextBadge(t, p)))
      .when(st === "working", (el) => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
      .when(st === "blocked", (el) => el.child(div().flex_none().px(6).h(18).flex().items_center().rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).child("Needs you")))
      .when(st === "done", (el) => el.child(div().size(7).flex_none().rounded(4).bg(t.done)))
      .when(this.hovered, (el) => el
        .child(this.button(t, `kph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }))
        .child(this.button(t, `kph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }))
        .child(this.button(t, `kph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }))
        .child(this.button(t, `kph-x-${pane}`, "close", "pane.close", { pane })));
  }
}
