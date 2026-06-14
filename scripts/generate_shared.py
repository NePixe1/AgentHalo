#!/usr/bin/env python3
"""Generate native constants from the Agent Halo shared behavior contract."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "shared" / "spec" / "agent-halo.v2.json"
CS_PATH = ROOT / "windows" / "GeneratedHaloSpec.cs"
SWIFT_PATH = ROOT / "mac" / "Sources" / "AgentHaloCore" / "GeneratedHaloSpec.swift"
STATE_ORDER = ["idle", "thinking", "working", "done", "attention", "error"]


def pascal(value: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in value.split("_"))


def number(value: object) -> str:
    if isinstance(value, int):
        return str(value)
    result = format(float(value), ".15g")
    return result if "." in result else result + ".0"


def csharp_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def validate(spec: dict) -> None:
    required = {
        "contractVersion", "releaseVersion", "algorithms", "states", "transitions",
        "attentionPulse", "errorPresentations", "gapMotion", "eventRules",
        "actionRules", "failureRules", "rateLimit", "settings", "platformExtensions",
    }
    missing = required - set(spec)
    if missing:
        raise ValueError(f"missing top-level keys: {sorted(missing)}")
    if spec["contractVersion"] != 2:
        raise ValueError("contractVersion must be 2")
    if list(spec["states"]) != STATE_ORDER:
        raise ValueError(f"states must be ordered as {STATE_ORDER}")
    priorities = sorted(state["priority"] for state in spec["states"].values())
    if priorities != list(range(len(STATE_ORDER))):
        raise ValueError("state priorities must be unique values 0 through 5")
    for name, state in spec["states"].items():
        if len(state["color"]) != 3 or any(not 0 <= channel <= 255 for channel in state["color"]):
            raise ValueError(f"invalid RGB color for {name}")
        for group in ("breath", "orbit"):
            if group not in state:
                raise ValueError(f"missing {group} for {name}")
    if spec["transitions"]["dimEnd"] >= spec["transitions"]["colorBlendEnd"]:
        raise ValueError("transition dimEnd must precede colorBlendEnd")


def spec_hash(spec: dict) -> str:
    canonical = json.dumps(spec, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def generate_csharp(spec: dict, digest: str) -> str:
    state_cases = []
    for name in STATE_ORDER:
        state = spec["states"][name]
        breath = state["breath"]
        orbit = state["orbit"]
        rgb = state["color"]
        state_cases.append(
            f"""                case HaloState.{pascal(name)}:
                    return new SharedStateParameters(
                        {state['priority']}, {csharp_string(state['label'])},
                        {rgb[0]}, {rgb[1]}, {rgb[2]},
                        {number(breath['period'])}, {number(breath['visualMaximum'])},
                        {number(breath['visualMinimum'])}, {number(breath['poweredMaximum'])},
                        {number(breath['poweredMinimum'])}, {number(breath['brightShare'])},
                        {number(orbit['velocity'])}, {number(orbit['envelopePeriod'])},
                        {number(orbit['driftAmplitude'])}, {number(orbit['driftPeriod'])},
                        {number(orbit['inertiaDamping'])}, {number(state['coreWhite'])},
                        {number(state['glowGain'])});"""
        )

    duration_cases = "\n".join(
        f"                case HaloState.{pascal(name)}: return {number(value)};"
        for name, value in spec["transitions"]["durationByTarget"].items()
    )
    event_arrays = "\n".join(
        f"        private static readonly string[] {pascal(name)} = new string[] {{ "
        + ", ".join(csharp_string(item) for item in values)
        + " };"
        for name, values in spec["eventRules"].items()
    )
    action_blocks = "\n".join(
        "            if (ContainsAny(value, new string[] { "
        + ", ".join(csharp_string(item) for item in rule["containsAny"])
        + f" }})) return {csharp_string(rule['label'])};"
        for rule in spec["actionRules"]
    )
    failure_blocks = "\n".join(
        "            if (ContainsAny(value, new string[] { "
        + ", ".join(csharp_string(item) for item in rule["containsAny"])
        + f" }})) return {csharp_string(rule['detail'])};"
        for rule in spec["failureRules"]
    )
    attention = spec["attentionPulse"]
    error = spec["errorPresentations"]
    gap = spec["gapMotion"]
    transition = spec["transitions"]
    rate = spec["rateLimit"]
    direct_path, nested_path = rate["containerPaths"]
    primary_path = rate["primaryPath"]
    secondary_path = rate["secondaryPath"]
    enum_states = ",\n        ".join(pascal(name) for name in STATE_ORDER)
    enum_errors = ",\n        ".join(pascal(name) for name in error["names"])

    return f"""// <auto-generated>
