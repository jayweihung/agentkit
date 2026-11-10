// kit panel for Herdr: see and change what kit manages (rules, skills, MCP servers, agents) without typing.
// It follows the agent (terminal) you clicked last: kit runs on that agent's machine, and the panel also lists
// what that agent reads from its folder (CLAUDE.md, .claude/rules, .claude/skills, .mcp.json) besides kit's.
// Installed by `kit herdr-panel install` into <Herdr home>/mods/kit, next to config.json (how to run kit
// on this computer) and mod.json. Everything goes through the kit command itself:
//   kit list --json --dir <folder> --pid <pid>   what there is, what is in use, what the folder adds
//   kit add|rm <kind> <name>
//   kit sync             update                                kit run <agent> --tool <tool>  (in a new tab)
// Roles (props.role): the panel (default), "toggle" (the tab-bar button that shows or hides "kit-panel") and
// "agents" (a tab: every agent on the left, what the chosen one uses and what needs you on the right).
import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { theme, settings, exec, hc, home, run, layout, shared, setShared, window, appHome, readTextFile, focused, terminals, spaces, agents, props as blockProps } from "herdr";

const TOGGLE = "kit-toggle", PANEL = "kit-panel";
const SHIPPED = ["main", "terminals", "win98"]; // Herdr's own layouts: read-only, so "放進上排" clones one first
const DATA = "kit.data.v2", BUSY = "kit.busy", MSG = "kit.msg", TARGET = "kit.target";
const TOGGLE_NODE = { id: TOGGLE, type: "block", content: { mod: "kit", props: { role: "toggle" } }, size: { px: 56 } };
const PANEL_NODE = { id: PANEL, type: "column", children: [{ id: "kit", type: "block", content: { mod: "kit" } }],
  size: { px: 420 }, min: 320, max: 800 };
