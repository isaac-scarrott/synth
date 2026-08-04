# The simulator is a session whose screen we read straight from the device's framebuffer

CONTEXT.md has listed the simulator as a session type since the vocabulary was written, and the designs
have carried an `iPhone 15 Pro` row with a drawn device frame since before 0.18.0. Neither was backed by
a line of Swift. This ADR commits to what a simulator session *is*, and to the one architectural choice
that decides everything downstream: **where the pixels come from**.

It follows ADR-0011's shape deliberately. The browser answered "the visible browser and the agent-driven
browser are the same surface" by picking an engine that speaks CDP. The simulator answers the same
question — you and Claude act on one device, not two — and the answer forces a different mechanism,
because a simulator is a separate process that will never hand us its window.

## The screen comes from the device's IOSurface, not from a captured window

A booted simulator device publishes its display as an `IOSurface` on a display port hanging off
`SimDevice.io`. We read that surface directly, in-process, and hand each new frame to an
`AVSampleBufferDisplayLayer` hosted in the pane. **Simulator.app is never launched and never involved.**

This was chosen over mirroring Simulator.app's window with ScreenCaptureKit, which is the obvious-looking
route and the wrong one. Window capture makes our pane a photograph of somebody else's window: it dies
when that window is minimised, occluded or on another Space; it drags in a Screen Recording TCC grant; it
forces input back through `CGEventPostToPid`, which delivers clicks and keys to a background app but
**drops mouse-move and scroll** — scroll routes by physical cursor position, and tracking areas are
`NSTrackingActiveInActiveApp` — so hover and panning would only work by stealing focus. And in Xcode 27
Simulator.app is replaced by Device Hub, which is exactly the kind of ground-shift that already killed
RocketSim's window-anchored architecture. Reading the framebuffer is untouched by all of it.

Reparenting the simulator's window into our hierarchy is not on the table, for the same reason ADR-0011
gave for Chrome: there is no supported or private path. `NSWindow.addChildWindow` needs an in-process
`NSWindow*` and no API converts a `CGWindowID` into one; `CARemoteLayerServer`, `EXHostViewController`
and `NSRemoteViewController` all require the *other* process to opt in, and Simulator.app never will.
Capture-and-forward is not a compromise here, it is the only architecture at this layer.

**This is private API, and that is an accepted cost, not an oversight.** Every shipping implementation of
this — Meta's idb, Anthropic's own simulator pane in Claude Code Desktop, NativeScript's SimDeck,
Software Mansion's `simulator-server` behind Radon IDE and Maestro Viewer — uses the same frameworks by
the same route, because Apple has shipped no alternative: there is still no public frame callback, no
touch-injection verb in `simctl` at any version, and no streaming or embedding API. Xcode 27 gave *agents*
simulator control through Apple's own MCP server, but only with Xcode.app running and the project open,
and it still exposes no way to put a live device inside another app's window.

The distribution question was tested rather than assumed. A Developer ID-signed, hardened-runtime binary
with **zero entitlements** loads both frameworks and drives a device: Library Validation admits them
because they are Apple-signed, so `com.apple.security.cs.disable-library-validation` is unnecessary and
would be a net loss. Notarization does not inspect for private API — per Apple DTS, "the notary service
does not currently do any sort of quality checks on your product". Synth ships Developer ID + notarized
through Sparkle, so this is clear. It also means **Synth can never go to the Mac App Store**, where
App Review does scan for non-public API. That trade is made knowingly.

## v1 attaches to a device and drives it; it does not build your app

A simulator session boots a device and gives you its screen, live and interactive, with Claude able to act
on the same screen. **Getting an app onto that device stays the user's job** — the terminal session already
running `npm run ios`, `expo`, or `xcodebuild` is not something Synth needs to own to be useful.

