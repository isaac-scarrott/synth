# Keyboard reference

Every binding in Synth, generated from the source the app itself reads, so this page cannot fall behind the build.

All of Synth is reachable from the keyboard, and chaining shortcuts is meant to feel instant. Nothing here waits on anything else finishing.

Three of these carry most of the day. `⌘K` is everything, scoped to whatever you have focused. `⌘⏎` takes you to whatever needs you. `⌘0` and `⌘1` move between the sidebar and the session, which is the move you make most and the one worth making without thinking.

57 bindings in 8 groups, read from `Shortcuts.swift` when this page was built. The same list is in the app under `⌘?`.

## General

|  |  |
|---|---|
| `⌘K` | Command menu |
| `⌘N` | New session |
| `⌘T` | New terminal |
| `⌘⇧T` | Scratch terminal |
| `⌘W` | Close session |
| `⌘B` | Toggle sidebar |
| `⌘⏎` | Jump to notification |
| `⌘,` | Settings |
| `⌘?` | Keyboard shortcuts |
| `⌘⇧F` | Send feedback |

## Command menu

|  |  |
|---|---|
| `↑` `↓` or `⌃J⌃K` | Move |
| `↵` | Open |
| `⌫` | Back |
| `⌘K` or `esc` | Close |

## Sidebar

|  |  |
|---|---|
| `↑` `↓` or `J` `K` | Move selection |
| `→` `←` or `L` `H` | Expand · collapse |
| `⇥` | Toggle group |
| `↵` or `Space` | Open · toggle |
| `A` | Add session |
| `R` | Rename |
| `D` | Close · archive |
| `⇧J⇧K` | Reorder |
| `esc` | Focus content |

## Split layout

|  |  |
|---|---|
| `⌘⇧→` or `⌘\|` | Split toward arrow |
| `⌘⇧—` | Split stacked |
| `⌘⌥→` or `⌘⌥L` | Focus pane |
| `⌘1` or `⌘9` | Focus pane N |
| `⌘0` | Focus sidebar |
| `` ⌘` `` or `` ⌘⇧` `` | Cycle panes |
| `⌘⌥⇧→` | Resize pane |
| `⌘⇧⏎` | Zoom pane |
| `⌘⇧U` | Unsplit |

## Browser

|  |  |
|---|---|
| `⌘L` | Go to address |
| `⌘R` | Reload |
| `⌘[` | Back |
| `⌘]` | Forward |
| `⌘+` or `⌘=` | Zoom in |
| `⌘−` | Zoom out |
| `⌘F` | Find in page |
| `⌥⌘I` | Inspect |
| `⌘⇧M` | Conditions |

## Simulator

|  |  |
|---|---|
| `⌘L` | Open app or URL |
| `⌘R` | Relaunch app |
| `⌘⇧H` | Home |
| `⌘⇧R` | Rotate |
| `⏎` | Send the comment you are writing |
| `esc` | Exit comment mode, or cancel a comment |

## Comments

|  |  |
|---|---|
| `⏎` | Add comment to the browser's batch |
| `⌥↑` | Widen comment target |
| `⌘⌥⏎` | Send all comments |
| `esc` | Exit comment mode |

## Tabs

|  |  |
|---|---|
| `⌘⇧]` or `⌃⇥` | Next tab |
| `⌘⇧[` or `⌃⇧⇥` | Previous tab |
| `⌘W` | Close tab |
| `⌘⇧→` | Send tab to pane · split |
| `drag` | Reorder tab |
| `⌘⇧U` | Merge pane |

## In Tabs mode

With Tabs switched on in **Settings ▸ Experimental**, the split-layout group changes rather than growing. `⌘⇧` with an arrow sends a tab to a neighbouring pane instead of splitting, `⌘⇧U` merges a pane instead of unsplitting it, and `⌘1` to `⌘9` select a tab as well as focusing a pane. Everything else is unchanged.

> This page is built from `Shortcuts.swift`, the same source the in-app `⌘?` sheet renders. A binding that changed in the app changed here, or the build failed.
