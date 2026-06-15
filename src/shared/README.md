# Shared cross-platform contract

`spec/agent-halo.v2.json` is the canonical source for behavior shared by the
Windows and macOS clients. Native rendering and operating-system integration remain
platform-specific.

The contract owns state metadata, lifecycle rules, action and failure matching,
rate-limit paths, animation parameters, gap motion, transition parameters, and the
shared portion of settings. Platform-only material and morph identifiers live under
`platformExtensions`.

Generate native constants:

```bash
python scripts/generate_shared.py
```

Verify generated files without modifying them:

```bash
python scripts/generate_shared.py --check
python scripts/check_shared.py
```

CI additionally installs `scripts/requirements-ci.in` and validates the contract
against `spec/agent-halo.v2.schema.json`.

Generated outputs are committed:

- `src/windows/GeneratedHaloSpec.cs`
- `src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift`

Do not edit generated files by hand. Both applications compile the generated source
and do not read the JSON contract at runtime.

Fixtures cover lifecycle reduction, failure classification, rate-limit layouts, and
deterministic animation samples. GitHub Actions checks code generation and runs the
Windows and macOS native test suites.