Owning the build loop was considered and deferred, not rejected on principle. Scheme detection,
`xcodebuild -destination` plumbing, error surfacing, and the long tail of RN / Expo / Tuist / SPM project
shapes is a project in its own right, and none of it is needed for the thing that makes a simulator
session worth having: seeing your app while an agent changes it. Synth owns the surface, not the content
— the same line the browser draws, where we run the browser and you decide what to load into it.

## A session claims a device from the installed fleet, and boots it

Creating a simulator session picks a device from `simctl list` and boots it if it is shut down; the last
session to let go of a device shuts it down again. Devices are machine-global state, so two branches that
pick the same model get the same device and therefore the same app state.

Cloning a device per branch — the device-level analogue of ADR-0004's worktree-per-branch — is the more
principled answer and is deliberately not v1. It costs a full device directory per clone, and it litters
`simctl list` with Synth-managed devices that would need their own sweeper, the way `ArchiveSweeper`
tends worktrees. That is a real feature with a real cost, and it should be built when shared device state
actually bites, not in anticipation. The persisted field is the device UDID, so nothing about this
decision blocks it later.

Attaching only to already-booted devices, never touching machine state, was rejected because it makes
"open a simulator" stop being one keystroke, which is the opposite of the premise.

## Input is Indigo HID, injected into the same device you are looking at

Touches, keys and hardware buttons are Indigo messages sent through SimulatorKit's legacy HID client to
the device's `IndigoHIDRegistrationPort`, addressed in normalised 0..1 display coordinates. There is no
XCUITest runner, no injected test bundle, and no app-side agent — the device is driven from outside, so
it works on any app, including ones we did not build.

The same path serves the user's pointer and Claude's tool calls, which is what makes ADR-0011's
same-surface guarantee hold here. A tap from the agent and a tap from the mouse are the same message.

## Claude drives it through a `synth-simulator` MCP server, mirroring `synth-browser`

A second Node stdio MCP server beside the existing one, installed by `MCPInstaller` and registered
per-worktree through the same `.mcp.json` / `opencode.json` sync. It resolves its Synth instance and
branch exactly as `synth-browser` does, and reaches the app over the existing control socket.

Unlike the browser, **every verb goes over the control socket** — there is no CDP-equivalent second
channel. The app already holds the warm HID session and the framebuffer, and routing everything through
it preserves the invariant `ControlServer` already documents: a tool call runs the same function the UI
runs. Where a verb is genuinely `simctl` work (list, install, launch, openurl) the app shells out, so the
agent and the user are always talking about the same device.

The tool vocabulary follows the convention that has converged across idb, mobile-mcp, AXe, Argent and
Maestro rather than inventing one: discovery, observe, act, lifecycle. **Observation is structured, action
is coordinate-based** — the agent reads the accessibility tree and taps the centre of an element's frame.
This is near-universal in the tools that work, and the reason is cost: an accessibility dump is tens to
hundreds of tokens where a screenshot is thousands. Accessibility comes from
`SimDevice.sendAccessibilityRequestAsync` with `AXPTranslator`, so it needs no test runner either.

## The live screen sits inside the hardware frame we already draw

0.18.0 replaced the generic black rectangle with device geometry taken from real hardware — per-edge
bezel, body and screen radii, side buttons on the rail — laid out at true viewport size and scaled to the
pane. The live stream goes inside that frame, and the device is resolved from the booted device's actual
model instead of being parsed out of the session's name.

**The drawn status bar comes out.** iOS renders its own status bar, island and home indicator into the
framebuffer, so drawing ours on top would double them. The frame keeps what the device cannot draw —
body, bezel, buttons, shadow — and the screen shows exactly what the device shows. Device screens stay
light in both themes, unchanged from 0.18.0: it is a separate machine on the desk.

## A device is never owned; a session row could be. They are different questions

**(Corrected 2026-08-03. The first version of this section conflated the two, and got the second one
wrong on the strength of the first.)**

