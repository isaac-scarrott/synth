#!/bin/bash
# The coding-agent gate: drives a real Synth build over its control socket (SYNTH_AUTOMATION=1)
# and proves both agents end to end — template spawn, resume, notifications, browser MCP,
# click-to-comment, abort semantics, and no regression in Claude Code's hook path.
#
# Needs: a CEF-enabled bundle (app/dev.sh builds one) whose path is in /tmp/synth-app-path.txt,
# and `opencode` + `claude` on PATH.
set -uo pipefail
cd "$(dirname "$0")"

# The browser suites need a CEF-enabled build. SwiftPM caches the manifest, so a build made while
# vendor/cef was absent silently yields a binary with no CEF (and no CDP) — the browser tests then
# fail for a reason that has nothing to do with the code under test. Fail fast and say so.
APP="$(cat /tmp/synth-app-path.txt)"
if ! SYNTH_AUTOMATION=1 "$APP/Contents/MacOS/Synth" --browser-check 2>&1 | grep -q "^PASS engine-created"; then
  echo "FAIL: this build has no CEF browser engine (touch app/Package.swift and rebuild, or use app/dev.sh)"
  exit 1
fi

P=0; F=0
for t in t1_template t2_resume t3_notifs t4a_mcpconfig t4b_agent_browser t5_comment t6_abort t7_regression t8_appmcp; do
  if python3 "$t.py" > "/tmp/$t.out" 2>&1; then
    echo "PASS $t ($(grep -c '  PASS' "/tmp/$t.out") checks)"; P=$((P+1))
  else
    echo "FAIL $t"; grep '  FAIL' "/tmp/$t.out" | head -5; F=$((F+1))
  fi
done
echo "suites: $P passed / $F failed"
exit $((F > 0))
