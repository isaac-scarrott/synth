---
name: to-spec
description: Turn the current conversation into a spec and write it to the repo as a markdown file — no interview, just synthesis of what you've already discussed.
disable-model-invocation: true
---

This skill takes the current conversation context and codebase understanding and produces a spec (you may know this document as a PRD). Do NOT interview the user — just synthesize what you already know.

Specs are markdown files in a `specs/` directory at the repo root, one file per spec: `specs/<slug>.md`, where the slug is a short kebab-case name for the feature. Frontmatter carries state:

```yaml
---
title: <spec title>
status: ready-for-agent    # ready-for-agent | in-progress | done
---
```

`ready-for-agent` means the spec needs no further triage — an agent can pick it up and break it into tickets or implement it directly.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better — the ideal number is one.

   Check with the user that these seams match their expectations.

3. Write the spec using the template below, save it to `specs/<slug>.md` with `status: ready-for-agent`, and commit it if the repo is under version control.

## Spec template

```markdown
---
title: <spec title>
status: ready-for-agent
---

## Problem Statement

<the problem that the user is facing, from the user's perspective>

## Solution

<the solution to the problem, from the user's perspective>

## User Stories

<a LONG, numbered list of user stories. Each in the format:

1. As a <role>, I want <capability>, so that <benefit>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending

This list should be extremely extensive and cover all aspects of the feature.>

## Implementation Decisions

<a list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.>

## Testing Decisions

<a list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)>

## Out of Scope

<a description of the things that are out of scope for this spec>

## Further Notes

<any further notes about the feature>
```