**The device is never owned.** It is machine-global state that the user drives by hand and that two
branches may share by design, per the device-lifecycle decision above. Its lifetime is decided by
reference count: the last session to let go shuts it down. An agent tidying up after itself must never
shut down a device someone else is looking at, and no ownership relationship may be allowed to imply
otherwise. This is implemented and is not up for negotiation.

**Reference count is only half of it, and the missing half was a `simctl boot` that did nothing.**
Claiming a device boots it if it is shut down and no-ops if it is not, so a claim on its own says
nothing about who started the device. Synth therefore records a claim *only* on an observed shutdown →
booted transition, and only a recorded claim ever authorises a shutdown — through `closeSession`,
through quit, or through the launch sweep. A device the user had running when a row attached outlives
every session Synth had on it, and losing a boot race counts as somebody else's boot. The record is
also **per Synth instance** (`simulator-claims/<pid>.json`, swept by dead pid the way
`InstanceRegistry` sweeps its advertisements): it used to be one shared `UserDefaults` key, so
starting a second Synth shut down the device the first one was displaying. Getting this wrong costs
the user their app state and any attached Xcode debug session, silently, which is why it is worth this
much prose.

**Whether a session row belongs to an agent is a separate question**, and the original text answered it
by mistake — it argued from "a device is shared" to "a simulator row cannot be owned", which does not
follow. ADR-0011's stage-four `ownerSessionID` is about *containment*: a visible relationship saying this
row exists because that agent made it, and closing the agent closes the row it spawned. That is just as
sensible for a simulator an agent opened to check its work as for a browser. Nothing about it requires
exclusive control of the hardware underneath, because release is reference-counted either way: closing an
owned row decrements, and only the last holder shuts the device down.

So: simulator rows carry no owner **today**, because nothing yet needs one — not because ownership is
wrong for them. The first thing that will need it is comment mode (below), whose whole delivery ladder is
addressed to an owner. When that lands, session-level ownership comes with it, and the device-sharing rule
above is unaffected.

**A simulator session with no device is a real state, not an error.** The worktree session template
constructs sessions by kind directly, so it can spawn a simulator row that has never claimed a device;
restored sessions likewise hold a UDID but no claim until their pane renders. The pane therefore needs a
first-class "pick a device" state rather than assuming a booted device exists, and `simulatorUDID` is
optional for that reason.

## The screen is also readable as text, without a test runner

`simulator_describe` reads the frontmost app's accessibility tree straight off the device:
`-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` plus the `AXPTranslator`
singleton from `AccessibilityPlatformTranslation.framework`, with our own `bridgeTokenDelegate`. **No
XCUITest runner, no injected test bundle, no `xcodebuild test-without-building`** — which is what lets it
work on an app we did not build, and is why it costs milliseconds rather than the 60+ seconds Appium
spends launching WebDriverAgent.

`AXPTranslator` has a **single** `bridgeTokenDelegate` slot, so there is exactly one process-wide
dispatcher and concurrent requests are told apart by token. Two panes on two devices cannot be allowed to
race for that slot.

Two request kinds, and the second is not a convenience: the frontmost-application walk, and a **point
hit-test**. The hit-test reaches elements the walk does not — asked at a status-bar coordinate it returned
a SpringBoard element absent from the walk entirely — which is the case for keeping both.

**Output is compact by design, because that is the entire point.** One element per line — role, label,
identifier, value, state — each carrying its frame's centre in the same normalised 0..1 coordinates
`simulator_tap` takes, so discovery feeds action directly. The honest measurement: a Settings root tree is
1069 bytes against a 219 KB PNG of the same screen, which is 206× on the wire but only **~5× in tokens**
(~300 versus ~1,500 for a downscaled image). The byte ratio is the wrong number to quote. The real win is
that the tree carries `#com.apple.settings.general` next to "General", so an agent aims a tap instead of
guessing at pixels — and an accessibility identifier is a string the developer can grep for in their own
source.