// Generated by scripts/generate_shared.py. Do not edit by hand.
// Contract SHA-256: {digest}
// </auto-generated>
using System;
using System.Linq;

namespace CodexHalo
{{
    public enum HaloState
    {{
        {enum_states}
    }}

    public enum ErrorPresentation
    {{
        {enum_errors}
    }}

    public sealed class SharedStateParameters
    {{
        public readonly int Priority;
        public readonly string Label;
        public readonly byte Red;
        public readonly byte Green;
        public readonly byte Blue;
        public readonly double BreathPeriod;
        public readonly double VisualMaximum;
        public readonly double VisualMinimum;
        public readonly double PoweredMaximum;
        public readonly double PoweredMinimum;
        public readonly double BrightShare;
        public readonly double OrbitVelocity;
        public readonly double EnvelopePeriod;
        public readonly double DriftAmplitude;
        public readonly double DriftPeriod;
        public readonly double InertiaDamping;
        public readonly double CoreWhite;
        public readonly double GlowGain;

        public SharedStateParameters(int priority, string label, byte red, byte green,
            byte blue, double breathPeriod, double visualMaximum, double visualMinimum,
            double poweredMaximum, double poweredMinimum, double brightShare,
            double orbitVelocity, double envelopePeriod, double driftAmplitude,
            double driftPeriod, double inertiaDamping, double coreWhite, double glowGain)
        {{
            Priority = priority;
            Label = label;
            Red = red;
            Green = green;
            Blue = blue;
            BreathPeriod = breathPeriod;
            VisualMaximum = visualMaximum;
            VisualMinimum = visualMinimum;
            PoweredMaximum = poweredMaximum;
            PoweredMinimum = poweredMinimum;
            BrightShare = brightShare;
            OrbitVelocity = orbitVelocity;
            EnvelopePeriod = envelopePeriod;
            DriftAmplitude = driftAmplitude;
            DriftPeriod = driftPeriod;
            InertiaDamping = inertiaDamping;
            CoreWhite = coreWhite;
            GlowGain = glowGain;
        }}
    }}

    public static class GeneratedHaloSpec
    {{
        public const int ContractVersion = {spec['contractVersion']};
        public const string ReleaseVersion = {csharp_string(spec['releaseVersion'])};
        public const string SpecSha256 = {csharp_string(digest)};
        public const double TransitionDimEnd = {number(transition['dimEnd'])};
        public const double TransitionColorBlendEnd = {number(transition['colorBlendEnd'])};
        public const double TransitionLowPowered = {number(transition['lowPowered'])};
        public const double AttentionPeriod = {number(attention['period'])};
        public const double AttentionFirstCenter = {number(attention['first']['center'])};
        public const double AttentionFirstWidth = {number(attention['first']['width'])};
        public const double AttentionFirstStrength = {number(attention['first']['strength'])};
        public const double AttentionSecondCenter = {number(attention['second']['center'])};
        public const double AttentionSecondWidth = {number(attention['second']['width'])};
        public const double AttentionSecondStrength = {number(attention['second']['strength'])};
        public const double AttentionLivingBase = {number(attention['livingBase'])};
        public const double AttentionLivingAmplitude = {number(attention['livingAmplitude'])};
        public const double AttentionLivingPhase = {number(attention['livingPhase'])};
        public const double ErrorBrightPower = {number(error['brightPower'])};
        public const double ErrorDimPower = {number(error['dimPower'])};
        public const double ErrorFlashPeriod = {number(error['flashPeriod'])};
        public const double ErrorFirstCenter = {number(error['first']['center'])};
        public const double ErrorFirstWidth = {number(error['first']['width'])};
        public const double ErrorSecondCenter = {number(error['second']['center'])};
        public const double ErrorSecondWidth = {number(error['second']['width'])};
        public const double MinimumGapSeparation = {number(gap['minimumSeparationDegrees'])};
        public const double MaximumGapSeparation = {number(gap['maximumSeparationDegrees'])};
        public const double RepulsionSpeedMinimum = {number(gap['repulsionSpeedMinimum'])};
        public const double RepulsionSpeedMaximum = {number(gap['repulsionSpeedMaximum'])};
        public const double RepulsionDurationFactor = {number(gap['repulsionDurationFactor'])};
        public const double RepulsionReferenceSpeed = {number(gap['repulsionReferenceSpeed'])};
        public const double RepulsionDurationMinimum = {number(gap['repulsionDurationMinimum'])};
        public const double RepulsionDurationMaximum = {number(gap['repulsionDurationMaximum'])};
        public const double ExitVelocityScale = {number(gap['exitVelocityScale'])};
        public const double ExitVelocityMinimum = {number(gap['exitVelocityMinimum'])};
        public const double ExitVelocityMaximum = {number(gap['exitVelocityMaximum'])};
        public const string RateLimitMarker = {csharp_string(rate['marker'])};
        public const string RatePayloadKey = {csharp_string(direct_path[0])};
        public const string RateInfoKey = {csharp_string(nested_path[1])};
        public const string RateLimitsKey = {csharp_string(direct_path[1])};
        public const string RatePrimaryKey = {csharp_string(primary_path[0])};
        public const string RateSecondaryKey = {csharp_string(secondary_path[0])};
        public const string RateUsedPercentKey = {csharp_string(primary_path[1])};
        public const int RateLimitTailBytes = {rate['tailBytes']};
        public const int RateLimitRecentFileCount = {rate['recentFileCount']};
        public const int RateLimitRecentLineCount = {rate['recentLineCount']};

{event_arrays}

        public static SharedStateParameters State(HaloState state)
        {{
            switch (state)
            {{
{chr(10).join(state_cases)}
                default: throw new ArgumentOutOfRangeException("state");
            }}
        }}

        public static double TransitionDuration(HaloState target)
        {{
            switch (target)
            {{
{duration_cases}
                default: return 1.78;
            }}
        }}

        public static bool IsTaskStartEvent(string value) {{ return Exact(value, TaskStartExact); }}
        public static bool IsTaskCompleteEvent(string value) {{ return Exact(value, TaskCompleteExact); }}
        public static bool IsFatalEvent(string value) {{ return Exact(value, FatalExact); }}
        public static bool IsToolOutput(string value) {{ return Exact(value, ToolOutputExact); }}
        public static bool IsToolCall(string value) {{ return Exact(value, ToolCallExact); }}
        public static bool IsAttentionEvent(string value)
        {{
            return ContainsAny((value ?? String.Empty).ToLowerInvariant(), AttentionContains);
        }}

        public static string FriendlyAction(string raw)
        {{
            string value = (raw ?? String.Empty).ToLowerInvariant();
{action_blocks}
            return "Executing";
        }}

        public static string ClassifyFailure(string text)
        {{
            string value = (text ?? String.Empty).ToLowerInvariant();
{failure_blocks}
            return null;
        }}

        private static bool Exact(string value, string[] choices)
        {{
            string normalized = (value ?? String.Empty).ToLowerInvariant();
            return choices.Contains(normalized);
        }}

        private static bool ContainsAny(string value, string[] choices)
        {{
            return choices.Any(delegate(string choice)
            {{
                return value.IndexOf(choice, StringComparison.Ordinal) >= 0;
            }});
        }}
    }}
}}
"""


def generate_swift(spec: dict, digest: str) -> str:
    enum_states = "\n".join(f"    case {name}" for name in STATE_ORDER)
    enum_errors = "\n".join(f"    case {name}" for name in spec["errorPresentations"]["names"])
    state_cases = []
    for name in STATE_ORDER:
        state = spec["states"][name]
        breath = state["breath"]
        orbit = state["orbit"]
        rgb = state["color"]
        state_cases.append(
            f"""        case .{name}:
            SharedStateParameters(
                priority: {state['priority']}, label: {swift_string(state['label'])},
                red: {rgb[0]}, green: {rgb[1]}, blue: {rgb[2]},
                breathPeriod: {number(breath['period'])},
                visualMaximum: {number(breath['visualMaximum'])},
                visualMinimum: {number(breath['visualMinimum'])},
                poweredMaximum: {number(breath['poweredMaximum'])},
                poweredMinimum: {number(breath['poweredMinimum'])},
                brightShare: {number(breath['brightShare'])},
                orbitVelocity: {number(orbit['velocity'])},
                envelopePeriod: {number(orbit['envelopePeriod'])},
                driftAmplitude: {number(orbit['driftAmplitude'])},
                driftPeriod: {number(orbit['driftPeriod'])},
                inertiaDamping: {number(orbit['inertiaDamping'])},
                coreWhite: {number(state['coreWhite'])},
                glowGain: {number(state['glowGain'])
            })"""
        )
    duration_cases = "\n".join(
        f"        case .{name}: {number(value)}"
        for name, value in spec["transitions"]["durationByTarget"].items()
    )
    event_arrays = "\n".join(
        f"    private static let {name}: Set<String> = ["
        + ", ".join(swift_string(item) for item in values)
        + "]"
        for name, values in spec["eventRules"].items()
    )
    action_blocks = "\n".join(
        "        if containsAny(value, ["
        + ", ".join(swift_string(item) for item in rule["containsAny"])
        + f"]) {{ return {swift_string(rule['label'])} }}"
        for rule in spec["actionRules"]
    )
    failure_blocks = "\n".join(
        "        if containsAny(value, ["
        + ", ".join(swift_string(item) for item in rule["containsAny"])
        + f"]) {{ return {swift_string(rule['detail'])} }}"
        for rule in spec["failureRules"]
    )
    attention = spec["attentionPulse"]
    error = spec["errorPresentations"]
    gap = spec["gapMotion"]
    transition = spec["transitions"]
    rate = spec["rateLimit"]
    direct_path, nested_path = rate["containerPaths"]
    primary_path = rate["primaryPath"]
    secondary_path = rate["secondaryPath"]

    return f"""// <auto-generated>
