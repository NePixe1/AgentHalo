# Agent Halo Windows Visual Parity Prompt

## Audit conclusion

`src/shared/spec/agent-halo.v2.json` contains most shared parameters, but it is
not sufficient to reproduce the Windows halo pixel-for-pixel.

The JSON currently contains:

- state priorities, labels, base colors, breath ranges, and orbit parameters
- transition durations and dim/color/power phase boundaries
- attention double-pulse parameters
- error flash parameters
- gap separation, repulsion duration, exit velocity, and inertia parameters
- lifecycle, action, failure, quota, and settings rules

Important behavior still lives in native code:

- the exact `livingBreathV1`, `softWave`, `smootherStep`, damping, and magnetic
  repulsion formulas
- the complete Windows material stack, including dark material, lit material,
  white core, narrow glow layers, alpha equations, and saturation compensation
- transition snapshots and interrupted-transition continuity
- completion double flash
- state energy and its damping
- fixed ring geometry, gap sizes, and rounded cap treatment
- small-gap drift harmonics and the runtime catch/repel state machine
- compositor-driven frame timing

There is also one canonical-data drift:

- JSON `working.color` is `[52, 158, 199]`
- Windows v0.13.0 actually renders execution blue as `[39, 161, 211]`

The current macOS renderer intentionally differs from Windows. It adds radius,
width, gap-opening, gap-skew, and secondary-contour morphing; it uses persistent
colored bloom and edge highlights; it does not consume the Windows transition
snapshot, completion double flash, energy damping, white-core material, or
steady-green no-glow behavior.

The following prompt is intended for the macOS-side Codex.

---

## Prompt for macOS Codex

You are implementing visual parity between Agent Halo v0.13.0 Windows and
macOS. Work in the existing single repository. Windows C#/WPF is the visual
reference; macOS remains native Swift/AppKit/Core Graphics.

The goal is perceptual and mathematical parity, not merely using the same state
names. Preserve native window, menu bar, startup, hit-testing, and AppKit code.
Replace the macOS halo animation and material behavior where it conflicts with
the Windows reference.

Do not redesign the halo. Do not add decorative particles, a center glyph,
radial center light, background plate, extra contour, or additional gaps. The
window must remain transparent and the only visible object must be one thick
ring split by two unequal moving gaps.

### Read these files first

1. `src/shared/spec/agent-halo.v2.json`
2. `src/windows/Program.cs`, especially class `HaloVisual`
3. `src/macos/Sources/AgentHaloCore/HaloMath.swift`
4. `src/macos/Sources/AgentHaloCore/HaloVisualModel.swift`
5. `src/macos/Sources/AgentHaloMac/HaloView.swift`
6. `src/macos/Sources/AgentHaloMac/HaloRenderer.swift`
7. `src/shared/expected/animation-samples.json`

Before editing, report every remaining visual difference between the Windows
and macOS implementations. Then implement the changes and run the macOS build,
CoreChecks, diagnostic renderer, and new parity tests.

## Canonical states

Use these actual Windows colors:

| State | Meaning | RGB | Light behavior |
|---|---|---:|---|
| Idle | Codex is not running | `113,132,140` | dark cool white, no emitted light, slow nonlinear motion |
| Thinking | pure reasoning or planning | `226,170,31` | bright amber, long-bright/short-dark living breath |
| Working | commands, tools, search, file edits | `39,161,211` | saturated blue, longer bright phase than yellow |
| Done | newly completed task | `38,198,108` | two bright completion flashes, then slow living breath |
| Steady done | Codex is running with no active task, or completion acknowledged | `38,198,108` | green material only, `powered = 0`, no emitted glow |
| Attention | Yes, approval, confirmation, or input required | `142,108,236` | violet soft double pulse, second pulse weaker |
| Error | a blocking failure | `218,50,86` | flashing, bright constant, or dim red presentation |

The state priority is:

```text
error > attention > working > thinking > done > idle
```

Do not treat normal authorization as an error. A tool or command failure that
does not stop the agent must remain Working or Thinking.

## Logical geometry

Render in a logical `112 x 112` coordinate system and scale uniformly:

```text
scale = min(width, height) / 112
center = bounds center
base radius = 35.8
base body width = 8.6
large gap angular size = 30 degrees
small gap angular size = 22 degrees
line caps = round
```

The gap sizes are fixed in the Windows reference. Do not animate gap width,
ring radius, body width, or add a secondary contour, except for these explicit
state effects:

