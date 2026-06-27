#!/usr/bin/env python3
"""Validate shared fixtures and deterministic animation samples."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_shared import ROOT, SPEC_PATH, validate  # noqa: E402


def clamp(value: float, lower: float, upper: float) -> float:
    return min(max(value, lower), upper)


def positive_modulo(value: float, modulus: float) -> float:
    result = value % modulus
    return result + modulus if result < 0 else result


def smoother_step(value: float) -> float:
    value = clamp(value, 0, 1)
    return value**3 * (value * (value * 6 - 15) + 10)


def soft_wave(phase: float) -> float:
    cycle = positive_modulo(phase, 1)
    triangle = cycle * 2 if cycle < 0.5 else (1 - cycle) * 2
    return smoother_step(triangle)


def living_breath(time: float, values: dict, powered: bool) -> float:
    maximum = values["poweredMaximum" if powered else "visualMaximum"]
    minimum = values["poweredMinimum" if powered else "visualMinimum"]
    period = values["period"]
    share = values["brightShare"]
    phase = positive_modulo(time, period) / period
    center = share + (1 - share) * 0.46
    distance = min(abs(phase - center), 1 - abs(phase - center))
    width = max(0.075, (1 - share) * 0.46)
    dip = math.exp(-((distance / width) ** 4))
    micro = 0.018 * math.sin(phase * math.pi * 2)
    micro += 0.009 * math.sin(phase * math.pi * 4 + 0.8)
    return clamp(maximum - (maximum - minimum) * dip + micro, minimum, maximum)


def smooth_pulse(phase: float, center: float, width: float) -> float:
    distance = min(abs(phase - center), 1 - abs(phase - center))
    return smoother_step(clamp(1 - distance / width, 0, 1))


def attention_pulse(time: float, config: dict) -> float:
    cycle = positive_modulo(time, config["period"]) / config["period"]
    first = smooth_pulse(cycle, config["first"]["center"], config["first"]["width"])
    first *= config["first"]["strength"]
    second = smooth_pulse(cycle, config["second"]["center"], config["second"]["width"])
    second *= config["second"]["strength"]
    living = config["livingBase"]
    living += config["livingAmplitude"] * soft_wave(cycle + config["livingPhase"])
    return clamp(living + first + second, 0, 1)


def classify_failure(text: str, rules: list[dict]) -> str | None:
    value = text.lower()
    for rule in rules:
        if any(token in value for token in rule["containsAny"]):
            return rule["detail"]
    return None


def read_path(document: dict, path: list[str]):
    current = document
    for component in path:
        if not isinstance(current, dict) or component not in current:
            return None
        current = current[component]
    return current


def reduce_lifecycle(spec: dict) -> list[str]:
    result = ["idle"]
    rules = spec["eventRules"]
    for raw in (ROOT / "src" / "shared" / "fixtures" / "lifecycle-basic.jsonl").read_text(
        encoding="utf-8"
    ).splitlines():
        root = json.loads(raw)
        payload = root.get("payload", {})
        kind = payload.get("type", "").lower()
        if root.get("type") == "event_msg":
            if kind in rules["taskStartExact"]:
                result.append("thinking")
            elif kind in rules["taskCompleteExact"]:
                result.append("done")
            elif any(token in kind for token in rules["attentionContains"]):
                result.append("attention")
            elif kind in rules["fatalExact"]:
                result.append("error")
        elif root.get("type") == "response_item":
            if kind.endswith("_call"):
                result.append("working")
            elif kind.endswith("_output"):
                result.append("working")
    return result


def main() -> int:
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    validate(spec)

    expected_lifecycle = json.loads(
        (ROOT / "src" / "shared" / "expected" / "lifecycle-basic.json").read_text(encoding="utf-8")
    )
    actual_sequence = reduce_lifecycle(spec)
    if actual_sequence != expected_lifecycle["sequence"]:
        raise AssertionError(f"lifecycle mismatch: {actual_sequence}")

    failures = json.loads(
        (ROOT / "src" / "shared" / "fixtures" / "failure-cases.json").read_text(encoding="utf-8")
    )
    for case in failures:
        actual = classify_failure(case["input"], spec["failureRules"])
        if actual != case["detail"]:
            raise AssertionError(f"failure case mismatch: {case['input']!r} -> {actual!r}")

    rate_cases = json.loads(
        (ROOT / "src" / "shared" / "fixtures" / "rate-limit-cases.json").read_text(encoding="utf-8")
    )
    rate = spec["rateLimit"]
    for case in rate_cases:
        limits = next(
            (value for path in rate["containerPaths"] if (value := read_path(case["document"], path)) is not None),
            None,
        )
        actual = None
        if limits is not None:
            primary = read_path(limits, rate["primaryPath"])
            secondary = read_path(limits, rate["secondaryPath"])
            if primary is not None and secondary is not None:
                actual = {
                    "primaryUsedPercent": float(primary),
                    "secondaryUsedPercent": float(secondary),
                }
        expected = case["expected"]
        if expected is not None:
            expected = {key: float(value) for key, value in expected.items()}
        if actual != expected:
            raise AssertionError(f"rate case mismatch: {case['name']} -> {actual!r}")

    expected_animation = json.loads(
        (ROOT / "src" / "shared" / "expected" / "animation-samples.json").read_text(encoding="utf-8")
    )
    tolerance = expected_animation["tolerance"]
    for sample in expected_animation["samples"]:
        state = sample["state"]
        time = sample["time"]
        if state == "attention":
            breath = powered = attention_pulse(time, spec["attentionPulse"])
        else:
            values = spec["states"][state]["breath"]
            breath = living_breath(time, values, False)
            powered = living_breath(time, values, True)
        if abs(breath - sample["breath"]) > tolerance:
            raise AssertionError(f"breath sample mismatch: {state}@{time} -> {breath}")
        if abs(powered - sample["powered"]) > tolerance:
            raise AssertionError(f"powered sample mismatch: {state}@{time} -> {powered}")

    # Locale JSON is the single source of truth under src/shared/locales and
    # is mirrored into the macOS and Windows targets as real files (symlinks
    # would survive into the SwiftPM bundle as dangling links). Fail if either
    # mirror drifts, so `scripts/build-macos.sh` / `build-windows.ps1` always
    # ship the latest translations.
    shared_locales = ROOT / "src" / "shared" / "locales"
    mirrors = [
        ROOT / "src" / "macos" / "Sources" / "AgentHaloCore" / "locales",
        ROOT / "src" / "windows" / "locales",
    ]
    for lang in ("zh.json", "en.json"):
        canonical = (shared_locales / lang).read_text(encoding="utf-8")
        for mirror in mirrors:
            target = mirror / lang
            if not target.exists():
                raise AssertionError(f"locale mirror missing: {target}")
            if target.read_text(encoding="utf-8") != canonical:
                raise AssertionError(
                    f"locale mirror drifted from shared source: {target} "
                    f"(re-run scripts/build-macos.sh and build-windows.ps1 to sync)"
                )

    print("PASS shared contract, fixtures, and animation samples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
