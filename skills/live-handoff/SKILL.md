---
name: live-handoff
description: "Keeps TODO.md in the project root as a live handoff file (current goal, checklist, last five changes, key decisions, next immediate step), updated after every file edit and kept under 100 lines, so work continues after /clear, compaction or a new session without re-reading the codebase. Use this skill whenever you edit, write or create files in a project, whenever a hook reminder mentions TODO.md or live-handoff, at the start of a session or after /clear or compaction when the project has a TODO.md, and when the user asks for a handoff, a status file, where things stand, or to pick up where the last session stopped."
---

# Live handoff

A long session fills its context with work that is already finished. This skill keeps the part worth carrying forward in one small file, `TODO.md` in the project root, and updates it the moment anything changes. A fresh context (a new session, `/clear`, compaction) then needs that file and nothing else to carry on.

Write `TODO.md` for a reader who has no memory of this session, because that reader will be you.

## The five rules

1. **`TODO.md` is the live state.** It sits in the project root and is the handoff document for the task in progress. If the project has none, create it at the first file change. Keep it under 100 lines, always (blank lines count).
2. **Five sections, exactly these, in this order:** `Current Goal`, `Checklist`, `Recent Changes (Max 5)`, `Key Decisions & Pitfalls`, `Next Immediate Step`. Do not add, rename or reorder sections.
3. **Update it right after every edit.** After any `Edit`, `Write` or `MultiEdit` call on a project file other than `TODO.md`, update `TODO.md` before the next action: before another tool call, before running anything, before replying. A hook reminds you each time. Edits sent together in one message count as one step: update once, straight after, covering all of them.
4. **Read it first.** At session start, on resume, and after `/clear` or compaction, read `TODO.md` before anything else and continue from `Next Immediate Step`. Do not re-scan the codebase to rebuild context: open only the files that step names. A hook prints the file into your context at those moments. Before your first update, open it once with the Read tool, because Edit refuses a file that was not read.
5. **Prune on every update.** Each update removes as well as adds, so the file never grows into the context problem it exists to solve.

Rule 3 is the easy one to skip and the expensive one to skip. A context can end at any moment, and whatever is not in the file by then is gone.

Two limits come before all five rules. A `TODO.md` that this skill did not write belongs to the user: leave it alone. And where the user has switched live-handoff off, do nothing. Both are under Edge cases.

## The file

Use exactly this shape:

```markdown
# TODO

## Current Goal
One or two sentences: what is being built or fixed, and what done looks like.

## Checklist
- [x] Step that is finished
- [ ] Step still to do
- [!] Step that is blocked: what blocks it

## Recent Changes (Max 5)
- `path/to/file`: what changed and why (newest first)

## Key Decisions & Pitfalls
- A decision and its reason, or a trap and how to avoid it

## Next Immediate Step
The single next action, concrete enough to start cold: the file, the function, the command.
```

What belongs in each section:

- **Current Goal**: the task as the user would recognise it. It changes only when the task changes.
- **Checklist**: the steps of the plan, usually 3 to 12 lines. `[x]` done, `[ ]` to do, `[!]` blocked or failed, with the reason on the same line.
- **Recent Changes (Max 5)**: one line per change, newest first: the file, what changed, and why. A sixth entry pushes the oldest out. Git keeps the full history; this is only the last few moves.
- **Key Decisions & Pitfalls**: whatever would cost the next reader time to find out again. A choice and its reason, an approach that failed, a limit the user set, a command that must not be run. It is not a diary.
- **Next Immediate Step**: one action, written as an instruction, for example: "In `src/auth/session.ts`, make `refresh()` retry once on 401, then run `npm test -- auth`." When the work is finished, say so here and name what the user should check.

## Updating after an edit

1. Add the change to `Recent Changes`. If that makes six, delete the oldest.
2. Tick, add or mark as blocked the `Checklist` items the change affects.
3. Rewrite `Next Immediate Step` so it describes what happens next from here.
4. Add to `Key Decisions & Pitfalls` only when you learned something the next reader needs.
5. Prune, then carry on with the task.

Use `Edit` on the lines that changed instead of writing the whole file again, and do not narrate the update to the user: the file is the record.

Project files are the ones the task is about. Claude Code's own files (its memory, plans and scratchpad, anything in the temp folder, unless the project itself lives there) and the snapshots in `.handoff/` are not, and need no entry. A project file changed some other way (a shell command, a notebook edit, a formatter) gets no reminder from the hook: record it the same way.

## Pruning

Check the size at every update. When the file comes near 100 lines, or its lines grow long:

- fold finished checklist items into one line ("- [x] Steps 1 to 4: schema, migration, API, tests");
- delete decisions that no longer affect anything still to do;
- keep one short line per item: no nested lists, no code blocks, no pasted output or logs;
- do not move the overflow into another file. What does not fit was not needed.

## Resuming

When a session starts, or after `/clear` or compaction, the `SessionStart` hook prints `TODO.md` under a "LIVE HANDOFF" header. Trust it over your own impression of earlier work and start on `Next Immediate Step` straight away. Read other files only when that step needs them.

- **The user asks for something else first.** Do it. For a side request (a question, a small fix) leave `Current Goal`, `Checklist` and `Next Immediate Step` as they are; a project file you changed still gets its line in `Recent Changes`. Rewrite the file for new work only when it replaces the task, and if the checklist still has open items, tell the user before you drop them.
- **The file disagrees with the code.** The code is right. Correct the file first, then continue.

## Edge cases

- **A `TODO.md` that live-handoff did not write.** Many projects have their own `TODO.md`. If the one you find is not empty and has fewer than three of these five section headings, it is the user's file: do not restructure it, prune it or add sections to it, and do not keep live-handoff state in that project. Reminders and snapshots stop there, and the session-start hook says so in one line. Convert it only when the user asks: save the original under another name first (for example `TODO.original.md`), never delete content you did not write, and say what you did. An empty `TODO.md`, or a live-handoff file that has lost a section, is still live-handoff's: put the five sections back at the next update.
- **Subagents do not touch `TODO.md`.** Several helpers rewriting one file collide. If you are a subagent, list every file you changed, and why, in your final report. If you are the main session, record a subagent's changes when it returns.
- **Nothing was edited.** A session that only reads or answers questions has nothing to record. Do not create `TODO.md` for it.
- **`.handoff/` is not yours to edit.** It holds a snapshot of `TODO.md` taken before each compaction (`.handoff/latest-handoff.md` is the newest), as a fallback if `TODO.md` is lost or damaged.
- **Switched off.** The user turns live-handoff off with a file named `.live-handoff-off` in the project root, or with `LIVE_HANDOFF_DISABLE=1` in the environment. The session-start hook then says so in one line. Where it is off, do not create or update `TODO.md`, whatever the rules above say.

## How the hooks help

Three hooks in the user's Claude Code settings run `scripts/sync_state.py` from this skill's folder:

- after `Edit`, `Write` or `MultiEdit` on a project file: a short reminder to update `TODO.md`, or to create it when the project has none;
- at session start, on resume, after `/clear` and after compaction: prints `TODO.md`;
- before compaction: copies `TODO.md` into `.handoff/`.

The reminders are a safety net. The rules above apply with or without them, except where live-handoff is switched off or the `TODO.md` is not its own.