// Generated by scripts/generate_shared.py. Do not edit by hand.
// Contract SHA-256: {digest}
// </auto-generated>
import Foundation

public enum HaloState: String, Codable, Equatable, Sendable, CaseIterable {{
{enum_states}
}}

public enum ErrorPresentation: String, Codable, Equatable, Sendable, CaseIterable {{
{enum_errors}
}}

public struct SharedStateParameters: Equatable, Sendable {{
    public let priority: Int
    public let label: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let breathPeriod: Double
    public let visualMaximum: Double
    public let visualMinimum: Double
    public let poweredMaximum: Double
    public let poweredMinimum: Double
    public let brightShare: Double
    public let orbitVelocity: Double
    public let envelopePeriod: Double
    public let driftAmplitude: Double
    public let driftPeriod: Double
    public let inertiaDamping: Double
    public let coreWhite: Double
    public let glowGain: Double
}}

public enum GeneratedHaloSpec {{
    public static let contractVersion = {spec['contractVersion']}
    public static let releaseVersion = {swift_string(spec['releaseVersion'])}
    public static let specSha256 = {swift_string(digest)}
    public static let transitionDimEnd = {number(transition['dimEnd'])}
    public static let transitionColorBlendEnd = {number(transition['colorBlendEnd'])}
    public static let transitionLowPowered = {number(transition['lowPowered'])}
    public static let attentionPeriod = {number(attention['period'])}
    public static let attentionFirstCenter = {number(attention['first']['center'])}
    public static let attentionFirstWidth = {number(attention['first']['width'])}
    public static let attentionFirstStrength = {number(attention['first']['strength'])}
    public static let attentionSecondCenter = {number(attention['second']['center'])}
    public static let attentionSecondWidth = {number(attention['second']['width'])}
    public static let attentionSecondStrength = {number(attention['second']['strength'])}
    public static let attentionLivingBase = {number(attention['livingBase'])}
    public static let attentionLivingAmplitude = {number(attention['livingAmplitude'])}
    public static let attentionLivingPhase = {number(attention['livingPhase'])}
    public static let errorBrightPower = {number(error['brightPower'])}
    public static let errorDimPower = {number(error['dimPower'])}
    public static let errorFlashPeriod = {number(error['flashPeriod'])}
    public static let errorFirstCenter = {number(error['first']['center'])}
    public static let errorFirstWidth = {number(error['first']['width'])}
    public static let errorSecondCenter = {number(error['second']['center'])}
    public static let errorSecondWidth = {number(error['second']['width'])}
    public static let minimumGapSeparation = {number(gap['minimumSeparationDegrees'])}
    public static let maximumGapSeparation = {number(gap['maximumSeparationDegrees'])}
    public static let repulsionSpeedMinimum = {number(gap['repulsionSpeedMinimum'])}
    public static let repulsionSpeedMaximum = {number(gap['repulsionSpeedMaximum'])}
    public static let repulsionDurationFactor = {number(gap['repulsionDurationFactor'])}
    public static let repulsionReferenceSpeed = {number(gap['repulsionReferenceSpeed'])}
    public static let repulsionDurationMinimum = {number(gap['repulsionDurationMinimum'])}
    public static let repulsionDurationMaximum = {number(gap['repulsionDurationMaximum'])}
    public static let exitVelocityScale = {number(gap['exitVelocityScale'])}
    public static let exitVelocityMinimum = {number(gap['exitVelocityMinimum'])}
    public static let exitVelocityMaximum = {number(gap['exitVelocityMaximum'])}
    public static let rateLimitMarker = {swift_string(rate['marker'])}
    public static let ratePayloadKey = {swift_string(direct_path[0])}
    public static let rateInfoKey = {swift_string(nested_path[1])}
    public static let rateLimitsKey = {swift_string(direct_path[1])}
    public static let ratePrimaryKey = {swift_string(primary_path[0])}
    public static let rateSecondaryKey = {swift_string(secondary_path[0])}
    public static let rateUsedPercentKey = {swift_string(primary_path[1])}
    public static let rateLimitTailBytes = {rate['tailBytes']}
    public static let rateLimitRecentFileCount = {rate['recentFileCount']}
    public static let rateLimitRecentLineCount = {rate['recentLineCount']}

{event_arrays}

