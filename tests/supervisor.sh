#!/bin/bash

# Execute the supervisor script from Helper.js for real, and check that it does
# the one thing it exists to do: not exit until the helper's whole process group
# is gone.
#
# The QML tests can check the shape of a command line. Only this can check that
# a grandchild which survives the group TERM is still swept, and that the
# supervisor's exit is therefore a true acknowledgement that nothing is left --
# which is the guarantee every start site in ContextMenu.qml relies on when it
# refuses to start a helper while the previous Process is still running.

set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

failures=0

report() {
  if [[ $1 == 0 ]]; then
    echo "PASS   : supervisor::$2"
  else
    echo "FAIL!  : supervisor::$2 -- $3"
    failures=$((failures + 1))
  fi
}

# Recover the script text from the JavaScript string literal in Helper.js: the
# lines between `var SUPERVISOR =` and its terminating `;`, each a quoted
# fragment, with the // comments between them dropped.
python3 - "$PROJECT_DIR/Helper.js" "$WORK/supervisor.sh" <<'PY'
import ast, re, sys

src = open(sys.argv[1]).read()

# The two exit codes the script interpolates, read from their declarations so
# this test cannot drift from the values the plugin actually uses.
consts = dict(re.findall(r'^var ([A-Z_]+) = (\d+);', src, re.M))

body = src.split("var SUPERVISOR =", 1)[1].split("\n    ;", 1)[0]

parts = []
for line in body.split("\n"):
    line = line.strip()
    if line.startswith("//") or not line:
        continue
    if line.startswith("+"):
        line = line[1:].strip()
    # A fragment is a run of double-quoted literals and bare constant names
    # joined by +. Substitute the names, then take the literals in order.
    for name, value in consts.items():
        line = re.sub(r'\b%s\b' % name, '"%s"' % value, line)
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', line)
    if not literals:
        raise SystemExit("supervisor.sh: unparsed fragment: %r" % line)
    for lit in literals:
        parts.append(ast.literal_eval('"%s"' % lit))

open(sys.argv[2], "w").write("".join(parts))
PY

if [[ ! -s $WORK/supervisor.sh ]]; then
  echo "FAIL!  : supervisor::extract -- could not recover the script from Helper.js"
  exit 1
fi

# A helper whose child ignores TERM and would outlive a naive kill. It records
# its pid so the test can look for it afterwards.
cat > "$WORK/stubborn" <<'EOF'
trap '' TERM
echo $$ > "$MARKER"
while :; do read -t 1 -r _ || :; done
EOF

# 1. A helper that finishes on its own: the supervisor passes its status back.
out=$(bash "$WORK/supervisor.sh" 5 'printf hello; exit 0' 2>/dev/null)
rc=$?
if [[ $rc == 0 && $out == "hello" ]]; then
  report 0 "passes_through_a_clean_run"
else
  report 1 "passes_through_a_clean_run" "rc=$rc out=$out"
fi

# 2. A helper that fails: the status is the helper's own, not the supervisor's.
bash "$WORK/supervisor.sh" 5 'exit 3' >/dev/null 2>&1
rc=$?
report $((rc == 3 ? 0 : 1)) "passes_through_a_failing_status" "expected 3, got $rc"

# 3. A helper that hangs past its deadline: timeout's 124, never a usable run.
bash "$WORK/supervisor.sh" 1 'read -r _ < /dev/zero; sleep 30' >/dev/null 2>&1
rc=$?
report $(($rc == 124 ? 0 : 1)) "enforces_the_deadline" "expected 124, got $rc"

# 4. Cancellation with a helper that ignores TERM. The guarantee under test is
#    the one every start site relies on: when the supervisor's own exit is
#    observed, nothing of the helper is still running. Which layer does the
#    killing is deliberately not asserted -- timeout's --kill-after escalation
#    reaches the whole group first, and the supervisor's identity-checked sweep
#    is the backstop for anything it misses. Removing either one has to fail
#    this, and removing --kill-after does.
export MARKER=$WORK/stubborn.pid
rm -f "$MARKER"
bash "$WORK/supervisor.sh" 30 "MARKER=$MARKER bash $WORK/stubborn" >/dev/null 2>&1 &
supervisor=$!

for _ in $(seq 1 100); do
  [[ -s $MARKER ]] && break
  read -t 0.05 -r _ < /dev/zero || :
done

if [[ ! -s $MARKER ]]; then
  report 1 "leaves_nothing_running_when_it_exits" "the stubborn helper never started"
  kill -TERM "$supervisor" 2>/dev/null
else
  stubborn=$(cat "$MARKER")
  kill -TERM "$supervisor" 2>/dev/null

  # Bounded, not `wait`. A supervisor that never returns is itself the failure
  # this checks for -- the helper it was cancelling ignores TERM -- and an
  # unbounded wait would hang the suite rather than report it.
  exited=1
  for _ in $(seq 1 200); do
    if ! kill -0 "$supervisor" 2>/dev/null; then
      exited=0
      break
    fi
    read -t 0.05 -r _ < /dev/zero || :
  done

  if ((exited != 0)); then
    report 1 "leaves_nothing_running_when_it_exits" "the supervisor did not exit within 10s of TERM"
    kill -KILL "$supervisor" 2>/dev/null
    kill -KILL "$stubborn" 2>/dev/null
  elif kill -0 "$stubborn" 2>/dev/null; then
    # The supervisor's promise is that nothing of the helper is left the moment
    # its own exit is observable, so there is deliberately no grace period here.
    report 1 "leaves_nothing_running_when_it_exits" "pid $stubborn still alive after the supervisor exited"
    kill -KILL "$stubborn" 2>/dev/null
  else
    report 0 "leaves_nothing_running_when_it_exits"
  fi
fi

if ((failures == 0)); then
  echo "Totals: 4 passed, 0 failed (supervisor.sh)"
else
  echo "Totals: $((4 - failures)) passed, $failures failed (supervisor.sh)"
fi
exit $((failures > 0))
