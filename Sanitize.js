.pragma library
.import "MenuModel.js" as MenuModel

// Everything that crosses into this plugin from outside -- menu files, helper
// process output, IPC arguments, hand-edited settings -- is bounded before it
// is parsed or rendered: byte caps before JSON parsing, row and field caps
// before entries join the model, finite range clamps on numbers.
//
// The ceilings and the checks live together here, with no dependency on the
// scene, so the limits can be read in one place and tested without a shell.
// ContextMenu.qml re-exports each ceiling as a property of its own, so the
// rest of the plugin still reads them as root.maxSomething.

// ---------------------------------------------------------------- ceilings

var MAX_MENU_FILE_BYTES = 2000000;
var MAX_MODEL_ITEMS = 10000;
var MAX_FIELD_CHARS = 512;
var MAX_HELPER_BYTES = 1000000;
var MAX_PROVIDER_ROWS = 2000;
var MAX_APP_ROWS = 3000;
var MAX_PROBE_BYTES = 262144;
var MAX_FILTER_CHARS = 128;

var MAX_SUMMON_PAYLOAD_BYTES = 4000000;
var MAX_DMENU_OPTIONS = 20000;
var MAX_OPTION_CHARS = 1024;
var MAX_PATH_CHARS = 4096;
var MAX_INPUT_CHARS = 1024;

// The most aliases one entry may carry into the model.
var MAX_ALIASES = 16;

// The entry fields that are strings and are therefore length-capped.
var ENTRY_FIELDS = ["id", "parent", "kind", "icon", "iconFont", "label", "title", "target", "description", "action", "provider", "when", "checked"];

// ---------------------------------------------------------------- checks

function boundText(value, max) {
    var s = String(value === undefined || value === null ? "" : value);
    return s.length > max ? s.slice(0, max) : s;
}

function finiteNum(value, lo, hi, fallback) {
    var n = Number(value);
    if (!isFinite(n))
        return fallback;
    return Math.min(hi, Math.max(lo, n));
}

// Cap entry count and every string field before parsed menu content joins the
// model. The entries are modified in place and the capped list returned, which
// is what the caller's model binding takes.
function sanitizeEntries(list) {
    if (!Array.isArray(list))
        return [];
    var out = list.slice(0, MAX_MODEL_ITEMS);
    for (var i = 0; i < out.length; i++) {
        var e = out[i];
        if (!e)
            continue;
        for (var f = 0; f < ENTRY_FIELDS.length; f++) {
            if (typeof e[ENTRY_FIELDS[f]] === "string" && e[ENTRY_FIELDS[f]].length > MAX_FIELD_CHARS)
                e[ENTRY_FIELDS[f]] = e[ENTRY_FIELDS[f]].slice(0, MAX_FIELD_CHARS);
        }
        if (Array.isArray(e.aliases)) {
            e.aliases = e.aliases.slice(0, MAX_ALIASES);
            for (var a = 0; a < e.aliases.length; a++)
                e.aliases[a] = boundText(e.aliases[a], MAX_FIELD_CHARS);
        }
    }
    return out;
}

// Called only for a read whose helper exited 0, which is what proves the file
// was under the byte ceiling. The length test below is a redundant one-way
// check: UTF-8 never uses fewer bytes than the string has UTF-16 code units, so
// more code units than MAX_MENU_FILE_BYTES always means more bytes as well. It
// can never be the reason truncated input is accepted, because it is not what
// accepts input in the first place.
function parseMenuText(t) {
    t = String(t || "");
    if (t.length > MAX_MENU_FILE_BYTES) {
        console.warn("glide-menus: menu source over " + MAX_MENU_FILE_BYTES + " bytes, ignoring");
        return [];
    }
    return sanitizeEntries(MenuModel.parseMenuJsonc(t));
}

// The options a select summon draws, capped in count and in width.
function sanitizeOptions(list) {
    if (!Array.isArray(list))
        return [];
    var out = list.slice(0, MAX_DMENU_OPTIONS);
    for (var i = 0; i < out.length; i++)
        out[i] = boundText(out[i], MAX_OPTION_CHARS);
    return out;
}

// A result path is used as a path and nothing else: the writer receives it as a
// positional argument and never as script text, so the only thing left to check
// is shape. It must be absolute -- a relative path would resolve against this
// process's working directory, which is not the caller's -- and free of the
// newline and NUL no mktemp path contains. The summon channel is the user's own
// IPC socket, so a path arriving here already carries that user's authority;
// this is a check on shape, not a privilege border. An empty return means the
// path is refused.
function resultPath(value) {
    var path = boundText(value, MAX_PATH_CHARS);
    if (path.indexOf("/") !== 0)
        return "";
    if (path.indexOf("\n") >= 0 || path.indexOf(String.fromCharCode(0)) >= 0)
        return "";
    return path;
}
