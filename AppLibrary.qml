// This plugin's own application library, used whenever omarchy-shell does not
// hand the menu one of its own.
//
// The shell owns an AppLibrary -- desktop entries, hidden-entry filtering,
// icon lookup, launching -- and passes a menu plugin a capability-scoped
// handle to it as `shell.appLibrary`. Omarchy 4.0.3 decides whether a plugin
// gets that handle with Array.isArray(manifest.kinds), and the manifest the
// panel loader passes has crossed a QVariant boundary by then: kinds.length is
// still 2 and kinds.indexOf("menu") still returns 0, but Array.isArray() on it
// is false. So the capability check reports no menu kind, the handle arrives
// null, and the Apps submenu has nothing to list. The same recomputation can
// destroy an already-granted handle mid-session, which leaves `shell` itself
// null in a plugin that had one a moment earlier.
//
// Rather than track which shell version grants what, the menu always has a
// library: the shell's while it is there, this one otherwise. The surface
// below is the shell's -- entryName, entrySubtext, sortedEntries, iconSource,
// launch, and an appsChanged signal -- so ContextMenu.qml cannot tell which of
// the two it is talking to.
//
// Entries come from Quickshell's DesktopEntries, are ranked by Omarchy's own
// AppSearch.js (vendored next to MenuModel.js, so the order matches the
// launcher's), and are filtered by the two hide lists the launcher applies.
// The scan that reads those lists is supplied by the caller as a ready argv,
// so this file has no opinion about how a subprocess is run.

import QtQuick
import Quickshell
import Quickshell.Io
import "AppSearch.js" as AppSearch
import "Helper.js" as Helper

Item {
  id: library

  // argv printing one hidden desktop id per line, built by the caller so the
  // plugin's bounded-helper harness stays in one place. Empty means no scan
  // and no filtering: every entry the desktop files do not hide is listed.
  property var hiddenScanCommand: []

  // A desktop id is a filename stem. Anything longer is not one, and is bound
  // before it becomes a map key.
  readonly property int maxIdChars: 128

  signal appsChanged()

  property var hiddenIds: ({})

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  function isHiddenEntry(entry) {
    return library.hiddenIds[String((entry && entry.id) || "")] === true
  }

  function sortedEntries(query) {
    var model = DesktopEntries.applications
    var values = model ? (model.values || []) : []
    return AppSearch.sortedEntries(values, query, function(entry) {
      return library.isHiddenEntry(entry)
    })
  }

  function iconSource(icon) {
    var value = String(icon || "")
    var generic = Quickshell.iconPath("application-x-executable", true)
    if (value.length === 0) return generic
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : generic
  }

  // The same two steps the shell's own launch takes, so an app started from
  // this menu lands where one started from the launcher lands: uwsm-app puts
  // it in its own scope rather than under the shell's service, and gtk-launch
  // resolves the desktop id, which keeps ids with spaces and entries UWSM
  // rejects working. The .desktop suffix has to stay, or ids such as
  // org.telegram.desktop do not resolve.
  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", id + ".desktop"])
  }

  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
    return value.slice(0, library.maxIdChars)
  }

  function rescanHidden() {
    if (hiddenScan.running) return
    if (!library.hiddenScanCommand || library.hiddenScanCommand.length === 0) return
    hiddenScan.collected = ""
    hiddenScan.command = library.hiddenScanCommand
    hiddenScan.running = true
  }

  Process {
    id: hiddenScan

    property string collected: ""

    stdout: SplitParser {
      // Accumulation only, as everywhere else in this plugin: the producer
      // owns the byte ceiling and reports an overflow as its exit status.
      onRead: function(line) { hiddenScan.collected += line + "\n" }
    }

    onExited: function(exitCode, exitStatus) {
      // A refused, killed or truncated scan knows about only part of the hide
      // lists, and merging it would show entries the launcher hides. Keep the
      // last complete answer instead.
      if (Helper.runUsable(exitCode, exitStatus)) {
        var next = ({})
        var lines = hiddenScan.collected.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var id = library.normalizeDesktopId(lines[i])
          if (id.length > 0) next[id] = true
        }
        library.hiddenIds = next
      }
      library.appsChanged()
    }
  }

  // DesktopEntries fills in shortly after the scene loads, and again whenever
  // a package adds or removes an entry. The hide lists are re-read with it,
  // because an entry can arrive already hidden.
  Connections {
    target: DesktopEntries.applications

    function onValuesChanged() {
      library.rescanHidden()
      library.appsChanged()
    }
  }

  Component.onCompleted: library.rescanHidden()
}
