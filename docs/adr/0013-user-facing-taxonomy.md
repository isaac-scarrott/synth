# The user-facing taxonomy: one noun per thing, one verb per consequence

Synth's language drifted. The same surface named itself three ways ("Command palette" in the ⌘?
sheet, "quick actions" in the browser hint, "Search or jump to anything…" in its own placeholder).
The same event was a "toast" in Settings and a "notification" in macOS. A ⌘K row promised to "Move
under" an owner whose indentation a later decision had already removed. None of this was wrong when
each piece shipped; it drifted because nothing held the vocabulary.

This ADR fixes the words. `CONTEXT.md` is the glossary and the normative reference; this file records
why three of the decisions went the way they did, because each is expensive to reverse and each looks
arbitrary without the argument.

## Workspace becomes Project

The top row is exactly one git repository. It was called a **workspace**, and one level below it sat
the **worktree**. Two nouns, one level apart, both opening on `work`, and the ⌘K delete fork showed
them as neighbouring rows: "Remove from sidebar" against "Delete worktree".

The collision was not theoretical. Writing marketing copy for the app, we twice reached past the
canonical term and wrote "project" and "repos" instead, in a codebase whose glossary explicitly
banned both.

So one of the two `work*` nouns had to go, and **worktree** is the one that cannot: it names a real
git concept that appears on disk, and ADR-0007 depends on saying it precisely. Workspace was the
softer word and it lost.

*Rejected:* **Repository**, which is what the row literally is. It is the most honest name and it was
close. But "project" is what people say out loud, it leaves room for a project to mean something more
than one repo later, and Synth never shows a repository that is not a project. *Rejected:*
**Workspace with the worktree renamed**, which resolves the collision from the wrong end by throwing
away the precision ADR-0007 bought.

## Red means loss, not disk

Three verbs, three consequences, and the colour tracks the consequence:

| Verb | What happens | What survives | Red |
| --- | --- | --- | --- |
| **Remove** | the row leaves the sidebar | the repo, the worktree folder | never |
| **Close** | the session ends, its process dies | every file | while it is busy |
| **Delete** | the worktree folder is destroyed | the git branch | always |

Sessions used to be **deleted**. But deleting a session touches no disk at all, and the code that
does it is already called `closeSession`. Renaming it to **Close** makes the verb honest.

That rename threatened to take the safety signal with it: if red meant "disk", then killing a live
agent mid-turn (the most frequent destructive thing anyone does in Synth) would lose its warning. So
red was re-based on **loss** instead. A busy Close wears red because a turn dies with it. An idle
Close does not, because nothing is lost. A Remove never does, because everything survives.

The glyph carries the same grammar as the word: a **trash can** destroys, a **minus** drops a row, an
**×** ends a session. Every one of these verbs used to wear the trash can, which said "destroy" three
times for three different consequences.

This supersedes the framing in ADR-0007, which read the distinction as `Remove` ≠ `Delete` on the
axis of the filesystem. The axis is recoverability, and the filesystem is only its most obvious case.

*Rejected:* **one verb, disambiguated by the consequence line**. The label is what people read; the
dialog is what they click through. *Rejected:* **Close stays red always**, which trains people to
dismiss the dialog and so disarms it exactly when it matters.

## Running and working merge into Busy

A terminal with a live process was **running** (green). An agent mid-turn was **working** (amber).
Two words and two colours for one fact: something is happening.

They merged into **busy**, one state, one amber dot. The row's icon already says whether it is an
agent or a dev server, so the colour was answering a question nothing had asked. Amber survived
rather than green because green reads as *healthy* and a burning agent turn is not a state of health;
amber reads as *in progress*, which is exactly what busy means.

*Rejected:* **keeping both colours under one word**, which leaves the UI drawing a distinction the
glossary denies. That is the drift this ADR exists to end.

## Consequences

- Every surface must be swept: the ⌘? sheet, the browser hint, Settings, both design files, the
  landing page. Roughly two hundred strings.
- Internal symbols keep their old names. `Palette.swift`, `store.palette` and `SessionKind` are not
  the domain, and renaming six files of Swift buys nothing a glossary entry cannot.
- Amber now carries every busy dot, and `docs/features/2026-07-09.md` records that `--work` amber
  sits four degrees of hue from the champagne accent. The two will meet far more often than before.
  Watch it once it is built.
