# Shared cross-platform contract

This directory contains platform-neutral behavior used to compare the Windows and
macOS implementations.

- `state-spec.json`: canonical state colors and animation parameters.
- `fixtures/`: sanitized Codex lifecycle input.
- `expected/`: expected reducer output for the matching fixture.

The native applications do not load these files at runtime yet. They are review and
test contracts. Moving runtime constants into generated platform code is a later task.
