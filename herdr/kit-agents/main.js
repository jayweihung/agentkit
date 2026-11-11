// kit Agents for Herdr: the agents kit's sources define (agents/<name>.md: which rules, skills and MCP
// it gets, which tools, its prompt). See them, change what each one uses, open one in a new tab.
// Separate from the kit panel (the repository of rules / skills / MCP). This computer only: the sources are
// the same on every machine, kit push sends the change and kit sync brings it everywhere.
// Shared state: kitag.busy is { label, at, ttl } (older than ttl = finished, so a window that closed mid-action
// can't keep every button grey); kitag.msg is kit's words after an action. A change here marks the repository's
// data (kit.data.v2) out of date, so the kit panel reads it again.
// Installed by `kit herdr-panel install` into <Herdr home>/mods/kit-agents. Everything goes through kit:
//   kit agents --json                              every agent and what it uses, what there is to add
//   kit agent <name> add|rm rule|skill|mcp <item>  change an agent (its file in the source)
//   kit run <name> --tool claude|codex|omp         open it (in a new tab)
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, Editor, EditorState } from "gpui-base";
import { theme, settings, exec, home, run, shared, setShared, window, appHome, readTextFile, writeTextFile, closeOverlay, props, spaces, focused, layout } from "herdr";

// Roles (props.role): the panel (default; "kit-agents-panel" beside the work area, or a window) and "toggle",
// the tab-bar button next to Kit's that shows or hides it. Agents stand beside Kit, not inside it.
const PANEL = "kit-agents-panel";
const DATA = "kitag.data.v1", BUSY = "kit.busy", MSG = "kitag.msg", REPO = "kit.data.v2";
const SHORT = 120000, STALE = 50000;
const KINDS = [["rule", "rules", "規則"], ["skill", "skills", "Skills"], ["mcp", "mcp", "MCP"]];
const TOOL_NAMES = { claude: "Claude", codex: "Codex", omp: "omp" };
const GIT = { new: "新的，還沒送出", changed: "改過" };

function findNode(node, id) {
  if (node?.id === id) return node;
  for (const c of node?.children ?? []) { const f = findNode(c, id); if (f) return f; }
  return null;
}
const fs = () => Number(settings().ui_font_size) || 13;
const mono = () => settings().font_family || (window()?.platform === "windows" ? "Consolas" : "Menlo");
const stop = (_e, cx) => cx.stop_propagation();
const isWindows = () => window()?.platform === "windows";
const shortDir = (d) => { const h = String(home() ?? "").replace(/\\/g, "/"); const p = String(d ?? "").replace(/\\/g, "/"); return p && h && (p + "/").startsWith(h + "/") ? "~" + p.slice(h.length) : p; };
const clean = (s) => String(s).split("\n").map((l) => l.replace(/^kit[:：]\s?/, "")).join("\n").trim();

// How to run kit here: the kit mod's config.json (written by kit herdr-panel install), else kit / kit.cmd on PATH.
async function kitArgv() {
  const text = await readTextFile(`${String(appHome()).replace(/\\/g, "/")}/mods/kit/config.json`).catch(() => null);
  let c = {};
  try { c = text ? JSON.parse(text) : {}; } catch { c = {}; }
  const kit = Array.isArray(c.kit) && c.kit.length ? c.kit.map(String) : [isWindows() ? "kit.cmd" : "kit"];
  const env = c.env && typeof c.env === "object" ? Object.entries(c.env).map(([k, v]) => `${k}=${v}`) : [];
  return env.length && !isWindows() ? ["/usr/bin/env", ...env, ...kit] : kit;
}
async function kit(args, timeout) {
  const argv = await kitArgv();
  try {
    const r = await exec(argv[0], [...argv.slice(1), ...args], { timeout });
    return { code: r.code, out: String(r.stdout ?? ""), err: String(r.stderr ?? "") };
  } catch (e) { return { code: -1, out: "", err: `沒辦法執行 kit：${e?.message ?? e}` }; }
}
async function load() {
  const r = await kit(["agents", "--json"], 60000);
  if (r.code !== 0) return { error: clean(r.err || r.out) || `kit agents 失敗（${r.code}）`, at: Date.now() };
  try { return { ...JSON.parse(r.out), at: Date.now() }; }
  catch { return { error: "kit agents --json 的輸出讀不懂（kit 太舊？請打 kit self-update）", at: Date.now() }; }
}