**There is no accessibility fallback.** `simctl` has no verb that reads a tree at any version, so a
degraded source refuses with an explanation rather than returning an empty tree — which would read as "the
screen has nothing on it" and is worse than an error.

### Corrections to the research this was built from

- **Frames arrive in the guest's own point space**, root at exactly `(0, 0, w, h)`. Reference
  implementations prescribe a width-uniform scale plus a letterbox offset, but that is for content inside
  Simulator.app's window. With no window, our
  `accessibilityTranslationConvertPlatformFrameToSystem:withToken:` is the identity, and a letterbox
  transform would invent an offset. Normalise against the device type's point size and nothing else.
- **`mainScreenScale` is not a `double`** despite reading like one. Messaging it as one returns register
  garbage — a NaN that propagates into every coordinate and traps in `Int(_:)`. Read both screen-geometry
  properties by key so KVC boxes them by their real type encoding.
- **`AccessibilityPlatformTranslation.framework`'s binary exists only in the dyld shared cache.** A
  `fileExists` precondition on its path rejects a framework that `dlopen`s perfectly well.
- **`accessibilityEnabled`, `accessibilityHidden`, `accessibilityFocused`, `accessibilitySelected` and
  `accessibilityTraits` do not resolve** on `AXPMacPlatformElement` here — and `valueForKey:` on an absent
  key *raises*, which aborted a probe outright. Every read goes through `respondsToSelector:` first, which
  also removes the need for an ObjC-exception shim; the repo has never had one.
- **The crashed-SpringBoard guard's pid half is nearly inert**: on a healthy tree the root's
  `accessibilityPresenterProcessIdentifier` reads `0`, i.e. always "dead". The zero-frame condition carries
  the check; the pid only prevents a false positive mid-launch. Do not rely on pid alone.
- `objectAtPoint:displayId:bridgeDelegateToken:` is **not** iOS-26-only, contrary to the reference
  material — it resolves on Xcode 16.4.

Not exercised anywhere yet, and worth knowing: the iOS 26.5+ pre-boot preferences write (implemented and
version-gated, but no runtime here needs it), two devices describing concurrently (the single-delegate
argument rests on the token registry, not on observation — four concurrent describes on *one* device were
verified), and the SpringBoard-crash retry itself.

## Accessibility frames are in the interface's space; taps address the display

These are different spaces whenever the interface is rotated, and conflating them is a silent wrong
answer rather than an error. The framebuffer never rotates — iOS draws its rotated interface sideways into
the same surface — so `tap` always addresses a portrait display, while AXP reports frames in whatever space
the app has laid itself out in.

A first attempt transposed the tree's divisor whenever `orientation.isLandscape`, and that was wrong twice
over. **An app can refuse to rotate** — Settings is portrait-locked — and nothing outside it can tell, so a
portrait tree got divided by the wrong axes and reported centres that tapped a different row. And for an
app that *did* rotate, dividing by the transposed size gives a correct point in the interface's space,
which `tap` then applies to the display: right numbers, wrong space, 90° out. Both were demonstrated by
tapping a reported centre and landing somewhere else.

**The projection is arithmetic; knowing which one to apply is the whole problem.** Normalise a frame's
centre against the interface's own extent — the display's point size, transposed when the interface is
landscape — and then apply that interface orientation's own `displayPoint(fromUpright:)`, the same
transform the pane uses to send a click to Indigo. The interface's space and the upright picture the user
sees are one space, so there is one transform for both and no second concept to keep in step.

**Which of the four an app laid itself out in is confirmed against the device, per read.** Nothing here
will say: the guest publishes no orientation read-back, an app may ignore a rotation, and the root frame's
shape says *landscape* without saying which landscape. What the device will answer is a hit test — and
`objectAtPoint:` takes points in the **display's** space while every frame comes back in the interface's,
which is exactly the asymmetry that makes the question answerable. Predict where an element's centre lands
on the display under a candidate space, ask what is at that place, and accept the candidate only if what
comes back *is* that element. A wrong candidate names a point belonging to some other part of the screen,
and the answer's frame says so. The root frame rules out the candidates it cannot fit; what Synth last
asked for only *orders* the survivors, so the usual read costs one extra round trip and a portrait-locked
app is read as portrait however many rotations it was sent. The point hit-test verb gets its confirmation
free: the caller's own point resolved to an element, and only a space that puts that point inside that
element's frame can be the real one — one consistent candidate is a proof.

