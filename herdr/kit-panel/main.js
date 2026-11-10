// kit panel for Herdr: the repository (倉庫) of what kit's sources have (rules, skills, MCP), per machine.
// It follows the agent (terminal) you clicked last: kit runs on that agent's machine, and the panel also lists
// what that agent reads from its folder (CLAUDE.md, .claude/rules, .claude/skills, .mcp.json) besides kit's.
// Installed by `kit herdr-panel install` into <Herdr home>/mods/kit, next to config.json (how to run kit
// on this computer) and mod.json. Everything goes through the kit command itself:
//   kit list --json --dir <folder> --pid <pid>   what there is, what is in use, what the folder adds
//   kit add|rm <kind> <name>
//   kit sync             update                                kit run <agent> --tool <tool>  (in a new tab)
// Roles (props.role): the panel (default), "toggle" (the tab-bar button that shows or hides "kit-panel") and
// "pane": a popup opened by the kit button in an agent's pane header (mod kit-pane) for that one agent (props.target).
import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { theme, settings, exec, hc, home, run, layout, shared, setShared, window, appHome, readTextFile, focused, terminals, spaces, closeOverlay, props as blockProps } from "herdr";

const TOGGLE = "kit-toggle", PANEL = "kit-panel";
const SHIPPED = ["main", "terminals", "win98"]; // Herdr's own layouts: read-only, so "放進上排" clones one first
const DATA = "kit.data.v2", BUSY = "kit.busy", MSG = "kit.msg", PANE_CACHE = "kit.pane.v1", PANE_DATA = "kit.pane.data.v1";
const TOGGLE_NODE = { id: TOGGLE, type: "block", content: { mod: "kit", props: { role: "toggle" } }, size: { px: 56 } };
const PANEL_NODE = { id: PANEL, type: "column", children: [{ id: "kit", type: "block", content: { mod: "kit" } }],
  size: { px: 420 }, min: 320, max: 800 };
const KINDS = [
  { kind: "rule", title: "Rules（規則）" },
  { kind: "skill", title: "Skills" },
  { kind: "mcp", title: "MCP" },
  { kind: "agent", title: "Agents" },
];
const POPUP_H = 560; // the "pane" popup (kit-pane opens it with this height too)
const TOOL_NAMES = { claude: "Claude", codex: "Codex", omp: "omp" };
const STATUS = { required: "團隊必備", used: "在用", unused: "沒用" };

const fs = () => Number(settings().ui_font_size) || 13;
const mono = () => settings().font_family || (window()?.platform === "windows" ? "Consolas" : "Menlo");
const stop = (_e, cx) => cx.stop_propagation();
const isWindows = () => window()?.platform === "windows";
function find(node, id) {
  if (node?.id === id) return node;
  for (const c of node?.children ?? []) { const f = find(c, id); if (f) return f; }
  return null;
}
function parentOf(node, test) {
  for (const c of node?.children ?? []) {
    if (test(c)) return node;
    const p = parentOf(c, test);
    if (p) return p;
  }
  return null;
}
// The layout with a tab-bar button + the panel beside the work area, the stray dock removed (like kit herdr-panel install).
function placed(root) {
  const strip = (n) => ({ ...n, children: n.children?.filter((c) => c.content?.mod !== "kit" && c.id !== PANEL).map(strip) });
  const tree = strip(JSON.parse(JSON.stringify(root)));
  const bar = parentOf(tree, (c) => c.content?.mod === "tabs");
  const body = parentOf(tree, (c) => c.content?.tab != null);
  if (!bar || !body) return null;
  bar.children.push(TOGGLE_NODE);
  body.children.push(PANEL_NODE);
  return tree;
}

