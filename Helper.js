.pragma library

// The subprocess harness: how this plugin runs anything outside its own
// process, and how it decides whether to believe the result.
//
// It is here rather than in ContextMenu.qml because it is the part with no
// opinion about menus. It has no dependency on Quickshell, on the QML scene,
// or on this plugin's state -- the environment it needs is passed in -- which
// is what lets the supervisor script be executed and checked by a test, and
// what would let another plugin adopt it unchanged.
//
// Three pieces, in the order a run goes through them:
//
//   command(seconds, script, env)  the argv: fixed absolute executables, a
//                                  cleared environment rebuilt from `env`, and
//                                  the supervisor with the deadline and the
//                                  body as positional arguments
//   boundedBody(script, capBytes)  wraps a script so its output is capped and
//                                  counted at the producer
//   runUsable(exitCode, status)    whether the run may be consumed at all
//
// pipeline() is the two of them together, which is what nearly every caller
// wants.

// Exit status a bounded helper uses to report that its producer went over the
// byte ceiling. It is carried by the process status, never by the data stream,
// and it is the authoritative overflow signal: the byte count is taken at the
// producer, before anything is decoded in the consuming process.
var OVERFLOW_EXIT = 9;

// The supervisor's own failure code: it could not confirm the helper's group
// empty within its five-second sweep. Never a usable run.
var SUPERVISOR_EXIT = 7;

// Helper scripts run through fixed absolute executables with a minimal
// explicit environment (no login shell, no inherited profile), a hard
// deadline, and a supervisor that owns the helper's whole process group from
// start to verified end.
//
// The Process's direct child is the supervisor below. It starts GNU timeout as
// the leader of a new process group with the script inside it, and it does not
// exit until that group is provably empty. So the Process's exited signal is
// the acknowledgement that the tree is gone, not an assumption about it, and
// every start site refuses to start while running is true, so a helper is
// never replaced before that arrives.
//
// Cancellation (signal(15), or the Process being torn down) reaches the
// supervisor, which forwards TERM to the group; timeout escalates the group to
// KILL two seconds later. Every signal the supervisor sends is bound to process
// identity first: a group signal only while the leader still exists with that
// pgid and its recorded start time, and, once the leader is gone, per-member
// KILLs only to processes whose pgid is still that group. A pid or pgid
// recycled to something else fails those checks and is never signalled.
// Orphans that escaped the leader (a grandchild that survived the group TERM)
// are swept the same way until none is left, or the supervisor gives up after
// five seconds with its own exit code, which no consumer accepts.
//
// The supervisor is a fixed script; the deadline and the helper body are
// positional arguments, never spliced into it.
var SUPERVISOR =
      "deadline=$1\n"
    + "body=$2\n"
    + "exec 5<> <(:)\n"
    + "/usr/bin/timeout --kill-after=2 \"$deadline\" /bin/bash -c \"$body\" &\n"
    + "leader=$!\n"
    // pgid and start time of a pid, from /proc, only when it belongs to the
    // leader's group. Fields after the comm ')' : 3 is pgrp, 20 starttime.
    + "ident() {\n"
    + "  local l\n"
    + "  read -r l < \"/proc/$1/stat\" 2>/dev/null || return 1\n"
    + "  l=${l##*) }\n"
    + "  set -- $l\n"
    + "  [ \"$3\" = \"$leader\" ] || return 1\n"
    + "  printf '%s' \"${20}\"\n"
    + "}\n"
    // timeout moves itself into its own group right after starting; wait
    // for that to be visible before recording the identity.
    + "start=\"\"\n"
    + "for _ in 1 2 3 4 5 6 7 8 9 10; do\n"
    + "  start=$(ident \"$leader\") && break\n"
    + "  read -t 0.01 -r -u 5 _ || :\n"
    + "done\n"
    + "group_ok() { [ -n \"$start\" ] && [ \"$(ident \"$leader\")\" = \"$start\" ]; }\n"
    + "stops=0\n"
    + "stop() { stops=$((stops + 1)); group_ok && /usr/bin/kill -TERM -- \"-$leader\" 2>/dev/null; }\n"
    + "trap stop TERM INT HUP\n"
    // wait is interrupted by the trap; go back to it until it returned on
    // its own, which is the leader's real exit status.
    + "while :; do\n"
    + "  before=$stops\n"
    + "  wait \"$leader\" 2>/dev/null; rc=$?\n"
    + "  [ \"$before\" = \"$stops\" ] && break\n"
    + "done\n"
    // The leader is reaped. Anything still in its group is an orphan of the
    // helper; KILL each one, but only after confirming it is still in that
    // group, until a full pass finds nothing.
    + "tries=0\n"
    + "while :; do\n"
    + "  left=0\n"
    + "  for p in $(/usr/bin/pgrep -g \"$leader\"); do\n"
    + "    read -r l < \"/proc/$p/stat\" 2>/dev/null || continue\n"
    + "    l=${l##*) }\n"
    + "    set -- $l\n"
    + "    [ \"$3\" = \"$leader\" ] || continue\n"
    + "    /usr/bin/kill -KILL \"$p\" 2>/dev/null && left=1\n"
    + "  done\n"
    + "  [ \"$left\" = 0 ] && break\n"
    + "  tries=$((tries + 1))\n"
    + "  [ \"$tries\" -gt 100 ] && exit " + SUPERVISOR_EXIT + "\n"
    + "  read -t 0.05 -r -u 5 _ || :\n"
    + "done\n"
    + "[ \"$stops\" -gt 0 ] && exit 143\n"
    + "exit \"$rc\"\n"
    ;

