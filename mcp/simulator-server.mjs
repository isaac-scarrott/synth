// Synth's simulator MCP server (ADR-0015, stdio) — the synth-browser server's sibling for iOS
// simulators instead of pages.
//
// Discovery and scoping are shared with the other servers (shared.mjs): the worktree named by
// $SYNTH_WORKTREE (opencode, which Synth sets explicitly) or $CLAUDE_PROJECT_DIR (Claude Code,
// which sets it itself) picks the Synth instance and the branch these tools act in.
//
// Unlike the browser there is no second channel. EVERY verb here goes over the app's control
// socket, because the app is what holds the warm Indigo HID session and the device's framebuffer —
// so a tool call taps the same device through the same source the user's pointer does, and where a
// verb is genuinely `simctl` work (launch, openurl, install) the app shells out. Two channels would
// mean two devices, which is the one thing ADR-0011 and ADR-0015 both exist to prevent.
//
// Observe structurally, act by coordinate — the convention idb, mobile-mcp, AXe, Argent and Maestro
// converged on. Coordinates are fractions of the screen (0..1 from the top-left), which is Indigo's
// own convention, so neither the pane's scale nor the device's pixel density reaches a caller.
//
// One server process serves a whole Claude session INCLUDING its sub-agents (they share the
// parent's MCP connections, and calls carry no caller identity). So the "focused session" is a
// single process-wide pointer — concurrent agents would fight over it. Every action tool therefore
// takes an optional sessionId that targets a session directly; focus is only a single-agent
// convenience.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { controlCall, exitWithParent, makeTool, requireScope, text } from "./shared.mjs";

// A screenshot copies and PNG-encodes a full device framebuffer, and the degraded path shells out
// to `simctl io screenshot`; installing an app is a process spawn over a bundle. Neither fits the
// 10s default.
const SLOW_MS = 60_000;

const server = new McpServer({ name: "synth-simulator", version: "0.1.0" });
const tool = makeTool(server);

// ---------------------------------------------------------------------------
// Session targeting.

let focusedSessionId = null;

async function call(verb, body, options) {
  const scope = requireScope();
  const { ok, ...rest } = await controlCall(
    scope.inst, { verb, worktreePath: scope.path, ...body }, options);
  return rest;
}

async function sessions() {
  return (await call("simulator.list")).sessions ?? [];
}

/** The sessionId a tool acts on: the one it named, else the focused one. Explicit targeting does
 *  NOT move the focus — that is what keeps concurrent agents out of each other's sessions. A
 *  focus that has vanished is an ERROR, not a silent retarget onto whatever row is newest. */
async function targetSession(sessionId) {
  const rows = await sessions();
  if (sessionId) {
    if (!rows.some((s) => s.sessionId === sessionId)) {
      throw new Error(`no simulator session ${sessionId} in this worktree — see simulator_list`);
    }
    return sessionId;
  }
  if (focusedSessionId) {
    if (rows.some((s) => s.sessionId === focusedSessionId)) return focusedSessionId;
    const gone = focusedSessionId;
    focusedSessionId = null;
    throw new Error(
      `the focused simulator session (${gone}) is gone — closed, or its row was deleted. ` +
      "Call simulator_list, then simulator_focus (or simulator_create) to pick a target.");
  }
  if (rows.length === 0) {
    throw new Error(
      "no simulator sessions are open in this worktree — create one with simulator_create");
  }
  focusedSessionId = rows[rows.length - 1].sessionId;
  return focusedSessionId;
}

const sessionIdParam = z.string().optional().describe(
  "session to act on (from simulator_create/simulator_list); overrides the focused session " +
  "without moving the focus. ALWAYS pass this when running as one of several agents (sub-agents " +
  "share this server, and the focus is a single process-wide pointer — last create/focus wins)");

const fraction = (what) => z.number().describe(
  `${what} as a fraction of the screen, 0..1 from the top-left — 0.5 is the middle. Not pixels: ` +
  "divide a pixel position by the size simulator_screenshot reported");

// ---------------------------------------------------------------------------
// Discovery.

tool("simulator_list",
  "List this worktree's Synth simulator sessions: sessionId, title, branch, the device UDID and " +
  "name, whether that device is booted, and whether Synth is attached to its framebuffer " +
  "(`booting` while a device is still coming up — attaching retries every second). A session with " +
  "no device yet is a normal state, not a fault: the user picks one in the pane. Returns the " +
  "sessionId to pass to every other tool — do that whenever other agents may be driving " +
  "simulators too, since the focus is one pointer shared by this server's whole process.",
  null,
  async () => {
    const scope = requireScope();
    const { ok, ...res } = await controlCall(
      scope.inst, { verb: "simulator.list", worktreePath: scope.path });
    const note = scope.exact ? "" : `\n(scoped to enclosing managed worktree ${scope.path})`;
    return text(JSON.stringify(res, null, 2) + note);
  });