```text
Attention body width += 0.30 * pulse
Error body width += 0.25 * pulse
Completion flash radius += 0.45 * flash
Completion flash body width += 0.65 * flash
```

The two visible arcs are:

```text
arc1:
  start = gapA + 30 / 2
  sweep = positiveModulo(gapB - 22 / 2 - start, 360)

arc2:
  start = gapB + 22 / 2
  sweep = positiveModulo(gapA - 30 / 2 - start, 360)
```

Remove or disable the current macOS `ringMorph`, animated `gapOpen`,
`gapSkew`, radius/width morph, secondary contour, and persistent edge
highlight for this parity mode.

## State parameters

Use the values generated from the shared spec, except for Working blue, which
must use the actual Windows value above until the JSON drift is fixed.

| State | Breath period | Visual max/min | Powered max/min | Bright share | Orbit base deg/s | Envelope period | Drift amp/period | Inertia damping | Core white | Glow gain |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Idle | 6.8 | 0.40 / 0.18 | 0 / 0 | 0.50 | 27 | 7.6 | 5.2 / 4.8 | 0.62 | 0.82 | 1.00 |
| Thinking | 5.5 | 1.00 / 0.26 | 1.00 / 0.18 | 0.70 | 78 | 4.2 | 7.0 / 3.6 | 0.66 | 0.90 | 1.13 |
| Working | 7.2 | 1.00 / 0.22 | 1.00 / 0.16 | 0.78 | 106 | 2.2 | 8.5 / 2.8 | 0.72 | 0.86 | 1.07 |
| Done | 9.2 | 0.92 / 0.22 | 0.84 / 0.09 | 0.76 | 38 | 8.5 | 4.2 / 5.5 | 0.58 | 0.84 | 1.00 |
| Attention | 5.8 | custom | custom | custom | 46 | 4.1 | 6.5 / 3.3 | 0.76 | 0.82 | 1.00 |
| Error | 1.55 | custom | custom | custom | 60 | 1.75 | 7.5 / 2.6 | 0.84 | 0.91 | 1.12 |

Thinking must have a shorter absolute bright duration than Working:

```text
Thinking: 5.5 * 0.70 = 3.85 seconds
Working:  7.2 * 0.78 = 5.616 seconds
```

These numbers describe the curve, but the result must not look like a timer
with a flat bright platform and a hard dark notch.

## Nonlinear living breath

Implement this exact function:

```text
phase = positiveModulo(time, period) / period
center = brightShare + (1 - brightShare) * 0.46
distance = abs(phase - center)
distance = min(distance, 1 - distance)
width = max(0.075, (1 - brightShare) * 0.46)
dip = exp(-pow(distance / width, 4))
micro =
    0.018 * sin(phase * 2*pi)
  + 0.009 * sin(phase * 4*pi + 0.8)

livingBreath =
  clamp(maximum - (maximum - minimum) * dip + micro,
        minimum, maximum)
```

This is deliberately not a sine wave. The fourth-power exponential produces
a long luminous region and a short rounded dip. The two low-amplitude
harmonics prevent the ring from feeling mechanically periodic.

For Idle only:

```text
softWave(x):
  cycle = positiveModulo(x, 1)
  triangle = cycle < 0.5 ? cycle*2 : (1-cycle)*2
  return smootherStep(triangle)

idleBreath =
  visualMinimum
  + (visualMaximum - visualMinimum) * softWave(time / period)
```

Idle always has `powered = 0`. It may move and subtly change material
intensity, but it must never look illuminated.

Use:

```text
smootherStep(x) = x^3 * (x * (x*6 - 15) + 10)
```

## Attention double pulse

The violet Attention state is a soft aviation-style double breath, not a
binary blink:

```text
cycle = positiveModulo(time, 5.8) / 5.8

smoothPulse(phase, center, width):
  distance = min(abs(phase-center), 1-abs(phase-center))
  normalized = clamp(1 - distance/width, 0, 1)
  return smootherStep(normalized)

first  = smoothPulse(cycle, 0.16, 0.095) * 1.00
second = smoothPulse(cycle, 0.38, 0.110) * 0.82
livingBase = 0.08 + 0.05 * softWave(cycle + 0.18)
pulse = clamp(livingBase + first + second, 0, 1)

powered = 0.10 + 0.90 * pulse
breath = 0.28 + 0.72 * pulse
intensity = 0.56 + 0.18 * pulse
bodyWidth = 8.6 + 0.30 * pulse
```