// something under way: a turning ring (Herdr turns it natively, no timer), alone or before "讀取中…" or a button's "送出中…"
const spin = (size, color) => svg("mods/workspace-chrome/spinner.svg").size(size).flex_none().text_color(color).spin(900);
const withSpin = (label, size, color) => (typeof label === "string" && /中…$/.test(label) ? h_flex().gap(5).items_center().child(spin(size, color)).child(label) : label);
const waiting = (t, z, text) => h_flex().gap(6).items_center().text_color(t.muted).child(spin(z - 1, t.muted)).child(text);
export default class KitAgents extends View {
  init(_p, cx) {
    this.role = props()?.role === "toggle" ? "toggle" : "panel";
    if (this.role === "toggle") return;   // the button only reads what the panel loaded
    this.open = null;      // the agent shown in detail (its name)
    this.adding = {};      // kind -> the "加上…" list is unfolded
    this.edit = null;      // { path, orig, dirty, err } while its file is open; this.code is the editor
    this.tool = this.load("tool") || "claude";
    this.mine = false;     // the id of the action this window started in kit.busy (shared with Kit: one kit action at a time)
    this.seq = 0;          // the newest load wins
    const b = shared(BUSY);
    if (b && (typeof b !== "object" || Date.now() - (b.at ?? 0) > (b.ttl ?? 0))) setShared(BUSY, null);
    const stale = () => !this.data || Date.now() - (this.data.at ?? 0) > STALE;
    this.refresh(cx);
    cx.timer.every(60000, (cx) => { if (stale() && !this.busy) this.refresh(cx); });
  }

  async close(cx) {
    if (this.mine && shared(BUSY)?.id === this.mine) setShared(BUSY, null);
    this.code?.release();
    this.code = null;
  }

  load(k) { try { return localStorage.getItem(`kitag.${k}`); } catch { return null; } }
  save(k, v) { try { localStorage.setItem(`kitag.${k}`, v); } catch {} }
  get data() { return shared(DATA) ?? null; }
  get busy() { const b = shared(BUSY); return b && typeof b === "object" && Date.now() - (b.at ?? 0) < (b.ttl ?? 0) ? b.label : null; }

  refresh(cx) {
    const seq = ++this.seq;
    this.loading = true;
    cx.spawn(async (cx) => {
      const d = await load();
      if (seq === this.seq) { setShared(DATA, d); this.loading = false; }
      cx.notify();
    });
  }
  // an agent file changed: this list and the repository's (改過 / 送出) are out of date
  changed(cx) {
    const r = shared(REPO);
    if (r) setShared(REPO, { ...r, at: 0 });
    this.refresh(cx);
  }

