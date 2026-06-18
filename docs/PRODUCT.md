# Agent Halo

## Product promise

Agent Halo is a quiet, always-visible desktop vital sign for coding agents. The
current release monitors Codex; the next provider target is Claude Code. It answers
one question without making the user return to the agent window: "What needs me
right now?"

## Principles

1. Ambient first: readable in peripheral vision, silent by default.
2. One organ, many states: a single original light form instead of a dashboard.
3. Persistent completion: green breathes until Codex returns to the foreground or the user acknowledges it.
4. Honest state: infer lifecycle activity, never claim to expose hidden reasoning.
5. Local only: read event metadata from local Codex JSONL sessions; never send content.

## State model

| State | Meaning | Color | Motion |
| --- | --- | --- | --- |
| Idle | No unacknowledged work | cool white | slow nonlinear gap orbit |
| Thinking | Turn active, no tool currently running | amber | gap drift and ring-body breathing |
| Working | Tool, command, search, or edit running | electric blue | fast gap orbit and ring-body breathing |
| Done | Turn completed and not acknowledged | mint | double flash, then slow ring-body breathing |
| Needs you | Explicit input/approval tool requested | violet | paired pulse |
| Error | Turn interrupted or errored | crimson | broken ring and sharp pulse |

## MVP

- Windows desktop, native WPF, transparent and always on top.
- Smooth composition-clock animation.
- Real-time monitoring of `%USERPROFILE%\.codex\sessions`.
- Multiple-session aggregation with priority ordering.
- Click-to-inspect compact session panel.
- Persistent completion acknowledgement.
- Tray controls, pause, live/demo modes, startup toggle, and exit.
- Position memory and edge snapping.
- Provider architecture prepared for future Claude Code lifecycle detection.
- No pets, chat content, cost meter, or cloud service.

## Visual language

The form borrows the compact, embedded-status principle of science-fiction android
indicators without copying game geometry or branding. The original mark is one
thick luminous ring with two unequal, non-diametric gaps. The large gap chases a
slowly drifting small gap until their separation approaches 40 degrees, then the
small gap is smoothly repelled toward 150 degrees, coasts with decaying momentum,
and resumes a bounded back-and-forth drift. The center remains transparent. Thinking
and working power the ring material itself from dim to a bright white core while the
state color remains at the tube edge. Its narrow layered bloom intensifies. Working
uses a roughly 3.2-second power cycle and thinking a roughly 5.2-second cycle.
Repulsion duration and exit momentum derive from the current orbit velocity, keeping
slow states organic. Animation advances on every desktop composition frame.
State is communicated through color, breathing intensity, and chase-and-repel motion.
No separate highlight travels around the ring.