The first pulse is full strength. The second is slightly weaker and broader.
Between pairs, retain a very low violet living movement instead of freezing.

## Error presentations

Error has three visual presentations:

1. `flashing`: Codex has a blocking error and is not in the foreground.
2. `bright`: Codex is in the foreground and the error is being viewed.
3. `dim`: the user has left Codex after viewing the error.

Flashing:

```text
cycle = positiveModulo(time, 1.55)
first  = exp(-pow((cycle - 0.12) / 0.055, 2))
second = exp(-pow((cycle - 0.34) / 0.065, 2))
pulse = clamp(first + second, 0, 1)
```

Bright:

```text
powered = 1.0
breath = 0.92
```

The Windows renderer intentionally uses full power for constant red even
though the shared diagnostic value is `0.92`.

Dim:

```text
powered = 0
breath = 0.10
intensity = 0.52
```

The flash itself may feel urgent and mechanical. Entering and leaving all
three error presentations must still use the continuous transition pipeline.

## Completion double flash

After transition into Done has completed, and only while completion is not
acknowledged:

```text
first  = exp(-pow((localStateTime - 0.28) / 0.14, 2))
second = exp(-pow((localStateTime - 0.92) / 0.18, 2))
flash = clamp(first + 0.90 * second, 0, 1)

intensity += 0.50 * flash
radius += 0.45 * flash
bodyWidth += 0.65 * flash
powered = clamp(powered + 0.82 * flash, 0, 1)
```

After the two flashes, use the normal slow Done breath. When Codex is opened
or the completion is acknowledged, smoothly collect the light into Steady
Done:

```text
powered = 0
breath = 0.34
intensity = 0.56
```

Do not leave a fixed green bloom around Steady Done.

## Continuous transitions

Every state and presentation change must start from the actual rendered frame,
not from the old state's nominal target.

Store this snapshot each frame:

```text
color
powered
breath
intensity
bodyWidth
coreWhite
glowGain
```

On a change:

1. Capture the current rendered snapshot.
2. Set the new state and local state time to zero.
3. Transition from the captured snapshot.
4. If another change arrives during the transition, capture that in-between
   frame and continue from it.

Target transition durations:

```text
Idle       1.78 s
Thinking   1.68 s
Working    1.48 s
Done       1.72 s
Attention  1.02 s
Error      0.92 s
Steady Done collection 1.45 s
Leaving Steady Done    1.15 s
Error -> flashing      0.82 s
Other error phase      1.24 s
```

Transition progress:

```text
raw = clamp((time - transitionStart) / duration, 0, 1)
progress = smootherStep(raw)
```

Color:

```text
colorProgress =
  smootherStep(clamp((progress - 0.18) / 0.56, 0, 1))

color = linear-sRGB-mix(fromColor, targetColor, colorProgress)
```

Use linear-light interpolation per RGB channel:

```text
sRGB -> linear:
  c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4)

linear -> sRGB:
  c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055
```

Light:

```text
low = 0.08

if progress < 0.36:
  powered = lerp(fromPowered, min(fromPowered, low),
                 smootherStep(progress / 0.36))
else if progress < 0.58:
  powered = min(fromPowered, low)
else:
  powered = lerp(min(fromPowered, low), targetPowered,
                 smootherStep((progress - 0.58) / 0.42))
```

Other scalar fields:

```text
scalarProgress =
  smootherStep(clamp((progress - 0.34) / 0.66, 0, 1))
```

Interpolate breath, intensity, body width, core white, and glow gain with
`scalarProgress`.

The transition must visibly perform:

```text
current light gently dims
-> color changes while dim
-> target light naturally powers up
```

No hard color switch, no flash used as a color transition, and no instant
glow shutdown. The target state's breath phase starts naturally after the
transition rather than entering at an arbitrary global-clock phase.

## Gap motion and magnetic repulsion

The gaps rotate. No bright dot travels around the inside of the ring.

Use actual display-frame delta, clamped to `[0.001, 0.08]` seconds.

Large gap base velocity comes from the state table. Modulate it:

```text
primary = softWave(time / envelopePeriod)
secondary = softWave(time / (envelopePeriod * 0.47) + 0.29)
velocityEnvelope =
  0.18 + 0.92 * pow(primary, 1.65) + 0.22 * secondary

targetVelocity = stateOrbitVelocity * velocityEnvelope
outerVelocity =
  targetVelocity + (outerVelocity-targetVelocity) * exp(-2.1 * delta)
gapA += outerVelocity * delta
```