// The argv for one supervised helper run.
//
// `env` carries the values the scripts need from the session -- HOME, USER,
// XDG_RUNTIME_DIR, HYPRLAND_INSTANCE_SIGNATURE, WAYLAND_DISPLAY, OMARCHY_PATH.
// They are read by the caller (only it can reach Quickshell.env) and passed
// through by name here; anything missing arrives as an empty string rather
// than as an inherited value, because `env -i` clears the rest.
function command(seconds, script, env) {
    env = env || {};
    return ["/usr/bin/env", "-i",
        "PATH=/usr/local/bin:/usr/bin:/bin",
        "HOME=" + String(env.HOME || ""),
        "USER=" + String(env.USER || ""),
        "XDG_RUNTIME_DIR=" + String(env.XDG_RUNTIME_DIR || ""),
        "HYPRLAND_INSTANCE_SIGNATURE=" + String(env.HYPRLAND_INSTANCE_SIGNATURE || ""),
        "WAYLAND_DISPLAY=" + String(env.WAYLAND_DISPLAY || ""),
        "OMARCHY_PATH=" + String(env.OMARCHY_PATH || ""),
        "/bin/bash", "-c", SUPERVISOR,
        "glide-menus-helper", String(seconds), String(script)];
}

// The bounded body of a helper: the byte ceiling is enforced *and counted* at
// the producer, and the verdict is reported out of band as the process exit
// status, never mixed into the data stream.
//
// head caps the stream at capBytes + 1 bytes before anything reaches the
// consuming process, and kills an unbounded writer with SIGPIPE at the source.
// tee copies those bytes to the real stdout (fd 4) while wc counts them, so the
// count is of raw bytes as produced, not of anything that process has decoded.
// A count above capBytes means the producer had more to say than the ceiling
// allows, so the helper exits OVERFLOW_EXIT and every consumer discards the run
// before decoding or parsing it.
//
// The byte count deliberately does not travel through QML string length. A QML
// string holds UTF-16 code units, so comparing its length with a byte ceiling
// under-counts multibyte data and can make truncated output look acceptable;
// and a byte-truncated tail is not valid UTF-8 anyway, so the decoded length
// cannot be trusted to reconstruct it.
function boundedBody(script, capBytes) {
    return "exec 4>&1\n"
        + "n=$({\n" + String(script) + "\n} | /usr/bin/head -c " + (capBytes + 1)
        + " | /usr/bin/tee /dev/fd/4 | /usr/bin/wc -c)\n"
        + "n=${n//[^0-9]/}\n"
        + "[ -n \"$n\" ] || exit " + OVERFLOW_EXIT + "\n"
        + "[ \"$n\" -gt " + capBytes + " ] && exit " + OVERFLOW_EXIT + "\n"
        + "exit 0\n";
}

// A supervised, bounded run: what nearly every caller wants.
function pipeline(seconds, script, capBytes, env) {
    return command(seconds, boundedBody(script, capBytes), env);
}

// True when a helper's run may be consumed: it ended on its own terms and its
// producer stayed under the ceiling. Anything else -- a non-zero exit, a crash,
// a timeout kill, an overflow, the supervisor's own failure -- fails closed.
function runUsable(exitCode, exitStatus) {
    return exitCode === 0 && exitStatus === 0;
}

// Single-quote a string for a shell command line. Used where a value has to
// become script text rather than a positional argument.
function shellQuoted(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}