tool("simulator_devices",
  "List the simulator devices installed on this machine (udid, name, runtime, whether booted). " +
  "These are machine-global: a device is shared state that the user drives by hand and that two " +
  "branches may be looking at, not something a session owns. Pass a name or udid to " +
  "simulator_create to pick one.",
  null,
  async () => text(JSON.stringify(await call("simulator.devices"), null, 2)));

// ---------------------------------------------------------------------------
// Lifecycle.

tool("simulator_create",
  "Create a Synth simulator session in this worktree's branch — a row in the sidebar showing one " +
  "device's live screen, which you and the user both act on. Boots the device if it is shut down " +
  "(that takes tens of seconds; simulator_list says when Synth has attached, and actions report " +
  "\"still booting\" until then). Focuses the new session and returns its sessionId. Getting an " +
  "app onto the device is not this tool's job: build and install it yourself (simulator_install), " +
  "or leave the user's `npm run ios` / `xcodebuild` to it.",
  {
    device: z.string().optional().describe(
      "device name or udid, e.g. \"iPhone 16 Pro\" (a prefix or substring is enough). Omitted: a " +
      "device that is already booted if there is one, else the first installed iPhone"),
  },
  async ({ device }) => {
    const res = await call("simulator.create", { ...(device && { device }) });
    focusedSessionId = res.sessionId;
    return text(JSON.stringify(res, null, 2));
  });

tool("simulator_close",
  "Close a simulator session, removing its row from the sidebar. Do this as soon as you are done " +
  "with a simulator the user has no reason to keep — one you opened only to check your own work. " +
  "The DEVICE is not yours: it is machine-global state, so it is only shut down when no other " +
  "session still holds it (the reply says which happened). Leave the session open when you " +
  "opened it for the user to look at, and tell them it is there.",
  { sessionId: z.string().describe("the sessionId to close (from simulator_create/simulator_list)") },
  async ({ sessionId }) => {
    const res = await call("simulator.close", { sessionId });
    if (focusedSessionId === sessionId) focusedSessionId = null;
    return text(`closed ${sessionId} — ` + (res.deviceStaysBooted
      ? "another session still holds the device, so it stays booted"
      : "nothing else held the device, so it is shutting down"));
  });

tool("simulator_focus",
  "Select which simulator session subsequent tools act on by default. The focus is one pointer " +
  "for the whole Claude session (sub-agents included) — with several agents active, skip this and " +
  "pass sessionId per call instead.",
  { sessionId: z.string().describe("a sessionId from simulator_list") },
  async ({ sessionId }) => {
    focusedSessionId = await targetSession(sessionId);
    return text(`focused ${focusedSessionId}`);
  });

// ---------------------------------------------------------------------------
// Action. Coordinates are normalised because that is what the device speaks; the app turns them
// into Indigo touches on the same session the pane is showing.

tool("simulator_tap",
  "Tap the device's screen. Find what to tap with simulator_describe and pass the cx,cy it printed " +
  "for that element — discovery there, action here. This is a coordinate, not an element: nothing " +
  "here knows what is under it, so a tap aimed by eye at a screenshot is a guess.",
  { x: fraction("horizontal position"), y: fraction("vertical position"), sessionId: sessionIdParam },
  async ({ x, y, sessionId }) => {
    await call("simulator.tap", { sessionId: await targetSession(sessionId), x, y });
    return text(`tapped (${x}, ${y})`);
  });

tool("simulator_swipe",
  "Swipe or drag across the device's screen — scrolling a list, a page in a pager, a sheet " +
  "dismissal. The gesture is paced in real time and interpolated, so iOS reads it as a swipe with " +
  "velocity rather than a teleport; a longer duration is a slower drag, which is what a " +
  "pull-to-refresh or a careful drag needs.",
  {
    fromX: fraction("start x"), fromY: fraction("start y"),
    toX: fraction("end x"), toY: fraction("end y"),
    durationMs: z.number().finite().min(16).max(10_000).optional().describe(
      "how long the finger is down in ms (default 300; longer = slower drag). Bounded: the gesture " +
      "is paced in real time, so a very long duration would just block."),
    sessionId: sessionIdParam,
  },
  async ({ fromX, fromY, toX, toY, durationMs, sessionId }) => {
    await call("simulator.swipe", {
      sessionId: await targetSession(sessionId), fromX, fromY, toX, toY,
      ...(durationMs !== undefined && { durationMs }),
    }, { timeoutMs: SLOW_MS });
    return text(`swiped (${fromX}, ${fromY}) → (${toX}, ${toY})`);
  });