This must never look like constant angular velocity. Working is the fastest,
Thinking is second, Error is urgent, Attention is moderate, Done and Idle are
slower but never frozen.

The angular separation between the gaps moves between approximately 150 and
40 degrees:

```text
minimum separation = 40 degrees
maximum separation = 150 degrees
repulsion trigger = separation <= 41.5 degrees
```

When not repelling, the small gap is not locked to the large gap. It remains
near an anchor and receives inertia plus bounded drift:

```text
inertiaVelocity *= exp(-stateInertiaDamping * delta)
inertiaOffset += inertiaVelocity * delta

direction = repulsionCount is even ? +1 : -1
primary = sin(time * 2*pi / driftPeriod)
secondary =
  0.22 * (
    sin(time * 2*pi / (driftPeriod*0.43) + 0.8)
    - sin(0.8)
  )
drift = direction * driftAmplitude * (primary + secondary)

gapB = smallGapAnchor + inertiaOffset + drift
```

As the large gap catches the small gap and separation reaches 40 degrees,
repel the small gap toward 150 degrees:

```text
speed = clamp(abs(outerVelocity), 14, 92)
repulsionDuration =
  clamp(1.42 * sqrt(72 / speed), 1.28, 3.05)

magneticEase(p):
  return clamp(smootherStep(p) + sin(p*pi)*0.055, 0, 1)

separation =
  lerp(repulsionStart, 150, magneticEase(progress))
gapB = gapA + separation
```

When repulsion finishes:

```text
smallGapAnchor = gapB
inertiaOffset = 0
inertiaVelocity =
  clamp(abs(outerVelocity) * 0.42, 9, 38)
```

The repulsion duration and exit inertia must scale with current orbit speed.
Slow green and idle motion must not use a blue-state snap speed. The push must
feel like magnetic repulsion with follow-through, not teleportation or a
pulled tween.

## Windows material model to reproduce

The macOS renderer must use `coreWhite` and `glowGain`. The current macOS
renderer reads these parameters but does not reproduce the Windows material.

For every frame:

```text
visualIntensity = 0.50 + breath * 0.18
intensity =
  clamp(visualIntensity + dampedStateEnergy * 0.18
        + completionFlash * 0.50,
        0, 1.32)
```

State energy targets:

```text
Idle 0.34
Thinking 0.86
Working 1.00
Done 0.68
Attention 0.98
Error 1.00
```

Damp energy continuously:

```text
energy =
  targetEnergy + (energy-targetEnergy) * exp(-4.2 * delta)
```

Color preparation:

```text
dimColor = HSL saturation(baseColor * 0.88)
emissionColor =
  HSL saturation(baseColor * (0.92 + 0.36 * powered))
glowColor =
  linear-sRGB-mix(emissionColor, RGB(242,248,249),
                  0.18 + 0.08 * powered)
```

Clamp HSL saturation to `[0,1]`; preserve hue and lightness.

Draw in this back-to-front order, using rounded caps:

```text
1. glow, width 19.5
   color emissionColor
   alpha = (12 + 39*powered) * intensity * glowGain

2. glow, width 14.5
   color emissionColor
   alpha = (22 + 52*powered) * intensity * glowGain

3. glow, width 11.2
   color emissionColor
   alpha = (38 + 70*powered) * intensity * glowGain

4. narrow pale glow, width 9.8
   color glowColor
   alpha = 82 * powered * intensity * glowGain

5. dark tube foundation, width bodyWidth + 1.15
   darkMaterial =
     linear-sRGB-mix(dimColor, RGB(18,24,26), 0.46)
   alpha = 242 * intensity

6. powered tube body, width bodyWidth
   litMaterial =
     linear-sRGB-mix(emissionColor, RGB(250,253,252), 0.56)
   poweredMaterial =
     linear-sRGB-mix(darkMaterial, litMaterial,
                     0.24 + 0.76*powered)
   alpha = (182 + 73*powered) * intensity

7. white lamp core, width bodyWidth - 2.25
   poweredCore =
     linear-sRGB-mix(emissionColor, RGB(253,255,255), coreWhite)
   alpha = (5 + 235*powered) * intensity

8. specular center line, width 1.65
   color RGB(255,255,255)
   alpha = 205 * powered * intensity
```

Round every alpha to the nearest integer and clamp to `[0,255]`.

This stack should look like a physical dark translucent light tube that becomes
internally illuminated. It must not look like a flat colored stroke, a neon
outline with a huge blur, or a bright dot moving around the ring.

