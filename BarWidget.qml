// The bar button.
//
// Stands in for the built-in Omarchy menu button: same glyph, same place, same
// right-click-for-a-terminal. What changes is what a click does -- the menu
// cascades down out of the button instead of opening a centred search card, so
// the bar button and the desktop right-click are the same menu reached two ways.
//
// Swap it in by replacing "omarchy.menu" with this plugin's id in the bar
// layout (Setup > Bar, or the bar.layout section of shell.json).

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.iryzhkov.glide-menus"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string glyph: String(root.setting("icon", ""))
  readonly property string glyphFont: String(root.setting("iconFont", "omarchy"))
  readonly property string secondaryCommand: String(root.setting("rightClickCommand", "xdg-terminal-exec"))

  // Which way the cascade leaves the button: down off a top bar, up off a
  // bottom one, sideways off a vertical one.
  function placement() {
    var position = root.bar ? String(root.bar.position || "top") : "top"
    if (position === "bottom") return "above"
    if (position === "left") return "right"
    if (position === "right") return "left"
    return "below"
  }

  // The button's top-left corner in the screen's own coordinates. The bar is a
  // layer surface pinned to one edge, so for a top or left bar its window
  // origin already is the screen's; only a bottom or right bar needs the offset
  // added. Omarchy's own bar does this conversion for drag-and-drop, so use its
  // version when it is there and keep the fallback for bars that predate it.
  function screenPoint() {
    var scenePoint = button.mapToItem(null, 0, 0)
    var window = button.QsWindow ? button.QsWindow.window : null

    if (root.bar && typeof root.bar.windowScreenPoint === "function")
      return root.bar.windowScreenPoint(scenePoint, window)

    var point = { x: scenePoint.x, y: scenePoint.y }
    if (window && window.screen) {
      var position = root.bar ? String(root.bar.position || "top") : "top"
      if (position === "bottom") point.y += Math.max(0, window.screen.height - window.height)
      else if (position === "right") point.x += Math.max(0, window.screen.width - window.width)
    }
    return point
  }

  function toggleMenu() {
    if (!root.bar) return

    var window = button.QsWindow ? button.QsWindow.window : null
    var screenName = (window && window.screen) ? String(window.screen.name) : ""
    var point = root.screenPoint()

    root.bar.run("omarchy-shell -q glideMenu toggleAtAnchor "
      + Util.shellQuote(screenName) + " "
      + Math.round(point.x) + " " + Math.round(point.y) + " "
      + Math.round(button.width) + " " + Math.round(button.height) + " "
      + root.placement())
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    fontFamily: root.glyphFont
    horizontalMargin: 7.5
    onPressed: function(pressedButton) {
      if (!root.bar) return
      if (pressedButton === Qt.RightButton) root.bar.run(root.secondaryCommand)
      else root.toggleMenu()
    }
  }
}