tool("simulator_type",
  "Type text into whatever the device has focused — tap the field first. Keystrokes go in as HID " +
  "keyboard usages, so \\n is Return; a character with no key on a US keyboard (an emoji, an " +
  "accent) is refused rather than half-typed.",
  {
    text: z.string().describe("text to type into the focused field"),
    sessionId: sessionIdParam,
  },
  async ({ text: value, sessionId }) => {
    await call("simulator.type", { sessionId: await targetSession(sessionId), text: value });
    return text(`typed ${JSON.stringify(value)}`);
  });

tool("simulator_press_button",
  "Press a hardware button: home, lock, sideButton, siri, applePay. Volume is deliberately " +
  "absent — the legacy Indigo path has no event source for it, so offering it would mean " +
  "offering something that silently does nothing.",
  {
    button: z.enum(["home", "lock", "sideButton", "siri", "applePay"]).describe(
      "which hardware button"),
    sessionId: sessionIdParam,
  },
  async ({ button, sessionId }) => {
    await call("simulator.pressButton", { sessionId: await targetSession(sessionId), button });
    return text(`pressed ${button}`);
  });

tool("simulator_rotate",
  "Turn the device to a given orientation — how you check a landscape layout, or a rotation your " +
  "app handles badly. Three things about it are worth knowing before you use it. Whether the app " +
  "actually turns is the APP's decision: one that declares portrait-only stays portrait and nothing " +
  "outside it can tell, so read the screen afterwards rather than assuming. The screen's pixel size " +
  "does NOT change — iOS draws its rotated interface into the same framebuffer — so " +
  "simulator_screenshot still reports the portrait size and hands back a sideways image; the user's " +
  "pane turns it upright, you have to allow for it. simulator_describe is unaffected: it works out " +
  "which way the app actually laid itself out by asking the device, so the cx,cy it prints is always " +
  "in simulator_tap's own coordinates and a tap at one lands whichever way up the device is.",
  {
    orientation: z.enum(["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"])
      .describe(
        "which way up. These are UIDeviceOrientation's own names, which are famously confusing: " +
        "landscapeLeft turns the device anticlockwise (its right-hand edge ends up at the top), " +
        "landscapeRight turns it clockwise. Either gives you a landscape layout; pick landscapeRight " +
        "if you have no reason to prefer one"),
    sessionId: sessionIdParam,
  },
  async ({ orientation, sessionId }) => {
    const res = await call("simulator.rotate", {
      sessionId: await targetSession(sessionId), orientation,
    });
    return text(`rotated to ${res.orientation} — ${res.note}`);
  });

tool("simulator_shake",
  "Shake the device. This is how you open the dev menu in a React Native or Expo app, and how you " +
  "trigger UIKit's shake-to-undo. It is a Darwin notification the app has to be listening for: an " +
  "app that ignores shakes shows nothing, and that is indistinguishable from here.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    await call("simulator.shake", { sessionId: await targetSession(sessionId) });
    return text("shook the device");
  });

// ---------------------------------------------------------------------------
// Observation. `simulator_describe` first, always: the accessibility tree of a real screen is a few
// hundred bytes where its screenshot is a megabyte, and it carries the labels and identifiers a
// screenshot makes you guess at.

tool("simulator_describe",
  "Read what is on the device's screen as text: the accessibility tree of the frontmost app. Do " +
  "this BEFORE simulator_screenshot — a whole screen is a few hundred bytes here against " +
  "thousands of tokens for an image, and it gives you labels and identifiers instead of pixels. " +
  "Discovery is this tool, action is simulator_tap at an element's centre: every line ends up as " +
  "`role|label|cx,cy` where cx,cy is the centre in 0..1 screen fractions, so pass those straight " +
  "to simulator_tap. Extra fields follow as tags: #accessibilityIdentifier, value=…, disabled, " +
  "focused; empty ones are omitted rather than printed as null. Pass x and y to hit-test a single " +
  "point instead of walking the tree — do that when something you can see in a screenshot is " +
  "missing from the list, which happens with SwiftUI tab bars, nav bars and toolbars (they " +
  "enumerate as empty containers, and their buttons only surface by being hit at). A hit-test on " +
  "empty space answers with the enclosing container's contents rather than nothing. Re-describe " +
  "after every action: this is a snapshot, not a subscription.",
  {
    x: z.number().optional().describe(
      "hit-test this horizontal fraction (0..1 from the left) instead of listing the whole tree; " +
      "pass y too"),
    y: z.number().optional().describe(
      "hit-test this vertical fraction (0..1 from the top) instead of listing the whole tree; " +
      "pass x too"),
    sessionId: sessionIdParam,
  },
  async ({ x, y, sessionId }) => {
    if ((x === undefined) !== (y === undefined)) {
      throw new Error("pass both x and y to hit-test a point, or neither for the whole tree");
    }
    const res = await call("simulator.describe", {
      sessionId: await targetSession(sessionId),
      ...(x !== undefined && { x, y }),
    }, { timeoutMs: SLOW_MS });
    return text(res.tree
      + (res.degraded ? `\n(degraded: ${res.degraded})` : "")
      + (res.note ? `\n(${res.orientation}: ${res.note})` : ""));
  });