// How to run kit here: config.json (written by kit herdr-panel install), else kit / kit.cmd on PATH.
async function kitConfig() {
  const home = appHome().replace(/\\/g, "/");
  const text = await readTextFile(`${home}/mods/kit/config.json`).catch(() => null);
  let c = {};
  try { c = text ? JSON.parse(text) : {}; } catch { c = {}; }
  const kit = Array.isArray(c.kit) && c.kit.length ? c.kit.map(String) : [isWindows() ? "kit.cmd" : "kit"];
  const env = c.env && typeof c.env === "object" ? Object.entries(c.env).map(([k, v]) => `${k}=${v}`) : [];
  // Windows has no env program: the variables are only for trying the panel on a Mac/Linux test setup.
  return env.length && !isWindows() ? ["/usr/bin/env", ...env, ...kit] : kit;
}
// On another machine (a space's machine): kit from PATH or ~/.local/bin (Mac/Linux), else kit.cmd (Windows).
const REMOTE_SH = ["sh", "-c", 'command -v kit >/dev/null 2>&1 && exec kit "$@"; exec "$HOME/.local/bin/kit" "$@"', "kit"];
async function kitArgv(machine) { return machine ? REMOTE_SH : kitConfig(); }
async function kit(args, timeout, machine = null) {
  const tries = machine ? [REMOTE_SH, ["kit.cmd"]] : [await kitConfig()];
  let last = "";
  for (const argv of tries) {
    try {
      const r = await exec(argv[0], [...argv.slice(1), ...args], { timeout, on: machine });
      return { code: r.code, out: String(r.stdout ?? ""), err: String(r.stderr ?? "") };
    } catch (e) { last = String(e?.message ?? e); }
  }
  return { code: -1, out: "", err: machine ? `連不到 ${machine}，或那台沒裝 kit：${last}` : `沒辦法執行 kit：${last}` };
}
// The terminal you clicked last (clicking this panel moves focus here, so keep the one before).
function currentTarget(prev) {
  const f = focused();
  if (!f?.terminal) return prev ?? { key: "local", term: null, machine: null, space: f?.space ?? null, cwd: null, title: "", agent: false };
  const t = terminals().find((x) => x.address === f.terminal) ?? {};
  const sp = spaces().find((s) => s.id === f.space);
  const machine = sp?.machine ?? null, cwd = f.cwd ?? t.cwd ?? null;
  return { key: `${machine ?? ""}|${cwd ?? ""}|${f.terminal}`, term: f.terminal, machine, space: f.space, cwd,
    title: t.title || t.name || t.program?.name || f.terminal, agent: Boolean(f.agent || t.program?.agent),
    program: t.program ?? null, status: t.status ?? null };
}
// the repository's view of a machine: no folder, no process (only what kit itself manages there)
const repoTarget = (machine) => ({ key: `repo|${machine ?? ""}`, term: null, machine, space: null, cwd: null, title: "", agent: false, program: null });
// the machines this window has spaces on (null: this computer)
const machinesHere = () => [null, ...new Set(spaces().map((s) => s.machine).filter(Boolean))];
// a folder with ~ for this computer's home (other machines' paths stay as they are)
const shortDir = (d) => { const h = String(home() ?? "").replace(/\\/g, "/"); return d && h && (d + "/").startsWith(h + "/") ? "~" + d.slice(h.length) : d; };
// kit's own messages, without the "kit: " / "kit：" in front of each line
const clean = (s) => String(s).split("\n").map((l) => l.replace(/^kit[:：]\s?/, "")).join("\n").trim();

