// kit for Herdr (mod "kit"). Roles (props.role):
//   panel (default)  the repository (倉庫): the sources' rules / skills / MCP on this computer, to read, edit, add
//                    (kit new) and send (kit push, after a --dry-run you confirm). The sources are the same on every
//                    machine: what is sent reaches the others with kit sync.
//   toggle           the tab-bar button that shows or hides the panel (reads the panel's data, never loads)
//   pane             a popup for one agent, opened by the kit button in its pane header (mod kit-pane). The header
//                    is the one that asks kit (kit list --json --dir --pid on the agent's machine); this popup shows
//                    that answer (shared kit.pane.data.v1) and asks the header for a fresh one (kit.pane.want).
//   editor           one file of the repository in its own big window (放大)
// Installed by `kit herdr-panel install` into <Herdr home>/mods/kit, next to config.json (how to run kit on this
// computer) and mod.json. Everything goes through the kit command itself.
//
// Shared state (every copy sees it; it survives a restart, so nothing in it may stay "busy" forever):
//   kit.data.v2   the repository's data ({ at: 0 } = out of date: the panel loads it again)
//   kit.load      { seq, at, done }  the repository's load in progress; only the newest one is kept
//   kit.busy      { label, at, ttl } one kit action at a time; older than its ttl counts as finished
//   kit.msg.<where>  kit's words after an action, per place (panel, pane:<key>, editor:<path>)
//   kit.editors   path -> { dirty } the files open in big windows
import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, Editor, EditorState } from "gpui-base";
import { theme, settings, exec, home, run, layout, shared, setShared, window, appHome, readTextFile, writeTextFile, closeOverlay, openOverlay, props as blockProps } from "herdr";

const TOGGLE = "kit-toggle", PANEL = "kit-panel";
const SHIPPED = ["main", "terminals", "win98"]; // Herdr's own layouts: read-only, so "放進上排" clones one first
const DATA = "kit.data.v2", LOAD = "kit.load", BUSY = "kit.busy", EDITORS = "kit.editors";
const PANE_CACHE = "kit.pane.v1", PANE_DATA = "kit.pane.data.v1", PANE_WANT = "kit.pane.want";
const MSG = (where) => `kit.msg.${where}`;
const TOGGLE_NODE = { id: TOGGLE, type: "block", content: { mod: "kit", props: { role: "toggle" } }, size: { px: 56 } };
const PANEL_NODE = { id: PANEL, type: "column", children: [{ id: "kit", type: "block", content: { mod: "kit" } }],
  size: { px: 420 }, min: 320, max: 800 };
// Agents stand beside Kit (mod kit-agents): their button before Kit's, their panel after Kit's, hidden until clicked
const AGENTS_TOGGLE = { id: "kit-agents-toggle", type: "block", content: { mod: "kit-agents", props: { role: "toggle" } }, size: { px: 66 } };
const AGENTS_NODE = { id: "kit-agents-panel", type: "column", children: [{ id: "kit-agents", type: "block", content: { mod: "kit-agents" } }],
  size: { px: 420 }, min: 320, max: 800, hidden: true };
const TABS_ROW = "kit-tabs-row";
const POPUP_H = 560; // the "pane" popup (kit-pane opens it with this height too)
const LONG = 600000, SHORT = 120000; // how long kit sync / push, and the other actions, may take
const STALE = 60000, LOAD_TTL = 90000;
// the files kit push sends (everything else in a source is left alone)
const ITEM_FILE = /^(rules\/[^/]+\.md|skills\/[^/]+\/.+|mcp\/[^/]+\.yaml|agents\/[^/]+\.md|third_party\.lock)$/;
const PUSH_KIND = { pr: "團隊 · 送出要審", direct: "自己的 · 直接推" };

const fs = () => Number(settings().ui_font_size) || 13;
const mono = () => settings().font_family || (window()?.platform === "windows" ? "Consolas" : "Menlo");
const stop = (_e, cx) => cx.stop_propagation();
const isWindows = () => window()?.platform === "windows";
const slash = (p) => String(p ?? "").replace(/\\/g, "/");
// a folder with ~ for this computer's home (other machines' paths stay as they are)
const shortDir = (d) => { const h = slash(home()), p = slash(d); return p && h && (p + "/").startsWith(h + "/") ? "~" + p.slice(h.length) : p; };
// something under way: a turning ring (Herdr turns it natively, no timer), alone or before "讀取中…" or a button's "送出中…"
const spin = (size, color) => svg("mods/workspace-chrome/spinner.svg").size(size).flex_none().text_color(color).spin(900);
const withSpin = (label, size, color) => (typeof label === "string" && /中…$/.test(label) ? h_flex().gap(5).items_center().child(spin(size, color)).child(label) : label);
const waiting = (t, z, text) => h_flex().gap(6).items_center().text_color(t.muted).child(spin(z - 1, t.muted)).child(text);
// kit's own messages, without the "kit: " / "kit：" in front of each line
const clean = (s) => String(s).split("\n").map((l) => l.replace(/^kit[:：]\s?/, "")).join("\n").trim();
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
// every pane header Herdr's own mod draws ("mod": "pane") drawn by kit-pane instead, as kit herdr-panel install does
function withKitHeaders(node) {
  if (Array.isArray(node)) return node.map(withKitHeaders);
  if (!node || typeof node !== "object") return node;
  const out = Object.fromEntries(Object.entries(node).map(([k, v]) => [k, withKitHeaders(v)]));
  if (out.content && out.content.mod === "pane") out.content = { ...out.content, mod: "kit-pane" };
  return out;
}
// The layout with a tab-bar button + the panel beside the work area, kit's pane headers, the stray dock removed.
// Kit's buttons go in one row with the tab bar. A tab bar in a column (Herdr's own layouts) gets a row around it
// (kit-tabs-row, its size; the bar fills the rest). Where the bar draws the window buttons itself (Windows, Linux)
// kit's go before it so the close button stays in the corner; on a Mac after it. The same as kit herdr-panel install.
function placed(root) {
  const strip = (n) => {
    const kids = n.children?.filter((c) => !["kit", "kit-agents"].includes(c.content?.mod) && c.id !== PANEL && c.id !== AGENTS_NODE.id).map(strip);
    return kids ? { ...n, children: kids.map((c) => (c.id === TABS_ROW && c.children?.length === 1 ? unrow(c) : c)) } : { ...n };
  };
  const unrow = (r) => { const x = { ...r.children[0] }; if (r.size) x.size = r.size; else delete x.size; return x; };
  const tree = withKitHeaders(strip(JSON.parse(JSON.stringify(root))));
  let bar = parentOf(tree, (c) => c.content?.mod === "tabs");
  const body = parentOf(tree, (c) => c.content?.tab != null);
  if (!bar || !body) return null;
  if (bar.type !== "row") {
    const i = bar.children.findIndex((c) => c.content?.mod === "tabs"), tabs = bar.children[i];
    const row = { id: TABS_ROW, type: "row", ...(tabs.size ? { size: tabs.size } : {}), children: [{ ...tabs, size: { weight: 1 } }] };
    bar.children[i] = row;
    bar = row;
  }
  const at = bar.children.findIndex((c) => c.content?.mod === "tabs");
  if (window()?.buttons) bar.children.splice(at, 0, AGENTS_TOGGLE, TOGGLE_NODE);
  else bar.children.splice(at + 1, 0, AGENTS_TOGGLE, TOGGLE_NODE);
  body.children.push(PANEL_NODE, AGENTS_NODE);
  return tree;
}