const KINDS = [
  { kind: "rule", title: "Rules（規則）" },
  { kind: "skill", title: "Skills" },
  { kind: "mcp", title: "MCP" },
  { kind: "agent", title: "Agents" },
];
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
    title: t.title || t.name || t.program?.name || f.terminal, agent: Boolean(f.agent || t.program?.agent) };
}
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
// An agent as a target, like currentTarget does for the focused terminal.
function agentTarget(a) {
  const t = terminals().find((x) => x.address === a.address) ?? {};
  const sp = spaces().find((s) => s.id === a.space);
  const machine = sp?.machine ?? null, cwd = t.cwd ?? null;
  return { key: `${machine ?? ""}|${cwd ?? ""}|${a.address}`, term: a.address, machine, space: a.space, cwd,
    title: a.title || t.name || a.program?.name || a.address, agent: true, report: t.report ?? null };
}
// What needs you about an agent (Herdr's status and kit's answer), most urgent first.
function needs(a, d) {
  const out = [];
  if (a.status === "blocked") out.push({ level: "blocked", text: "等你回應" });
  if (d?.error) out.push({ level: "blocked", text: /連不到/.test(d.error) ? "連不到那台" : "kit 出錯" });
  else if (d?.warn) out.push({ level: "blocked", text: "連不到那台" });
  if (d?.kit_version_wanted) out.push({ level: "warn", text: "kit 要更新" });
  const news = (d?.items ?? []).filter((i) => i.new).length;
  if (news && !d?.here?.user) out.push({ level: "info", text: `${news} 個新的` });
  if (d?.here?.user) out.push({ level: "info", text: `${d.here.user} 唯讀` });
  if (!d) out.push({ level: "dim", text: "讀取中" });
  return out;
}
function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class KitPanel extends View {
  init(_p, cx) {
    const role = blockProps()?.role;
    this.role = role === "toggle" || role === "agents" ? role : "panel";
    if (this.role === "agents") return this.initAgents(cx);
    this.filter = "";
    this.tool = this.load("tool") || "claude";
    this.folded = {};
    try { this.folded = JSON.parse(this.load("folded") || "{}"); } catch { this.folded = {}; }
    // Both the button and the panel keep the shared list fresh (a hidden panel may not have started yet);
    // the background sync Claude starts may change things, so look again every minute.
    this.target = currentTarget(shared(TARGET) ?? null);
    const stale = () => !this.data || this.data.key !== this.target.key || Date.now() - (this.data.at ?? 0) > 50000;
    if (this.role === "panel" || stale()) this.refresh(cx);
    cx.timer.every(60000, (cx) => { if (stale() && !this.busy) this.refresh(cx); });
    // follow the agent you click: look at the focus often, ask kit again only when it changed
    if (this.role === "panel") cx.timer.every(700, (cx) => {
      const t = currentTarget(this.target);
      if (t.key !== this.target.key) { this.target = t; setShared(TARGET, t); if (!this.busy) this.refresh(cx); cx.notify(); }
    });
  }

  load(k) { try { return localStorage.getItem(`kit.${k}`); } catch { return null; } }
  save(k, v) { try { localStorage.setItem(`kit.${k}`, v); } catch {} }

  get data() { return shared(DATA) ?? null; }
  get busy() { return shared(BUSY) ?? null; }

  refresh(cx) {
    const tg = this.target ?? currentTarget(null);
    cx.spawn(async (cx) => { setShared(DATA, await loadFor(tg)); cx.notify(); });
  }

  // ---------- the agents tab ----------
  initAgents(cx) {
    this.cache = new Map();   // agent address -> kit's answer for it
    this.sel = null;
    this.loading = false;
    const sweep = (cx) => {   // ask kit about every agent, one at a time (the chosen one first)
      if (this.loading) return;
      this.loading = true;
      cx.spawn(async (cx) => {
        const list = agents();
        const order = [...list.filter((a) => a.address === this.sel), ...list.filter((a) => a.address !== this.sel)];
        for (const a of order) {
          const tg = agentTarget(a), old = this.cache.get(a.address);
          if (old && old.key === tg.key && Date.now() - old.at < 50000) continue;
          this.cache.set(a.address, await loadFor(tg));
          cx.notify();
        }
        this.loading = false;
      });
    };
    sweep(cx);
    cx.timer.every(5000, (cx) => sweep(cx));
  }

  renderAgents(cx) {
    const t = theme(), z = fs();
    const list = agents();
    if (!this.sel || !list.some((a) => a.address === this.sel)) this.sel = (list.find((a) => a.focused) ?? list[0])?.address ?? null;
    const left = v_flex().id("agents-list").w(300).flex_none().h_full().overflow_y_scrollbar().border_r(1).border_color(t.border).py(6);
    left.child(div().px(12).pb(6).font_semibold().child(`Agents（${list.length}）`));
    let lastSpace = null;
    for (const a of list) {
      if (a.space !== lastSpace) { lastSpace = a.space; left.child(div().px(12).pt(8).pb(2).text_size(z - 2).text_color(t.muted).child(a.space_name)); }
      const tg = agentTarget(a), d = this.cache.get(a.address), n = needs(a, d), on = a.address === this.sel;
      const where = [tg.machine ?? "這台電腦", shortDir(tg.cwd)].filter(Boolean).join(" · ");
      left.child(h_flex().id(`ag-${a.address}`).mx(6).px(8).py(6).gap(8).items_center().rounded(6).cursor_pointer()
        .bg(on ? t.selected : t.surface).hover((s) => s.bg(on ? t.selected : t.hover)).on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.sel = a.address; cx.notify(); })
        .child(div().size(28).flex_none().rounded(14).bg(t.raised).flex().items_center().justify_center().child(icon(a.program, 16, t.foreground) ?? div().child("•")))
        .child(v_flex().flex_1().min_w(0)
          .child(div().truncate().font_semibold().child(a.title || tg.title))
          .child(div().truncate().text_size(z - 2).text_color(t.muted).child(where)))
        .when(n.length > 0, (el) => el.child(this.chip(t, z, n[0]))));
    }
    if (!list.length) left.child(div().px(12).text_color(t.muted).child("現在沒有 agent。"));
    const a = list.find((x) => x.address === this.sel);
    return h_flex().id("agents-root").size_full().bg(t.surface).text_size(z).text_color(t.foreground)
      .child(left)
      .child(a ? this.agentDetail(t, z, a) : div().flex_1().p(16).text_color(t.muted).child("選左邊一個 agent。"));
  }

  chip(t, z, n) {
    const c = n.level === "blocked" ? t.blocked : n.level === "warn" ? t.ansi3 ?? t.blocked : n.level === "dim" ? t.muted : t.done;
    return div().flex_none().px(6).h(18).rounded(5).bg(c + "26").text_size(z - 3).font_semibold().text_color(c).flex().items_center().child(n.text);
  }

  agentDetail(t, z, a) {
    const tg = agentTarget(a), d = this.cache.get(a.address), n = needs(a, d);
    const box = v_flex().id("agent-detail").flex_1().min_w(0).h_full().overflow_y_scrollbar().p(16).gap(12);
    box.child(h_flex().gap(10).items_center()
      .child(div().size(40).flex_none().rounded(20).bg(t.raised).flex().items_center().justify_center().child(icon(a.program, 22, t.foreground) ?? div().child("•")))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().text_size(z + 3).font_semibold().child(a.title || tg.title))
        .child(div().truncate().text_size(z - 1).text_color(t.muted).child([a.program?.name, tg.machine ?? "這台電腦", shortDir(tg.cwd)].filter(Boolean).join(" · "))))
      .child(this.btn(t, z, "go-agent", "切到這個 agent", { kind: "primary", on: () => run("agent.focus", { terminal: a.address }) })));
    const urgent = n.filter((x) => x.level === "blocked" || x.level === "warn" || (x.level === "info" && /新的/.test(x.text)));
    if (urgent.length) box.child(v_flex().gap(6).p(10).rounded(8).bg(t.raised)
      .child(div().font_semibold().child("要處理"))
      .children(urgent.map((x) => h_flex().gap(8).items_center().child(this.chip(t, z, x)).child(div().text_size(z - 1).text_color(t.muted).child(this.needHelp(x, d))))));
    if (tg.report) box.child(div().text_size(z - 1).text_color(t.muted).child(`它最後說：${typeof tg.report === "string" ? tg.report : tg.report.msg ?? JSON.stringify(tg.report)}`));
    if (!d) return box.child(div().text_color(t.muted).child("讀取中…"));
    if (d.error) return box.child(this.problem(t, z, d.error));
    if (d.here?.user) return box.child(div().text_size(z - 1).text_color(t.muted)
      .child(`這個 agent 用 ${d.here.user} 帳號跑${d.here.user === "root" ? "，只用你在 Mac 上簽過的版本。" : "。"}這裡看不到也不能改。`));
    const kitUsed = (d.items ?? []).filter((i) => i.status === "used" || i.status === "required");
    const dir = (d.here?.items ?? []).filter((i) => i.scope === "dir"), mine = (d.here?.items ?? []).filter((i) => i.scope === "user");
    const group = (title, rows, render) => {
      box.child(div().mt(4).font_semibold().child(`${title}（${rows.length}）`));
      if (!rows.length) box.child(div().text_size(z - 1).text_color(t.muted).child("沒有"));
      else box.child(v_flex().gap(2).children(rows.map(render)));
    };
    group("kit 給的（帳號共用）", kitUsed, (i) => this.hereRow(t, z, { kind: i.kind, name: i.name, description: i.description || i.source, tools: "claude", scope: "kit", path: i.name }));
    group("這個目錄自己的", dir, (i) => this.hereRow(t, z, i));
    if (mine.length) group("帳號裡另外有的（不是 kit 管的）", mine, (i) => this.hereRow(t, z, i));
    return box.child(div().text_size(z - 1.5).text_color(t.dim).child("要加上或拿掉 kit 的東西：切到這個 agent，用右邊的 kit 面板。"));
  }

  needHelp(x, d) {
    if (x.text === "等你回應") return "它停下來在等你，切過去看。";
    if (x.text === "連不到那台") return d?.warn ?? d?.error ?? "";
    if (x.text === "kit 出錯") return d?.error ?? "";
    if (x.text === "kit 要更新") return `團隊要 kit ${d?.kit_version_wanted} 以上；在那台打  kit self-update`;
    return "來源裡有新東西，切過去在 kit 面板按「⟳ 同步」看。";
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
    if (this.role === "agents") return this.renderAgents(cx);
    const t = theme(), z = fs();
    const root = v_flex().id("kit-root").size_full().bg(t.surface).text_size(z).text_color(t.foreground);
    root.child(this.header(t, z));
    if (!find(layout(), TOGGLE)) root.child(this.moveBanner(t, z));
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
    return root.child(this.list(t, z, d));
  }

  header(t, z) {
    const d = this.data, busy = this.busy, tg = this.target ?? {};
    const inBar = Boolean(find(layout(), TOGGLE));
    const where = [tg.title || "這台電腦", d?.machine ?? tg.machine ?? "這台電腦", shortDir(d?.here?.dir ?? tg.cwd)].filter(Boolean).join(" · ");
    return v_flex().flex_none().border_b(1).border_color(t.border)
      .child(h_flex().px(10).py(6).gap(6).items_center()
        .child(div().flex_1().min_w(0).truncate().font_semibold().child(d?.kit ? `kit ${d.kit}` : "kit"))
        .child(this.btn(t, z, "sync", busy === "同步" ? "同步中…" : "⟳ 同步", { kind: "primary", off: Boolean(busy), on: (cx) => this.act("同步", ["sync"], cx) }))
        .child(this.btn(t, z, "reload", "↻", { off: Boolean(busy), on: (cx) => this.refresh(cx) }))
        .child(this.btn(t, z, "all-agents", "全部 agent", { on: () => run("tab.new", { name: "Agents", mod: "kit", props: { role: "agents" } }) }))
        .when(inBar, (el) => el.child(this.btn(t, z, "hide", "✕", { on: () => run("layout.hide", { id: PANEL }) }))))
      .child(div().px(12).pb(3).text_size(z - 1).truncate().text_color(t.foreground).child(`跟著：${where}`))
      .when(Boolean(d?.sources?.length), (el) => el.child(div().px(12).pb(5).text_size(z - 1.5).truncate().text_color(t.muted)
        .child(`來源：${d.sources.map((s) => s.name).join("、")}`)));
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
    const items = d.items ?? [];
    const tools = d.tools ?? ["claude"];
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(10);
    const news = items.filter((i) => i.new).length;
    if (news) body.child(div().text_size(z - 1).text_color(t.done).child(`有 ${news} 個新的（標「新」）。按「⟳ 同步」後就不再標新。`));
    for (const { kind, title } of KINDS) {
      const rows = items.filter((i) => i.kind === kind);
      if (!rows.length) continue;
      const folded = Boolean(this.folded[kind]);
      const used = rows.filter((i) => i.status === "used" || i.status === "required").length;
      body.child(h_flex().id(`sec-${kind}`).gap(6).items_center().cursor_pointer().on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.folded[kind] = !folded; this.save("folded", JSON.stringify(this.folded)); cx.notify(); })
        .child(div().w(12).text_color(t.muted).child(folded ? "▸" : "▾"))
        .child(div().font_semibold().child(title))
        .child(div().text_size(z - 1.5).text_color(t.muted).child(kind === "agent" ? `${rows.length} 個` : `在用 ${used} / ${rows.length}`)));
      if (kind === "agent" && tools.length > 1 && !folded) body.child(this.toolPicker(t, z, tools));
      if (!folded) body.child(v_flex().gap(4).children(rows.map((i) => this.row(t, z, i))));
    }
    if (!items.length) body.child(div().text_color(t.muted).child("來源裡還沒有東西。"));
    if (d.here) this.hereSections(t, z, d.here, body);
    return body;
  }

  // what the agent reads besides kit's: its folder (and the ones above), and this account's own (not kit's)
  hereSections(t, z, here, body) {
    const groups = [
      { id: "here-dir", title: "這個目錄自己的（只看）", rows: (here.items ?? []).filter((i) => i.scope === "dir") },
      { id: "here-user", title: "帳號裡另外有的（不是 kit 管的）", rows: (here.items ?? []).filter((i) => i.scope === "user") },
    ];
    body.child(div().mt(4).border_t(1).border_color(t.border));
    if (here.error) body.child(div().text_size(z - 1).text_color(t.muted).child(`${shortDir(here.dir)}：${here.error}`));
    for (const g of groups) {
      if (!g.rows.length) continue;
      const folded = this.folded[g.id] ?? g.rows.length > 8;
      const count = ["rule", "skill", "mcp"].map((k) => [k, g.rows.filter((i) => i.kind === k).length]).filter(([, n]) => n)
        .map(([k, n]) => `${k === "rule" ? "規則" : k === "skill" ? "skill" : "MCP"} ${n}`).join(" · ");
      body.child(h_flex().id(`sec-${g.id}`).gap(6).items_center().cursor_pointer().on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.folded[g.id] = !folded; this.save("folded", JSON.stringify(this.folded)); cx.notify(); })
        .child(div().w(12).text_color(t.muted).child(folded ? "▸" : "▾"))
        .child(div().font_semibold().child(g.title))
        .child(div().text_size(z - 1.5).text_color(t.muted).child(count)));
      if (!folded) body.child(v_flex().gap(4).children(g.rows.map((i) => this.hereRow(t, z, i))));
    }
    if (!groups.some((g) => g.rows.length) && !here.error) body.child(div().text_size(z - 1).text_color(t.muted).child("這個目錄沒有自己的規則、skill、MCP。"));
  }

  hereRow(t, z, i) {
    const badge = (text) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(t.muted).child(text);
    const kind = i.kind === "rule" ? "規則" : i.kind === "skill" ? "skill" : "MCP";
    const head = h_flex().gap(5).items_center().min_w(0).child(badge(kind))
      .child(div().min_w(0).truncate().font_semibold().child(shortDir(i.name)));
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
    if (i.status === "required") head.child(badge("必備", t.accent));
    if (i.status === "used") head.child(badge("在用", t.working));
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
      .when(!off, (el) => el.cursor_pointer().hover((st) => st.opacity(0.85)).on_mouse_down("left", stop).on_click((_e, cx) => on?.(cx)))
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