// kit list --json for a target (an agent: its machine, folder and process), as the panel shows it
async function loadFor(tg) {
  const args = ["list", "--json"];
  if (tg.cwd) args.push("--dir", tg.cwd);
  if (tg.term) {
    const g = await hc(["get", tg.term, "--json"]).catch(() => null);
    try { const pid = JSON.parse(g?.stdout ?? "{}").pid; if (pid) args.push("--pid", String(pid)); } catch {}
  }
  let r = await kit(args, 60000, tg.machine), warn = null;
  // an older kit without --dir: ask again without it
  if (r.code !== 0 && /--dir|--pid|用法/.test(r.err)) r = await kit(["list", "--json"], 60000, tg.machine);
  if (r.code === -1 && tg.machine) { warn = clean(r.err); r = await kit(["list", "--json"], 60000, null); }
  if (r.code !== 0) return { error: clean(r.err || r.out) || `kit list 失敗（${r.code}）`, key: tg.key, at: Date.now() };
  try { return { ...JSON.parse(r.out), key: tg.key, warn, machine: warn ? null : tg.machine, at: Date.now() }; }
  catch { return { error: "kit list --json 的輸出讀不懂（kit 太舊？請打 kit self-update）", key: tg.key, at: Date.now() }; }
}
function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class KitPanel extends View {
  init(_p, cx) {
    const role = blockProps()?.role;
    this.role = role === "toggle" || role === "pane" ? role : "panel";
    this.filter = "";
    this.tool = this.load("tool") || "claude";
    this.folded = {};
    try { this.folded = JSON.parse(this.load("folded") || "{}"); } catch { this.folded = {}; }
    // Both the button and the panel keep the shared list fresh (a hidden panel may not have started yet);
    // the background sync Claude starts may change things, so look again every minute.
    if (this.role === "pane") {
      // one agent, the one whose header button was clicked: its own list, not the panel's shared one
      this.target = blockProps()?.target ?? currentTarget(null);
      this.refresh(cx);
      // until its list is there, look again (an overlay may not redraw on its own when shared changes)
      cx.timer.every(500, (cx) => { if (!this.data) cx.notify(); });
      return;
    }
    // the repository (倉庫): everything kit's sources have, for one machine's account (this computer unless picked)
    this.kind = this.load("kind") || "skill";
    this.open = null;   // the row showing its details
    if (this.role === "panel") {
      this.input = InputState.new({ placeholder: "找：名字、說明、來源" });
      this.input.on("change", (_e, cx) => { this.filter = this.input.value().trim().toLowerCase(); cx.notify(); });
    }
    this.target = repoTarget(this.load("machine") || null);
    const stale = () => !this.data || this.data.key !== this.target.key || Date.now() - (this.data.at ?? 0) > 50000;
    if (this.role === "panel" || stale()) this.refresh(cx);
    cx.timer.every(60000, (cx) => { if (stale() && !this.busy) this.refresh(cx); });
    // the toggle button follows the machine the panel picked
    if (this.role === "toggle") cx.timer.every(2000, (cx) => {
      const m = this.load("machine") || null;
      if (m !== this.target.machine) { this.target = repoTarget(m); cx.notify(); }
    });
  }

  pickMachine(m, cx) {
    this.save("machine", m ?? "");
    this.target = repoTarget(m);
    this.open = null;
    setShared(MSG, null);
    if (!this.busy) this.refresh(cx);
    cx.notify();
  }

  load(k) { try { return localStorage.getItem(`kit.${k}`); } catch { return null; } }
  save(k, v) { try { localStorage.setItem(`kit.${k}`, v); } catch {} }

  // the popup's list lives in shared too (per agent): it shows at once next time, and a stuck load can be seen from outside
  get data() { return this.role === "pane" ? (shared(PANE_DATA) ?? {})[this.target?.key] ?? null : shared(DATA) ?? null; }
  get busy() { return shared(BUSY) ?? null; }

  refresh(cx) {
    const tg = this.target ?? currentTarget(null);
    cx.spawn(async (cx) => {
      let d;
      try { d = await loadFor(tg); } catch (e) { d = { error: `讀不到：${e?.message ?? e}`, key: tg.key, at: Date.now() }; }
      if (this.role === "pane") setShared(PANE_DATA, { ...(shared(PANE_DATA) ?? {}), [tg.key]: d }); else setShared(DATA, d);
      cx.notify();
    });
  }


  // add / rm / sync: one at a time, the result (kit's own words) shown above the list
  act(label, args, cx) {
    if (this.busy) return;
    setShared(BUSY, label);
    setShared(MSG, null);
    cx.notify();
    cx.spawn(async (cx) => {
      const r = await kit(args, 600000, this.data?.machine ?? null);
      const text = clean([r.out, r.err].filter(Boolean).join("\n"));
      setShared(MSG, { ok: r.code === 0, label, text: text || (r.code === 0 ? "完成" : `失敗（${r.code}）`), at: Date.now() });
      setShared(BUSY, null);
      // the pane headers' counts are out of date now: they ask kit again on their next look
      const pc = shared(PANE_CACHE);
      if (pc) setShared(PANE_CACHE, Object.fromEntries(Object.entries(pc).map(([k, v]) => [k, { ...v, at: 0, busy: false }])));
      const sd = shared(DATA);
      if (this.role === "pane" && sd) setShared(DATA, { ...sd, at: 0 });
      this.refresh(cx);
      cx.notify();
    });
  }

  // kit run <agent> in a new tab of this space (kit syncs first, then starts the tool)
  openAgent(name, cx) {
    cx.spawn(async (cx) => {
      const machine = this.data?.machine ?? null;
      const argv = await kitArgv(machine);
      const tool = (this.data?.tools ?? ["claude"]).includes(this.tool) ? this.tool : "claude";
      const kitArgs = [...argv, "run", name, "--tool", tool];
      // kit.cmd is a batch file: start it through cmd so the terminal can run it
      const full = isWindows() && /\.(cmd|bat)$/i.test(argv[0]) ? ["cmd.exe", "/d", "/c", ...kitArgs] : kitArgs;
      try {
        await run("tab.new", { name: `${name}（${TOOL_NAMES[tool] ?? tool}）`, argv: full, ...(this.target?.space ? { space: this.target.space } : {}), ...(this.target?.cwd ? { folder: this.target.cwd } : {}) });
        setShared(MSG, { ok: true, label: "開啟", text: `在新分頁開了 ${name}（${TOOL_NAMES[tool] ?? tool}）`, at: Date.now() });
      } catch (e) {
        setShared(MSG, { ok: false, label: "開啟", text: `開不起來：${e?.message ?? e}`, at: Date.now() });
      }
      cx.notify();
    });
  }

  async moveIntoBar(cx) {
    this.moveErr = null;
    let name = shared("layout");
    if (SHIPPED.includes(name)) {
      // Herdr's own layout can't change shape: work on a copy of it (once; later moves reuse the copy).
      const as = `${name}-kit`;
      try { await run("layout.clone", { name, as }); } catch { await run("layout.switch", { name: as }); }
      await cx.sleep(800);
      name = shared("layout");
    }
    const tree = placed(layout());
    if (!tree) { this.moveErr = "這個版面沒有上排分頁列，沒辦法自動放。"; cx.notify(); return; }
    await run("layout.set", { layout: tree });
  }

  render(cx) {
    if (this.role === "toggle") return this.renderToggle();
    const t = theme(), z = fs();
    // a popup is as tall as its content, and the list (flex_1) has none of its own: give the popup a height
    const root = v_flex().id("kit-root").size_full().bg(t.surface).text_size(z).text_color(t.foreground)
      .when(this.role === "pane", (el) => el.h(POPUP_H).rounded(8));
    root.child(this.header(t, z));
    if (this.role === "panel" && !find(layout(), TOGGLE)) root.child(this.moveBanner(t, z));
    const d = this.data, msg = shared(MSG);
    if (msg) root.child(this.message(t, z, msg));
    if (!d) return root.child(div().p(14).text_color(t.muted).child("讀取中…"));
    if (d.error) return root.child(this.problem(t, z, d.error));
    if (d.warn) root.child(div().flex_none().mx(10).mt(8).p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked)
      .child(`${d.warn}\n先顯示這台電腦的。`));
    if (d.here?.user) return root.child(v_flex().p(14).gap(6)
      .child(div().font_semibold().child(`這個 agent 用 ${d.here.user} 帳號跑`))
      .child(div().text_size(z - 1).text_color(t.muted).child(d.here.user === "root"
        ? "root 只用你在 Mac 上簽過的版本，這裡看不到也不能改。要換版本：在 Mac 上 kit approve，再請它 kit sync。"
        : "這裡只看得到你自己帳號的 kit，看不到也不能改它的。")));
    if (d.kit_version_wanted) root.child(div().flex_none().mx(10).mt(8).p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked)
      .child(`團隊要 kit ${d.kit_version_wanted} 以上，你的是 ${d.kit}。請在終端機打  kit self-update`));
    return root.child(this.role === "panel" ? this.repo(t, z, d) : this.list(t, z, d));
  }

  // 倉庫: tabs per kind (+ the sources), a search, each thing with what it is, where from, and whether this account uses it
  repo(t, z, d) {
    const items = (d.items ?? []).filter((i) => i.kind !== "agent"), f = this.filter;
    const sources = d.sources ?? [];
    const tabs = [["rule", "規則"], ["skill", "Skills"], ["mcp", "MCP"], ["source", "來源"]];
    const count = (k) => k === "source" ? sources.length : items.filter((i) => i.kind === k).length;
    const newIn = (k) => items.filter((i) => i.kind === k && i.new).length;
    const kind = tabs.some(([k]) => k === this.kind) ? this.kind : "skill";
    const box = v_flex().flex_1().min_h(0);
    box.child(h_flex().flex_none().px(10).pt(8).gap(4).children(tabs.map(([k, label]) => {
      const on = k === kind, n = newIn(k);
      return h_flex().id(`tab-${k}`).h(28).px(10).gap(5).items_center().rounded(6).cursor_pointer()
        .bg(on ? t.selected : t.surface).text_color(on ? t.foreground : t.muted).font_semibold()
        .hover((st) => st.bg(t.hover)).on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.kind = k; this.save("kind", k); this.open = null; cx.notify(); })
        .child(label).child(div().text_size(z - 2).text_color(t.dim).child(String(count(k))))
        .when(n > 0, (el) => el.child(div().px(4).rounded(4).text_size(z - 3).bg(t.done).text_color(t.background).child(`${n} 新`)));
    })));
    box.child(div().flex_none().px(10).pt(8).child(Input.new(this.input).h(30).px(8).rounded(6).border_1().border_color(t.border)
      .bg(t.background).text_size(z - 1).text_color(t.foreground)));
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(2);
    const hit = (...xs) => !f || xs.some((x) => String(x ?? "").toLowerCase().includes(f));
    if (kind === "source") {
      body.child(div().pb(4).text_size(z - 1.5).text_color(t.muted).child("kit 從這些地方拿東西。按上面的 ⟳ 同步 會把每個來源更新成最新的。"));
      const rows = sources.filter((s) => hit(s.name, s.source));
      for (const s of rows) {
        const n = items.filter((i) => i.source === s.name).length;
        body.child(v_flex().id(`src-${s.name}`).px(8).py(6).gap(1).rounded(6).hover((st) => st.bg(t.hover))
          .child(h_flex().gap(6).items_center().child(div().font_semibold().child(s.name))
            .child(div().text_size(z - 2).text_color(t.dim).child(`${n} 樣`)))
          .child(div().truncate().text_size(z - 1.5).text_color(t.muted).font_family(mono()).child(shortDir(s.source))));
      }
      if (!rows.length) body.child(div().p(8).text_color(t.muted).child(sources.length ? "找不到符合的來源。" : "還沒有來源：在終端機打  kit init <團隊來源的網址>"));
      return box.child(body);
    }
    const rank = (i) => (i.new ? 0 : 3) + (i.status === "required" ? 0 : i.status === "used" ? 1 : 2);
    const rows = items.filter((i) => i.kind === kind && hit(i.name, i.description, i.source))
      .sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
    body.child(div().pb(4).text_size(z - 1.5).text_color(t.muted)
      .child(`「加上」＝${d.machine ?? "這台電腦"} 你這個帳號的每個 agent 都會有。只想給一個 agent 用，點它視窗上的 kit 按鈕。`));
    for (const i of rows) body.child(this.repoRow(t, z, i));
    if (!rows.length) body.child(div().p(8).text_color(t.muted).child(f ? "找不到符合的。" : "這一類還沒有東西。"));
    return box.child(body);
  }

  // a repository row: click it for the whole description and where it comes from
  repoRow(t, z, i) {
    const id = `${i.kind}:${i.name}`, opened = this.open === id;
    const row = this.row(t, z, i);
    return v_flex().id(`repo-${id}`).rounded(6).when(opened, (el) => el.bg(t.raised))
      .on_mouse_down("left", stop)
      .on_click((_e, cx) => { this.open = opened ? null : id; cx.notify(); })
      .child(row)
      .when(opened, (el) => el.child(v_flex().px(8).pb(8).gap(4).text_size(z - 1.5).text_color(t.muted)
        .when(Boolean(i.description), (e) => e.child(div().text_color(t.foreground).child(i.description)))
        .child(div().child(`來源：${i.source || "—"}　·　${STATUS[i.status] ?? i.status}${i.new ? "　·　剛加進來源" : ""}`))));
  }

  header(t, z) {
    if (this.role === "panel") return this.repoHeader(t, z);
    const d = this.data, busy = this.busy, tg = this.target ?? {};
    const inBar = Boolean(find(layout(), TOGGLE));
    const where = [d?.machine ?? tg.machine ?? "這台電腦", shortDir(d?.here?.dir ?? tg.cwd)].filter(Boolean).join(" · ");
    const pic = icon(tg.program, 18, t.foreground);
    return h_flex().flex_none().px(10).py(8).gap(8).items_center().border_b(1).border_color(t.border)
      .child(div().size(32).flex_none().rounded(16).bg(t.raised).flex().items_center().justify_center().child(pic ?? div().text_color(t.muted).child("•")))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().font_semibold().child(tg.title || "這台電腦"))
        .child(div().truncate().text_size(z - 1.5).text_color(t.muted).child(where)))
      .child(this.btn(t, z, "sync", busy === "同步" ? "同步中…" : "⟳ 同步", { small: true, off: Boolean(busy), on: (cx) => this.act("同步", ["sync"], cx) }))
      .when(this.role === "pane", (el) => el.child(this.btn(t, z, "close", "✕", { small: true, on: () => closeOverlay(blockProps()?.overlay) })))
      .when(this.role !== "pane" && inBar, (el) => el.child(this.btn(t, z, "hide", "✕", { small: true, on: () => run("layout.hide", { id: PANEL }) })));
  }

  repoHeader(t, z) {
    const d = this.data, busy = this.busy, inBar = Boolean(find(layout(), TOGGLE));
    const ms = machinesHere(), cur = this.target?.machine ?? null;
    const head = h_flex().px(10).py(8).gap(8).items_center()
      .child(div().size(32).flex_none().rounded(8).bg(t.raised).flex().items_center().justify_center().font_semibold().text_size(z - 1).child("kit"))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().font_semibold().child("倉庫"))
        .child(div().truncate().text_size(z - 1.5).text_color(t.muted)
          .child(d && !d.error ? `${(d.items ?? []).filter((i) => i.kind !== "agent").length} 樣 · ${(d.sources ?? []).length} 個來源` : "規則、skill、MCP 都在這裡")))
      .child(this.btn(t, z, "sync", busy === "同步" ? "同步中…" : "⟳ 同步", { small: true, off: Boolean(busy), on: (cx) => this.act("同步", ["sync"], cx) }))
      .when(inBar, (el) => el.child(this.btn(t, z, "hide", "✕", { small: true, on: () => run("layout.hide", { id: PANEL }) })));
    const v = v_flex().flex_none().border_b(1).border_color(t.border).child(head);
    if (ms.length > 1) v.child(h_flex().px(10).pb(8).gap(4).items_center()
      .child(div().text_size(z - 1.5).text_color(t.dim).child("哪台："))
      .children(ms.map((m) => div().id(`m-${m ?? "here"}`).px(8).py(2).rounded(5).text_size(z - 1.5).cursor_pointer()
        .bg(m === cur ? t.selected : t.raised).text_color(m === cur ? t.foreground : t.muted)
        .border_1().border_color(m === cur ? t.accent : t.raised)
        .on_mouse_down("left", stop).on_click((_e, cx) => this.pickMachine(m, cx))
        .child(m ?? "這台電腦"))));
    return v;
  }

  moveBanner(t, z) {
    return v_flex().flex_none().px(12).py(10).gap(6).bg(t.raised).border_b(1).border_color(t.border)
      .child(div().text_size(z - 1).text_color(t.muted).child(this.moveErr ?? "這個面板還在版面最外面。按下面的按鈕，會放進上排（一顆 kit 按鈕，按了開關面板）。"))
      .child(h_flex().child(this.btn(t, z, "move", "放進上排", { kind: "primary", on: (cx) => cx.spawn(async (cx) => this.moveIntoBar(cx)) })));
  }

  message(t, z, msg) {
    return h_flex().flex_none().mx(10).mt(8).p(8).gap(8).items_start().rounded(6).bg(t.raised)
      .border_1().border_color(msg.ok ? t.border : t.ansi1)
      .child(div().flex_1().min_w(0).text_size(z - 1).font_family(mono()).text_color(msg.ok ? t.foreground : t.ansi1)
        .child(`${msg.label}：${msg.ok ? "" : "失敗\n"}${msg.text}`))
      .child(div().id("msg-close").flex_none().px(4).cursor_pointer().text_color(t.muted).hover((s) => s.text_color(t.foreground))
        .on_mouse_down("left", stop).on_click((_e, cx) => { setShared(MSG, null); cx.notify(); }).child("✕"));
  }

  problem(t, z, text) {
    const notInit = /kit init/.test(text);
    return v_flex().p(14).gap(8)
      .child(div().font_semibold().text_color(t.ansi1).child("kit 出錯了"))
      .child(div().font_family(mono()).text_size(z - 1).child(text))
      .when(notInit, (el) => el.child(div().text_size(z - 1).text_color(t.muted)
        .child("第一次用要先在終端機打  kit init <團隊來源的網址>，好了再按 ↻。")));
  }

  list(t, z, d) {
    const items = d.items ?? [], tools = d.tools ?? ["claude"], here = d.here?.items ?? [];
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(8);
    const kindName = { rule: "規則", skill: "Skills", mcp: "MCP" };
    // 1. what this agent uses: kit's (can be taken off) and its folder's / this account's own (look only)
    body.child(div().font_semibold().child("這個 agent 在用的"));
    for (const kind of ["rule", "skill", "mcp"]) {
      const kitRows = items.filter((i) => i.kind === kind && (i.status === "used" || i.status === "required"));
      const ownRows = here.filter((i) => i.kind === kind);
      const n = kitRows.length + ownRows.length;
      const folded = this.folded[`use-${kind}`] ?? n > 8;
      body.child(this.secHead(t, z, `use-${kind}`, `${kindName[kind]}（${n}）`, folded, ""));
      if (folded) continue;
      if (!n) { body.child(div().pl(18).text_size(z - 1.5).text_color(t.dim).child("沒有")); continue; }
      body.child(v_flex().gap(2).children([...kitRows.map((i) => this.row(t, z, i)), ...ownRows.map((i) => this.hereRow(t, z, i))]));
    }
    if (d.here?.error) body.child(div().text_size(z - 1.5).text_color(t.muted).child(`${shortDir(d.here.dir)}：${d.here.error}`));
    // 2. what kit has that this agent does not use yet
    const more = items.filter((i) => i.kind !== "agent" && i.status === "unused");
    const news = more.filter((i) => i.new).length;
    if (more.length) {
      // the popup is about this one agent: what it could add is the point, so open it there
      const folded = this.role === "pane" ? (this.folded.paneMore ?? false) : (this.folded.more ?? true);
      body.child(div().mt(6).border_t(1).border_color(t.border));
      body.child(this.secHead(t, z, this.role === "pane" ? "paneMore" : "more", `可以加上的（${more.length}）`, folded, news ? `${news} 個新的` : ""));
      if (!folded) body.child(v_flex().gap(2)
        .child(div().pl(18).text_size(z - 1.5).text_color(t.muted).child(`加上後，${d.machine ?? "這台電腦"} 這個帳號的每個 agent 都會有。來源：${(d.sources ?? []).map((s) => s.name).join("、")}`))
        .children(more.map((i) => this.row(t, z, i))));
    }
    // kit's agents (hello, ping, …) are not here: they get their own Agent panel
    if (!items.length && !here.length) body.child(div().text_color(t.muted).child("來源裡還沒有東西。"));
    return body;
  }

  secHead(t, z, id, title, folded, note) {
    return h_flex().id(`sec-${id}`).gap(6).items_center().cursor_pointer().on_mouse_down("left", stop)
      .on_click((_e, cx) => { this.folded[id] = !folded; this.save("folded", JSON.stringify(this.folded)); cx.notify(); })
      .child(div().w(12).text_color(t.muted).child(folded ? "▸" : "▾"))
      .child(div().text_size(z - 0.5).child(title))
      .when(Boolean(note), (el) => el.child(div().px(5).rounded(4).text_size(z - 3).bg(t.done).text_color(t.background).child(note)));
  }

  hereRow(t, z, i) {
    const badge = (text) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(t.muted).child(text);
    const head = h_flex().gap(5).items_center().min_w(0)
      .child(div().min_w(0).truncate().font_semibold().child(shortDir(i.name)))
      .child(badge(i.scope === "user" ? "這個帳號" : "這個目錄"));
    if (i.tools && i.tools !== "claude") head.child(badge(i.tools === "codex omp" ? "Codex／omp" : i.tools));
    const sub = i.description || shortDir(i.path);
    return v_flex().id(`here-${i.scope}-${i.kind}-${i.path}-${i.name}`).px(8).py(4).gap(1).rounded(6).hover((s) => s.bg(t.hover))
      .child(head)
      .when(Boolean(sub), (el) => el.child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child(sub)));
  }

  toolPicker(t, z, tools) {
    const cur = tools.includes(this.tool) ? this.tool : "claude";
    return h_flex().gap(4).items_center().pl(18)
      .child(div().text_size(z - 1.5).text_color(t.muted).child("用"))
      .children(tools.map((tool) => div().id(`tool-${tool}`).px(8).py(2).rounded(5).text_size(z - 1.5).cursor_pointer()
        .bg(tool === cur ? t.selected : t.raised).text_color(tool === cur ? t.foreground : t.muted)
        .border_1().border_color(tool === cur ? t.accent : t.raised)
        .on_mouse_down("left", stop).on_click((_e, cx) => { this.tool = tool; this.save("tool", tool); cx.notify(); })
        .child(TOOL_NAMES[tool] ?? tool)))
      .child(div().text_size(z - 1.5).text_color(t.muted).child("開"));
  }

  row(t, z, i) {
    const busy = Boolean(this.busy);
    const badge = (text, color) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(color).child(text);
    const head = h_flex().gap(5).items_center().min_w(0)
      .child(div().min_w(0).truncate().font_semibold().text_color(i.status === "unused" ? t.muted : t.foreground).child(i.name));
    // in the popup "kit" tells kit's things from the folder's own; in the repository it is all kit's: say used or not
    const repo = this.role === "panel";
    if (i.status === "required") head.child(badge(repo ? "團隊必備" : "kit · 必備", t.accent));
    if (i.status === "used") head.child(badge(repo ? "在用" : "kit", t.working));
    if (i.new) head.child(badge("新", t.done));
    let action;
    if (i.kind === "agent") action = this.btn(t, z, `run-${i.name}`, "開啟", { small: true, on: (cx) => this.openAgent(i.name, cx) });
    else if (i.status === "required") action = div().flex_none().text_size(z - 1.5).text_color(t.dim).child("拿不掉");
    else if (i.status === "used") action = this.btn(t, z, `rm-${i.kind}-${i.name}`, "拿掉", { small: true, off: busy, on: (cx) => this.act(`拿掉 ${i.name}`, ["rm", i.kind, i.name], cx) });
    else action = this.btn(t, z, `add-${i.kind}-${i.name}`, "加上", { small: true, kind: "primary", off: busy, on: (cx) => this.act(`加上 ${i.name}`, ["add", i.kind, i.name], cx) });
    const sub = [i.description, i.source].filter(Boolean).join(" · ");
    return h_flex().id(`row-${i.kind}-${i.name}`).gap(8).items_center().px(8).py(5).rounded(6).hover((s) => s.bg(t.hover))
      .child(v_flex().flex_1().min_w(0).gap(1)
        .child(head)
        .when(Boolean(sub), (el) => el.child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child(sub))))
      .child(action);
  }

  btn(t, z, id, label, { kind, on, off, small } = {}) {
    const bg = off ? t.raised : kind === "primary" ? t.solid : t.raised;
    const fg = off ? t.dim : kind === "primary" ? t.solid_foreground : t.foreground;
    return div().id(id).h(small ? 26 : 30).px(small ? 10 : 12).flex().flex_none().items_center().justify_center().rounded(6)
      .text_size(small ? z - 1 : z).font_semibold().bg(bg).text_color(fg)
      .when(!off, (el) => el.cursor_pointer().hover((st) => st.opacity(0.85)).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); on?.(cx); }))
      .child(label);
  }

  // The tab-bar button: "kit" plus how many new things there are; click shows / hides the panel.
  renderToggle() {
    const t = theme(), node = find(layout(), PANEL), on = node && !node.hidden;
    const d = this.data;
    const news = (d?.items ?? []).filter((i) => i.new).length;
    const badge = d?.error ? div().text_color(t.ansi1).child("!")
      : news ? div().px(5).rounded(8).text_size(11).font_semibold().bg(t.done).text_color(t.background).child(String(news)) : null;
    return h_flex().size_full().pr(6).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(h_flex().id("toggle-kit").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(on ? t.selected : t.chrome).text_color(on ? t.foreground : t.muted)
        .hover((st) => st.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: PANEL }))
        .child("kit")
        .when(Boolean(badge), (el) => el.child(badge)));
  }
}