  // kit agent <name> add|rm ...: one at a time, kit's own words shown above
  act(label, args, cx) {
    if (this.busy) return;
    const id = `${Date.now()}-${Math.random()}`;
    setShared(BUSY, { label, at: Date.now(), ttl: SHORT, id });
    this.mine = id;
    setShared(MSG, null);
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await kit(args, SHORT);
        const text = clean([r.out, r.err].filter(Boolean).join("\n"));
        setShared(MSG, { ok: r.code === 0, label, text: text || (r.code === 0 ? "完成" : `失敗（${r.code}）`), at: Date.now() });
      } finally {
        if (this.mine && shared(BUSY)?.id === this.mine) setShared(BUSY, null);
        this.mine = false;
        this.changed(cx);
        cx.notify();
      }
    });
  }

  // where kit run starts: kit here is this computer's, so a space on this computer (the shown one if it is,
  // else the first), in the folder of the pane you were in when that is on this computer too
  place() {
    const f = focused(), all = spaces() ?? [];
    const local = all.filter((s) => !s.machine);
    const sp = local.find((s) => s.id === f?.space) ?? local.find((s) => s.active) ?? local[0] ?? null;
    const folder = sp && f?.space === sp.id && f?.cwd ? f.cwd : sp?.folder || null;
    return { ...(sp ? { space: sp.id } : {}), ...(folder ? { folder } : {}) };
  }

  // kit run <agent> in a new tab (kit syncs first, then starts the tool)
  openAgent(name, cx) {
    if (this.opening) return;
    const where = this.place();
    if (!where.space) {
      setShared(MSG, { ok: false, label: "開啟", text: "這台電腦沒有開著的 space：先在這台開一個 space，再按開啟。", at: Date.now() });
      cx.notify();
      return;
    }
    this.opening = true;
    cx.spawn(async (cx) => {
      try {
      const argv = await kitArgv();
      const tools = this.data?.tools ?? ["claude"];
      const tool = tools.includes(this.tool) ? this.tool : "claude";
      const kitArgs = [...argv, "run", name, "--tool", tool];
      // kit.cmd is a batch file: start it through cmd so the terminal can run it
      const full = isWindows() && /\.(cmd|bat)$/i.test(argv[0]) ? ["cmd.exe", "/d", "/c", ...kitArgs] : kitArgs;
      try {
        await run("tab.new", { name: `${name}（${TOOL_NAMES[tool] ?? tool}）`, argv: full, ...where });
        setShared(MSG, { ok: true, label: "開啟", text: `在新分頁開了 ${name}（${TOOL_NAMES[tool] ?? tool}）`, at: Date.now() });
      } catch (e) {
        setShared(MSG, { ok: false, label: "開啟", text: `開不起來：${e?.message ?? e}`, at: Date.now() });
      }
      } finally { this.opening = false; cx.notify(); }
    });
  }

  // its file (frontmatter + prompt) in an editor, saved only if nobody changed it meanwhile
  async editFile(a, cx) {
    const text = await readTextFile(a.path).catch(() => null);
    if (text === null) { setShared(MSG, { ok: false, label: "打開", text: `讀不到 ${shortDir(a.path)}`, at: Date.now() }); return; }
    this.code?.release();
    const th = theme();
    this.code = EditorState.new({ language: "md", value: text, soft_wrap: true, font_family: settings().font_family, font_size: 12,
      syntax: { keyword: th.ansi5, string: th.ansi2, comment: th.dim, function: th.ansi4, type: th.ansi3, number: th.ansi1, constant: th.ansi6 } });
    this.edit = { path: a.path, name: a.name, orig: text, dirty: false, err: null };
    this.code.on("change", (_e, cx) => {
      const dirty = this.code.value() !== this.edit?.orig;
      if (this.edit && dirty !== this.edit.dirty) { this.edit.dirty = dirty; cx.notify(); }
    });
  }
  closeFile(cx) { this.code?.release(); this.code = null; this.edit = null; cx.notify(); }
  saveFile(cx) {
    const e = this.edit;
    if (!e?.dirty) return;
    const text = this.code.value();
    cx.spawn(async (cx) => {
      try {
        await writeTextFile(e.path, text, e.orig);
        e.orig = text; e.dirty = false; e.err = null;
        this.changed(cx);
      } catch { e.err = "這個檔案在別的地方被改過了。先複製你改的，按「重新讀取」，再貼回去。"; }
      cx.notify();
    });
  }

  // The tab-bar button: "Agents", with how many agent files are changed and not sent; click shows / hides the panel.
  renderToggle() {
    const t = theme(), node = findNode(layout(), PANEL), on = Boolean(node && !node.hidden);
    const d = this.data, changed = (d?.agents ?? []).filter((a) => a.git === "new" || a.git === "changed").length;
    return h_flex().size_full().pr(6).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(h_flex().id("toggle-kit-agents").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(on ? t.selected : t.chrome).text_color(on ? t.foreground : t.muted)
        .hover((st) => st.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => { if (node) run("layout.toggle", { id: PANEL }); else run("mod.open", { name: "kit-agents" }); })
        .child("Agents")
        .when(changed > 0, (el) => el.child(div().size(6).rounded(3).bg(t.working))));
  }

  render(cx) {
    if (this.role === "toggle") return this.renderToggle();
    const t = theme(), z = fs(), d = this.data, msg = shared(MSG);
    const root = v_flex().id("kitag-root").size_full().bg(t.surface).text_size(z).text_color(t.foreground);
    const a = this.open && (d?.agents ?? []).find((x) => x.name === this.open);
    root.child(this.header(t, z, d, a));
    if (msg) root.child(this.message(t, z, msg));
    if (!d) return root.child(div().p(14).child(waiting(t, z, "讀取中…")));
    if (d.error) return root.child(v_flex().p(14).gap(8)
      .child(div().font_semibold().text_color(t.ansi1).child("kit 出錯了"))
      .child(div().font_family(mono()).text_size(z - 1).child(d.error))
      .child(div().text_size(z - 1).text_color(t.muted).child("修好後按上面的 ⟳ 重新讀取。")));
    if (this.edit) return root.child(this.editor(t, z));
    if (a) return root.child(this.detail(t, z, d, a));
    return root.child(this.list(t, z, d));
  }

  header(t, z, d, a) {
    const busy = this.busy, n = (d?.agents ?? []).length;
    const sub = a ? `${a.source} · ${shortDir(a.path)}` : d && !d.error ? `${n} 個 agent · 用 kit run 開` : "Kit 來源裡定義好的 agent";
    const overlay = props()?.overlay;
    return h_flex().flex_none().px(10).py(8).gap(8).items_center().border_b(1).border_color(t.border)
      .when(Boolean(a) && !this.edit, (el) => el.child(this.btn(t, z, "back", "← 回去", { small: true, on: (cx) => { this.open = null; this.adding = {}; cx.notify(); } })))
      .when(!a, (el) => el.child(div().size(32).flex_none().rounded(8).bg(t.raised).flex().items_center().justify_center().font_semibold().text_size(z - 4).child("agent")))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().font_semibold().child(a ? a.name : "Agents"))
        .child(div().truncate().text_size(z - 1.5).text_color(t.muted).child(sub)))
      .when(Boolean(busy), (el) => el.child(h_flex().flex_none().gap(5).items_center().text_size(z - 1.5).text_color(t.muted).child(spin(z - 2, t.muted)).child(`${busy}…`)))
      .child(this.btn(t, z, "reload", this.loading ? spin(z - 2, t.dim) : "⟳", { small: true, off: Boolean(this.loading), on: (cx) => this.refresh(cx) }))
      .when(Boolean(overlay), (el) => el.child(this.btn(t, z, "close", "✕", { small: true, on: () => closeOverlay(overlay) })))
      .when(!overlay && Boolean(findNode(layout(), PANEL)), (el) => el.child(this.btn(t, z, "hide", "✕", { small: true, on: () => run("layout.hide", { id: PANEL }) })));
  }

  message(t, z, msg) {
    return h_flex().flex_none().mx(10).mt(8).p(8).gap(8).items_start().rounded(6).bg(t.raised)
      .border_1().border_color(msg.ok ? t.border : t.ansi1)
      .child(div().flex_1().min_w(0).text_size(z - 1).font_family(mono()).text_color(msg.ok ? t.foreground : t.ansi1)
        .child(`${msg.label}：${msg.ok ? "" : "失敗\n"}${msg.text}`))
      .child(div().id("msg-close").flex_none().px(4).cursor_pointer().text_color(t.muted).hover((s) => s.text_color(t.foreground))
        .on_mouse_down("left", stop).on_click((_e, cx) => { setShared(MSG, null); cx.notify(); }).child("✕"));
  }

  badge(t, z, text, color) {
    return div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(color).child(text);
  }

  // every agent: name, git state, what it is, where from, how much it uses; click for its detail
  list(t, z, d) {
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(2);
    const ags = [...(d.agents ?? [])].sort((x, y) => x.name.localeCompare(y.name));
    if (!ags.length) return body.child(div().p(8).text_color(t.muted).child("來源裡還沒有 agent。在終端機打  kit new agent <名字>  寫一個。"));
    for (const a of ags) {
      const counts = `規則 ${(a.rules ?? []).length} · skill ${(a.skills ?? []).length} · MCP ${(a.mcp ?? []).length}`;
      body.child(h_flex().id(`ag-${a.name}`).gap(8).items_center().px(8).py(6).rounded(6).cursor_pointer()
        .hover((s) => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.open = a.name; this.adding = {}; setShared(MSG, null); cx.notify(); })
        .child(v_flex().flex_1().min_w(0).gap(1)
          .child(h_flex().gap(5).items_center().min_w(0)
            .child(div().min_w(0).truncate().font_semibold().child(a.name))
            .when(Boolean(GIT[a.git]), (el) => el.child(this.badge(t, z, GIT[a.git], a.git === "new" ? t.done : t.working))))
          .child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child([a.description, a.source].filter(Boolean).join(" · ") || "（還沒寫說明）"))
          .child(div().text_size(z - 2).text_color(t.dim).child(counts)))
        .child(div().flex_none().text_color(t.dim).child("›")));
    }
    return body;
  }

  // one agent: what it is, its tools, what it uses (拿掉) and could use (加上…), open it, edit its file
  detail(t, z, d, a) {
    const busy = Boolean(this.busy), avail = d.available ?? {};
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(8);
    body.child(v_flex().gap(2)
      .child(div().child(a.description || "（還沒寫說明）"))
      .when(Boolean(GIT[a.git]), (el) => el.child(div().text_size(z - 1.5).text_color(a.git === "new" ? t.done : t.working)
        .child(`${GIT[a.git]}：改好按倉庫的「送出」，或在終端機打  kit push`))));
    // open: pick the tool, then kit run in a new tab
    const tools = d.tools ?? ["claude"], cur = tools.includes(this.tool) ? this.tool : "claude";
    body.child(h_flex().gap(4).items_center().flex_wrap()
      .children(tools.length > 1 ? tools.map((tool) => div().id(`tool-${tool}`).px(8).py(2).rounded(5).text_size(z - 1.5).cursor_pointer()
        .bg(tool === cur ? t.selected : t.raised).text_color(tool === cur ? t.foreground : t.muted)
        .border_1().border_color(tool === cur ? t.accent : t.raised)
        .on_mouse_down("left", stop).on_click((_e, cx) => { this.tool = tool; this.save("tool", tool); cx.notify(); })
        .child(TOOL_NAMES[tool] ?? tool)) : [])
      .child(div().flex_1())
      .child(this.btn(t, z, "edit", "編輯檔案", { small: true, on: (cx) => cx.spawn(async (cx) => { await this.editFile(a, cx); cx.notify(); }) }))
      .child(this.btn(t, z, "run", "開啟", { small: true, kind: "primary", on: (cx) => this.openAgent(a.name, cx) })));
    // tools it may use
    const only = a.tools_only ?? [], deny = a.tools_deny ?? [];
    body.child(v_flex().gap(2).p(8).rounded(6).bg(t.raised).text_size(z - 1.5)
      .child(div().font_semibold().text_size(z - 1).child("可以用的工具"))
      .child(div().text_color(t.muted).child(only.length ? `只能用：${only.join("、")}` : "不限（照工具本身的設定）"))
      .when(deny.length > 0, (el) => el.child(div().text_color(t.muted).child(`不准用：${deny.join("、")}`))));
    // what it uses, per kind
    for (const [kind, key, title] of KINDS) {
      const used = a[key] ?? [], more = (avail[kind] ?? []).filter((x) => !used.includes(x)).sort();
      body.child(div().mt(4).font_semibold().child(`${title}（${used.length}）`));
      if (!used.length) body.child(div().pl(8).text_size(z - 1.5).text_color(t.dim).child("沒有"));
      for (const name of used) body.child(h_flex().id(`use-${kind}-${name}`).gap(8).items_center().px(8).py(4).rounded(6).hover((s) => s.bg(t.hover))
        .child(div().flex_1().min_w(0).truncate().child(name))
        .child(this.btn(t, z, `rm-${kind}-${name}`, "拿掉", { small: true, off: busy, on: (cx) => this.act(`拿掉 ${name}`, ["agent", a.name, "rm", kind, name], cx) })));
      if (!more.length) continue;
      const open = Boolean(this.adding[kind]);
      body.child(h_flex().id(`more-${kind}`).gap(6).items_center().pl(8).cursor_pointer().text_size(z - 1.5).text_color(t.muted)
        .hover((s) => s.text_color(t.foreground)).on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.adding[kind] = !open; cx.notify(); })
        .child(div().w(12).child(open ? "▾" : "▸")).child(`加上…（${more.length}）`));
      if (open) for (const name of more) body.child(h_flex().id(`add-${kind}-${name}`).gap(8).items_center().px(8).py(4).rounded(6).hover((s) => s.bg(t.hover))
        .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(name))
        .child(this.btn(t, z, `add-${kind}-${name}-b`, "加上", { small: true, kind: "primary", off: busy, on: (cx) => this.act(`加上 ${name}`, ["agent", a.name, "add", kind, name], cx) })));
    }
    if (a.prompt) body.child(v_flex().mt(4).gap(4)
      .child(div().font_semibold().child("Prompt"))
      .child(div().p(8).rounded(6).bg(t.raised).text_size(z - 1.5).text_color(t.muted).child(a.prompt)));
    return body;
  }

  editor(t, z) {
    const e = this.edit;
    return v_flex().flex_1().min_h(0)
      .child(h_flex().flex_none().px(10).py(8).gap(6).items_center().border_b(1).border_color(t.border)
        .child(this.btn(t, z, "file-back", e.dirty ? "← 不存，回去" : "← 回去", { small: true, on: (cx) => this.closeFile(cx) }))
        .child(div().flex_1().min_w(0).truncate().font_semibold().child(`${e.name}.md`))
        .child(this.btn(t, z, "file-save", e.dirty ? "存檔" : "已存", { small: true, kind: "primary", off: !e.dirty, on: (cx) => this.saveFile(cx) })))
      .when(Boolean(e.err), (el) => el.child(div().flex_none().mx(10).mt(8).p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked).child(e.err)))
      .child(Editor.new(this.code).flex_1().min_h(0))
      .child(h_flex().flex_none().px(10).py(6).gap(6).items_center().border_t(1).border_color(t.border)
        .child(div().flex_1().text_size(z - 2).text_color(t.dim).child(e.dirty ? "還沒存檔" : "上面 --- 之間是設定（rules、skills、mcp、tools），下面是 prompt"))
        .child(this.btn(t, z, "file-reload", "重新讀取", { small: true, on: (cx) => cx.spawn(async (cx) => { const a = (this.data?.agents ?? []).find((x) => x.name === e.name); if (a) await this.editFile(a, cx); cx.notify(); }) })));
  }

  btn(t, z, id, label, { kind, on, off, small } = {}) {
    const bg = off ? t.raised : kind === "primary" ? t.solid : t.raised;
    const fg = off ? t.dim : kind === "primary" ? t.solid_foreground : t.foreground;
    return div().id(id).h(small ? 26 : 30).px(small ? 10 : 12).flex().flex_none().items_center().justify_center().rounded(6)
      .text_size(small ? z - 1 : z).font_semibold().bg(bg).text_color(fg)
      .when(!off, (el) => el.cursor_pointer().hover((st) => st.opacity(0.85)).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); on?.(cx); }))
      .child(withSpin(label, small ? z - 2 : z - 1, fg));
  }
}