The visible bloom must remain narrow. Brightening should mainly make the tube
body and white core come alive; do not solve brightness by making a thick,
low-quality outer halo.

## Frame scheduling

Do not advance animation with a hard-coded `1/60` delta. Use a display-linked
callback or the best available macOS display refresh callback and compute
actual elapsed time. Support 60 Hz, 120 Hz, and variable refresh displays.

Requirements:

- clamp a single animation delta to `[0.001, 0.08]`
- render once per unique display callback
- avoid timer drift and accumulated phase error
- preserve the animation state when the window moves between displays
- keep all animation formulas time-based, never frame-count based

## Known macOS implementation differences to remove

The current macOS implementation will not match Windows until these are fixed:

1. `HaloView` uses a fixed 60 Hz `Timer` and fixed delta.
2. `transitionProgress` is passed but not used by `HaloRenderer`.
3. No current rendered snapshot is captured when state changes.
4. State color changes directly instead of dim/change/power-up.
5. `HaloRenderer` uses ring radius/width/gap morph and a secondary contour.
6. `coreWhite` and `glowGain` do not drive the full Windows material stack.
7. Steady green still draws persistent colored outer layers.
8. Completion green double flash is missing.
9. Working blue uses the JSON value instead of Windows `[39,161,211]`.
10. macOS intensity uses current breath where Windows uses damped state energy.
11. macOS gap sizes animate; Windows uses fixed 30 and 22 degree gaps.

## Implementation boundary

Keep platform-native:

- AppKit panel and menu bar integration
- mouse interaction and drag behavior
- launch agent and app activation
- Core Graphics drawing API

Share or exactly port:

- state colors and brightness parameters
- breath, attention, error, transition, damping, and gap formulas
- visual snapshot structure
- material layer equations
- geometry constants
- completion double flash
- deterministic test samples

Prefer moving the remaining constants into the shared spec only after parity is
proven. Do not first rewrite the entire architecture. Make the smallest native
changes required to match the reference, then extract constants in a separate
commit.

## Required tests

Add deterministic tests with tolerance for:

1. Thinking at `t=1.0` is full power and at `t=4.6` is its dark dip.
2. Working at `t=0.8` is full power and at `t=6.35` is its dark dip.
3. Thinking bright duration is shorter than Working bright duration.
4. Attention has a strong first pulse, weaker second pulse, and moving low base.
5. Completion has two flashes centered near `0.28` and `0.92` seconds.
6. Steady Done produces zero powered glow.
7. Error flashing, bright, and dim produce distinct target snapshots.
8. Gap separation travels from 40 to 150 degrees with magnetic easing.
9. Repulsion duration is longer at low orbit speed than at high orbit speed.
10. Interrupted transitions are continuous in color, powered level, width,
    core white, and glow gain.
11. Working blue is `[39,161,211]`.
12. Transparent pixels outside the glow remain alpha zero.

Render comparison strips for:

```text
Idle full motion cycle
Thinking full breath cycle
Working full breath cycle
Done double flash plus slow breath
Attention full double-pulse cycle
Error flashing -> bright -> dim
Thinking -> Working
Working -> Done
Done -> Steady Done
Steady Done -> Thinking
Attention -> Working
Error -> Thinking
Gap motion in Idle, Thinking, Working, and Done
```

Render each strip on transparent, white, and near-black backgrounds. Compare
geometry, tube brightness, core whiteness, glow thickness, transition
continuity, and gap motion against Windows diagnostic output.

## Acceptance criteria

The work is not complete merely because both clients pass shared numeric tests.
It is complete when:

- both platforms show one thick ring with the same fixed geometry
- both gaps are always visible and unequal
- rotation is nonlinear and never looks constant-speed
- the small gap drifts, is caught near 40 degrees, is repelled toward 150
  degrees, and continues with speed-scaled inertia
- yellow, blue, and completed green breathe with long bright and short dark
  phases without visible curve corners
- violet clearly performs two soft pulses
- bright red, yellow, and blue reach the same perceived full-power class
- state changes dim, recolor, and relight without a hard frame
- file creation and patch application count as blue execution, not yellow reasoning
- steady green has material color but no emitted glow
- the lit tube has a white internal core and narrow colored edge glow
- there is no center light, moving bright dot, square background, or oversized
  bloom
- animation remains smooth at the active display refresh rate

After implementation, return:

1. a difference report
2. the files changed
3. formulas or constants that still remain platform-specific
4. build and test results
5. diagnostic image paths
6. any deliberate visual difference that remains, with justification
