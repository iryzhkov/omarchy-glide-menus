// Omarchy context menus.
//
// The whole Omarchy menu tree, drawn as a cascading context menu instead of a
// centred search card. It reads the very same sources the built-in menu does --
// Omarchy's default omarchy-menu.jsonc plus the user extension at
// ~/.config/omarchy/extensions/omarchy-menu.jsonc -- through a verbatim copy of
// Omarchy's own MenuModel.js, so the two can never drift apart: an entry added
// to the extension file shows up in both, with the same `when:` guards and the
// same ✓ marks.
//
// What differs is the interaction. This opens under the pointer, submenus
// cascade sideways as you hover, and the whole chain stays on screen so you can
// see the path you took. Three ways in:
//
//   * right-click the desktop (a transparent catcher on the Bottom layer, so it
//     sits above the wallpaper and below every window)
//   * the bar button in BarWidget.qml, which cascades down from itself
//   * a keybinding, which opens at the pointer on the Overlay layer -- above
//     whatever window happens to be focused
//
// Provider-backed submenus (Apps, Font, Power profile) are filled in from the
// same sources the built-in menu uses, so nothing has to hand off to it. Long
// lists are typed at rather than scrolled: any printable key filters the pane
// you are standing in.

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
  readonly property bool desktopRightClick: root.setting("desktopRightClick", true) !== false
  readonly property bool wallpaperDoubleClick: root.setting("wallpaperDoubleClick", true) !== false
  readonly property bool inlineApps: root.setting("inlineApps", true) !== false
  readonly property int submenuDelay: Math.max(0, Number(root.setting("submenuDelay", 140)) || 0)

  // ---------------------------------------------------------------- state

  property bool opened: false

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

  readonly property int paneWidth: Style.space(Math.max(120, Number(root.setting("paneWidth", 300)) || 300))
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

    var rows = root.rowsFor(spec.menuId)
    // The deepest pane filters by the live type-ahead; parents keep showing
    // the filter that was parked on them when their submenu opened.
    var filter = depth === root.panes.length - 1 ? root.filterText : String(spec.filter || "")
    if (!filter) return rows

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
    root.openPane(screenName, { menuId: "root", x: Number(x) || 0, y: Number(y) || 0 })
  }

  function openPane(screenName, spec) {
    root.targetScreen = String(screenName || "")
    root.originX = spec.x
    root.originY = spec.y
    root.filterText = ""
    root.selectedIndex = -1
    root.paneGeometry = []
    root.panes = [spec]
    root.searchProvidersLoaded = false
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
    var spec = { menuId: "root", x: Number(x) || 0, y: Number(y) || 0, flipX: false, flipY: false }
    var side = String(placement || "below")

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

    var route = MenuModel.resolveRoute(root.items, root.itemOrder, menuId)
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
      var parentRows = root.rowsFor(next[i].menuId)
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

  function close() {
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
    defaultMenuFile.reload()
    userMenuFile.reload()
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
    if (next < 0) next = rows.length - 1
    if (next >= rows.length) next = 0
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
      root.selectedIndex = root.visibleRows(root.panes.length - 1).length - 1
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
      root.filterText += event.text
      event.accepted = true
    }
  }

  // ------------------------------------------------------------- sources

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.defaultItems = MenuModel.parseMenuJsonc(text()); root.rebuild() }
    onLoadFailed: { root.defaultItems = []; root.rebuild() }
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.userItems = MenuModel.parseMenuJsonc(text()); root.rebuild() }
    onLoadFailed: { root.userItems = []; root.rebuild() }
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
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A killed batch only reported the rows it reached. Keep the last
      // complete answer rather than let a partial one hide things at random.
      if (exitCode !== 0 || exitStatus !== 0) {
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
    providerProc.command = ["bash", "-lc", spec.script]
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

    var lines = String(text || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
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

    var entries = root.appLibrary.sortedEntries("")
    var appRows = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = root.appLibrary.entrySubtext(entry)
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
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: root.appLibrary.entryName(entry),
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
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0)
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
    command: ["bash", "-lc", "hyprctl -j cursorpos; echo '@@'; hyprctl -j monitors"]
    stdout: StdioCollector {
      onStreamFinished: root.openAtProbedPointer(text)
    }
  }

  function openAtPointer(route) {
    if (pointerProc.running) return
    pointerProc.route = String(route || "root")
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
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.openAtPointer(payload.menu || payload.route || "root")
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
    wallpaperProc.command = ["bash", "-lc",
      "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
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
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
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
      Loader {
        active: root.centeredLayout && root.animations && root.ghostMenuId !== ""
        sourceComponent: GhostPane { panelItem: panel }
      }

      Repeater {
        model: root.panes.length

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
            Math.max(root.rowsFor(spec.menuId).length, 1) * root.rowHeight + root.panePadding * 2,
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
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
          }
          Behavior on y {
            enabled: root.animations && root.centeredLayout && pane.geometrySettled
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
          }
          Behavior on height {
            enabled: root.animations && root.centeredLayout && pane.geometrySettled
            NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
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
          opacity: !root.animations || entered ? 1 : 0

          transform: Translate {
            x: root.animations && root.centeredLayout && !pane.entered ? Style.space(28) : 0
            Behavior on x {
              enabled: root.animations
              NumberAnimation { duration: 340; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.38, 1.21, 0.22, 1.0, 1, 1] }
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

          onXChanged: root.notePaneGeometry(index, x, y, list.contentY)
          onYChanged: root.notePaneGeometry(index, x, y, list.contentY)
          Component.onCompleted: {
            root.notePaneGeometry(index, x, y, list.contentY)
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
            onContentYChanged: root.notePaneGeometry(pane.index, pane.x, pane.y, contentY)

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
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
                color: row.active ? root.selectedText : root.foreground
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

    readonly property var ghostRows: root.ghostMenuId ? root.rowsFor(root.ghostMenuId) : []

    width: root.paneWidth
    height: Math.min(
      Math.max(ghostRows.length, 1) * root.rowHeight + root.panePadding * 2,
      panelItem.height - Style.gapsOut * 2)
    x: (panelItem.width - width) / 2 + (root.paneWidth + Style.space(12))

    // Sit exactly where the real child pane would open: top-aligned with
    // the selected row, flipped to extend upward when the space is above
    // (mirrors the pane delegate's anchoredChildY logic).
    readonly property real anchorRowY:
      root.geometryFor(root.panes.length - 1).y + root.selectedRowY(root.panes.length - 1)
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
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            width: root.iconColumn
            horizontalAlignment: Text.AlignHCenter
            text: gEntry ? gEntry.icon : ""
            font.family: (gEntry && gEntry.iconFont) ? gEntry.iconFont : root.fontFamily
            font.pixelSize: Style.font.heading
            color: Color.muted
          }
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm + root.iconColumn + Style.spacing.xs
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: gEntry ? MenuModel.labelFor(gEntry, root.checkedResults) : ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: Color.muted
            elide: Text.ElideRight
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
