# Agent tools

Every agent Synth hosts gets a real browser, a booted iPhone, and a way to hand work to a new branch. You do not wire any of it up, and you do not wire it up again for the next agent.

Synth bundles three MCP servers and hands them to each agent on the command that launches it. You do not install or register them, and nothing for them is written into your repository. Change agent and the same tools are there.

These pages are for knowing what your agent can reach. You do not call these yourself: you ask the agent, and it does.

42 tools across 3 servers, read from the servers themselves when this page was built. Every one of them ships with Synth: there is nothing to install and nothing to register.

## synth-browser

|  |  |
|---|---|
| `browser_list` | List this worktree's Synth browser sessions (sessionId, title, url, branch; owned sessions carry an owner field — the Synth session UUID of the owning claude). |
| `browser_create`(url?) | Create a new Synth browser session in this worktree's branch (visible in the sidebar, selected), optionally pre-navigated to a URL. |
| `browser_close`(sessionId) | Close a browser session you created, removing its row from the sidebar. |
| `browser_navigate`(url, sessionId, waitUntil?, timeout?) | Navigate a browser session to a URL. |
| `browser_back`(sessionId) | Go back in the session's history. |
| `browser_forward`(sessionId) | Go forward in the session's history. |
| `browser_reload`(sessionId, waitUntil?, timeout?) | Reload the session's page. |
| `browser_device_mode`(sessionId, on?, device?, landscape?, network?, cpu?) | Read or set the session's conditions — the three things that make a machine worse than this one, each independent of the others and each resting at normal: the SCREEN the page is emulated at (Chrome device-toolbar emulation: true innerWidth/innerHeight, devicePixelRatio, and mobile layout on the handhelds), the NETWORK and the CPU. |
| `browser_viewport`(sessionId, width?, height?, deviceScaleFactor?, mobile?, reset?) | Read or set the size the page lays out at, in CSS pixels — the agent's own viewport control, free of the device fleet. |
| `browser_click`(sessionId, ref?, selector?, x?, y?, button?, clickCount?) | Click in the session's page: a snapshot ref, a CSS selector, or viewport coordinates. |
| `browser_type`(text, sessionId, ref?, selector?, submit?) | Type text into the session's page — into a ref or selector (replacing its value) or the currently focused element; optionally press Enter after. |
| `browser_hover`(sessionId, ref?, selector?) | Hover the pointer over an element — the only way to reach a menu, tooltip or control that appears on hover. |
| `browser_press_key`(key, sessionId, ref?, selector?, repeat?) | Press a key in the session's page — Escape to dismiss, Tab to move focus, ArrowDown to walk a listbox, Enter to confirm. |
| `browser_select_option`(sessionId, ref?, selector?, values?, labels?, indexes?) | Choose in a native <select>. |
| `browser_scroll`(sessionId, ref?, selector?, to?, dy?, dx?) | Scroll the page, or bring one element into view — how a lazy list loads its next page and how anything below the fold becomes clickable. |
| `browser_wait_for`(sessionId, text?, textGone?, ref?, selector?, state?, expression?, timeout?) | Wait for the page to reach a condition instead of guessing at a delay: text to appear or go, an element to become visible or leave, or a JS expression to turn truthy. |
| `browser_screenshot`(sessionId, path?, inline?, fullPage?, ref?, selector?) | Screenshot the session's page to a PNG file and return its path — the viewport by default, or the whole scrollable page (fullPage), or one element (ref or selector). |
| `browser_network`(sessionId, request?, filter?, type?, failedOnly?, limit?, path?) | The session's network traffic. |
| `browser_record_start`(sessionId) | Start recording the session's page as video. |
| `browser_record_stop`(sessionId, path?) | Stop recording and encode the video: mp4 (H.264) when a full ffmpeg is installed, else webm (VP8) via Playwright's bundled ffmpeg. |
| `browser_snapshot`(sessionId, selector?, maxDepth?) | Accessibility-tree snapshot (aria) of the session's page — the fast, text-sized way to read page structure. |
| `browser_cookies`(sessionId, set?, urls?) | Read or set the session's cookies. |
| `browser_health`(reconnect?) | State of Synth's browser engine when the tools misbehave: how many CDP targets it hosts across ALL worktrees and agents (attach cost scales with that number, so it explains slow or timing-out calls that have nothing to do with your own pages), and which of this worktree's sessions still answer. |
| `browser_console`(sessionId) | Recent console messages (including errors) from the session's page. |
| `browser_evaluate`(expression, sessionId) | Evaluate a JavaScript expression in the session's page; returns the JSON-serialized result. |

