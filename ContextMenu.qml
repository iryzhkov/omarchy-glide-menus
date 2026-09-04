// Glide menus — the Omarchy menu tree as a keyboard-first cascading menu
// with clean, centered motion. A fork of Cantina's omarchy-context-menus;
// the menu model is still a verbatim copy of Omarchy's own MenuModel.js
// reading omarchy-menu.jsonc plus the user extension, so entries, `when:`
// guards and ✓ marks can never drift from the built-in menu.
//
// The interaction model, in the default centered layout:
//
//   * the pane being used always sits mid-screen; ancestors slide one slot
//     left per level, and depth changes animate as one sliding chain
//   * a translucent ghost previews the selected row's submenu on the right
//     — exactly where the real pane materializes on Right/Enter
//   * a selection pill glides between rows, stretching mid-travel
//   * typing searches the whole subtree under the pane (apps included, with
//     breadcrumbs); provider submenus shortlist their top entries otherwise
//   * walking back restores the parked filter and selection of the parent,
//     and the closed pane slides off right instead of vanishing
//
// Three ways in: right-click the desktop (catcher on the Bottom layer), the
// bar button, or a keybinding/IPC summon (omarchy-shell glideMenu toggle).
// The `layoutStyle` setting restores the original anchored cascade.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

Item {
  id: root

  // Injected by omarchy-shell when the plugin is mounted.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "io.github.iryzhkov.glide-menus"
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  readonly property string defaultMenuPath: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  readonly property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"

  // ------------------------------------------------------------- settings
  //
  // Read from this plugin's own entry in ~/.config/omarchy/shell.json, which
  // lands in one of two places depending on how it was enabled: in the bar
  // layout when the bar button is in use, and in `plugins[]` otherwise.
  //
  //   "bar": { "layout": { "left": [
  //     { "id": "io.github.iryzhkov.glide-menus", "desktopRightClick": false }
  //   ] } }
  //
  // Either is read, layout entry first, because that is the one the bar's own
  // settings form writes to. The shell only ever looks at `id` in these
  // entries, so any other key rides along untouched -- which is what makes the
  // entry a plugin's natural settings store.

  readonly property var settings: {
    var config = root.shell ? root.shell.shellConfig : null
    if (!config) return ({})

    var layout = (config.bar && config.bar.layout) ? config.bar.layout : ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var e = 0; e < entries.length; e++) {
        if (entries[e] && String(entries[e].id) === root.pluginId) return entries[e]
      }
    }

    var list = Array.isArray(config.plugins) ? config.plugins : []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && String(list[i].id) === root.pluginId) return list[i]
    }
    return ({})
  }

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return (value === undefined || value === null) ? fallback : value
  }

  readonly property bool animations: root.setting("animations", true) !== false
  readonly property bool summonCentered: String(root.setting("summonPlacement", "center")) !== "pointer"
  // "centered": the deepest pane always sits mid-screen and ancestors slide
  // off to the right; "anchored": the original cascade that grows from the
  // summon point.
  readonly property bool centeredLayout: String(root.setting("layoutStyle", "centered")) !== "anchored"
  readonly property bool escClosesAll: root.setting("escClosesAll", true) !== false
  readonly property bool hoverSelects: root.setting("hoverSelects", false) === true
  readonly property int appsShown: root.finiteNum(root.setting("appsShown", 12), 0, 100, 12)
  readonly property bool desktopRightClick: root.setting("desktopRightClick", true) !== false
  readonly property bool wallpaperDoubleClick: root.setting("wallpaperDoubleClick", true) !== false
  readonly property bool inlineApps: root.setting("inlineApps", true) !== false
  readonly property int submenuDelay: root.finiteNum(root.setting("submenuDelay", 140), 0, 2000, 140)

  // ------------------------------------------------------ input hardening
  //
  // Everything that crosses into this file from outside — menu files, helper
  // process output, IPC arguments, hand-edited settings — is bounded before
  // it is parsed or rendered: byte caps before JSON parsing, row and field
  // caps before entries join the model, finite range clamps on numbers.

  readonly property int maxMenuFileBytes: 2000000
  readonly property int maxModelItems: 10000
  readonly property int maxFieldChars: 512
  readonly property int maxHelperBytes: 1000000
  readonly property int maxProviderRows: 2000
  readonly property int maxAppRows: 3000
  readonly property int maxProbeBytes: 262144
  readonly property int maxFilterChars: 128

  // Exit status a bounded helper uses to report that its producer went over
  // the byte ceiling. It is carried by the process status, never by the data
  // stream, and it is the authoritative overflow signal: the byte count is
  // taken at the producer, before anything is decoded in this process.
  readonly property int helperOverflowExit: 9

  function boundText(value, max) {
    var s = String(value === undefined || value === null ? "" : value)
    return s.length > max ? s.slice(0, max) : s
  }

  function finiteNum(value, lo, hi, fallback) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.min(hi, Math.max(lo, n))
  }

  // Cap entry count and every string field before parsed menu content joins
  // the model.
  function sanitizeEntries(list) {
    if (!Array.isArray(list)) return []
    var out = list.slice(0, root.maxModelItems)
    var fields = ["id", "parent", "kind", "icon", "iconFont", "label", "title",
                  "target", "description", "action", "provider", "when", "checked"]
    for (var i = 0; i < out.length; i++) {
      var e = out[i]
      if (!e) continue
      for (var f = 0; f < fields.length; f++) {
        if (typeof e[fields[f]] === "string" && e[fields[f]].length > root.maxFieldChars)
          e[fields[f]] = e[fields[f]].slice(0, root.maxFieldChars)
      }
      if (Array.isArray(e.aliases)) {
        e.aliases = e.aliases.slice(0, 16)
        for (var a = 0; a < e.aliases.length; a++)
          e.aliases[a] = root.boundText(e.aliases[a], root.maxFieldChars)
      }
    }
    return out
  }

  // Called only for a read whose helper exited 0, which is what proves the
  // file was under the byte ceiling. The length test below is a redundant
  // one-way check: UTF-8 never uses fewer bytes than the string has UTF-16
  // code units, so more code units than maxMenuFileBytes always means more
  // bytes as well. It can never be the reason truncated input is accepted,
  // because it is not what accepts input in the first place.
  function parseMenuText(t) {
    t = String(t || "")
    if (t.length > root.maxMenuFileBytes) {
      console.warn("glide-menus: menu source over " + root.maxMenuFileBytes + " bytes, ignoring")
      return []
    }
    return root.sanitizeEntries(MenuModel.parseMenuJsonc(t))
  }

  // Helper scripts run through fixed absolute executables with a minimal
  // explicit environment (no login shell, no inherited profile) and a hard
  // deadline. GNU timeout puts the child in its own process group and
  // signals the whole group, TERM then KILL, so the tree cannot outlive the
  // deadline; Process reaps on exit.
  function helperCommand(seconds, script) {
    return ["/usr/bin/env", "-i",
      "PATH=/usr/local/bin:/usr/bin:/bin",
      "HOME=" + Quickshell.env("HOME"),
      "USER=" + Quickshell.env("USER"),
      "XDG_RUNTIME_DIR=" + Quickshell.env("XDG_RUNTIME_DIR"),
      "HYPRLAND_INSTANCE_SIGNATURE=" + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"),
      "WAYLAND_DISPLAY=" + Quickshell.env("WAYLAND_DISPLAY"),
      "OMARCHY_PATH=" + root.omarchyPath,
      "/usr/bin/timeout", "--kill-after=2", String(seconds),
      "/bin/bash", "-c", String(script)]
  }

  // The bounded body of a helper: the byte ceiling is enforced *and counted*
  // at the producer, and the verdict is reported out of band as the process
  // exit status, never mixed into the data stream.
  //
  // head caps the stream at capBytes + 1 bytes before anything reaches this
  // process, and kills an unbounded writer with SIGPIPE at the source. tee
  // copies those bytes to the real stdout (fd 4) while wc counts them, so
  // the count is of raw bytes as produced, not of anything this process has
  // decoded. A count above capBytes means the producer had more to say than
  // the ceiling allows, so the helper exits helperOverflowExit and every
  // consumer discards the run before decoding or parsing it.
  //
  // The byte count deliberately does not travel through QML string length.
  // A QML string holds UTF-16 code units, so comparing its length with a
  // byte ceiling under-counts multibyte data and can make truncated output
  // look acceptable; and a byte-truncated tail is not valid UTF-8 anyway, so
  // the decoded length cannot be trusted to reconstruct it.
  function boundedBody(script, capBytes) {
    return "exec 4>&1\n"
      + "n=$({\n" + String(script) + "\n} | /usr/bin/head -c " + (capBytes + 1)
      + " | /usr/bin/tee /dev/fd/4 | /usr/bin/wc -c)\n"
      + "n=${n//[^0-9]/}\n"
      + "[ -n \"$n\" ] || exit " + root.helperOverflowExit + "\n"
      + "[ \"$n\" -gt " + capBytes + " ] && exit " + root.helperOverflowExit + "\n"
      + "exit 0\n"
  }

  function helperPipeline(seconds, script, capBytes) {
    return root.helperCommand(seconds, root.boundedBody(script, capBytes))
  }

  // True when a helper's run may be consumed: it ended on its own terms and
  // its producer stayed under the ceiling. Anything else — a non-zero exit,
  // a crash, a timeout kill, an overflow — fails closed.
  function helperRunUsable(exitCode, exitStatus) {
    return exitCode === 0 && exitStatus === 0
  }

  // Cancellation is an explicit process-group teardown that is verified
  // rather than assumed.
  //
  // GNU timeout makes itself the leader of a new process group and runs the
  // helper tree inside it, so the wrapper's own pid is that group's id.
  // signal(15) therefore delivers TERM to the whole group, and timeout's
  // --kill-after escalates the group to KILL two seconds later. The
  // wrapper's exited signal is the acknowledgement that the wrapper itself
  // is reaped, and every start site refuses to start while running is true,
  // so a helper is never replaced before that acknowledgement arrives.
  //
  // What exited cannot prove is that no descendant escaped the group, so the
  // group id is handed to the sweeper below, which independently KILLs the
  // group and only forgets it once a probe confirms no process in it is left.
  // The sweep runs off to the side: it never delays a fresh helper, because
  // a fresh helper gets a new group of its own.
  property var teardownGroups: []

  function cancelHelper(proc) {
    if (!proc.running) return
    var pgid = proc.processId
    proc.signal(15)
    if (pgid > 0 && root.teardownGroups.indexOf(pgid) < 0) {
      var pending = root.teardownGroups.slice()
      pending.push(pgid)
      root.teardownGroups = pending
      teardownSweep.restart()
    }
  }

  // Long enough for TERM plus timeout's two-second KILL escalation to have
  // run their course, so the usual case is confirmed dead on the first pass.
  Timer {
    id: teardownSweep
    interval: 3500
    repeat: false
    onTriggered: root.sweepTeardownGroups()
  }

  function sweepTeardownGroups() {
    if (root.teardownGroups.length === 0 || reaperProc.running) return
    var groups = root.teardownGroups.slice()
    var list = ""
    for (var i = 0; i < groups.length; i++) list += " " + String(groups[i])
    reaperProc.sweeping = groups
    reaperProc.command = root.helperCommand(5,
        "rc=0\n"
      + "for g in" + list + "; do\n"
      + "  /usr/bin/kill -KILL -- \"-$g\" 2>/dev/null\n"
      + "  /usr/bin/kill -0 -- \"-$g\" 2>/dev/null && rc=1\n"
      + "done\n"
      + "exit $rc\n")
    reaperProc.running = true
  }

  // Forces and then verifies the death of every group a cancellation left
  // behind. rc 0 means no process answered for any of them, which is the
  // proof that the teardown completed; anything else schedules another pass.
  Process {
    id: reaperProc
    property var sweeping: []
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0) {
        var swept = reaperProc.sweeping
        var left = []
        for (var i = 0; i < root.teardownGroups.length; i++)
          if (swept.indexOf(root.teardownGroups[i]) < 0) left.push(root.teardownGroups[i])
        root.teardownGroups = left
      }
      reaperProc.sweeping = []
      if (root.teardownGroups.length > 0) teardownSweep.restart()
    }
  }

  function shellQuoted(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ---------------------------------------------------------------- state

  property bool opened: false

  // Normally the open menu grabs the keyboard (Exclusive layer focus).
  // Scripted demos and tests can release the grab and drive the menu over
  // IPC instead: omarchy-shell glideMenu nav 1 / enter / back.
  property bool grabKeyboard: true

  // Which screen the menu belongs to, and where on it it was summoned. Only
  // the panel for that screen draws anything, so a right-click on the left
  // monitor does not open a menu on the right one.
  property string targetScreen: ""
  property real originX: 0
  property real originY: 0

  // The open cascade, outermost first: one entry per visible pane.
  //   { menuId, x, y, flipX, flipY }
  // Pane 0 is anchored at the summon point; each deeper pane is positioned by
  // the row that opened it (see openChild). flipX/flipY put the pane's right
  // or bottom edge on the anchor instead of its left or top, which is how the
  // bar button cascades upwards off a bottom bar.
  property var panes: []

  // Resolved on-screen geometry per pane, reported by the delegates. The
  // keyboard path has no delegate to ask, so it reads positions from here.
  property var paneGeometry: []

  property var items: ({})
  property var itemOrder: []
  property var defaultItems: []
  property var userItems: []

  property var whenResults: ({})
  property var checkedResults: ({})

  // Type-ahead. Applies to the deepest pane only -- the one the pointer or the
  // keyboard is standing in -- and is cleared whenever that pane changes.
  property string filterText: ""
  property int selectedIndex: -1

  property bool searchProvidersLoaded: false

  onFilterTextChanged: {
    root.selectedIndex = root.filterText.length > 0 ? 0 : -1
    // First keystroke of a search: pull in every provider-backed submenu this
    // plugin can fill (Apps above all), so their rows are searchable too.
    if (root.filterText.length > 0 && !root.searchProvidersLoaded) {
      root.searchProvidersLoaded = true
      Qt.callLater(function() {
        for (var i = 0; i < root.itemOrder.length; i++) {
          var entry = root.item(root.itemOrder[i])
          if (entry && entry.provider && root.providerSupported(entry.provider))
            root.loadProvider(entry.kind === "link" ? entry.target : entry.id)
        }
      })
    }
  }

  // ------------------------------------------------------------- surfaces
  //
  // Shares the [menu] theme tokens, so a theme that styles the built-in menu
  // styles this too without knowing it exists.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(1)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily

  readonly property int paneWidth: Style.space(root.finiteNum(root.setting("paneWidth", 300), 120, 520, 300))
  // Same row metric as the built-in menu card, so the two feel like one
  // family rather than a dense context menu next to an airy launcher.
  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  readonly property int panePadding: Style.spacing.xs
  readonly property int iconColumn: Style.space(30)

  // ---------------------------------------------------------------- data

  function rebuild() {
    var merged = MenuModel.mergeMenuSources(root.defaultItems, root.userItems)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    // A rebuild drops every provider row with it, so anything already showing
    // has to be enumerated again rather than left as a submenu that went empty.
    root.providersLoaded = ({})
    root.evaluateGuards()
    root.loadProvidersForOpenPanes()
  }

  function item(id) {
    return MenuModel.item(root.items, id)
  }

  // Rows of one submenu, in definition order, with hidden entries dropped.
  function rowsFor(menuId) {
    var out = []
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || entry.parent !== menuId) continue
      if (!MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry, 0)) continue
      out.push(entry)
    }
    return out
  }

  // What a pane actually draws: its rows, filtered by the type-ahead when it
  // is the pane being typed at.
  function visibleRows(depth) {
    var spec = root.panes[depth]
    if (!spec) return []

    // The deepest pane filters by the live type-ahead; parents keep showing
    // the filter that was parked on them when their submenu opened.
    var filter = depth === root.panes.length - 1 ? root.filterText : String(spec.filter || "")
    if (!filter) return root.displayRows(spec.menuId)

    // Typing searches the whole subtree under this pane, not just its own
    // rows: "emby" at the root finds the app inside Apps, "theme" finds the
    // Style > Theme submenu. Matches keep definition order.
    var terms = filter.toLowerCase().trim().split(/\s+/)
    var out = []
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry) continue
      if (!root.inSubtree(entry, spec.menuId)) continue
      if (!MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry, 0)) continue
      var haystack = MenuModel.nameSearchText(entry)
      var matched = true
      for (var t = 0; t < terms.length; t++) {
        if (terms[t] && haystack.indexOf(terms[t]) < 0) { matched = false; break }
      }
      if (matched) out.push(entry)
    }
    return out
  }

  // What a pane shows when it is not being searched: provider-filled
  // submenus (Apps above all, fonts too) are shortlisted to the top
  // `appsShown` entries — the provider already ranks them — with a muted
  // hint row pointing at the type-ahead for the rest. Searching always
  // covers the full set.
  function displayRows(menuId) {
    var rows = rowsFor(menuId)
    var entry = root.item(menuId)
    if (root.appsShown > 0 && entry && entry.provider && rows.length > root.appsShown) {
      var out = rows.slice(0, root.appsShown)
      out.push({
        id: menuId + ".__more", parent: menuId, kind: "hint",
        icon: "\uDB80\uDF49", iconFont: "", appIcon: "", appId: "",
        label: "type to search " + (rows.length - root.appsShown) + " more",
        title: "", target: "", description: "", action: "", provider: "",
        aliases: [], when: "", checked: "", order: 0
      })
      return out
    }
    return rows
  }

  // Whether `entry` sits anywhere under `menuId` (its parent chain reaches
  // it). Direct children count; the subtree root itself does not.
  function inSubtree(entry, menuId) {
    var id = entry.parent
    var guard = 0
    while (id && guard < 32) {
      if (id === menuId) return true
      var parent = root.item(id)
      id = parent ? parent.parent : ""
      guard += 1
    }
    return false
  }

  // "Style › Theme" breadcrumb for a search result that lives below the
  // pane being searched, so equal labels from different branches read apart.
  function entryPathLabel(entry, stopAt) {
    var parts = []
    var id = entry.parent
    var guard = 0
    while (id && id !== stopAt && id !== "root" && guard < 8) {
      var parent = root.item(id)
      if (!parent) break
      parts.unshift(parent.label || parent.title || id)
      id = parent.parent
      guard += 1
    }
    return parts.join(" \u203a ")
  }

  // A row that opens another pane. Provider-backed rows count before their
  // contents have loaded -- that is the point of the chevron -- as long as the
  // provider is one this plugin can fill in itself.
  function isSubmenu(entry) {
    if (!entry) return false
    if (entry.kind !== "menu" && entry.kind !== "link") return false
    if (entry.provider) return root.providerSupported(entry.provider)
    return root.rowsFor(entry.kind === "link" ? entry.target : entry.id).length > 0
  }

  function targetOf(entry) {
    return entry.kind === "link" ? entry.target : entry.id
  }

  function notePaneGeometry(depth, x, y, contentY) {
    var next = root.paneGeometry.slice()
    while (next.length <= depth) next.push({ x: 0, y: 0, contentY: 0 })
    next[depth] = { x: x, y: y, contentY: contentY }
    root.paneGeometry = next
  }

  function geometryFor(depth) {
    var known = root.paneGeometry[depth]
    return known ? known : { x: root.originX, y: root.originY, contentY: 0 }
  }

  // ------------------------------------------------------------ lifetime

  function openAt(screenName, x, y) {
    root.openPane(screenName, {
      menuId: "root",
      x: root.finiteNum(x, 0, 32768, 0),
      y: root.finiteNum(y, 0, 32768, 0)
    })
  }

  function openPane(screenName, spec) {
    root.targetScreen = root.boundText(screenName, 128)
    root.originX = spec.x
    root.originY = spec.y
    root.filterText = ""
    root.selectedIndex = -1
    root.paneGeometry = []
    root.panes = [spec]
    root.searchProvidersLoaded = false
    exitClear.stop()
    root.exitSnapshot = null
    root.opened = true
    // Guards are cheap and their answers go stale (is a recording running? is
    // night light on?), so re-run them each time the menu is summoned rather
    // than trusting the set from the last open.
    root.evaluateGuards()
    root.loadProvidersForOpenPanes()
  }

  // Anchor the first pane to a rectangle rather than a point -- the bar button
  // hands us its own, and the menu cascades off whichever edge has the room.
  function openAtAnchor(screenName, x, y, w, h, placement) {
    var spec = {
      menuId: "root",
      x: root.finiteNum(x, 0, 32768, 0),
      y: root.finiteNum(y, 0, 32768, 0),
      flipX: false, flipY: false
    }
    w = root.finiteNum(w, 0, 32768, 0)
    h = root.finiteNum(h, 0, 32768, 0)
    var side = root.boundText(placement || "below", 16)

    if (side === "above") spec.flipY = true
    else if (side === "left") spec.flipX = true
    else if (side === "right") spec.x += Number(w) || 0
    else spec.y += Number(h) || 0

    root.openPane(screenName, spec)
  }

  // Open with a whole branch already expanded, e.g. "style.theme" opens
  // root > Style > Theme as three cascaded panes. Useful for binding a key to
  // a deep part of the tree while keeping the parents visible to browse.
  function openAtRoute(screenName, x, y, menuId) {
    root.openAt(screenName, x, y)

    var route = MenuModel.resolveRoute(root.items, root.itemOrder, root.boundText(menuId, 200))
    var chain = []
    var id = String(route || "")
    var guard = 0
    while (id && id !== "root" && guard < 32) {
      chain.unshift(id)
      var entry = root.item(id)
      id = entry ? entry.parent : ""
      guard += 1
    }

    var next = root.panes.slice(0, 1)
    var px = next[0].x
    var py = next[0].y
    for (var i = 0; i < chain.length; i++) {
      var parentRows = root.displayRows(next[i].menuId)
      var rowIndex = -1
      for (var r = 0; r < parentRows.length; r++) {
        if (parentRows[r].id === chain[i]) { rowIndex = r; break }
      }
      if (rowIndex < 0) break
      px = px + root.paneWidth - Style.space(2)
      py = py + rowIndex * root.rowHeight
      next.push({ menuId: chain[i], x: px, y: py })
    }
    root.panes = next
    root.loadProvidersForOpenPanes()
  }

  // Cancel every non-interactive helper. Each cancellation is the acknowledged
  // group teardown described at cancelHelper: TERM to the group, KILL two
  // seconds later, the wrapper's exited signal as the acknowledgement, and a
  // sweep afterwards that confirms nothing in the group survived.
  function cancelHelpers() {
    pointerProc.cancelled = true
    root.cancelHelper(pointerProc)
    root.cancelHelper(providerProc)
    root.cancelHelper(guardProc)
    root.providerQueue = []
    root.guardsPending = false
  }

  Component.onDestruction: root.cancelHelpers()

  function close() {
    root.cancelHelpers()
    root.opened = false
    root.panes = []
    root.paneGeometry = []
    root.filterText = ""
    root.selectedIndex = -1
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // Truncate the cascade to `depth` panes. Used when the pointer moves to a
  // different row, so stale submenus close instead of piling up.
  // The submenu the current selection points at, previewed as a translucent
  // ghost pane beside the active one before it is entered. Follows keyboard
  // selection and (when hover selects) the pointer.
  readonly property string ghostMenuId: {
    if (!opened || panes.length === 0 || selectedIndex < 0) return ""
    var rows = visibleRows(panes.length - 1)
    var entry = rows[selectedIndex]
    if (!entry || !isSubmenu(entry)) return ""
    return targetOf(entry)
  }
  // Deferred: loading a provider mutates the menu model that the
  // ghostMenuId binding itself reads, so doing it inline is a binding loop.
  onGhostMenuIdChanged: if (ghostMenuId) Qt.callLater(function() {
    if (root.ghostMenuId) root.loadProvider(root.ghostMenuId)
  })

  // The submenu that was just closed by walking back, kept briefly so the
  // pointer landing back on its parent row does not hover-reopen it: the
  // child pane had the hover until it died, and the parent row regaining it
  // restarts the dwell. Click, Enter, and Right still reopen immediately.
  // True while a freshly opened pane is still sliding in from the ghost
  // slot; the next ghost preview waits so the slot holds one thing at a
  // time.
  property bool paneEntering: false
  Timer {
    id: enterClear
    interval: 380
    repeat: false
    onTriggered: root.paneEntering = false
  }
  function noteEntering() {
    root.paneEntering = true
    enterClear.restart()
  }

  // Snapshot of the pane a walk-back just closed, so it can slide right and
  // fade instead of vanishing: the Repeater destroys the real delegate the
  // moment the model shrinks.
  property var exitSnapshot: null
  Timer {
    id: exitClear
    interval: 380
    repeat: false
    onTriggered: root.exitSnapshot = null
  }

  property string recentlyClosedMenu: ""
  Timer {
    id: reopenGuard
    interval: 600
    repeat: false
    onTriggered: root.recentlyClosedMenu = ""
  }

  function truncate(depth) {
    if (root.panes.length <= depth) return
    if (root.panes[depth] && root.panes[depth].menuId) {
      root.recentlyClosedMenu = String(root.panes[depth].menuId)
      reopenGuard.restart()
      if (root.centeredLayout && root.animations && root.opened) {
        var closingGeo = root.geometryFor(depth)
        // Assigned synchronously: the stand-in must exist in the very frame
        // the real pane is destroyed or the hand-off reads as a blink.
        root.exitSnapshot = { menuId: String(root.panes[depth].menuId), y: closingGeo.y }
        exitClear.restart()
      }
    }
    var next = root.panes.slice(0, depth)
    // The pane that becomes deepest takes its parked filter back as the live
    // type-ahead, so walking back up the cascade restores the same filtered
    // view that was left behind.
    var restored = ""
    var restoredSel = -1
    if (depth > 0 && next[depth - 1]) {
      var parked = next[depth - 1]
      if (parked.filter) restored = String(parked.filter)
      if (parked.sel !== undefined) restoredSel = Number(parked.sel)
      if (parked.filter !== undefined || parked.sel !== undefined) {
        next[depth - 1] = Object.assign({}, parked)
        delete next[depth - 1].filter
        delete next[depth - 1].sel
      }
    }
    // Filter first, panes second: both invalidate the surviving pane's rows
    // and height, and doing it in this order keeps the animated properties
    // retargeting toward the final geometry instead of a stale intermediate.
    root.filterText = restored
    root.panes = next
    root.paneGeometry = root.paneGeometry.slice(0, depth)
    // Land back on the row the submenu was opened from, not at the top.
    root.selectedIndex = restoredSel
  }

  function openChild(depth, entry, paneX, paneY, rowY) {
    if (!root.isSubmenu(entry)) {
      root.truncate(depth + 1)
      return false
    }

    var target = root.targetOf(entry)
    // Already open on this exact row -- nothing to do (avoids rebuilding the
    // pane, and losing its scroll position, on every hover event).
    if (root.panes.length > depth + 1 && root.panes[depth + 1].menuId === target) return false

    var next = root.panes.slice(0, depth + 1)
    // Park the live type-ahead and the row we are descending from on this
    // pane, so a walk back up restores both the filtered view and the
    // selection (see truncate).
    var parked = { filter: root.filterText || "" }
    var fromRows = root.visibleRows(depth)
    for (var fr = 0; fr < fromRows.length; fr++) {
      if (fromRows[fr] === entry || fromRows[fr].id === entry.id) { parked.sel = fr; break }
    }
    next[depth] = Object.assign({}, next[depth], parked)
    root.filterText = ""
    next.push({
      menuId: target,
      // Overlap by the border so the cascade reads as one connected surface
      // and the pointer can cross between panes without falling through a gap.
      x: paneX + root.paneWidth - Style.space(2),
      y: paneY + rowY - root.panePadding
    })
    root.paneGeometry = root.paneGeometry.slice(0, depth + 1)
    root.panes = next
    // A quick forward while a demoted pane is still sliding into the ghost
    // slot would show two children at once — the new pane takes that slot
    // now, so the stand-in yields immediately.
    exitClear.stop()
    root.exitSnapshot = null
    root.noteEntering()
    root.loadProvider(target)
    return true
  }

  function activate(depth, entry, paneX, paneY, rowY) {
    if (!entry) return

    if (entry.kind === "app") {
      var appId = entry.appId
      var label = entry.label
      root.dismiss()
      if (root.appLibrary) root.appLibrary.launch(appId, label)
      return
    }

    if (root.isSubmenu(entry)) {
      root.openChild(depth, entry, paneX, paneY, rowY)
      return
    }

    // A provider this plugin cannot fill in itself: hand it to the built-in
    // menu, opened at that route, rather than show an empty pane. Unless this
    // plugin *is* what the built-in menu resolves to -- installed as its
    // replacement -- in which case the handoff would come straight back here.
    if (entry.provider) {
      if (!root.stockMenuAvailable()) return
      root.dismiss()
      Util.execDetached("omarchy-menu summon " + Util.shellQuote(entry.id))
      return
    }

    if (entry.action) {
      root.dismiss()
      Util.execDetached(entry.action)
    }
  }

  // Whether the built-in Omarchy menu is still a separate, reachable plugin.
  // Declaring `clonedFrom` in the manifest disables it and makes the id
  // `omarchy.menu` resolve to this plugin, so anything that would hand work
  // back to it has to ask first or it is talking to itself.
  function stockMenuAvailable() {
    var registry = root.pluginRegistry || (root.shell ? root.shell.pluginRegistry : null)
    if (!registry || typeof registry.resolveEnabledId !== "function") return false
    var resolved = String(registry.resolveEnabledId("omarchy.menu") || "")
    return resolved !== "" && resolved !== root.pluginId
  }

  // `omarchy-menu refresh` and `omarchy-menu ping` reach a plugin through
  // `omarchy-shell shell call omarchy.menu <verb>`, so standing in for the
  // built-in menu means answering to them as well.
  function refresh() {
    root.boundedMenuRead(defaultMenuReader)
    root.boundedMenuRead(userMenuReader)
    root.providersLoaded = ({})
    root.evaluateGuards()
    root.loadProvidersForOpenPanes()
    return "ok"
  }

  function ping() {
    return "ok"
  }

  // ------------------------------------------------------------- keyboard

  function moveSelection(delta) {
    var rows = root.visibleRows(root.panes.length - 1)
    if (rows.length === 0) return
    var next = root.selectedIndex + delta
    if (root.selectedIndex < 0) next = delta > 0 ? 0 : rows.length - 1
    // Walk over inert hint rows; guard against an all-hint pane.
    for (var hops = 0; hops < rows.length; hops++) {
      if (next < 0) next = rows.length - 1
      if (next >= rows.length) next = 0
      if (!rows[next] || rows[next].kind !== "hint") break
      next += delta > 0 ? 1 : -1
    }
    root.selectedIndex = next
  }

  function selectedEntry() {
    var rows = root.visibleRows(root.panes.length - 1)
    if (root.selectedIndex < 0 || root.selectedIndex >= rows.length) return null
    return rows[root.selectedIndex]
  }

  // Where the selected row sits on screen, so a keyboard-opened submenu lands
  // exactly where a hover-opened one would.
  function selectedRowY(depth) {
    return root.selectedIndex * root.rowHeight - root.geometryFor(depth).contentY
      + root.panePadding + (root.filterText.length > 0 ? root.rowHeight : 0)
  }

  function activateSelected() {
    var entry = root.selectedEntry()
    if (!entry) return
    var depth = root.panes.length - 1
    var geometry = root.geometryFor(depth)
    var before = root.panes.length
    root.activate(depth, entry, geometry.x, geometry.y, root.selectedRowY(depth))
    if (root.panes.length > before) root.selectedIndex = 0
  }

  function goBack() {
    if (root.filterText.length > 0) { root.filterText = ""; return }
    if (root.panes.length > 1) root.truncate(root.panes.length - 1)
    else root.dismiss()
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.escClosesAll) root.dismiss()
      else root.goBack()
      event.accepted = true
    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
      root.moveSelection(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
      root.moveSelection(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Home) {
      root.selectedIndex = 0
      event.accepted = true
    } else if (event.key === Qt.Key_End) {
      var endRows = root.visibleRows(root.panes.length - 1)
      var endAt = endRows.length - 1
      while (endAt > 0 && endRows[endAt] && endRows[endAt].kind === "hint") endAt -= 1
      root.selectedIndex = endAt
      event.accepted = true
    } else if (event.key === Qt.Key_Right) {
      var entry = root.selectedEntry()
      if (entry && root.isSubmenu(entry)) root.activateSelected()
      event.accepted = true
    } else if (event.key === Qt.Key_Left) {
      root.goBack()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.activateSelected()
      event.accepted = true
    } else if (event.key === Qt.Key_Backspace) {
      if (root.filterText.length > 0) root.filterText = root.filterText.slice(0, -1)
      else root.goBack()
      event.accepted = true
    } else if (event.text && event.text.length > 0 && event.text.charCodeAt(0) >= 0x20
               && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
      if (root.filterText.length < root.maxFilterChars)
        root.filterText += root.boundText(event.text, 8)
      event.accepted = true
    }
  }

  // ------------------------------------------------------------- sources

  // The FileViews only watch; they never load. Reading goes through a
  // bounded helper instead, and the helper opens the file exactly once and
  // then validates the descriptor it is holding — never the pathname.
  //
  // The pathname is opened first, into fd 3. Everything after that
  // interrogates the open file description through /proc/self/fd/3, which is
  // an fstat of the object actually opened, not a fresh walk of a mutable
  // path, so nothing can be swapped in between a check and the read:
  //
  //   * stat -L reports the opened object's type, owner, link count and
  //     mode. It must be a regular file (a FIFO, device or directory is
  //     refused), owned by this user or by root (the default menu is a
  //     root-owned system file), with exactly one link and no group or
  //     other write bit.
  //   * readlink resolves the descriptor back to the path it really came
  //     from, which must equal the physical form of the path that was asked
  //     for. That is what refuses a symlinked leaf, and it validates the
  //     parent components too, since a redirected directory anywhere along
  //     the path lands the descriptor somewhere else than the one requested.
  //
  // The bytes are then streamed from fd 3 itself, so the file that was
  // validated is exactly the file that is read. A FIFO left at the path
  // blocks the open instead of returning a descriptor; the helper's deadline
  // covers that, and the timeout kill is a non-zero exit like any other
  // rejection. Every failure — a refused open, a failed check, an overflow —
  // yields an empty item list rather than a partial parse.
  function menuReadScript(path) {
    var q = root.shellQuoted(path)
    return "p=" + q + "\n"
      + "{ exec 3< \"$p\" ; } 2>/dev/null || exit 3\n"
      + "i=$(/usr/bin/stat -L -c '%F|%u|%h|%f' /proc/self/fd/3) || exit 3\n"
      + "IFS='|' read -r ftype fuid fnlink fmode <<< \"$i\"\n"
      + "[ \"$ftype\" = 'regular file' ] || exit 3\n"
      + "[ \"$fnlink\" = 1 ] || exit 3\n"
      + "[ \"$fuid\" = \"$(/usr/bin/id -u)\" ] || [ \"$fuid\" = 0 ] || exit 3\n"
      + "(( 0x$fmode & 0022 )) && exit 3\n"
      + "real=$(/usr/bin/readlink /proc/self/fd/3) || exit 3\n"
      + "want=$( { cd -P -- \"${p%/*}\" && pwd -P ; } 2>/dev/null )/${p##*/}\n"
      + "[ \"$real\" = \"$want\" ] || exit 3\n"
      + root.boundedBody("/usr/bin/cat <&3", root.maxMenuFileBytes)
  }

  function boundedMenuRead(proc) {
    if (proc.running) { proc.readPending = true; return }
    proc.readPending = false
    proc.command = root.helperCommand(5, root.menuReadScript(proc.menuPath))
    proc.running = true
  }

  component MenuReadProcess: Process {
    id: reader
    property string menuPath: ""
    property var apply: null
    property bool readPending: false
    stdout: StdioCollector { id: readerCollector }
    // The read is consumed only here, once the helper's exit status has said
    // the descriptor passed every check and the producer stayed under the
    // ceiling. Nothing is parsed from the collector on its own, so the order
    // in which the stream and the process finish cannot let a rejected or
    // truncated read through.
    onExited: function(exitCode, exitStatus) {
      var usable = root.helperRunUsable(exitCode, exitStatus)
      // A rejection is otherwise indistinguishable from an empty menu file,
      // so say which file was refused and how: exit 3 is a failed check on
      // the opened descriptor, helperOverflowExit is a file over the byte
      // ceiling, and anything else is the deadline or a killed helper.
      if (!usable)
        console.warn("glide-menus: refused menu source " + reader.menuPath
                     + " (exit " + exitCode + ", status " + exitStatus + ")")
      if (reader.apply) reader.apply(usable ? root.parseMenuText(readerCollector.text) : [])
      root.rebuild()
      if (reader.readPending) Qt.callLater(function() { root.boundedMenuRead(reader) })
    }
  }

  MenuReadProcess {
    id: defaultMenuReader
    menuPath: root.defaultMenuPath
    apply: function(items) { root.defaultItems = items }
  }

  MenuReadProcess {
    id: userMenuReader
    menuPath: root.userMenuPath
    apply: function(items) { root.userItems = items }
  }

  FileView {
    path: root.defaultMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.boundedMenuRead(defaultMenuReader)
  }

  FileView {
    path: root.userMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.boundedMenuRead(userMenuReader)
  }

  Component.onCompleted: {
    root.boundedMenuRead(defaultMenuReader)
    root.boundedMenuRead(userMenuReader)
  }

  // -------------------------------------------------------------- guards
  //
  // `when:` hides a row and `checked:` appends a ✓. Both are bash. They are
  // batched into a single subprocess by MenuModel.guardScript -- the very one
  // the built-in menu uses -- so opening the menu never waits on a fork per row.

  property bool guardsPending: false

  function evaluateGuards() {
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = root.helperPipeline(10, script, root.maxHelperBytes)
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      // Accumulation only. The ceiling is enforced and reported by the
      // producer, so this stops appending at an absurd size and does not
      // touch the process: cancelling a helper is a teardown with an
      // acknowledgement, never a bare running = false.
      onRead: function(data) {
        if (guardProc.collected.length > root.maxHelperBytes) return
        guardProc.collected += data + "\n"
      }
    }
    onExited: function(exitCode, exitStatus) {
      // A killed batch only reported the rows it reached, and an overflow
      // run arrived truncated; the helper's exit status says which. Keep the
      // last complete answer rather than let a partial one hide rows at
      // random.
      if (!root.helperRunUsable(exitCode, exitStatus)) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  // ----------------------------------------------------------- providers
  //
  // A `provider:` submenu has no children in the JSONC; its rows are
  // enumerated at runtime. The bash ones emit `label\tvalue\tcurrent` per line
  // and are lifted straight from the built-in menu so both agree on what the
  // list is and what picking from it runs. `apps` is native: rows come from
  // the shell's shared AppLibrary, the same one the launcher reads.

  property var providersLoaded: ({})
  property var providerQueue: []

  readonly property var providerSpecs: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function providerSupported(name) {
    var key = String(name || "")
    if (key === "apps") return root.inlineApps && root.appLibrary !== null
    return root.providerSpecs[key] !== undefined
  }

  function markProviderLoaded(id, value) {
    var next = ({})
    for (var key in root.providersLoaded) next[key] = root.providersLoaded[key]
    next[id] = value === true
    root.providersLoaded = next
  }

  function loadProvider(menuId) {
    var entry = root.item(menuId)
    if (!entry || !entry.provider || !root.providerSupported(entry.provider)) return

    if (entry.provider === "apps") {
      if (root.providersLoaded[menuId]) return
      root.markProviderLoaded(menuId, true)
      root.mergeAppRows(menuId)
      return
    }

    var spec = root.providerSpecs[entry.provider]
    // A volatile list may have been reshaped by the last pick from it, so
    // entering the submenu is worth paying for the enumeration again.
    if (root.providersLoaded[menuId] && !spec.volatile) return

    if (providerProc.running) {
      if (root.providerQueue.indexOf(menuId) < 0) root.providerQueue = root.providerQueue.concat([menuId])
      return
    }

    root.markProviderLoaded(menuId, true)
    providerProc.menuId = menuId
    providerProc.providerKey = entry.provider
    providerProc.collected = ""
    providerProc.command = root.helperPipeline(15, spec.script, root.maxHelperBytes)
    providerProc.running = true
  }

  function loadProvidersForOpenPanes() {
    for (var i = 0; i < root.panes.length; i++) root.loadProvider(root.panes[i].menuId)
  }

  function startNextProvider() {
    while (root.providerQueue.length > 0) {
      var queue = root.providerQueue.slice()
      var id = queue.shift()
      root.providerQueue = queue
      var entry = root.item(id)
      if (!entry || !entry.provider) continue
      root.loadProvider(id)
      return
    }
  }

  function mergeProviderRows(text, menuId, providerKey) {
    var spec = root.providerSpecs[providerKey]
    if (!spec) return

    var lines = String(text || "").slice(0, root.maxHelperBytes).split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      if (providerRows.length >= root.maxProviderRows) break
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = root.boundText(parts[0] || "", root.maxFieldChars)
      var value = root.boundText(parts[1] || parts[0] || "", root.maxFieldChars)
      var current = root.boundText(parts[2] || "", root.maxFieldChars)
      if (!label) continue
      // Distinct values can slugify alike -- Fira Code and Fira-Code both give
      // fira-code -- and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + MenuModel.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        iconFont: "",
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }

    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
  }

  // Apps come from the shell's AppLibrary rather than a bash enumeration, so
  // they carry their real icons and launch through the same code path (and the
  // same launch feedback) as the built-in launcher.
  function mergeAppRows(menuId) {
    if (!root.appLibrary) return

    var entries = root.appLibrary.sortedEntries("").slice(0, root.maxAppRows)
    var appRows = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i].entry
      var appId = root.boundText(entry.id || "", root.maxFieldChars)
      if (!appId) continue
      var subtext = root.boundText(root.appLibrary.entrySubtext(entry), root.maxFieldChars)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }

      appRows.push({
        id: menuId + "." + appId,
        parent: menuId,
        kind: "app",
        icon: "",
        iconFont: "",
        appIcon: root.boundText(entry.icon || "", root.maxFieldChars),
        appId: appId,
        label: root.boundText(root.appLibrary.entryName(entry), root.maxFieldChars),
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        order: 0
      })
    }

    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    stdout: SplitParser {
      // Accumulation only, as in guardProc: the producer owns the ceiling.
      onRead: function(data) {
        if (providerProc.collected.length > root.maxHelperBytes) return
        providerProc.collected += data + "\n"
      }
    }
    onExited: function(exitCode, exitStatus) {
      // An overflow run arrived truncated and the exit status says so:
      // discard it and let the submenu retry, rather than merge a half list.
      if (root.helperRunUsable(exitCode, exitStatus))
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
      else
        root.markProviderLoaded(providerProc.menuId, false)
      root.startNextProvider()
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      for (var id in root.providersLoaded) {
        var entry = root.item(id)
        if (entry && entry.provider === "apps" && root.providersLoaded[id]) root.mergeAppRows(id)
      }
    }
  }

  // ----------------------------------------------------------------- IPC

  // Where the pointer is, and which monitor it is on. Asked of Hyprland only
  // when a keybinding opens the menu -- one subprocess on the keypress, which
  // is cheaper than keeping a pointer tracker alive for the whole session.
  Process {
    id: pointerProc
    property string route: "root"
    property bool cancelled: false
    command: root.helperPipeline(3, "hyprctl -j cursorpos; echo '@@'; hyprctl -j monitors", root.maxProbeBytes)
    stdout: StdioCollector { id: pointerCollector }
    // Consumed only on a clean exit, so a truncated or killed probe can
    // never place a menu from a half-read monitor list.
    onExited: function(exitCode, exitStatus) {
      if (!pointerProc.cancelled && root.helperRunUsable(exitCode, exitStatus))
        root.openAtProbedPointer(pointerCollector.text)
    }
  }

  function openAtPointer(route) {
    if (pointerProc.running) return
    pointerProc.cancelled = false
    pointerProc.route = root.boundText(route || "root", 200)
    pointerProc.running = true
  }

  function openAtProbedPointer(text) {
    var parts = String(text || "").split("@@")
    var cursor = null
    var monitors = []
    try { cursor = JSON.parse(parts[0]) } catch (e) { cursor = null }
    try { monitors = JSON.parse(parts[1]) } catch (e) { monitors = [] }
    if (!Array.isArray(monitors) || monitors.length === 0) return

    var chosen = null
    var localX = 0
    var localY = 0

    if (cursor && typeof cursor.x === "number") {
      for (var i = 0; i < monitors.length; i++) {
        var monitor = monitors[i]
        var scale = monitor.scale || 1
        // A 90°/270° transform swaps the panel's own dimensions round before
        // they become the monitor's logical size.
        var rotated = (Number(monitor.transform) || 0) % 2 === 1
        var width = (rotated ? monitor.height : monitor.width) / scale
        var height = (rotated ? monitor.width : monitor.height) / scale
        if (cursor.x >= monitor.x && cursor.x < monitor.x + width
            && cursor.y >= monitor.y && cursor.y < monitor.y + height) {
          chosen = monitor
          localX = cursor.x - monitor.x
          localY = cursor.y - monitor.y
          break
        }
      }
    }

    // No cursor, or it sits in a gap between monitors: fall back to the middle
    // of whichever monitor has focus.
    if (!chosen) {
      for (var f = 0; f < monitors.length; f++) {
        if (monitors[f].focused) { chosen = monitors[f]; break }
      }
      if (!chosen) chosen = monitors[0]
      var fallbackScale = chosen.scale || 1
      localX = (chosen.width / fallbackScale) / 2
      localY = (chosen.height / fallbackScale) / 2
    }

    // Summoned by key or IPC: place the first pane mid-screen rather than
    // under the pointer when so configured. The desktop right-click path
    // never comes through here, so it keeps opening at the click.
    if (root.summonCentered) {
      var cScale = chosen.scale || 1
      var cRotated = (Number(chosen.transform) || 0) % 2 === 1
      var cWidth = (cRotated ? chosen.height : chosen.width) / cScale
      var cHeight = (cRotated ? chosen.width : chosen.height) / cScale
      var approxH = Math.max(1, root.rowsFor("root").length) * root.rowHeight + root.panePadding * 2
      localX = Math.max(Style.gapsOut, cWidth / 2 - root.paneWidth / 2)
      localY = Math.max(Style.gapsOut, cHeight / 2 - approxH / 2)
    }

    if (pointerProc.route && pointerProc.route !== "root")
      root.openAtRoute(String(chosen.name), localX, localY, pointerProc.route)
    else
      root.openAt(String(chosen.name), localX, localY)
  }

  // Plugin lifecycle. The host calls these for
  //   omarchy-shell shell toggle io.github.iryzhkov.glide-menus '{"menu":"root"}'
  // which is the shape a keybinding wants: no coordinates to work out, and
  // toggle already knows whether the menu is showing.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(root.boundText(payloadJson || "{}", 4096)) } catch (e) { payload = ({}) }
    root.openAtPointer(root.boundText(payload.menu || payload.route || "root", 200))
  }

  IpcHandler {
    target: "glideMenu"

    // Open at the pointer, above whatever window is focused.
    function open(): void {
      root.openAtPointer("root")
    }

    // Open at the pointer with a branch pre-expanded, e.g.
    //   omarchy-shell glideMenu openRoute style
    function openRoute(menuId: string): void {
      root.openAtPointer(menuId)
    }

    function toggle(): void {
      if (root.opened) root.dismiss()
      else root.openAtPointer("root")
    }

    // Scripted navigation, equivalent to the arrow keys and Enter. Useful
    // for demos and automated tests; goes through the same code paths.
    function nav(delta: int): void {
      root.moveSelection(root.finiteNum(delta, -100, 100, 0))
    }

    function enter(): void {
      root.activateSelected()
    }

    function back(): void {
      root.goBack()
    }

    function setGrab(on: string): void {
      root.grabKeyboard = String(on) !== "false"
    }

    function close(): void {
      root.dismiss()
    }

    // Explicit placement, used by the desktop catcher and the bar button.
    function openAt(screenName: string, x: real, y: real): void {
      root.openAt(screenName, x, y)
    }

    function openAtRoute(screenName: string, x: real, y: real, menuId: string): void {
      root.openAtRoute(screenName, x, y, menuId)
    }

    function openAtAnchor(screenName: string, x: real, y: real, w: real, h: real, placement: string): void {
      root.openAtAnchor(screenName, x, y, w, h, placement)
    }

    function toggleAtAnchor(screenName: string, x: real, y: real, w: real, h: real, placement: string): void {
      if (root.opened) root.dismiss()
      else root.openAtAnchor(screenName, x, y, w, h, placement)
    }
  }

  // ------------------------------------------------------- desktop catcher
  //
  // A transparent, screen-filling surface on the Bottom layer: above the
  // wallpaper, below every window and below the bar. It exists so the plugin
  // needs no fork of the background plugin to hear a right-click on the
  // desktop -- install it next to whichever wallpaper renderer you already run.
  //
  // It does take the clicks the background plugin would otherwise get, so the
  // gesture that one owns is passed along: double-click still opens the
  // wallpaper picker. Its double-right-click theme switcher is not, because a
  // single right-click now opens this menu instead -- Style > Theme is two rows
  // away, and omarchy-theme-switcher is still on its own keybinding.

  Process { id: wallpaperProc }

  function openWallpaperPicker() {
    if (wallpaperProc.running) return
    wallpaperProc.command = root.helperCommand(600,
      "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\"")
    wallpaperProc.running = true
  }

  Variants {
    model: root.desktopRightClick ? Quickshell.screens : []

    PanelWindow {
      id: catcher
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      WlrLayershell.namespace: "omarchy-context-menu-catcher"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        // Single press, not double: a context menu that needs a double
        // right-click is a context menu nobody finds.
        onPressed: function(mouse) {
          if (mouse.button !== Qt.RightButton) return
          root.openAt(catcher.modelData.name, mouse.x, mouse.y)
          mouse.accepted = true
        }

        onDoubleClicked: function(mouse) {
          if (mouse.button !== Qt.LeftButton || !root.wallpaperDoubleClick) return
          root.openWallpaperPicker()
          mouse.accepted = true
        }
      }
    }
  }

  // ----------------------------------------------------------- the cascade

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: root.opened && root.targetScreen === modelData.name
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      WlrLayershell.namespace: "omarchy-context-menu"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.grabKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Click-away. No scrim: a context menu should not dim the desktop it is
      // acting on. Right-click here re-opens at the new spot, which is what a
      // second right-click on the desktop should do.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openAt(panel.modelData.name, mouse.x, mouse.y)
          else root.dismiss()
          mouse.accepted = true
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      // Focus has to be taken after the window maps, or the compositor hands
      // it back before there is anything to give it to.
      onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

      // Ghost preview of the submenu the selection points at, to the right
      // of the active pane — the direction the Right key travels. Centered
      // layout only; it fades and never takes input.
      // Held back while an exit stand-in is in flight: walking back restores
      // the selection onto the closed submenu's row, and its preview would
      // otherwise spawn in the same slot the departing pane is sliding
      // through — two copies of the same menu at once.
      Loader {
        active: root.centeredLayout && root.animations && root.ghostMenuId !== ""
          && root.exitSnapshot === null && !root.paneEntering
        sourceComponent: GhostPane {
          panelItem: panel

          // The preview is the selected row's submenu, so clicking it is
          // the same gesture as pressing Right: promote it to a real pane
          // (falling through would hit click-away and dismiss the menu).
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
              root.activateSelected()
              mouse.accepted = true
            }
          }
        }
      }

      // A pane closed by walking back is demoted, not discarded: it slides
      // one slot right in step with the chain while its text drains to the
      // ghost's muted color, landing exactly where — and looking exactly
      // how — the ghost preview of that submenu then takes over.
      Loader {
        active: root.centeredLayout && root.animations && root.exitSnapshot !== null
        sourceComponent: GhostPane {
          panelItem: panel
          menuId: root.exitSnapshot ? root.exitSnapshot.menuId : ""
          z: -1

          property bool gone: false
          Component.onCompleted: gone = true
          dimmed: gone

          x: (panel.width - width) / 2 + (gone ? root.paneWidth + Style.space(12) : 0)
          y: root.exitSnapshot ? root.exitSnapshot.y : Style.gapsOut

          Behavior on x {
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
          }
        }
      }

      Repeater {
        // A plain integer model resets every delegate on each change, which
        // replayed the surviving panes' entrance animations on every
        // back/forward step (the "parent teleports" glitch). ScriptModel
        // diffs the index list, so only the pane actually added or removed
        // is created or destroyed; the rest keep their state and just
        // animate to their new slots.
        model: ScriptModel {
          values: {
            var indices = []
            for (var i = 0; i < root.panes.length; i++) indices.push(i)
            return indices
          }
        }

        delegate: BorderSurface {
          id: pane
          required property int index

          // A pane is destroyed one frame after the cascade it belonged to was
          // truncated, so `index` can briefly outrun `panes`. Stand in for the
          // missing spec rather than read `.x` off undefined.
          readonly property var spec: root.panes[index] || ({ x: 0, y: 0 })
          readonly property var rows: root.visibleRows(index)
          readonly property bool deepest: index === root.panes.length - 1
          readonly property string paneFilter: deepest ? root.filterText : String(spec.filter || "")
          readonly property bool filtering: paneFilter.length > 0
          readonly property int headerHeight: filtering ? root.rowHeight : 0

          // Flip left of the anchor rather than run off the right edge, and
          // lift up rather than run off the bottom. A cascade that opens off
          // screen is a cascade you cannot use.
          readonly property real anchorX: spec.x
          readonly property real anchorY: spec.y
          readonly property real baseX: spec.flipX === true ? anchorX - width : anchorX
          readonly property real baseY: spec.flipY === true ? anchorY - height : anchorY
          readonly property bool overflowsRight: baseX + width > panel.width - Style.gapsOut
          readonly property real alternateX: index === 0
            ? anchorX - width
            : anchorX - width - root.paneWidth + Style.space(4)

          // Centered layout: the pane being used stays mid-screen so the
          // eyes never travel; each ancestor slides one slot to the LEFT
          // (back the way you came), the oldest walking off the edge, and
          // forward — the Right key — is rightward. Depth changes animate
          // as one sliding chain.
          readonly property real centeredX: (panel.width - width) / 2
            - (root.panes.length - 1 - index) * (root.paneWidth + Style.space(12))

          // Vertical position comes from the pane's natural (unfiltered)
          // height, not its live height: the top edge — and with it the
          // type-ahead input — stays put while a search changes the row
          // count, and the pane only grows or shrinks downward.
          readonly property real naturalHeight: Math.min(
            Math.max(root.displayRows(spec.menuId).length, 1) * root.rowHeight + root.panePadding * 2,
            panel.height - Style.gapsOut * 2)

          x: root.centeredLayout
            ? centeredX
            : Math.max(Style.gapsOut, overflowsRight ? alternateX : baseX)
          // Root pane: centered on its natural height. Child panes anchor to
          // the row they were opened from (spec.y carries its level): top
          // aligned and growing downward when there is room below, flipped
          // to bottom-aligned — extending upward from the row — when the
          // space is above instead. Either way the child intersects its
          // parent at the anchor row rather than floating at its own center.
          readonly property real anchoredChildY: {
            var rowTop = anchorY
            if (naturalHeight <= panel.height - Style.gapsOut - rowTop) return rowTop
            var flippedTop = rowTop + root.rowHeight + root.panePadding - naturalHeight
            if (flippedTop >= Style.gapsOut) return flippedTop
            return Math.max(Style.gapsOut, Math.min(rowTop, panel.height - Style.gapsOut - naturalHeight))
          }
          y: root.centeredLayout
            ? (index === 0
                ? Math.max(Style.gapsOut, (panel.height - naturalHeight) / 2)
                : anchoredChildY)
            : Math.max(Style.gapsOut, Math.min(baseY, panel.height - height - Style.gapsOut))

          // Geometry settles for a beat before the slide Behaviors arm: a
          // freshly created pane (or a freshly mapped panel window) must
          // appear in place, not fly in from pre-layout coordinates.
          property bool geometrySettled: false
          Timer {
            interval: 100
            running: pane.entered
            repeat: false
            onTriggered: pane.geometrySettled = true
          }

          Behavior on x {
            enabled: root.animations && root.centeredLayout && pane.geometrySettled
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
          }
          Behavior on y {
            enabled: root.animations && root.centeredLayout && pane.geometrySettled
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
          }
          Behavior on height {
            enabled: root.animations && root.centeredLayout && pane.geometrySettled
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
          }

          width: root.paneWidth
          height: Math.min(
            headerHeight + Math.max(rows.length, 1) * root.rowHeight + root.panePadding * 2,
            root.centeredLayout
              ? panel.height - y - Style.gapsOut
              : panel.height - Style.gapsOut * 2)

          radius: root.cornerRadius
          color: root.background
          borderSpec: root.borderSpec
          clip: true
          z: index

          // Caelestia-style entrance: the pane grows out of the corner it was
          // anchored at, with an expressive overshoot, instead of popping in.
          readonly property bool flippedXEffective: spec.flipX === true || overflowsRight
          property bool entered: false
          transformOrigin: spec.flipY === true
            ? (flippedXEffective ? Item.BottomRight : Item.BottomLeft)
            : (flippedXEffective ? Item.TopRight : Item.TopLeft)
          scale: !root.animations || entered || root.centeredLayout ? 1 : 0.85
          // Submenu panes enter opaque (the slide from the ghost slot is
          // the transition); the root pane of a fresh summon fades in where
          // it stands.
          opacity: !root.animations || entered || (root.centeredLayout && index > 0) ? 1 : 0

          transform: Translate {
            // Only submenu panes slide in from the ghost slot; the root pane
            // of a fresh summon appears in place, without movement.
            x: root.animations && root.centeredLayout && !pane.entered && index > 0
              ? root.paneWidth + Style.space(12) : 0
            Behavior on x {
              enabled: root.animations
              NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
            }
          }
          Behavior on scale {
            enabled: root.animations
            NumberAnimation { duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
          }
          Behavior on opacity {
            enabled: root.animations
            NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0, 0, 0, 1, 1, 1] }
          }

          // Which row this pane's glide highlight should sit on: the row whose
          // submenu is open for parent panes, the live selection for the
          // deepest pane.
          readonly property int glideRow: {
            if (!deepest) {
              for (var i = 0; i < rows.length; i++)
                if (root.submenuOpenFor(index, rows[i])) return i
              return -1
            }
            return root.selectedIndex
          }

          onXChanged: if (panel.visible) root.notePaneGeometry(index, x, y, list.contentY)
          onYChanged: if (panel.visible) root.notePaneGeometry(index, x, y, list.contentY)
          Component.onCompleted: {
            if (panel.visible) root.notePaneGeometry(index, x, y, list.contentY)
            pane.entered = true
          }

          // Swallow clicks so they don't reach the click-away layer, and make
          // right-click anywhere in a pane walk back one level.
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onPressed: function(mouse) {
              root.goBack()
              mouse.accepted = true
            }
          }

          // The type-ahead, shown only once something has been typed. It is
          // what makes a 400-row Apps submenu usable without a search card.
          Item {
            id: filterHeader
            visible: pane.filtering
            height: pane.headerHeight
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: root.panePadding }

            Text {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm
              verticalAlignment: Text.AlignVCenter
              text: "󰍉  " + pane.paneFilter
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              color: root.selectedText
              elide: Text.ElideRight
            }
          }

          Text {
            visible: pane.rows.length === 0
            anchors.fill: parent
            anchors.topMargin: pane.headerHeight + root.panePadding
            anchors.leftMargin: Style.spacing.sm + root.iconColumn
            verticalAlignment: Text.AlignVCenter
            text: pane.filtering ? "No matches" : "…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: Qt.darker(root.foreground, 1.5)
          }

          ListView {
            id: list
            anchors.fill: parent
            anchors.margins: root.panePadding
            anchors.topMargin: root.panePadding + pane.headerHeight
            model: pane.rows.length
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            onContentYChanged: if (panel.visible) root.notePaneGeometry(pane.index, pane.x, pane.y, contentY)

            Connections {
              target: root
              enabled: pane.deepest
              function onSelectedIndexChanged() {
                if (root.selectedIndex >= 0 && root.selectedIndex < pane.rows.length)
                  list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
              }
            }

            // The selection highlight, one per pane: an accent surface that
            // glides between rows, its leading edge faster than its trailing
            // edge so it stretches mid-travel (same motion as glide-workspaces).
            Rectangle {
              id: glidePill
              parent: list.contentItem
              z: -1
              visible: root.animations && pane.glideRow >= 0

              readonly property real target: pane.glideRow >= 0 ? pane.glideRow * root.rowHeight : 0
              property real leadY: target
              property real trailY: target
              onTargetChanged: { leadY = target; trailY = target }

              Behavior on leadY {
                enabled: glidePill.visible
                NumberAnimation { duration: 240; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
              }
              Behavior on trailY {
                enabled: glidePill.visible
                NumberAnimation { duration: 380; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.05, 0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1, 1, 1] }
              }

              x: Style.space(2)
              width: list.width - Style.space(4)
              y: Math.min(leadY, trailY)
              height: Math.abs(leadY - trailY) + root.rowHeight
              radius: Math.max(0, root.cornerRadius - Style.space(2))
              color: root.selectedBackground
            }

            delegate: Item {
              id: row
              required property int index

              readonly property var entry: pane.rows[row.index]
              readonly property bool isApp: entry && entry.kind === "app"
              readonly property bool submenu: root.isSubmenu(entry) || (entry && entry.provider)
              readonly property bool active: hover.hovered
                || (pane.deepest && root.selectedIndex === row.index)
                || root.submenuOpenFor(pane.index, entry)

              width: list.width
              height: root.rowHeight

              HoverHandler {
                id: hover
                // Opening on hover is what makes a cascade feel like a cascade.
                // A short dwell keeps a diagonal sweep toward an open submenu
                // from tearing it down on the way past.
                onHoveredChanged: {
                  if (!root.hoverSelects) return
                  if (hovered) {
                    if (pane.deepest) root.selectedIndex = row.index
                    dwell.restart()
                  } else {
                    dwell.stop()
                  }
                }
              }

              Timer {
                id: dwell
                interval: root.submenuDelay
                repeat: false
                onTriggered: {
                  if (!hover.hovered) return
                  if (row.entry && root.isSubmenu(row.entry)) {
                    if (root.targetOf(row.entry) === root.recentlyClosedMenu) return
                    root.openChild(pane.index, row.entry, pane.x, pane.y,
                                   row.y - list.contentY + root.panePadding + pane.headerHeight)
                  } else {
                    // A leaf: everything deeper than this pane is stale.
                    // Truncating restores this pane's parked filter, which can
                    // reshuffle (or destroy) the delegates — so resolve the
                    // hovered entry again instead of trusting row.index.
                    var hoveredEntry = row.entry
                    root.truncate(pane.index + 1)
                    var newRows = root.visibleRows(pane.index)
                    for (var nr = 0; nr < newRows.length; nr++) {
                      if (newRows[nr] === hoveredEntry || newRows[nr].id === hoveredEntry.id) {
                        root.selectedIndex = nr
                        break
                      }
                    }
                  }
                }
              }

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Style.space(2)
                anchors.rightMargin: Style.space(2)
                radius: Math.max(0, root.cornerRadius - Style.space(2))
                // With animations on, the gliding pill below the delegates is
                // the highlight; this static one is the fallback.
                color: row.active && !root.animations ? root.selectedBackground : "transparent"
              }

              Text {
                id: iconText
                visible: !row.isApp
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconColumn
                horizontalAlignment: Text.AlignHCenter
                text: row.entry ? row.entry.icon : ""
                textFormat: Text.PlainText
                font.family: (row.entry && row.entry.iconFont) ? row.entry.iconFont : root.fontFamily
                font.pixelSize: Style.font.heading
                color: row.active ? root.selectedText : root.foreground
              }

              Image {
                id: appIcon
                visible: row.isApp
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm + (root.iconColumn - width) / 2
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // Decode at physical pixels -- a logical-size decode leaves PNG
                // icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: (row.isApp && root.appLibrary) ? root.appLibrary.iconSource(row.entry.appIcon) : ""
              }

              Text {
                id: pathHint
                anchors.right: chevron.left
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, row.width * 0.4)
                visible: pane.filtering && text !== ""
                text: pane.filtering && row.entry ? root.entryPathLabel(row.entry, pane.spec.menuId) : ""
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: Qt.darker(root.foreground, 1.5)
                elide: Text.ElideLeft
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm + root.iconColumn + Style.spacing.xs
                anchors.right: pathHint.visible ? pathHint.left : chevron.left
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                text: row.entry ? MenuModel.labelFor(row.entry, root.checkedResults) : ""
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: row.entry && row.entry.kind === "hint" ? Font.Normal : Font.Medium
                font.italic: row.entry ? row.entry.kind === "hint" : false
                color: row.entry && row.entry.kind === "hint"
                  ? Qt.darker(root.foreground, 1.5)
                  : (row.active ? root.selectedText : root.foreground)
                elide: Text.ElideRight
              }

              Text {
                id: chevron
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                visible: row.submenu
                text: "›"
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                color: row.active ? root.selectedText : Qt.darker(root.foreground, 1.5)
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  root.activate(pane.index, row.entry, pane.x, pane.y,
                                row.y - list.contentY + root.panePadding + pane.headerHeight)
                  mouse.accepted = true
                }
              }
            }
          }
        }
      }
    }
  }

  component GhostPane: BorderSurface {
    id: ghost
    required property var panelItem
    // Which submenu to render; instances may override position and opacity
    // (the exit snapshot reuses this component to slide a closed pane away).
    property string menuId: root.ghostMenuId
    // Preview instances render muted; the exit stand-in wears the real
    // pane's colors so the hand-off is seamless.
    property bool dimmed: true

    readonly property var ghostRows: ghost.menuId ? root.displayRows(ghost.menuId) : []

    width: root.paneWidth
    height: Math.min(
      Math.max(ghostRows.length, 1) * root.rowHeight + root.panePadding * 2,
      panelItem.height - Style.gapsOut * 2)
    x: (panelItem.width - width) / 2 + (root.paneWidth + Style.space(12))

    // Sit exactly where the real child pane would open: top-aligned with
    // the selected row, flipped to extend upward when the space is above
    // (mirrors the pane delegate's anchoredChildY logic).
    // Matches the spec.y a real openChild would compute (row level minus
    // the pane padding), so ghost and materialized pane land identically.
    readonly property real anchorRowY:
      root.geometryFor(root.panes.length - 1).y + root.selectedRowY(root.panes.length - 1) - root.panePadding
    y: {
      if (naturalBelow) return anchorRowY
      var flippedTop = anchorRowY + root.rowHeight + root.panePadding - height
      if (flippedTop >= Style.gapsOut) return flippedTop
      return Math.max(Style.gapsOut, Math.min(anchorRowY, panelItem.height - Style.gapsOut - height))
    }
    readonly property bool naturalBelow: height <= panelItem.height - Style.gapsOut - anchorRowY

    radius: root.cornerRadius
    color: root.background
    borderSpec: root.borderSpec
    clip: true
    // Fully opaque surface — transparency over busy windows kills
    // legibility. The "not yet real" feel comes entirely from the muted
    // text color.
    opacity: 1

    Column {
      anchors.fill: parent
      anchors.margins: root.panePadding

      Repeater {
        model: Math.min(ghost.ghostRows.length, 14)

        Item {
          required property int index
          readonly property var gEntry: ghost.ghostRows[index]

          width: parent.width
          height: root.rowHeight

          Text {
            visible: !gEntry || gEntry.kind !== "app"
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            width: root.iconColumn
            horizontalAlignment: Text.AlignHCenter
            text: gEntry ? gEntry.icon : ""
            textFormat: Text.PlainText
            font.family: (gEntry && gEntry.iconFont) ? gEntry.iconFont : root.fontFamily
            font.pixelSize: Style.font.heading
            color: ghost.dimmed ? Color.muted : root.foreground
          }

          Image {
            visible: gEntry && gEntry.kind === "app"
            width: Style.font.iconLarge
            height: Style.font.iconLarge
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm + (root.iconColumn - width) / 2
            anchors.verticalCenter: parent.verticalCenter
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            source: (gEntry && gEntry.kind === "app" && root.appLibrary) ? root.appLibrary.iconSource(gEntry.appIcon) : ""
          }
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm + root.iconColumn + Style.spacing.xs
            anchors.right: ghostChevron.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            text: gEntry ? MenuModel.labelFor(gEntry, root.checkedResults) : ""
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: ghost.dimmed ? Color.muted : root.foreground
            elide: Text.ElideRight
            Behavior on color { ColorAnimation { duration: 320 } }
          }

          Text {
            id: ghostChevron
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            visible: gEntry ? (root.isSubmenu(gEntry) || gEntry.provider !== "") : false
            text: "\u203a"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: ghost.dimmed ? Color.muted : root.foreground
            Behavior on color { ColorAnimation { duration: 320 } }
          }
        }
      }
    }
  }

  // True when the pane below `depth` was opened by `entry` -- used to keep a
  // parent row highlighted while its submenu is showing.
  function submenuOpenFor(depth, entry) {
    if (!entry) return false
    if (root.panes.length <= depth + 1) return false
    return root.panes[depth + 1].menuId === root.targetOf(entry)
  }
}
