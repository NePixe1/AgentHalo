# macOS Agent Switch Inactive Icon Contrast Design

## Goal

Make the inactive agent icon in the macOS details-panel switch visibly more subdued when the user selects the other agent.

## Scope

- Change only `AgentToggleView` on macOS.
- Keep the selected icon fully opaque (`1.0`).
- Set the unselected icon opacity to `0.40` in both Codex-selected and Claude Code-selected states.
- Preserve the existing selection-pill geometry, animation duration, click handling, accessibility labels, and persisted agent-selection behavior.

## Implementation

`AgentToggleView.updateSelectedState(animated:)` remains the sole presentation point for the two icon alpha values. Replace its inactive value (`0.58`) with `0.40`; no assets, layout constraints, or Windows code change.

## Verification

Extend the macOS interaction checks to assert that each inactive icon has opacity `0.40` while the selected icon has opacity `1.0`, then run the focused interaction-check executable and the macOS package tests/build used by the repository.