// How to run kit here: config.json (written by kit herdr-panel install), else kit / kit.cmd on PATH.
async function kitConfig() {
  const text = await readTextFile(`${slash(appHome())}/mods/kit/config.json`).catch(() => null);
  let c = {};
  try { c = text ? JSON.parse(text) : {}; } catch { c = {}; }
  const kit = Array.isArray(c.kit) && c.kit.length ? c.kit.map(String) : [isWindows() ? "kit.cmd" : "kit"];
  const env = c.env && typeof c.env === "object" ? Object.entries(c.env).map(([k, v]) => `${k}=${v}`) : [];
  // Windows has no env program: the variables are only for trying the panel on a Mac/Linux test setup.
  return env.length && !isWindows() ? ["/usr/bin/env", ...env, ...kit] : kit;
}
// On another machine (a space's machine): kit from PATH or ~/.local/bin (Mac/Linux), else kit.cmd (Windows).
const REMOTE_SH = ["sh", "-c", 'command -v kit >/dev/null 2>&1 && exec kit "$@"; exec "$HOME/.local/bin/kit" "$@"', "kit"];
async function kit(args, timeout, machine = null) {
  const ways = machine ? [REMOTE_SH, ["kit.cmd"]] : [await kitConfig()];
  let last = "";
  for (const argv of ways) {
    let r;
    try { r = await exec(argv[0], [...argv.slice(1), ...args], { timeout, on: machine }); }
    catch (e) { last = String(e?.message ?? e); continue; }
    if (machine && argv === REMOTE_SH && (r.code === 127 || r.code === 9009)) { last = String(r.stderr ?? ""); continue; }
    return { code: r.code, out: String(r.stdout ?? ""), err: String(r.stderr ?? "") };
  }
  return { code: -1, out: "", err: machine ? `連不到 ${machine}，或那台沒裝 kit：${clean(last)}` : `沒辦法執行 kit：${last}` };
}
// kit push --dry-run's list of files (the indented lines), to compare before the real push
const sendList = (out) => String(out ?? "").split("\n").filter((l) => /^  \S/.test(l)).map((l) => l.trim()).sort().join("\n");
// big windows that said within 2 minutes that they are open
function liveEditors() {
  const all = shared(EDITORS) ?? {}, now = Date.now(), out = {};
  for (const [k, v] of Object.entries(all)) if (v && now - (v.at ?? 0) < 120000) out[k] = v;
  return out;
}
// the item files git sees as changed in a source folder (relative to it); -z: names exactly as they are
async function gitChanges(dir) {
  // where the folder sits in its repo, as git itself spells it (symlinks, junctions, drive letters don't matter)
  const top = await exec("git", ["-C", dir, "rev-parse", "--show-prefix"], { timeout: 15000 });
  if (top.code !== 0) return [];
  const pre = String(top.stdout).replace(/[\r\n]+$/, "");
  const r = await exec("git", ["-C", dir, "status", "--porcelain", "-z", "--untracked-files=all"], { timeout: 15000 });
  if (r.code !== 0) return [];
  const parts = String(r.stdout).split("\0"), files = [];
  for (let i = 0; i < parts.length; i++) {
    const e = parts[i];
    if (e.length < 4) continue;
    if (e[0] === "R" || e[0] === "C") i++;   // a rename: the old name comes next
    const path = e.slice(3);
    if (!path.startsWith(pre)) continue;
    const rel = path.slice(pre.length);
    if (ITEM_FILE.test(rel)) files.push(rel);
  }
  return files;
}
// The repository: kit list --json on this computer, each item's place in its source and whether git sees it changed.
async function loadRepo() {
  const r = await kit(["list", "--json"], 60000), at = Date.now();
  if (r.code !== 0) return { key: "repo", error: clean(r.err || r.out) || `kit list 失敗（${r.code}）`, at };
  let d;
  try { d = JSON.parse(r.out); } catch { return { key: "repo", error: "kit list --json 的輸出讀不懂（kit 太舊？請打 kit self-update）", at }; }
  const sources = await Promise.all((d.sources ?? []).map(async (s) => ({ ...s, files: s.dir ? await gitChanges(s.dir).catch(() => []) : [] })));
  const srcOf = (p) => sources.find((s) => s.dir && slash(p).startsWith(slash(s.dir) + "/"));
  const items = (d.items ?? []).filter((i) => i.kind !== "agent").map((i) => {
    const s = srcOf(i.path), rel = s ? slash(i.path).slice(slash(s.dir).length + 1) : "", folder = rel.replace(/[^/]*$/, "");
    const changed = Boolean(s && s.files.some((f) => f === rel || (i.kind === "skill" && folder && f.startsWith(folder))));
    return { ...i, rel, changed, src: s?.name ?? i.source };
  });
  const dirty = sources.map((s) => ({ name: s.name, push: s.push ?? null,
    items: s.files.filter((f) => !f.startsWith("agents/")).length, agents: s.files.filter((f) => f.startsWith("agents/")).length }))
    .filter((x) => x.items + x.agents > 0);
  return { ...d, key: "repo", at, items, sources, dirty };
}
// open a file in this computer's own program for it (explorer: no cmd.exe parsing of & or ^ in the path)
function openOutside(path) {
  const w = window()?.platform;
  if (w === "windows") return exec("explorer.exe", [String(path).replace(/\//g, "\\")]);
  if (w === "macos") return exec("open", ["-t", path]);
  return exec("xdg-open", [path]);
}
function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

export default class KitPanel extends View {
  init(_p, cx) {
    const role = blockProps()?.role;
    this.role = ["toggle", "pane", "editor"].includes(role) ? role : "panel";
    this.filter = "";
    this.kind = this.load("kind") || "skill";
    this.folded = {};
    try { this.folded = JSON.parse(this.load("folded") || "{}"); } catch { this.folded = {}; }
    this.edit = null;    // { item, orig, dirty, err } while a file is open; this.code is its editor
    this.code = null;
    this.making = null;  // { source } while adding a new one
    this.plan = null;    // 送出: [{ name, push, ok, text }] what kit push --dry-run said, waiting for 確定送出
    this.mine = false;   // this copy started the action in kit.busy
    // an action whose window closed (or the app quit) before it ended must not keep every button grey
    const b = shared(BUSY);
    if (b && (typeof b !== "object" || Date.now() - (b.at ?? 0) > (b.ttl ?? 0))) setShared(BUSY, null);

    if (this.role === "editor") {
      const p = blockProps() ?? {};
      this.where = `editor:${p.item?.path ?? ""}`;
      if (p.item) cx.spawn(async (cx) => { await this.openItem(p.item, cx, p.value, p.orig); cx.notify(); });
      cx.timer.every(30000, () => this.mark());
      return;
    }
    if (this.role === "pane") {
      this.target = blockProps()?.target ?? { key: "" };
      this.where = `pane:${this.target.key}`;
      const c = (shared(PANE_CACHE) ?? {})[this.target.key];
      if (!c || Date.now() - (c.started ?? 0) > 10000) this.want();
      this.openedAt = Date.now();
      cx.timer.every(2000, (cx) => { if (!this.data) cx.notify(); });   // so a load nobody answers shows up (below)
      return;
    }
    this.where = this.role;
    if (this.role === "toggle") return;   // it only shows what the panel loaded
    this.input = InputState.new({ placeholder: "找：名字、說明、來源" });
    this.input.on("change", (_e, cx) => { this.filter = this.input.value().trim().toLowerCase(); cx.notify(); });
    this.newName = InputState.new({ placeholder: "名字：小寫英文、數字和 -" });
    this.newName.on("submit", (_e, cx) => this.make(cx));
    this.newName.on("change", (_e, cx) => cx.notify());   // the path it will make follows the name
    this.newUrl = InputState.new({ placeholder: "網址，例如 https://github.com/作者/repo" });
    this.newUrl.on("submit", (_e, cx) => this.look(cx));
    this.newUrl.on("change", (_e, cx) => { if (this.making?.look || this.making?.urlErr) { this.making.look = null; this.making.urlErr = null; cx.notify(); } });
    // load when there is nothing, it is a minute old, or someone marked it out of date (at: 0)
    const due = () => !this.loading && (!this.data || this.data.at === 0 || Date.now() - (this.data.at ?? 0) > STALE);
    if (due() || !this.data) this.refresh(cx);
    cx.timer.every(2000, (cx) => { if (due() && !this.busy) this.refresh(cx); });
  }

  async close(cx) {
    this.endBusy();
    if (this.role === "editor" && this.edit) {
      const ed = { ...(shared(EDITORS) ?? {}) };
      delete ed[this.edit.item.path];
      setShared(EDITORS, ed);
    }
    this.code?.release();
    this.code = null;
  }

  load(k) { try { return localStorage.getItem(`kit.${k}`); } catch { return null; } }
  save(k, v) { try { localStorage.setItem(`kit.${k}`, v); } catch {} }

  get data() { return this.role === "pane" ? (shared(PANE_DATA) ?? {})[this.target?.key] ?? null : shared(DATA) ?? null; }
  get busy() { const b = shared(BUSY); return b && typeof b === "object" && Date.now() - (b.at ?? 0) < (b.ttl ?? 0) ? b.label : null; }
  get loading() {
    if (this.role === "pane") { const c = (shared(PANE_CACHE) ?? {})[this.target?.key]; return Boolean(c?.busy && Date.now() - (c.started ?? 0) < LOAD_TTL); }
    const l = shared(LOAD); return Boolean(l && !l.done && Date.now() - (l.at ?? 0) < LOAD_TTL);
  }
  get msg() { return shared(MSG(this.where)) ?? null; }
  setMsg(m) { setShared(MSG(this.where), m); }

  // the repository's data, newest load wins (a slower older load can't put back what an action changed)
  refresh(cx) {
    const seq = (shared(LOAD)?.seq ?? 0) + 1;
    setShared(LOAD, { seq, at: Date.now(), done: false });
    cx.spawn(async (cx) => {
      let d;
      try { d = await loadRepo(); } catch (e) { d = { key: "repo", error: `讀不到：${e?.message ?? e}`, at: Date.now() }; }
      if ((shared(LOAD)?.seq ?? 0) === seq) { setShared(DATA, d); setShared(LOAD, { seq, at: Date.now(), done: true }); }
      cx.notify();
    });
  }
  // the popup's agent: ask its pane header to look again
  want() {
    if (!this.target?.key) return;
    setShared(PANE_WANT, { ...(shared(PANE_WANT) ?? {}), [this.target.key]: Date.now() });
  }
  // after a change on a machine: the repository and every agent header there are out of date
  changed(machine) {
    const d = shared(DATA);
    if (d && !machine) setShared(DATA, { ...d, at: 0 });
    const m = machine ?? "", now = Date.now(), want = { ...(shared(PANE_WANT) ?? {}) };
    for (const k of Object.keys(shared(PANE_CACHE) ?? {})) if (k.split("|")[0] === m) want[k] = now;
    setShared(PANE_WANT, want);
  }

  // one action at a time across every copy of the panel; only the copy that took the lock gives it back
  startBusy(label, ttl) {
    if (this.busy) return false;
    const id = `${Date.now()}-${Math.random()}`;
    setShared(BUSY, { label, at: Date.now(), ttl, id });
    this.mine = id;
    return true;
  }
  endBusy() { if (this.mine && shared(BUSY)?.id === this.mine) setShared(BUSY, null); this.mine = false; }

  // add / rm / sync: one at a time, the result (kit's own words) shown above the list
  act(label, args, cx, ttl = SHORT) {
    if (!this.startBusy(label, ttl)) return;
    this.setMsg(null);
    cx.notify();
    const machine = this.role === "pane" ? this.target?.machine ?? null : null;
    cx.spawn(async (cx) => {
      try {
        const r = await kit(args, ttl, machine);
        const text = clean([r.out, r.err].filter(Boolean).join("\n"));
        this.setMsg({ ok: r.code === 0, label, text: text || (r.code === 0 ? "完成" : `失敗（${r.code}）`), at: Date.now() });
      } finally {
        this.endBusy();
        this.changed(machine);
        cx.notify();
      }
    });
  }

  // 送出, step 1: what kit push would send from each changed source (--dry-run), shown for 確定送出
  planPush(cx) {
    const dirty = this.data?.dirty ?? [];
    if (!dirty.length || !this.startBusy("檢查", SHORT * dirty.length)) return;
    this.setMsg(null);
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const plan = [];
        for (const x of dirty) {
          const r = await kit(["push", "--to", x.name, "--dry-run"], SHORT);
          plan.push({ name: x.name, push: x.push, ok: r.code === 0 && !/沒有要送的/.test(r.out), files: sendList(r.out), text: clean([r.out, r.err].filter(Boolean).join("\n")) });
        }
        this.plan = plan;
      } finally { this.endBusy(); cx.notify(); }
    });
  }
  // 送出, step 2: kit push for one source
  push(p, cx) {
    if (!this.startBusy("送出", LONG)) return;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const again = await kit(["push", "--to", p.name, "--dry-run"], SHORT);
        const ok = again.code === 0 && !/沒有要送的/.test(again.out), files = sendList(again.out);
        if (!ok || files !== p.files) {
          const np = { ...p, ok, files, text: clean([again.out, again.err].filter(Boolean).join("\n")) };
          this.plan = (this.plan ?? []).map((x) => (x.name === p.name ? np : x));
          this.setMsg({ ok: false, label: `送出 ${p.name}`, text: "要送的檔案跟剛才列的不一樣了（剛剛有存檔或改過），什麼都沒送。請再看一次下面的清單。", at: Date.now() });
          return;
        }
        const r = await kit(["push", "--to", p.name], LONG);
        let text = clean([r.out, r.err].filter(Boolean).join("\n")) || (r.code === 0 ? "送出了" : `失敗（${r.code}）`);
        if (r.code === 0 && p.push !== "direct" && /PR|分支/.test(text)) text += "\n\n改的檔案現在在送出的分支上：PR 合併、kit sync 之後才會回到這裡。";
        this.setMsg({ ok: r.code === 0, label: `送出 ${p.name}`, text, at: Date.now() });
        this.plan = (this.plan ?? []).filter((x) => x.name !== p.name);
        if (!this.plan.length) this.plan = null;
      } finally { this.endBusy(); this.changed(null); cx.notify(); }
    });
  }

  async moveIntoBar(cx) {
    this.moveErr = null;
    if (Object.values(liveEditors()).some((e) => e.dirty)) {
      this.moveErr = "有大視窗還沒存檔：換版面會把它關掉。先存檔或關掉大視窗，再按一次。";
      cx.notify();
      return;
    }
    try {
      let name = shared("layout");
      if (SHIPPED.includes(name)) {
        // Herdr's own layout can't change shape: work on a copy of it (once; later moves reuse the copy).
        const as = `${name}-kit`;
        try { await run("layout.clone", { name, as }); } catch { await run("layout.switch", { name: as }); }
        for (let i = 0; i < 50 && shared("layout") !== as; i++) await cx.sleep(100);
        if (shared("layout") !== as) throw new Error(`沒有切到 ${as}`);
        name = as;
      }
      const tree = placed(layout());
      if (!tree) { this.moveErr = "這個版面沒有上排分頁列，沒辦法自動放。"; return; }
      await run("layout.set", { layout: tree });
    } catch (e) {
      this.moveErr = `沒放成功：${e?.message ?? e}`;
    } finally { cx.notify(); }
  }

  render(cx) {
    if (this.role === "toggle") return this.renderToggle();
    const t = theme(), z = fs(), msg = this.msg;
    const root = v_flex().id("kit-root").size_full().bg(t.surface).text_size(z).text_color(t.foreground)
      // a popup is as tall as its content, and the list (flex_1) has none of its own: give the popup a height
      .when(this.role === "pane", (el) => el.h(POPUP_H).rounded(8));
    if (this.role === "editor") {
      if (msg) root.child(this.message(t, z, msg));
      return root.child(this.edit ? this.editor(t, z) : div().p(14).child(waiting(t, z, "讀取中…")));
    }
    root.child(this.role === "pane" ? this.paneHeader(t, z) : this.repoHeader(t, z));
    if (this.role === "panel" && !find(layout(), TOGGLE)) root.child(this.moveBanner(t, z));
    if (msg) root.child(this.message(t, z, msg));
    const d = this.data;
    if (!d && this.role === "pane" && !this.loading && Date.now() - (this.openedAt ?? 0) > 8000)
      return root.child(div().p(14).text_color(t.muted).child("讀不到這個 agent（它可能換了資料夾，或已經關掉）。關掉這個視窗，再按一次它上面的 Kit 按鈕。"));
    if (!d) return root.child(div().p(14).child(waiting(t, z, "讀取中…")));
    if (d.error) return root.child(this.problem(t, z, d.error));
    if (this.role === "pane" && d.here?.user) return root.child(v_flex().p(14).gap(6)
      .child(div().font_semibold().child(`這個 agent 用 ${d.here.user} 帳號跑`))
      .child(div().text_size(z - 1).text_color(t.muted).child(d.here.user === "root"
        ? "root 只用簽過的版本（kit approve），這裡看不到也不能改。要換版本：簽一個新的 kit approve，再請它 kit sync。"
        : "這裡只看得到你自己帳號的 kit，看不到也不能改它的。")));
    if (d.kit_version_wanted) root.child(div().flex_none().mx(10).mt(8).p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked)
      .child(`團隊要 kit ${d.kit_version_wanted} 以上，你的是 ${d.kit}。請在終端機打  kit self-update`));
    if (this.role === "pane") return root.child(this.agentList(t, z, d));
    if (this.plan) root.child(this.planCard(t, z));
    return root.child(this.edit ? this.editor(t, z) : this.repo(t, z, d));
  }

  // ---------- the popup: one agent ----------
  paneHeader(t, z) {
    const d = this.data, busy = this.busy, tg = this.target ?? {};
    const where = [tg.machine ?? "這台電腦", shortDir(d?.here?.dir ?? tg.cwd)].filter(Boolean).join(" · ");
    const pic = icon(tg.program, 18, t.foreground), canSync = d && !d.error && !d.here?.user;
    return h_flex().flex_none().px(10).py(8).gap(6).items_center().border_b(1).border_color(t.border)
      .child(div().size(32).flex_none().rounded(16).bg(t.raised).flex().items_center().justify_center().child(pic ?? div().text_color(t.muted).child("•")))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().font_semibold().child(tg.title || "agent"))
        .child(h_flex().gap(5).items_center().min_w(0).when(this.loading, (el) => el.child(spin(z - 3, t.muted)))
          .child(div().truncate().text_size(z - 1.5).text_color(t.muted).child(this.loading ? `${where} · 讀取中…` : where))))
      .when(Boolean(canSync), (el) => el.child(this.btn(t, z, "sync", busy === "同步" ? "同步中…" : "同步", { small: true, off: Boolean(busy), on: (cx) => this.act("同步", ["sync"], cx, LONG) })))
      .child(this.btn(t, z, "reload", this.loading ? spin(z - 2, t.dim) : "⟳", { small: true, off: this.loading, on: () => this.want() }))
      .child(this.btn(t, z, "close", "✕", { small: true, on: () => closeOverlay(blockProps()?.overlay) }));
  }

  agentList(t, z, d) {
    const items = d.items ?? [], here = d.here?.items ?? [], ag = d.here?.agent;
    const machine = this.target?.machine ?? "這台電腦";
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(8);
    const kindName = { rule: "規則", skill: "Skills", mcp: "MCP" };
    // 1. what kit run started it with: only this agent has it, for this run
    if (ag) {
      body.child(div().font_semibold().child(`這次啟動帶的（agent ${ag.name}）`));
      body.child(div().text_size(z - 1.5).text_color(t.muted).child(`用 kit run 開的：只有這個 agent 有，關掉就沒了。要改它，到 Agents 改 ${ag.name}。`));
      for (const [kind, key] of [["rule", "rules"], ["skill", "skills"], ["mcp", "mcp"]]) {
        const names = ag[key] ?? [];
        if (names.length) body.child(h_flex().gap(6).flex_wrap().pl(8).text_size(z - 1)
          .child(div().text_color(t.dim).child(`${kindName[kind]}：`))
          .children(names.map((n) => div().px(6).rounded(4).bg(t.raised).child(n))));
      }
      body.child(div().mt(4).border_t(1).border_color(t.border));
    }
    // 2. what it reads besides: kit's for the whole account (can be taken off) and its folder's / account's own (look only)
    body.child(div().font_semibold().child(ag ? "另外也讀到的" : "這個 agent 在用的"));
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
    // 3. what kit has that the account does not use yet
    const more = items.filter((i) => i.kind !== "agent" && i.status === "unused");
    const news = more.filter((i) => i.new).length;
    if (more.length) {
      const folded = this.folded.paneMore ?? false;
      body.child(div().mt(6).border_t(1).border_color(t.border));
      body.child(this.secHead(t, z, "paneMore", `可以加到整個帳號的（${more.length}）`, folded, news ? `${news} 個新的` : ""));
      if (!folded) body.child(v_flex().gap(2).children(more.map((i) => this.row(t, z, i))));
    }
    body.child(div().mt(6).p(8).rounded(6).bg(t.raised).text_size(z - 1.5).text_color(t.muted)
      .child(`「加到整個帳號」「從帳號拿掉」改的是 ${machine} 上你這個帳號的全部：Claude Code、Codex、omp（有裝的）和每個 agent 都會一起有或一起沒有，不只這一個。只想給某個 agent，請點 kit run 開的 agent，在它的視窗按「加上」。正在跑的要重開才會讀到。`));
    if (!items.length && !here.length && !ag) body.child(div().text_color(t.muted).child("來源裡還沒有東西。"));
    return body;
  }

  secHead(t, z, id, title, folded, note) {
    return h_flex().id(`sec-${id}`).gap(6).items_center().cursor_pointer().on_mouse_down("left", stop)
      .on_click((_e, cx) => { this.folded[id] = !folded; this.save("folded", JSON.stringify(this.folded)); cx.notify(); })
      .child(div().w(12).text_color(t.muted).child(folded ? "▸" : "▾"))
      .child(div().text_size(z - 0.5).child(title))
      .when(Boolean(note), (el) => el.child(div().px(5).rounded(4).text_size(z - 3).bg(t.done).text_color(t.background).child(note)));
  }

  // something the agent reads that kit doesn't manage: its folder's (CLAUDE.md, .claude/…, .mcp.json) or the account's own
  hereRow(t, z, i) {
    const badge = (text) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(t.muted).child(text);
    const head = h_flex().gap(5).items_center().min_w(0)
      .child(div().min_w(0).truncate().font_semibold().child(shortDir(i.name)))
      .child(badge(i.scope === "user" ? "這個帳號（不是 kit 的）" : "這個資料夾"));
    if (i.tools && i.tools !== "claude") head.child(badge(i.tools === "codex omp" ? "Codex／omp" : i.tools));
    const sub = i.description || shortDir(i.path);
    return v_flex().id(`here-${i.scope}-${i.kind}-${i.path}-${i.name}`).px(8).py(4).gap(1).rounded(6).hover((s) => s.bg(t.hover))
      .child(head)
      .when(Boolean(sub), (el) => el.child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child(sub)));
  }

  // one of kit's things for the account: in use (從帳號拿掉), required (拿不掉) or not (加到整個帳號)
  row(t, z, i) {
    const busy = Boolean(this.busy);
    const badge = (text, color) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(color).child(text);
    const head = h_flex().gap(5).items_center().min_w(0)
      .child(div().min_w(0).truncate().font_semibold().text_color(i.status === "unused" ? t.muted : t.foreground).child(i.name));
    if (i.status === "required") head.child(badge("Kit · 團隊必備", t.accent));
    if (i.status === "used") head.child(badge("Kit · 整個帳號", t.working));
    if (i.new) head.child(badge("新", t.done));
    let action;
    if (i.status === "required") action = div().flex_none().text_size(z - 1.5).text_color(t.dim).child("拿不掉");
    else if (i.status === "used") action = this.btn(t, z, `rm-${i.kind}-${i.name}`, "從帳號拿掉", { small: true, off: busy, on: (cx) => this.act(`從帳號拿掉 ${i.name}`, ["rm", i.kind, i.name], cx) });
    else action = this.btn(t, z, `add-${i.kind}-${i.name}`, "加到整個帳號", { small: true, kind: "primary", off: busy, on: (cx) => this.act(`加到整個帳號 ${i.name}`, ["add", i.kind, i.name], cx) });
    const sub = [i.description, i.source].filter(Boolean).join(" · ");
    return h_flex().id(`row-${i.kind}-${i.name}`).gap(8).items_center().px(8).py(5).rounded(6).hover((s) => s.bg(t.hover))
      .child(v_flex().flex_1().min_w(0).gap(1)
        .child(head)
        .when(Boolean(sub), (el) => el.child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child(sub))))
      .child(action);
  }

  // ---------- the repository ----------
  repoHeader(t, z) {
    const d = this.data, busy = this.busy, inBar = Boolean(find(layout(), TOGGLE));
    const dirty = d?.dirty ?? [], nItems = dirty.reduce((a, x) => a + x.items, 0), nAgents = dirty.reduce((a, x) => a + x.agents, 0);
    const what = [nItems ? `規則／skill／MCP ${nItems} 個檔案` : "", nAgents ? `agent ${nAgents} 個` : ""].filter(Boolean).join("、");
    const sub = what ? `改過${what}，還沒送出` : d && !d.error ? `${(d.items ?? []).length} 樣` : "規則、skill、MCP 都在這裡";
    const head = h_flex().px(10).py(8).gap(6).items_center()
      .child(div().size(32).flex_none().rounded(8).bg(t.raised).flex().items_center().justify_center().font_semibold().text_size(z - 1).child("Kit"))
      .child(v_flex().flex_1().min_w(0)
        .child(div().truncate().font_semibold().child("倉庫"))
        .child(h_flex().gap(5).items_center().min_w(0).when(this.loading, (el) => el.child(spin(z - 3, t.muted)))
          .child(div().truncate().text_size(z - 1.5).text_color(what ? t.working : t.muted).child(this.loading ? `${sub} · 讀取中…` : sub))))
      .when(Boolean(what) && !this.plan, (el) => el.child(this.btn(t, z, "push", busy === "檢查" ? "檢查中…" : "送出…", { small: true, kind: "primary", off: Boolean(busy), on: (cx) => this.planPush(cx) })))
      .child(this.btn(t, z, "sync", busy === "同步" ? "同步中…" : "同步", { small: true, off: Boolean(busy), on: (cx) => this.act("同步", ["sync"], cx, LONG) }))
      .child(this.btn(t, z, "reload", this.loading ? spin(z - 2, t.dim) : "⟳", { small: true, off: this.loading, on: (cx) => this.refresh(cx) }))
      .when(inBar, (el) => el.child(this.btn(t, z, "hide", "✕", { small: true, on: () => run("layout.hide", { id: PANEL }) })));
    const v = v_flex().flex_none().border_b(1).border_color(t.border).child(head);
    // each source and what 送出 does with it
    const srcs = d?.sources ?? [];
    if (srcs.length) v.child(h_flex().px(10).pb(8).gap(4).flex_wrap().items_center().text_size(z - 2)
      .children(srcs.map((s) => h_flex().gap(4).px(6).py(1).rounded(5).bg(t.raised).items_center()
        .child(div().text_color(t.foreground).child(s.name))
        .when(Boolean(PUSH_KIND[s.push]), (el) => el.child(div().text_color(s.push === "pr" ? t.accent : t.dim).child(PUSH_KIND[s.push]))))));
    return v;
  }

  // 送出: what each source would send, and 確定送出 per source
  planCard(t, z) {
    const busy = Boolean(this.busy);
    const card = v_flex().flex_none().mx(10).mt(8).p(10).gap(8).rounded(8).bg(t.raised).border_1().border_color(t.accent)
      .child(h_flex().items_center().child(div().flex_1().font_semibold().child("送出前看一下"))
        .child(this.btn(t, z, "plan-cancel", "取消", { small: true, on: (cx) => { this.plan = null; cx.notify(); } })));
    for (const p of this.plan) card.child(v_flex().gap(4)
      .child(h_flex().gap(6).items_center()
        .child(div().flex_1().font_semibold().child(p.name))
        .when(Boolean(PUSH_KIND[p.push]), (el) => el.child(div().text_size(z - 2).text_color(t.muted).child(PUSH_KIND[p.push])))
        .when(p.ok, (el) => el.child(this.btn(t, z, `push-${p.name}`, this.busy === "送出" ? "送出中…" : "確定送出", { small: true, kind: "primary", off: busy, on: (cx) => this.push(p, cx) }))))
      .child(div().p(6).rounded(6).bg(t.background).font_family(mono()).text_size(z - 2).text_color(p.ok ? t.foreground : t.ansi1).child(p.text || "（kit 沒說什麼）")));
    return card;
  }

  // tabs per kind, + 新增, a search, the list; a row opens the file in the editor
  repo(t, z, d) {
    const items = d.items ?? [], f = this.filter;
    const tabs = [["rule", "規則"], ["skill", "Skills"], ["mcp", "MCP"]];
    const kind = tabs.some(([k]) => k === this.kind) ? this.kind : "skill";
    const box = v_flex().flex_1().min_h(0);
    box.child(h_flex().flex_none().px(10).pt(8).gap(4).items_center().children(tabs.map(([k, label]) => {
      const on = k === kind, n = items.filter((i) => i.kind === k).length, ch = items.filter((i) => i.kind === k && i.changed).length;
      return h_flex().id(`tab-${k}`).h(28).px(10).gap(5).items_center().rounded(6).cursor_pointer()
        .bg(on ? t.selected : t.surface).text_color(on ? t.foreground : t.muted).font_semibold()
        .hover((st) => st.bg(t.hover)).on_mouse_down("left", stop)
        .on_click((_e, cx) => { this.kind = k; this.save("kind", k); this.making = null; cx.notify(); })
        .child(label).child(div().text_size(z - 2).text_color(t.dim).child(String(n)))
        .when(ch > 0, (el) => el.child(div().size(6).rounded(3).bg(t.working)));
    })).child(div().flex_1())
      .child(this.btn(t, z, "new", "＋ 新增", { small: true, on: (cx) => {
        this.making = this.making ? null : { source: (d.sources ?? [])[0]?.name ?? null, mode: "write", look: null, pick: 0 };
        if (this.making) this.newName.focus();
        cx.notify();
      } })));
    box.child(div().flex_none().px(10).pt(8).child(Input.new(this.input).h(30).px(8).rounded(6).border_1().border_color(t.border)
      .bg(t.background).text_size(z - 1).text_color(t.foreground)));
    const hit = (...xs) => !f || xs.some((x) => String(x ?? "").toLowerCase().includes(f));
    const rows = items.filter((i) => i.kind === kind && hit(i.name, i.description, i.source))
      .sort((a, b) => (b.changed - a.changed) || (b.new - a.new) || a.name.localeCompare(b.name));
    const body = v_flex().flex_1().min_h(0).overflow_y_scrollbar().px(10).py(8).gap(2);
    if (this.making) body.child(this.maker(t, z, d, kind));   // in the scroll area: a long one (a skill looked at) can be scrolled
    for (const i of rows) body.child(this.repoRow(t, z, i));
    if (!rows.length) body.child(div().p(8).text_color(t.muted).child(f ? "找不到符合的。" : "這一類還沒有東西，按「＋ 新增」寫一個。"));
    return box.child(body);
  }

  // + 新增: write a new one from scratch (a name, which source; kit new makes the file and the editor opens it),
  // or, for skills, collect someone else's from a URL (kit collect --look shows what it would take, then kit collect).
  // Every step says where the file goes and what comes next.
  maker(t, z, d, kind) {
    const srcs = d.sources ?? [], m = this.making, cur = m.source, src = srcs.find((x) => x.name === cur);
    const what = { rule: "規則", skill: "skill", mcp: "MCP" }[kind];
    const mode = kind === "skill" ? m.mode : "write";
    const note = (text, color) => div().text_size(z - 1.5).text_color(color ?? t.muted).child(text);
    const chip = (id, label, on, click) => div().id(id).px(8).py(3).rounded(5).text_size(z - 1.5).cursor_pointer()
      .bg(on ? t.selected : t.surface).text_color(on ? t.foreground : t.muted).border_1().border_color(on ? t.accent : t.border)
      .on_mouse_down("left", stop).on_click((_e, cx) => click(cx)).child(label);
    const box = v_flex().flex_none().mb(8).p(10).gap(8).rounded(8).bg(t.raised)
      .child(div().font_semibold().child(`新增${what}`));
    if (kind === "skill") box.child(h_flex().gap(4)
      .child(chip("mode-write", "自己從頭寫", mode === "write", (cx) => { m.mode = "write"; this.newName.focus(); cx.notify(); }))
      .child(chip("mode-collect", "從網址收別人的", mode === "collect", (cx) => { m.mode = "collect"; this.newUrl.focus(); cx.notify(); })));
    if (mode === "collect") box.child(v_flex().gap(3).child(note("網址（GitHub 之類的 repo）", t.dim))
      .child(Input.new(this.newUrl).h(30).px(8).rounded(6).border_1().border_color(t.accent).bg(t.background).text_size(z - 1).text_color(t.foreground))
      .child(note("kit 會下載這個 repo，找出裡面的 skill（有 SKILL.md 的資料夾），連同原作者的 LICENSE 收進你的倉。", t.dim)));
    else {
      const hint = { skill: "之後在 Claude 打 /名字、Codex 打 $名字 叫它", rule: "只是用來認它的名字；規則的內容每次都會給 agent", mcp: "MCP server 的名字" }[kind];
      box.child(v_flex().gap(3).child(note("名字（小寫英文、數字和 -）", t.dim))
        .child(Input.new(this.newName).h(30).px(8).rounded(6).border_1().border_color(t.accent).bg(t.background).text_size(z - 1).text_color(t.foreground))
        .child(note(hint, t.dim)));
    }
    if (srcs.length) box.child(v_flex().gap(4)
      .child(note("放在哪個倉", t.dim))
      .child(h_flex().gap(4).flex_wrap().children(srcs.map((x) => chip(`to-${x.name}`, PUSH_KIND[x.push] ? `${x.name}（${PUSH_KIND[x.push]}）` : x.name,
        x.name === cur, (cx) => { m.source = x.name; m.look = null; cx.notify(); })))));
    if (mode === "write") {
      const name = this.newName.value().trim() || "名字";
      const rel = { rule: `rules/${name}.md`, skill: `skills/${name}/SKILL.md`, mcp: `mcp/${name}.yaml` }[kind];
      if (src?.dir) box.child(note(`會建立 ${shortDir(src.dir)}/${rel}，然後在這裡打開讓你寫。`, t.foreground));
      box.child(note(`寫完存檔 → 上排「送出…」送上去 → 要用它就到 Agents 視窗按「加到整個帳號」。`));
      return box.child(h_flex().gap(6)
        .child(this.btn(t, z, "make", "建立並打開", { small: true, kind: "primary", off: Boolean(this.busy), on: (cx) => this.make(cx) }))
        .child(this.btn(t, z, "make-cancel", "取消", { small: true, on: (cx) => { this.making = null; cx.notify(); } })));
    }
    const lk = m.look;
    box.child(h_flex().gap(6)
      .child(this.btn(t, z, "look", this.busy === "下載" ? "下載中…" : lk ? "重新下載" : "下載看看", { small: true, kind: lk ? undefined : "primary", off: Boolean(this.busy), on: (cx) => this.look(cx) }))
      .child(this.btn(t, z, "make-cancel", "取消", { small: true, on: (cx) => { this.making = null; cx.notify(); } })));
    if (m.urlErr) box.child(note(m.urlErr, t.ansi1));
    if (!lk && this.busy === "下載") return box.child(this.working(t, z, "下載中：大的 repo 可能要一兩分鐘…"));
    if (!lk) return box.child(note("先下載看看：kit 只會列出找到什麼，還不會放進你的倉。", t.dim));
    const sk = lk.skills ?? [], i = Math.min(m.pick ?? 0, Math.max(sk.length - 1, 0)), x = sk[i];
    const card = v_flex().gap(5).p(8).rounded(6).bg(t.background);
    if (sk.length > 1) card.child(note(`這個 repo 有 ${sk.length} 個 skill，選一個：`, t.foreground))
      .child(h_flex().gap(4).flex_wrap().children(sk.map((y, j) => chip(`pick-${j}`, y.name, j === i, (cx) => { m.pick = j; cx.notify(); }))));
    if (!x) return box.child(card.child(note("找不到 skill。", t.ansi1)));
    // every line first, then the head with its button: an element can be added to a parent only once
    const scripts = String(x.scripts ?? "").split(" ").filter(Boolean), desc = String(x.description ?? "");
    const lines = [];
    let block = null, label = "收進來", allow = false;
    if (desc) lines.push(note(desc.length > 180 ? desc.slice(0, 180).trimEnd() + " …" : desc));
    lines.push(note(x.license ? `授權：${x.license}${x.license === "unknown" ? "（認不出種類，收進來後請自己看 LICENSE）" : x.license === "GPL" ? "（改了再發布要公開原始碼）" : ""}` : "沒有 LICENSE：不知道能不能用，kit 不收。",
      x.license ? t.foreground : t.ansi1));
    if (!x.license) block = "沒有 LICENSE";
    if (scripts.length) lines.push(note(`⚠ 有 ${scripts.length} 個會執行的程式（${scripts.slice(0, 3).join("、")}${scripts.length > 3 ? " …" : ""}），送出前請看過。`, t.working));
    if (x.skipped) lines.push(note(`${x.skipped} 個圖片、捷徑之類的非文字檔不會收。`, t.dim));
    if (!x.valid) { block = "名字不行"; lines.push(note(`名字 ${x.name} 不能用（只能小寫英文、數字和 -）：請用指令 kit collect … --name 換名字。`, t.ansi1)); }
    if (x.exists === "own") { block = "已經有同名的"; lines.push(note(`${lk.source} 已經有你自己的 ${x.name}，不會蓋掉它。要收請用指令 kit collect … --name 換名字。`, t.ansi1)); }
    if (x.exists === "collected") lines.push(note(`之前收過 ${x.name}：會整份換成這次下載的版本。`, t.working));
    lines.push(note(`會放到 ${shortDir(slash(x.dest).replace(/\/SKILL\.md$/, "/"))}`, t.foreground));
    if (!lk.allowed && lk.can_allow) { allow = true; label = "加進清單並收進來";
      lines.push(note(`${lk.id} 還不在 ${lk.source} 的允許清單（kit.yaml 的 collect_sources）。按下去會一起加進清單，之後這個作者的東西就能收。`, t.working)); }
    else if (!lk.allowed) { block = block ?? "不在允許清單";
      lines.push(note(`${lk.id} 不在 ${lk.source} 的允許清單。這是團隊的倉，要請維護者把它加進 kit.yaml 的 collect_sources 才能收。`, t.ansi1)); }
    lines.push(note("收進來後：用 git diff 看收了哪些檔案 → 上排「送出…」送上去 → 要用它就到 Agents 視窗按「加到整個帳號」。"));
    const act = block ? div().flex_none().text_size(z - 2).text_color(t.ansi1).child(`不能收：${block}`)
      : this.btn(t, z, "collect", this.busy === "收" ? "收進來中…" : label, { small: true, kind: "primary", off: Boolean(this.busy), on: (cx) => this.collect(x, allow, cx) });
    card.child(h_flex().gap(6).items_center()
        .child(div().font_semibold().child(x.name))
        .child(div().flex_1().text_size(z - 2).text_color(t.dim).child(x.path === "." ? "（在 repo 最外層）" : `（在 ${x.path}/）`))
        .child(act))
      .children(lines);
    if (this.busy === "收") card.child(this.working(t, z, "收進來中：下載、複製檔案…"));
    return box.child(card);
  }

  // 下載看看: kit collect --look (only looks; nothing is written)
  look(cx) {
    const m = this.making, url = this.newUrl.value().trim();
    if (!m) return;
    if (!url) { m.urlErr = "先在上面貼上網址（灰字只是例子）"; this.newUrl.focus(); cx.notify(); return; }
    if (!this.startBusy("下載", SHORT)) return;
    m.look = null; m.pick = 0;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await kit(["collect", url, "--look", ...(m.source ? ["--to", m.source] : [])], SHORT);
        if (r.code !== 0) { this.setMsg({ ok: false, label: "下載看看", text: clean(r.err || r.out), at: Date.now() }); return; }
        try { m.look = JSON.parse(r.out); this.setMsg(null); }
        catch { this.setMsg({ ok: false, label: "下載看看", text: "kit collect --look 的輸出讀不懂（kit 太舊？請打 kit self-update）", at: Date.now() }); }
      } finally { this.endBusy(); cx.notify(); }
    });
  }

  // 收進來: kit collect at the commit just looked at's URL, the folder picked, --allow when it was offered; then open it
  collect(x, allow, cx) {
    const m = this.making, lk = m?.look;
    if (!lk) return;
    if (!this.startBusy("收", LONG)) return;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await kit(["collect", lk.url, "--to", lk.source, "--path", x.path, ...(allow ? ["--allow"] : [])], LONG);
        if (r.code !== 0) { this.setMsg({ ok: false, label: "收進來", text: clean(r.err || r.out), at: Date.now() }); return; }
        this.making = null;
        this.newUrl.set_value("");
        this.setMsg({ ok: true, label: "收進來", text: clean([r.out, r.err].filter(Boolean).join("\n")), at: Date.now() });
        const seq = (shared(LOAD)?.seq ?? 0) + 1;
        setShared(LOAD, { seq, at: Date.now(), done: false });
        const d = await loadRepo();
        if ((shared(LOAD)?.seq ?? 0) === seq) { setShared(DATA, d); setShared(LOAD, { seq, at: Date.now(), done: true }); }
        const it = (d.items ?? []).find((i) => i.kind === "skill" && i.name === x.name);
        if (it) await this.openItem(it, cx);
      } finally { this.endBusy(); cx.notify(); }
    });
  }

  make(cx) {
    const name = this.newName.value().trim(), kind = this.kind, to = this.making?.source;
    if (!name) return;
    if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) { this.setMsg({ ok: false, label: "新增", text: "名字只能用小寫英文、數字和 -", at: Date.now() }); cx.notify(); return; }
    if (!this.startBusy("新增", SHORT + LOAD_TTL)) return;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await kit(["new", kind, name, ...(to ? ["--to", to] : [])], SHORT);
        if (r.code !== 0) { this.setMsg({ ok: false, label: "新增", text: clean(r.err || r.out), at: Date.now() }); return; }
        this.making = null;
        this.newName.set_value("");
        this.setMsg(null);
        const seq = (shared(LOAD)?.seq ?? 0) + 1;
        setShared(LOAD, { seq, at: Date.now(), done: false });
        const d = await loadRepo();
        if ((shared(LOAD)?.seq ?? 0) === seq) { setShared(DATA, d); setShared(LOAD, { seq, at: Date.now(), done: true }); }
        const it = (d.items ?? []).find((i) => i.kind === kind && i.name === name);
        if (it) await this.openItem(it, cx);
      } finally { this.endBusy(); cx.notify(); }
    });
  }

  // a row: name, marks (改過 / 新 / 團隊必備), what it is and where from; click to open it
  repoRow(t, z, i) {
    const badge = (text, color) => div().flex_none().px(5).rounded(4).text_size(z - 2.5).text_color(t.background).bg(color).child(text);
    return h_flex().id(`repo-${i.kind}-${i.name}`).gap(8).items_center().px(8).py(6).rounded(6).cursor_pointer()
      .hover((s) => s.bg(t.hover)).on_mouse_down("left", stop)
      .on_click((_e, cx) => cx.spawn(async (cx) => { await this.openItem(i, cx); cx.notify(); }))
      .child(v_flex().flex_1().min_w(0).gap(1)
        .child(h_flex().gap(5).items_center().min_w(0)
          .child(div().min_w(0).truncate().font_semibold().child(i.name))
          .when(Boolean(i.changed), (el) => el.child(badge("改過", t.working)))
          .when(Boolean(i.new), (el) => el.child(badge("新", t.done)))
          .when(i.status === "required", (el) => el.child(badge("團隊必備", t.accent))))
        .child(div().min_w(0).truncate().text_size(z - 1.5).text_color(t.muted).child([i.description, i.src].filter(Boolean).join(" · ") || "（還沒寫說明）")))
      .child(div().flex_none().text_color(t.dim).child("›"));
  }

  // ---------- one file in the editor (in the panel, or its own window) ----------
  async openItem(i, cx, value, orig) {
    const text = orig ?? await readTextFile(i.path).catch(() => null);
    if (text === null) { this.setMsg({ ok: false, label: "打開", text: `讀不到 ${shortDir(i.path)}`, at: Date.now() }); return; }
    this.code?.release();
    const th = theme();
    this.code = EditorState.new({ language: i.kind === "mcp" ? "yaml" : "md", value: value ?? text, soft_wrap: true,
      font_family: settings().font_family, font_size: 12,
      syntax: { keyword: th.ansi5, string: th.ansi2, comment: th.dim, function: th.ansi4, type: th.ansi3, number: th.ansi1, constant: th.ansi6 } });
    this.edit = { item: i, orig: text, dirty: value != null && value !== text, err: null, saved: false };
    this.mark();
    this.code.on("change", (_e, cx) => {
      const dirty = this.code.value() !== this.edit?.orig;
      if (this.edit && dirty !== this.edit.dirty) { this.edit.dirty = dirty; this.mark(); cx.notify(); }
    });
  }
  // a big window says which file it holds and whether it has unsaved edits (so 放大 never replaces those)
  mark() {
    if (this.role !== "editor" || !this.edit) return;
    setShared(EDITORS, { ...(shared(EDITORS) ?? {}), [this.edit.item.path]: { dirty: this.edit.dirty, at: Date.now() } });
  }

  // the open file moves to a big window (what you typed goes along, saved or not); the panel goes back to its list
  enlarge(cx) {
    const e = this.edit;
    if (!e) return;
    if (liveEditors()[e.item.path]?.dirty) {
      this.setMsg({ ok: false, label: "放大", text: "這個檔案已經開在大視窗裡，還沒存檔。先去那裡存檔或關掉。", at: Date.now() });
      cx.notify();
      return;
    }
    openOverlay({ mod: "kit", kind: "window", key: `kit-editor:${e.item.path}`, width: 0.7, height: 0.85,
      props: { role: "editor", item: e.item, orig: e.orig, value: this.code.value() } });
    this.closeItem(cx);
  }

  closeItem(cx) {
    this.code?.release();
    this.code = null;
    this.edit = null;
    cx.notify();
  }

  saveItem(cx) {
    const e = this.edit;
    if (!e?.dirty) return;
    const text = this.code.value();
    cx.spawn(async (cx) => {
      try {
        await writeTextFile(e.item.path, text, e.orig);
        e.orig = text; e.dirty = false; e.err = null; e.saved = true;
        this.mark();
        this.changed(null);
      } catch {
        e.err = "這個檔案在別的地方被改過了。先複製你改的，按「重新讀取」，再貼回去。";
      }
      cx.notify();
    });
  }

  // its name and place, 存檔 / 放大 / 重新讀取 / 用編輯器開, then the editor
  editor(t, z) {
    const e = this.edit, i = e.item, big = this.role === "editor";
    const leave = big
      ? this.btn(t, z, "back", e.dirty ? "✕ 不存，關掉" : "✕ 關掉", { small: true, on: () => closeOverlay(blockProps()?.overlay) })
      : this.btn(t, z, "back", e.dirty ? "← 不存，回去" : "← 回去", { small: true, on: (cx) => this.closeItem(cx) });
    const unsent = e.saved || i.changed;
    return v_flex().flex_1().min_h(0)
      .child(h_flex().flex_none().px(10).py(8).gap(6).items_center().border_b(1).border_color(t.border)
        .child(leave)
        .child(v_flex().flex_1().min_w(0)
          .child(div().truncate().font_semibold().child(i.name))
          .child(div().truncate().text_size(z - 2).text_color(t.muted).child(`${i.src ?? i.source} · ${i.rel || shortDir(i.path)}`)))
        .when(!big, (el) => el.child(this.btn(t, z, "bigger", "⤢ 放大", { small: true, on: (cx) => this.enlarge(cx) })))
        .child(this.btn(t, z, "save", e.dirty ? "存檔" : "已存", { small: true, kind: "primary", off: !e.dirty, on: (cx) => this.saveItem(cx) })))
      .when(Boolean(e.err), (el) => el.child(div().flex_none().mx(10).mt(8).p(8).rounded(6).bg(t.raised).text_size(z - 1).text_color(t.blocked).child(e.err)))
      .child(Editor.new(this.code).flex_1().min_h(0))
      .child(h_flex().flex_none().px(10).py(6).gap(6).items_center().border_t(1).border_color(t.border)
        .child(div().flex_1().text_size(z - 2).text_color(t.dim).child(e.dirty ? "還沒存檔" : unsent ? "存好了，還沒送出（倉庫上面的「送出…」）" : ""))
        .child(this.btn(t, z, "reload-file", "重新讀取", { small: true, on: (cx) => cx.spawn(async (cx) => { await this.openItem(i, cx); cx.notify(); }) }))
        .child(this.btn(t, z, "outside", "用編輯器開", { small: true, on: () => { openOutside(i.path).catch(() => {}); } })));
  }

  // ---------- shared pieces ----------
  moveBanner(t, z) {
    return v_flex().flex_none().px(12).py(10).gap(6).bg(t.raised).border_b(1).border_color(t.border)
      .child(div().text_size(z - 1).text_color(this.moveErr ? t.blocked : t.muted).child(this.moveErr ?? "這個面板還在版面最外面。按下面的按鈕，會放進上排（Agents、Kit 兩顆按鈕，按了開關面板），每個 agent 視窗上也會有 Kit 按鈕。"))
      .child(h_flex().child(this.btn(t, z, "move", "放進上排", { kind: "primary", on: (cx) => cx.spawn(async (cx) => this.moveIntoBar(cx)) })));
  }

  message(t, z, msg) {
    return h_flex().flex_none().mx(10).mt(8).p(8).gap(8).items_start().rounded(6).bg(t.raised)
      .border_1().border_color(msg.ok ? t.border : t.ansi1)
      .child(div().flex_1().min_w(0).text_size(z - 1).font_family(mono()).text_color(msg.ok ? t.foreground : t.ansi1)
        .child(`${msg.label}：${msg.ok ? "" : "失敗\n"}${msg.text}`))
      .child(div().id("msg-close").flex_none().px(4).cursor_pointer().text_color(t.muted).hover((s) => s.text_color(t.foreground))
        .on_mouse_down("left", stop).on_click((_e, cx) => { this.setMsg(null); cx.notify(); }).child("✕"));
  }

  problem(t, z, text) {
    const notInit = /kit init/.test(text);
    return v_flex().p(14).gap(8)
      .child(div().font_semibold().text_color(t.ansi1).child("kit 出錯了"))
      .child(div().font_family(mono()).text_size(z - 1).child(text))
      .child(div().text_size(z - 1).text_color(t.muted).child(notInit
        ? "第一次用要先在終端機打  kit init <團隊來源的網址>，好了再按上面的 ⟳。"
        : "修好後按上面的 ⟳ 重新讀取。"));
  }

  // working on it: a bar with a piece sliding through it (Herdr animates it; no timer) and what is going on
  working(t, z, text) {
    return v_flex().gap(4)
      .child(div().relative().h(4).w_full().rounded(2).overflow_hidden().bg(t.surface)
        .child(div().absolute().top(0).h(4).w(90).rounded(2).bg(t.accent).loop("left", { from: -90, to: 460, period: 1400 })))
      .child(div().text_size(z - 1.5).text_color(t.muted).child(text));
  }

  btn(t, z, id, label, { kind, on, off, small } = {}) {
    const bg = off ? t.raised : kind === "primary" ? t.solid : t.raised;
    const fg = off ? t.dim : kind === "primary" ? t.solid_foreground : t.foreground;
    return div().id(id).h(small ? 26 : 30).px(small ? 10 : 12).flex().flex_none().items_center().justify_center().rounded(6)
      .text_size(small ? z - 1 : z).font_semibold().bg(bg).text_color(fg)
      .when(!off, (el) => el.cursor_pointer().hover((st) => st.opacity(0.85)).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); on?.(cx); }))
      .child(withSpin(label, small ? z - 2 : z - 1, fg));
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
        .child("Kit")
        .when(Boolean(badge), (el) => el.child(badge)));
  }
}