## synth-simulator

|  |  |
|---|---|
| `simulator_list` | List this worktree's Synth simulator sessions: sessionId, title, branch, the device UDID and name, whether that device is booted, and whether Synth is attached to its framebuffer (`booting` while a device is still coming up — attaching retries every second). |
| `simulator_devices` | List the simulator devices installed on this machine (udid, name, runtime, whether booted). |
| `simulator_create`(device?) | Create a Synth simulator session in this worktree's branch — a row in the sidebar showing one device's live screen, which you and the user both act on. |
| `simulator_close`(sessionId) | Close a simulator session, removing its row from the sidebar. |
| `simulator_tap`(x, y, sessionId) | Tap the device's screen. |
| `simulator_swipe`(fromX, fromY, toX, toY, sessionId, durationMs?) | Swipe or drag across the device's screen — scrolling a list, a page in a pager, a sheet dismissal. |
| `simulator_type`(text, sessionId) | Type text into whatever the device has focused — tap the field first. |
| `simulator_press_button`(button, sessionId) | Press a hardware button: home, lock, sideButton, siri, applePay. |
| `simulator_rotate`(orientation, sessionId) | Turn the device to a given orientation — how you check a landscape layout, or a rotation your app handles badly. |
| `simulator_shake`(sessionId) | Shake the device. |
| `simulator_describe`(sessionId, x?, y?) | Read what is on the device's screen as text: the accessibility tree of the frontmost app. |
| `simulator_screenshot`(sessionId) | Screenshot the device's screen (PNG, at the device's own pixel size). |
| `simulator_launch`(bundleId, sessionId, args?) | Launch an installed app on the device by bundle identifier, foregrounding it. |
| `simulator_terminate`(bundleId, sessionId) | Stop a running app on the device. |
| `simulator_open_url`(url, sessionId) | Open a URL on the device — an https link in Safari, or your app's own scheme or universal link, which is how you reach a deep link without navigating to it by hand. |
| `simulator_install`(path, sessionId) | Install a built .app bundle on the device. |

## synth-app

|  |  |
|---|---|
| `worktree_create`(branch, base?, handoff?) | Create a new git worktree in this repo through Synth, so a separate line of work gets its own branch, checkout and sessions instead of piling onto the current one. |

## What an agent may and may not do

**An agent may drive anything, and close only what it opened.** Any agent can act on any browser or simulator, because the surface is shared with you and with every other session. Closing is different, because it takes something away: a browser you opened yourself is yours, and so is one you detached or attached elsewhere.

**Every tool names its session.** One server process serves an agent and all of its subagents, so there is no ambient "current" session to inherit: an agent that wants to act on a page passes that page's `sessionId`. This is why two agents working at once cannot drive each other's windows by accident.

A device is different again. Simulators are shared machine state, so a device Synth booted is released by reference count, and an agent cannot shut down a device you are looking at.

## Creating a branch always asks

`worktree_create` is the one tool that stops and waits for a person. When an agent decides work belongs somewhere else, it writes a brief and asks for a branch of its own. You see the project, the base branch, and what it means to do.

Return creates it and starts an agent inside that already knows what it is there for. Escape declines, and tells the agent to carry on where it is. Dismissing the prompt any other way is a decline as well, because a prompt you closed is not a prompt you agreed to.

This is the only gate Synth adds. Everything else an agent does, it does with whatever permissions [the agent itself asks you for](agents.md#agents-run-on-your-machine).

## Screenshots and video

A screenshot goes to a file by default and is only returned inline when asked for. Images are the largest thing an agent can put in its own context, and most of the time it needs to have looked rather than to keep looking.

Video is the other way round: `browser_record_stop` returns a path, never frames. A recording is for you to watch, not for the model to read.

> This page is built from the servers themselves. The tool list, the arguments and the summary lines are read out of the same files Synth ships to your agent, so a tool that changed there changed here.
