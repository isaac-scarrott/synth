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

**Superseded in part — 2026-07-20.** Feedback rejected the neutral Removes and the busy-only Close:
a destructive verb rendered in the same colour as a neutral one reads as safe, and people clicked
past it. Red is now the **negative-action** signal, not the recoverability signal. It marks anything
that ends, removes, or re-parents ownership, unconditionally: **Close** (always, not only while
busy), every **Remove** (branch, project, and the "Remove from sidebar" fork), and **Detach** /
**Attach** (as a pair — the two verbs that make and break containment). **Delete** stays red as
before. Only neutral, additive, and affirmative controls stay uncoloured — Cancel, "Not now", and a
confirm frame's own affirmative button are never red. The recoverability table above no longer
governs which verbs are red (a busy-only Close and a never-red Remove are both gone); the glyph
grammar (trash destroys, minus drops a row, × ends a session) is unchanged, and the confirm-before-
Close safety is unchanged. `CONTEXT.md`'s **Remove**, **Close**, and **Red** entries carry the new
rule.

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

## 2026-07-24 — a fourth verb: Archive

The delete fork this ADR cites as evidence ("Remove from sidebar" against "Delete worktree", the
neighbouring ⌘K rows that motivated renaming workspace → project) is gone. It was replaced by
**Archive** on the branch row plus a `Delete worktree now` one level down, so the citation above is
history rather than current UI. The argument it supports is untouched.

**Why a fourth verb and not a reused third.** Archive-as-hide-only would be verbatim `Remove`, and
adopting `Remove` for it would be pure drift. But the new state has two consequences `Remove` does
not own: an archived row is enumerable and restorable *indefinitely* (a removed row is gone the
moment the 8-second undo drains), and something later reclaims its folder. One noun per thing, one
verb per consequence — this is a different consequence, so it gets its own verb.

**The cost, and how it is actually paid.** Mail, Gmail, Linear and Notion have all trained
"archive = kept forever". Here it means "kept, then reclaimed once the work is provably safe
elsewhere". The first attempt paid for that gap by making every surface state the consequence
("folder deletes in 7 days once it's merged and clean"). That was wrong, and it was cut: it turned
a one-word action into a running commentary on machinery the user has no decision to make about,
and it put a countdown in front of someone who only wanted the row gone.

The honest reading is that "kept, then reclaimed when it is provably safe to" **is** archiving —
what the user keeps is the branch and the work, neither of which is ever destroyed. The folder is
an implementation detail of ADR-0007, and a folder Synth can rebuild from a remote on demand is not
a thing the user owns a decision about. So the UI says `Archived <name>`, the list says
`archived 3d ago`, and the conditions live in `os.Logger` and the automation seam. If the clean-up
ever grows a case where the user really would lose something, that case is a bug in the conditions,
not a missing sentence in the copy.

**Glyph.** An archive box. Not the trash can (which destroys) and not the minus (Remove). In the
same pass the project row's Remove moved off the trash can onto the minus — a trash can on an action
that destroys nothing was the actual violation of §"a trash can destroys", and it had been sitting
there while the fork existed to explain it away.

**Confirmation.** Archive confirms nowhere. `Delete worktree now` confirms everywhere. The rule is
that the dialog attaches to irreversibility, never to the entry surface — a verb whose consequence
depends on whether it was reached by click, by `d`, by ⌘W or by ⌘K is not one verb. This was decided
against an explicit proposal to confirm only in ⌘K.

**One verb, one label.** `Archive` is the label everywhere; the thing being archived is context (the
`ctx` field, the group heading, the frame's crumb) exactly as it is for `Rename`, `New terminal` and
every other action. A verb that reads "Archive locked" in a list of bare verbs is the kind of small
inconsistency that makes a simple action feel like a special case.