Two things about that confirmation were measured rather than reasoned, and both are load-bearing.
**Containment is not confirmation**: asked in the wrong space, Safari's address field came back containing
the keyboard's dictate key's centre at three times its area, so an area bound loose enough to admit a
legitimate wrapper admitted that too. The test is that the returned element sits *inside* the candidate
element's own frame. And **the status bar shadows hit tests** in the display's top strip — SpringBoard's
Dynamic Island answers there — so a prediction landing in it confirms nothing; more than one anchor is
tried for that reason.

### A tree can be in two coordinate spaces at once

Found while finishing the projection, and not something any of the reference implementations mention.
**With the keyboard up in landscape, Safari's own elements come back in the interface's space while every
key comes back in the display's, unrotated** — as flat siblings of them, in one list. There is nothing
structural to tell them apart: `accessibilityWindow`, `accessibilityParent` and
`accessibilityTopLevelUIElement` are all absent on `AXPMacPlatformElement` here, and
`accessibilityPresenterProcessIdentifier` reads 0 on every element, not just the root. Measured: a hit
test at a key's raw centre returns that key, and at its projected centre returns nothing.

So each element is assigned a space, not the tree. Elements the app's own extent cannot hold but a
transposed one exactly can are the evidence that a second space exists; that space is then confirmed the
same way the first was; and elements that *both* could hold — the overlap is the whole top-left square of
the display — are settled one hit test each, bounded, with anything the device will not settle reported in
the app's own space and the tree saying so. That cost is paid only on a screen that really is mixed. Two
things are deliberately *not* read as a second space, because they are not one: an element that overflows
every space (a carousel's content view is wider than the screen whichever way up it is), and a frame
overhanging its own bounds by a few points — the emoji and dictate keys stick 3pt past the display's right
edge, and reading that as proof of a different space is how a correct classification turns into a wrong one.

`describe` still refuses when no projection can be confirmed at all, naming the two sizes — but a
portrait-shaped tree the size of the display falls back to the identity with a printed caveat rather than
refusing, because a launching app or an alert over a bare root has nothing to hit test against and the
identity is the only reading its own extent admits. What stays indistinguishable from out here, and is
therefore stated rather than handled: an interface laid out upside down whose root is portrait-shaped, and
a second space living wholly inside the region both spaces could contain.

### Corrections to the projection attempt this was finished from

- **"The interface's space turns opposite to the orientation's name" was wrong.** `landscapeRight`'s own
  transform is the right one to apply to an interface laid out for `landscapeRight`; nothing needs
  inverting. Both landscape transforms map 0..1 onto 0..1, so centres *outside* 0..1 cannot have come from
  the transform's direction at all — they came from normalising against the un-transposed portrait profile
  before applying it. The measurement was real; the conclusion drawn from it was not.
- **"`objectAtPoint:` takes display points" holds**, and it is more than a fact to design around — it is
  the only reason a projection can be confirmed instead of assumed.
- **"Both together are still not enough" was a consequence of the first error.** With the interface's own
  extent as the divisor, a hit test at a reported centre returns the element that reported it: 5 of 6
  anchors matched frame-exactly on the first try, and the sixth was a Safari tab genuinely scrolled off
  the display, which produces an untestable prediction under the *correct* projection too. There was no
  missing origin and no inset.

The assertions that let the first attempt through are worth recording as a lesson. One compared Synth's own
transposition against the flag the check had just set — `874 > 402`, unfalsifiable. The other printed
"describe→tap round-trips in landscape" while never issuing a tap in landscape at all. **An assertion that
pins the wrong behaviour is worse than no assertion**, because it converts a bug into a guarantee.

What replaced them names a *consequence*, and "the screen changed" is deliberately not it: a tap a quarter
turn out changes the screen too, by hitting something else. So the check taps the reported centre of
Safari's address field in landscape and requires the keyboard to appear; taps the reported centre of the
keyboard's own `x` key — the element in the second space — and requires the field to read `x`; and taps
Settings' General row while the device has been asked for landscape and requires its About row to appear.
Each consequence is asserted absent before and present after. All three were then shown to fail against a
deliberately broken projection, and the interesting part of that run is that `tap-changed-screen` still
passed at 34% while the tap landed on Apple Intelligence & Siri instead of General. That is the assertion
this feature is not allowed to rest on. 48 assertions pass live, and the forced-degraded run passes too.

## Comments are stage three, and the accessibility tree is what makes them possible

ADR-0011's stage three lets the user click an element on the live page and leave a comment that reaches
the owning Claude session as *located* context. The simulator wants the same thing, and it is not built.
Recording what it needs, because the shape is now clear and one part of it is not obvious:

`CommentMode` reaches its anchor by **injecting JavaScript into the page** to intercept the click and
build a CSS selector. There is no equivalent here: no DOM, and no injection point, because the app under
test is not ours. **The anchor is the accessibility element under the tap** — role, label, identifier and
frame, from the hit-test above. That is a better anchor than a CSS selector, not a worse one: an
accessibility identifier is a string the developer can search for in their own source, which is exactly
what a located comment is for. Intercepting the tap itself is trivial, since the pane already converts the
pointer to normalised device coordinates before handing it to Indigo.

Two things carry over unchanged. Delivery is the existing ladder — owner live, owner dormant so boot and
wait, no owner so spawn one — which is why this is the feature that brings session-level ownership with it.
And the security posture: accessibility labels come from the app under test, so a comment embeds
**untrusted text** exactly as a page-derived one does, and delivery must stay restricted to a session the
supervisor seam has confirmed, because Claude Code has no injection API and delivery pastes.

## Shipping rules, added after an independent review (2026-08-03)

The feature was reviewed by someone with no stake in it, against the bar "assume every user turns the
Experimental toggle on". The private-API layer survived that review — framework relocation and selector
loss were *demonstrated* to degrade rather than break, and two sessions on one device were shown to
coexist. Every serious finding was in the app integration around it. The rules those findings turned into:

**Nothing that crosses the private boundary is converted directly.** `Int(someDouble)` traps on NaN, on
infinity and out of range, and a private property whose real type is not the one we messaged it as returns
register garbage — which is exactly how `mainScreenScale` produced a NaN that reached `Int(_:)`. A trap
here is not a degraded pane, it is the loss of the user's terminals and agent sessions. Numbers from a
private read *or from a tool argument* go through `safeInt`/`safeDuration`. Tool arguments count because
the control socket is reachable by any local process: an unbounded `durationMs` was both a trap (negative
values converting to unsigned) and a way to block a thread for minutes.

**No `simctl` on the main actor, ever.** Enumerating the fleet is three subprocess spawns plus a plist read
per installed device — around 350 ms — and the pane needed a device's geometry on attach and again on every
retry tick while it booted. Measured, that put the main thread at 76% blocked for the length of a boot, in
an app whose first stated principle is that chained shortcuts feel instant. The fleet is cached and
refreshed off-actor; panes read the cache. A slightly stale device costs one extra retry, which is the
cheap direction to be wrong in.

**An input verb that cannot prove it worked must not claim it did.** Delivery is asynchronous — built on
main, sent on a private queue — so the call cannot report its own send. It can refuse when there is no
session and surface a failure a send already recorded, and that is now what it does; every input verb
throws, and the pane shows the refusal. Answering "tapped" for a tap that never left the process is the one
answer an agent cannot recover from: it re-reads the screen, sees nothing, and taps again forever.

**Silence is not death, and death is not silence.** The cadence is damage-driven, so a static screen
legitimately produces no frames — but the IOSurface stays mapped after the device goes away, so
`captureCurrentFrame()` keeps succeeding with the last screen of a device that no longer exists. Liveness is
therefore *asked* of CoreSimulator before a frame is handed out as current, not inferred from frame arrival.

**Devices Synth booted are released when Synth quits.** Quitting does not route through `closeSession`, and
a detached task does not outlive the process, so this is a synchronous shutdown on the terminate path
alongside the existing state flush. A leaked booted device costs the user well over a gigabyte and dozens of
processes, with nothing in any UI to say why.

**Private handles are confined.** The HID client is written off-actor (the session costs ~1.2 s to open),
read on the send queue, and cleared on teardown; three threads on one strong reference is a double-release.
Everything crossing threads is locked or queue-confined.

**And the feature ships behind an Experimental toggle, off by default**, with the `synth-simulator` MCP
server registered only when the toggle is on *and* a full Xcode is present. Registering a server whose every
tool errors costs every agent context for nothing. `isXcodeAvailable` tests for `simctl` alone: it used to
accept any of three paths, which made the Command Line Tools look like a full Xcode, so the feature
advertised itself and then failed with `xcrun: error: unable to find utility "simctl"`.

**The toggle is enforced at the socket, not only in what Synth offers.** Which create routes appear and
which MCP servers are registered is discoverability, and discoverability is not a gate: the control
socket is reachable by any local process, and an agent that was running when the toggle flipped still
holds the tool list it was given — so `simulator.create` booted a device with the experiment off. Every
`simulator.*` verb now refuses unless the toggle is on and Xcode is present, and the refusal names the
toggle, because an agent with a stale tool list needs to be told why rather than left guessing.

## Consequences

- Synth gains a hard dependency on a full Xcode install, located through `xcode-select` / `DEVELOPER_DIR`
  and never hardcoded. Simulator sessions are unavailable without it and must say so plainly.
- Framework paths, class names and selectors are resolved by name at runtime — `dlopen`, `NSClassFromString`,
  `dlsym`, guarded by `respondsToSelector:` — and never linked. Xcode 27 alone moved SimulatorKit's bundle,
  migrated display protocols to `CoreSimDeviceIO`, deleted `attachConsumer:`, and changed the Indigo mouse
  builder's signature. Every one of those is survivable by a name lookup and fatal to a link.
- A `simctl`-only degraded mode is part of the design, not a later rescue: when the framebuffer path fails
  to resolve, the pane falls back to `simctl io screenshot` polling so a simulator session still shows
  something, and says why it is degraded.
- Mac App Store distribution is foreclosed.
- Frames are pushed on the device's damage callback, not on a timer. A static screen costs nothing; this is
  the same contract Google's emulator gRPC service arrived at independently, and it should not be traded
  for a fixed frame rate.

## Verified on this machine before committing

Xcode 16.4 / macOS 15.3.2, from a plain third-party process with Simulator.app never launched:
`SimServiceContext` → default device set → booted `iPhone 16` → display port → live `IOSurface` at
1179×2556 @3x, JPEG-encoded; then an Indigo tap at normalised (0.5, 0.28) landed on Settings' Apple Account
row and pushed its sign-in sheet, confirmed by re-capture. Damage-driven cadence measured at 1 frame in 3s
on a static screen and 6 while the sheet animated.

## The frame rate was measured before the pane was designed around it, and it holds

Benchmarked at 1179×2556 against a page repainting every frame, timing the production step only
(`IOSurface` → `CVPixelBuffer`; no JPEG or H.264, because the pane hands the buffer to an
`AVSampleBufferDisplayLayer`):

| | |
|---|---|
| static screen | 1 frame / 5.2s |
| full-frame animation | **50.9 fps mean**, gap p50 **16.96 ms** (= 59 fps modal) |
| gap p95 / p99 | 53.7 ms / 92.3 ms |
| our cost per frame | **p50 0.022 ms**, p99 8.4 ms |
| torn frames | 1.3% |

**We are not the bottleneck and the pane can feel native.** Our own work is 22µs against a 16.7ms frame —
0.13% of the budget. The modal cadence is a clean 60Hz; the mean sits at 51 because of occasional
multi-frame stalls (p99 92ms) which are the guest's own render jank, not capture. Tearing is inherent to
handing over a live surface rather than copying it, and at 1.3% it is the right trade — detect it, as idb
does, rather than pay to prevent it.

Three implementation constraints fell out of measuring, each of which would otherwise have been found the
hard way:

- **A booted device exposes two ports with `portIdentifier == "com.apple.framebuffer.display"`**, the same
  proxy class and the same proxy UUID — and the first is inert, `displaySize` 0×0 with a nil
  `framebufferSurface`. Selecting on protocol conformance alone, which is the obvious implementation,
  binds to a display that never delivers a frame. Require a non-zero `displaySize` *and* a live surface.
- **The first `CVPixelBufferCreateWithIOSurface` costs 11–28 ms** against 22µs steady-state — lazy
  CoreVideo setup. Prime it off the first frame or opening a pane visibly hitches.
- **Damage callbacks burst**: the minimum observed inter-frame gap was 0.00 ms, i.e. two callbacks inside
  the same nanosecond. Work must be coalesced to display refresh rather than done per callback — the same
  lesson ADR-0011 records for CEF's schedule callbacks.

On this Xcode the display protocols are `SimDisplayIOSurfaceRenderable`
(`framebufferSurface`, `registerCallbackWithUUID:ioSurfacesChangeCallback:` — note the plural) and
`SimDisplayRenderable` (`displaySize`, `registerCallbackWithUUID:damageRectanglesCallback:`). The
singular `ioSurface` / `ioSurfaceChangeCallback:` spellings do not exist here, so probe for both and
treat an absent spelling as information rather than failure. Register the surface-change callback with a
**one-argument** block: if the runtime passes two (unmasked, masked) the extra argument is harmless,
whereas declaring more parameters than are passed is not.

The `registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:`
form, which was reported as new in Xcode 27, **does in fact resolve on Xcode 16.4** even though it is
declared on neither of the two protocols above. Prefer it when present and fall back to the two-callback
registration, which is what the implementation does.

## Input latency, and one more property of a frame

Measured tap-to-visible-change: **59–70 ms** from the Indigo message being sent to the first changed frame
arriving, across runs. That is the whole perceptible loop — message, guest render, damage callback, capture —
and it is comfortably below the threshold where input feels detached. Under interaction the cadence held at
gap p50 16.5 ms with our own cost at 18µs; the mean frame rate over a mixed window reads lower (~27 fps)
purely because the device is idle and producing nothing for much of it, which is the cadence working.

**A `SimulatorFrame` is a live view of the device's surface, not a snapshot.** It wraps the IOSurface rather
than copying it, so two frames captured seconds apart share one buffer and compare byte-identical. This is
correct for the pane, which enqueues each frame immediately, but it means **anything needing a still must
copy at capture time** — the agent-facing screenshot verb above all. Diffing two retained frames to decide
whether the screen changed silently always answers "no"; compare the seed, or copy.

Selectors are case-sensitive and CoreSimulator does not spell things the way Swift would. `SimDevice`'s
identifier selector is **`UDID`**, not `udid`; letting Swift synthesise the lowercase name makes
`respondsToSelector:` false for every device and lookup fails with "no device with that UDID" while naming
a device that is sitting right there, booted. Every runtime-messaged name needs checking against the
runtime, not against how it reads in Swift.