tool("simulator_screenshot",
  "Screenshot the device's screen (PNG, at the device's own pixel size). The image is a copy taken " +
  "at capture time, so two screenshots of a screen that changed really do differ. Reach for this " +
  "when you need to see it — layout, colour, a rendering bug, something with no accessibility " +
  "label. To find out what is on screen and where to tap, simulator_describe is the same answer " +
  "for a thousandth of the tokens.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const sid = await targetSession(sessionId);
    // The PNG travels via a file rather than base64 inside the control socket's JSON line: same
    // bytes, and a megabyte-long line is a worse failure mode on both ends.
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "synth-sim-")), "screen.png");
    try {
      const res = await call("simulator.screenshot", { sessionId: sid, path: file },
                             { timeoutMs: SLOW_MS });
      const data = fs.readFileSync(file).toString("base64");
      const notes = [
        res.degraded && `degraded: ${res.degraded}`,
        res.fallback,
        res.note,
        res.torn && "the guest drew while the frame was being read, so a band of it may be from " +
                    "the next frame (inherent to reading a live surface; take another if it matters)",
      ].filter(Boolean);
      return {
        content: [
          { type: "image", data, mimeType: "image/png" },
          { type: "text",
            text: `${res.width}×${res.height} device pixels` +
                  (notes.length ? ` — ${notes.join("; ")}` : "") },
        ],
      };
    } finally {
      fs.rmSync(path.dirname(file), { recursive: true, force: true });
    }
  });

// ---------------------------------------------------------------------------
// Apps. Genuinely `simctl` work, which the app shells out for so the agent and the user are always
// talking about the same device.

tool("simulator_launch",
  "Launch an installed app on the device by bundle identifier, foregrounding it. Launching an app " +
  "that is already running brings it forward; it does not restart it.",
  {
    bundleId: z.string().describe("bundle identifier, e.g. com.apple.Preferences"),
    args: z.array(z.string()).optional().describe("launch arguments passed to the app"),
    sessionId: sessionIdParam,
  },
  async ({ bundleId, args, sessionId }) => {
    const res = await call("simulator.launch", {
      sessionId: await targetSession(sessionId), bundleId, ...(args && { args }),
    }, { timeoutMs: SLOW_MS });
    return text(`launched ${bundleId}${res.output ? ` — ${res.output}` : ""}`);
  });

tool("simulator_terminate",
  "Stop a running app on the device. Pair it with simulator_launch when you need a known starting " +
  "state: launching an app that is already running only brings it forward, so whatever the last " +
  "run left on screen is still there.",
  {
    bundleId: z.string().describe("bundle identifier, e.g. com.apple.Preferences"),
    sessionId: sessionIdParam,
  },
  async ({ bundleId, sessionId }) => {
    await call("simulator.terminate", { sessionId: await targetSession(sessionId), bundleId },
               { timeoutMs: SLOW_MS });
    return text(`terminated ${bundleId}`);
  });

tool("simulator_open_url",
  "Open a URL on the device — an https link in Safari, or your app's own scheme or universal link, " +
  "which is how you reach a deep link without navigating to it by hand.",
  {
    url: z.string().describe("URL to open, e.g. https://example.com or myapp://order/42"),
    sessionId: sessionIdParam,
  },
  async ({ url, sessionId }) => {
    await call("simulator.openUrl", { sessionId: await targetSession(sessionId), url },
               { timeoutMs: SLOW_MS });
    return text(`opened ${url}`);
  });

tool("simulator_install",
  "Install a built .app bundle on the device. Synth does not build your app (ADR-0015): point " +
  "this at what your own build produced — a .app under a DerivedData Build/Products directory, or " +
  "wherever your build script put it. Installing over an existing copy replaces it and keeps its " +
  "data; launch it afterwards with simulator_launch.",
  {
    path: z.string().describe("absolute path to the .app bundle"),
    sessionId: sessionIdParam,
  },
  async ({ path: appPath, sessionId }) => {
    await call("simulator.install", { sessionId: await targetSession(sessionId), path: appPath },
               { timeoutMs: SLOW_MS });
    return text(`installed ${appPath}`);
  });

await server.connect(new StdioServerTransport());
// No persistent handles to release — every verb is one control-socket round trip — but exit
// promptly on parent death rather than lingering on an in-flight screenshot's socket wait.
exitWithParent();
