#!/bin/bash
# The coding-agent gate: drives a real Synth build over its control socket (SYNTH_AUTOMATION=1)
# and proves every agent end to end — template spawn, resume, notifications, browser MCP,
# click-to-comment, abort semantics, `agy`'s two-programs-one-name detection rule, and no
# regression in Claude Code's hook path.
#
# Needs: a CEF-enabled bundle (app/dev.sh builds one) whose path is in /tmp/synth-app-path.txt,
# and `opencode` + `claude` on PATH. Antigravity additionally wants `agy` — the CLI, from
# `brew install --cask antigravity-cli` or the official installer's ~/.local/bin — and, for the
# gates that take a real turn, a signed-in one (`agy models` must answer). Missing or signed out,
# those gates print one SKIP line and are counted apart from passes: this stays green on a
# machine that simply hasn't got the agent.
#
# Run a subset by naming suites: ./run.sh t14_antigravity_detect t15_antigravity
set -uo pipefail
cd "$(dirname "$0")"

# The browser suites need a CEF-enabled build. SwiftPM caches the manifest, so a build made while
# vendor/cef was absent silently yields a binary with no CEF (and no CDP) — the browser tests then
# fail for a reason that has nothing to do with the code under test. Fail fast and say so.
# Same override lib.py honours, so the precheck and the suites can never gate different builds.
APP="${SYNTH_APP:-$(cat /tmp/synth-app-path.txt)}"
if ! SYNTH_AUTOMATION=1 "$APP/Contents/MacOS/Synth" --browser-check 2>&1 | grep -q "^PASS engine-created"; then
  echo "FAIL: this build has no CEF browser engine (touch app/Package.swift and rebuild, or use app/dev.sh)"
  exit 1
fi

SUITES="t1_template t2_resume t3_notifs t4a_mcpconfig t4b_agent_browser t5_comment t6_abort
        t7_regression t8_appmcp t9_archive t10_toasts t11_update t12_scratch t13_termcontrast
        t14_antigravity_detect t15_antigravity t16_antigravity_resume t17_agent_quit
        t18_antigravity_states"

P=0; F=0; S=0
for t in ${*:-$SUITES}; do
  if python3 "$t.py" > "/tmp/$t.out" 2>&1; then
    if grep -q '^SKIP: ' "/tmp/$t.out"; then
      echo "SKIP $t — $(sed -n 's/^SKIP: //p' "/tmp/$t.out" | head -1)"; S=$((S+1))
    else
      echo "PASS $t ($(grep -c '  PASS' "/tmp/$t.out") checks)"; P=$((P+1))
    fi
  else
    echo "FAIL $t"; grep '  FAIL' "/tmp/$t.out" | head -5; F=$((F+1))
  fi
done
echo "suites: $P passed / $F failed / $S skipped"
exit $((F > 0))
