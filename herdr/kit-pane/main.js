// A pane's header with kit's button: what this agent uses (rules, skills, MCP), one click to see and change it.
// `kit herdr-panel install` puts it in the layout in place of Herdr's own pane header ("mod": "pane"),
// and `kit herdr-panel uninstall` puts Herdr's back. Like Herdr's header it shows the program's icon, the
// name, the folder and the agent's status, with split / zoom / close on hover. Props from the app: { pane, terminal }.
// The button runs on the pane's machine:  kit list --json --dir <its folder> --pid <its process>
// and opens the kit mod as a popup (role "pane") for this agent.
import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, spaces, props, run, theme, home, exec, hc, shared, setShared, appHome, readTextFile, window, openOverlay } from "herdr";

const CACHE = "kit.pane.v1";   // shared: key -> { at, text, level } (every header and the popup can see it)
const isWindows = () => window()?.platform === "windows";

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}
function folder(cwd) {
  if (!cwd) return "";
  const h = String(home() ?? "");
  return cwd === h ? "~" : h && cwd.startsWith(h + "/") ? "~" + cwd.slice(h.length) : cwd;
}
// how to run kit: here as kit herdr-panel install wrote it (mods/kit/config.json), on another machine from its PATH
const REMOTE_SH = ["sh", "-c", 'command -v kit >/dev/null 2>&1 && exec kit "$@"; exec "$HOME/.local/bin/kit" "$@"', "kit"];
async function kitHere() {
  const text = await readTextFile(`${String(appHome()).replace(/\\/g, "/")}/mods/kit/config.json`).catch(() => null);
  let c = {};
  try { c = text ? JSON.parse(text) : {}; } catch { c = {}; }
  const kit = Array.isArray(c.kit) && c.kit.length ? c.kit.map(String) : [isWindows() ? "kit.cmd" : "kit"];
  const env = c.env && typeof c.env === "object" ? Object.entries(c.env).map(([k, v]) => `${k}=${v}`) : [];
  return env.length && !isWindows() ? ["/usr/bin/env", ...env, ...kit] : kit;
}
async function kitList(machine, cwd, term) {
  const args = ["list", "--json"];
  if (cwd) args.push("--dir", cwd);
  const g = term ? await hc(["get", term, "--json"]).catch(() => null) : null;
  try { const pid = JSON.parse(g?.stdout ?? "{}").pid; if (pid) args.push("--pid", String(pid)); } catch {}
  for (const argv of machine ? [REMOTE_SH, ["kit.cmd"]] : [await kitHere()]) {
    try {
      const r = await exec(argv[0], [...argv.slice(1), ...args], { timeout: 60000, on: machine });
      if (r.code !== 0) return { error: String(r.stderr || r.stdout || "").trim() };
      return JSON.parse(String(r.stdout));
    } catch (e) { if (!machine) return { error: String(e?.message ?? e) }; }
  }
  return { error: `連不到 ${machine}，或那台沒裝 kit` };
}
// the button's words: how many rules / skills / MCP this agent reads
function summary(d) {
  if (!d) return { text: "…", level: "dim" };
  if (d.error) return { text: "出錯了", level: "bad", why: d.error };
  if (d.here?.user) return { text: `${d.here.user} 唯讀`, level: "dim" };
  const used = (d.items ?? []).filter((i) => i.status === "used" || i.status === "required");
  const own = d.here?.items ?? [];
  const n = (k) => used.filter((i) => i.kind === k).length + own.filter((i) => i.kind === k).length;
  const news = (d.items ?? []).filter((i) => i.new).length;
  return { text: `規則 ${n("rule")} · skill ${n("skill")} · MCP ${n("mcp")}`, level: news ? "new" : "ok", news,
    counts: [["規則", n("rule")], ["skill", n("skill")], ["MCP", n("mcp")]] };
}

export default class KitPane extends View {
  init(_p, cx) {
    this.hovered = false;
    cx.timer.every(15000, (cx) => { this.look(cx); });
    this.look(cx);
  }

  me() { return panes().find((p) => p.pane === props()?.pane); }
  where(p) {
    const sp = spaces().find((s) => (s.tabs ?? []).some((t) => t.id === p.tab));
    const machine = sp?.machine ?? null;
    return { machine, space: sp?.id ?? null, key: `${machine ?? ""}|${p.cwd ?? ""}|${p.terminal}` };
  }

  // ask kit about this agent when it is new or a minute old (one ask at a time per agent, shared by all headers)
  look(cx) {
    const p = this.me();
    if (!p?.terminal || !p.program?.agent) return;
    const w = this.where(p), cache = shared(CACHE) ?? {}, c = cache[w.key];
    if (c && (c.busy && Date.now() - c.at < 90000 || !c.busy && Date.now() - c.at < 60000)) return;
    setShared(CACHE, { ...cache, [w.key]: { ...(c ?? {}), busy: true, at: Date.now() } });
    cx.spawn(async (cx) => {
      const d = await kitList(w.machine, p.cwd, p.terminal);
      setShared(CACHE, { ...(shared(CACHE) ?? {}), [w.key]: { ...summary(d), at: Date.now(), busy: false } });
      cx.notify();
    });
  }

  button(t, id, name, command, args) {
    return div().id(id).p(3).rounded(4).text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => { cx.stop_propagation(); run(command, args); })
      .child(svg(`mods/pane/${name}.svg`).size(14));
  }

  kitButton(t, p) {
    const w = this.where(p), c = (shared(CACHE) ?? {})[w.key];
    const s = c?.text ? c : summary(null);
    const color = s.level === "bad" ? t.blocked : s.level === "dim" ? t.dim : t.muted;
    // [kit | 規則 1  skill 3  MCP 1]: the word kit says what it is, the numbers stand out from their labels
    const body = s.counts
      ? s.counts.map(([label, n]) => h_flex().gap(3).items_center()
        .child(div().text_color(t.dim).child(label))
        .child(div().font_semibold().text_color(n ? t.foreground : t.dim).child(String(n))))
      : [div().text_color(color).child(s.text)];
    return h_flex().id(`kit-btn-${p.pane}`).flex_none().h(22).pl(2).pr(8).gap(7).items_center().rounded(6)
      .bg(t.surface).border_1().border_color(t.border).text_size(11)
      .hover((st) => st.bg(t.hover).border_color(t.accent))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => {
        cx.stop_propagation();
        const target = { key: w.key, term: p.terminal, machine: w.machine, space: w.space, cwd: p.cwd ?? null,
          title: ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || "", program: p.program ?? null };
        openOverlay({ mod: "kit", props: { role: "pane", target }, kind: "popup", width: 440, height: 560 });
      })
      .child(div().h(16).px(5).flex().items_center().rounded(4).bg(t.raised).font_semibold().text_color(t.foreground).child("kit"))
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