    public static func state(_ state: HaloState) -> SharedStateParameters {{
        switch state {{
{chr(10).join(state_cases)}
        }}
    }}

    public static func transitionDuration(target: HaloState) -> Double {{
        switch target {{
{duration_cases}
        }}
    }}

    public static func isTaskStartEvent(_ value: String) -> Bool {{ taskStartExact.contains(value.lowercased()) }}
    public static func isTaskCompleteEvent(_ value: String) -> Bool {{ taskCompleteExact.contains(value.lowercased()) }}
    public static func isFatalEvent(_ value: String) -> Bool {{ fatalExact.contains(value.lowercased()) }}
    public static func isToolOutput(_ value: String) -> Bool {{ toolOutputExact.contains(value.lowercased()) }}
    public static func isToolCall(_ value: String) -> Bool {{ toolCallExact.contains(value.lowercased()) }}
    public static func isAttentionEvent(_ value: String) -> Bool {{
        containsAny(value.lowercased(), Array(attentionContains))
    }}

    public static func friendlyAction(_ raw: String) -> String {{
        let value = raw.lowercased()
{action_blocks}
        return "Executing"
    }}

    public static func classifyFailure(_ text: String) -> String? {{
        let value = text.lowercased()
{failure_blocks}
        return nil
    }}

    private static func containsAny(_ value: String, _ choices: [String]) -> Bool {{
        choices.contains {{ value.contains($0) }}
    }}
}}
"""


def write_or_check(path: Path, content: str, check: bool) -> bool:
    content = content.replace("\r\n", "\n")
    current = path.read_text(encoding="utf-8").replace("\r\n", "\n") if path.exists() else None
    if current == content:
        return True
    if check:
        print(f"out of date: {path.relative_to(ROOT)}", file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"generated {path.relative_to(ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    args = parser.parse_args()
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    validate(spec)
    digest = spec_hash(spec)
    results = [
        write_or_check(CS_PATH, generate_csharp(spec, digest), args.check),
        write_or_check(SWIFT_PATH, generate_swift(spec, digest), args.check),
    ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
