using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using DrawingColor = System.Drawing.Color;
using MediaColor = System.Windows.Media.Color;
using MediaBrush = System.Windows.Media.Brush;
using MediaPen = System.Windows.Media.Pen;
using MediaPoint = System.Windows.Point;

namespace CodexHalo
{
public sealed class HaloVisual : FrameworkElement
    {
        private struct VisualSnapshot
        {
            public MediaColor Color;
            public double Powered;
            public double Breath;
            public double Intensity;
            public double BodyWidth;
            public double CoreWhite;
            public double GlowGain;
        }

        private readonly Stopwatch clock;
        private HaloState state;
        private HaloState previousState;
        private DateTime stateChangedUtc;
        private MediaColor transitionFromColor;
        private double transitionStartSeconds;
        private double transitionDuration;
        private VisualSnapshot transitionFromVisual;
        private VisualSnapshot renderedVisual;
        private bool hasRenderedFrame;
        private string label;
        private int count;
        private bool isRendering;
        private double testTime;
        private double testSinceState;
        private bool useTestTime;
        private long frameCount;
        private double lastAnimationSeconds;
        private TimeSpan lastRenderingTime;
        private double frameIntervalSumMs;
        private double frameIntervalMaxMs;
        private long frameIntervalCount;
        private long slowFrameCount;
        private long renderingCallbackCount;
        private long duplicateRenderingTimeCount;
        private int gen0AtReset;
        private int gen1AtReset;
        private int gen2AtReset;
        private double outerPhase;
        private double innerPhase;
        private double outerVelocity;
        private double gapSeparation;
        private bool gapRepelling;
        private double gapRepulsionElapsed;
        private double gapRepulsionStart;
        private double gapRepulsionDuration;
        private int gapRepulsionCount;
        private double smallGapAnchor;
        private double smallGapDriftElapsed;
        private double smallGapInertiaOffset;
        private double smallGapInertiaVelocity;
        private double energy;
        private bool steadyDone;
        private ErrorPresentation errorPresentation;

        public HaloVisual()
        {
            clock = Stopwatch.StartNew();
            state = HaloState.Idle;
            previousState = HaloState.Idle;
            stateChangedUtc = DateTime.UtcNow;
            transitionFromColor = StateColor(HaloState.Idle);
            transitionStartSeconds = -10;
            transitionDuration = 1;
            renderedVisual.Color = transitionFromColor;
            label = "READY";
            energy = TargetEnergy(HaloState.Idle);
            outerPhase = 97;
            gapSeparation = GeneratedHaloSpec.MaximumGapSeparation;
            innerPhase = outerPhase + gapSeparation;
            smallGapAnchor = innerPhase;
            SnapsToDevicePixels = false;
            Focusable = false;
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        public HaloState State
        {
            get { return state; }
        }

        public double MeasuredFps
        {
            get
            {
                return frameIntervalSumMs <= 0 ? 0 :
                    frameIntervalCount * 1000.0 / frameIntervalSumMs;
            }
        }

        public string PerformanceSummary
        {
            get
            {
                double averageMs = frameIntervalCount <= 0 ? 0 :
                    frameIntervalSumMs / frameIntervalCount;
                return String.Format(CultureInfo.InvariantCulture,
                    "{0:F1} FPS\nAverage frame: {1:F2} ms\nWorst frame: {2:F2} ms\n" +
                    "Frames over 25 ms: {3}\nWPF render tier: {4}\nGC collections: {5}/{6}/{7}\n" +
                    "Rendering callbacks: {8}\nDuplicate rendering times: {9}",
                    MeasuredFps, averageMs, frameIntervalMaxMs, slowFrameCount,
                    RenderCapability.Tier >> 16,
                    GC.CollectionCount(0) - gen0AtReset,
                    GC.CollectionCount(1) - gen1AtReset,
                    GC.CollectionCount(2) - gen2AtReset,
                    renderingCallbackCount, duplicateRenderingTimeCount);
            }
        }

        public void ResetPerformanceMetrics()
        {
            frameCount = 0;
            frameIntervalSumMs = 0;
            frameIntervalMaxMs = 0;
            frameIntervalCount = 0;
            slowFrameCount = 0;
            renderingCallbackCount = 0;
            duplicateRenderingTimeCount = 0;
            lastRenderingTime = TimeSpan.Zero;
            gen0AtReset = GC.CollectionCount(0);
            gen1AtReset = GC.CollectionCount(1);
            gen2AtReset = GC.CollectionCount(2);
        }

        public void SetState(HaloState value, string stateLabel, int sessionCount)
        {
            if (state != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                previousState = state;
                state = value;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = TransitionDuration(previousState, state);
            }
            label = stateLabel ?? CodexSessionMonitor.StateLabel(value);
            count = sessionCount;
            InvalidateVisual();
        }

        public void SetSteadyDone(bool value)
        {
            if (steadyDone != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                steadyDone = value;
                previousState = state;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = value ? 1.45 : 1.15;
                InvalidateVisual();
            }
        }

        private void CaptureTransitionStart(double now)
        {
            double localTime = Math.Max(0,
                (DateTime.UtcNow - stateChangedUtc).TotalSeconds);
            transitionFromVisual = hasRenderedFrame ? renderedVisual :
                TargetVisual(state, localTime);
            transitionFromColor = transitionFromVisual.Color;
        }

        public void SetErrorPresentation(ErrorPresentation value)
        {
            if (errorPresentation != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                errorPresentation = value;
                previousState = state;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = value == ErrorPresentation.Flashing ? 0.82 : 1.24;
                InvalidateVisual();
            }
        }

        public void SetTestTime(double seconds)
        {
            useTestTime = true;
            testTime = seconds;
            testSinceState = seconds;
            previousState = state;
            transitionFromColor = StateColor(state);
            transitionFromVisual = TargetVisual(state, seconds);
            transitionStartSeconds = -10;
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-seconds);
            InvalidateVisual();
        }

        public void SetTestTransition(HaloState from, HaloState to, double progress,
            double absoluteTime)
        {
            useTestTime = true;
            previousState = from;
            state = to;
            transitionFromColor = StateColor(from);
            transitionFromVisual = TargetVisual(from, absoluteTime);
            transitionDuration = TransitionDuration(from, to);
            transitionStartSeconds = absoluteTime - transitionDuration *
                Clamp(progress, 0, 1);
            testTime = absoluteTime;
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(
                -transitionDuration * Clamp(progress, 0, 1));
            InvalidateVisual();
        }

        public void SetTestSteadyGreenTransition(double progress)
        {
            useTestTime = true;
            previousState = HaloState.Done;
            state = HaloState.Done;
            steadyDone = true;
            transitionFromColor = StateColor(HaloState.Done);
            transitionFromVisual = TargetVisual(HaloState.Done, 0);
            transitionFromVisual.Powered = 0.82;
            transitionFromVisual.Breath = 0.90;
            transitionDuration = 1.45;
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        public void SetTestSteadyGreenToThinking(double progress)
        {
            useTestTime = true;
            previousState = HaloState.Done;
            state = HaloState.Thinking;
            steadyDone = false;
            transitionFromColor = StateColor(HaloState.Done);
            transitionFromVisual = TargetVisual(HaloState.Done, 0);
            transitionFromVisual.Powered = 0;
            transitionFromVisual.Breath = 0.34;
            transitionDuration = TransitionDuration(HaloState.Done,
                HaloState.Thinking);
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        public void SetTestErrorPresentationTransition(ErrorPresentation from,
            ErrorPresentation to, double progress)
        {
            useTestTime = true;
            previousState = HaloState.Error;
            state = HaloState.Error;
            errorPresentation = from;
            transitionFromVisual = TargetVisual(HaloState.Error, 0.18);
            transitionFromColor = StateColor(HaloState.Error);
            errorPresentation = to;
            transitionDuration = to == ErrorPresentation.Flashing ? 0.82 : 1.24;
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (!isRendering)
            {
                CompositionTarget.Rendering += OnRendering;
                isRendering = true;
            }
        }

        private void OnUnloaded(object sender, RoutedEventArgs e)
        {
            if (isRendering)
            {
                CompositionTarget.Rendering -= OnRendering;
                isRendering = false;
            }
        }

        private void OnRendering(object sender, EventArgs e)
        {
            renderingCallbackCount++;
            double now = clock.Elapsed.TotalSeconds;
            RenderingEventArgs rendering = e as RenderingEventArgs;
            double animationDelta;
            if (rendering != null && lastRenderingTime != TimeSpan.Zero)
            {
                if (rendering.RenderingTime == lastRenderingTime)
                {
                    duplicateRenderingTimeCount++;
                    return;
                }
                animationDelta = (rendering.RenderingTime - lastRenderingTime).TotalSeconds;
            }
            else
            {
                animationDelta = lastAnimationSeconds <= 0 ? 1.0 / 60.0 :
                    now - lastAnimationSeconds;
            }
            if (rendering != null)
            {
                lastRenderingTime = rendering.RenderingTime;
            }
            lastAnimationSeconds = now;
            animationDelta = Clamp(animationDelta, 0.001, 0.08);
            AdvanceAnimation(animationDelta, now);

            if (frameCount > 0)
            {
                double intervalMs = animationDelta * 1000;
                frameIntervalSumMs += intervalMs;
                frameIntervalCount++;
                frameIntervalMaxMs = Math.Max(frameIntervalMaxMs, intervalMs);
                if (intervalMs > 25)
                {
                    slowFrameCount++;
                }
            }
            frameCount++;
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            double width = ActualWidth;
            double height = ActualHeight;
            if (width <= 0 || height <= 0)
            {
                return;
            }

            double t = useTestTime ? testTime : clock.Elapsed.TotalSeconds;
            double sinceState = useTestTime ? testSinceState :
                Math.Max(0, (DateTime.UtcNow - stateChangedUtc).TotalSeconds);
            double transition = TransitionProgress(t);
            MediaPoint center = new MediaPoint(width / 2.0, height / 2.0);
            double scale = Math.Min(width, height) / 112.0;
            dc.PushTransform(new ScaleTransform(scale, scale, center.X, center.Y));

            MediaColor color = AnimatedColor(t);
            double displayEnergy = useTestTime
                ? Lerp(TargetEnergy(previousState), TargetEnergy(state), transition)
                : energy;
            double displayOuterPhase = outerPhase;
            double displayInnerPhase = innerPhase;
            if (useTestTime)
            {
                TestGapPhases(previousState, state, t, transition,
                    out displayOuterPhase, out displayInnerPhase);
            }

            DrawPureRing(dc, center, color, displayEnergy, displayOuterPhase,
                displayInnerPhase, t, sinceState, transition);
            hasRenderedFrame = true;
            dc.Pop();
        }

        private void DrawPureRing(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double gapA, double gapB, double t, double sinceState,
            double transition)
        {
            double localStateTime = useTestTime && transitionStartSeconds < 0
                ? sinceState : Math.Max(0, sinceState - transitionDuration);
            VisualSnapshot target = TargetVisual(state, localStateTime);
            target.Color = color;
            VisualSnapshot visual = TransitionVisual(transitionFromVisual, target,
                transition);
            double breath = visual.Breath;
            double completionFlash = state == HaloState.Done
                && !steadyDone && transition >= 0.999
                    ? CompletionDoubleFlash(localStateTime) : 0;
            double intensity = Clamp(visual.Intensity + displayEnergy * 0.18 +
                completionFlash * 0.5, 0, 1.32);
            double radius = 35.8 + completionFlash * 0.45;
            double bodyWidth = visual.BodyWidth + completionFlash * 0.65;
            double powered = visual.Powered;
            powered = Clamp(powered + completionFlash * 0.82, 0, 1);
            renderedVisual = visual;
            renderedVisual.Color = color;
            renderedVisual.Powered = powered;
            MediaColor dimColor = AdjustSaturation(color, 0.88);
            MediaColor emissionColor = AdjustSaturation(color,
                0.92 + 0.36 * powered);
            MediaColor glowColor = MixColor(emissionColor,
                MediaColor.FromRgb(242, 248, 249), 0.18 + 0.08 * powered);
            double glowGain = visual.GlowGain;
            StreamGeometry[] ringGeometry = CreateDynamicRingGeometry(center,
                radius, gapA, gapB);
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(emissionColor,
                    Alpha((12 + 39 * powered) * intensity * glowGain)), 19.5));
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(emissionColor,
                    Alpha((22 + 52 * powered) * intensity * glowGain)), 14.5));
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(emissionColor,
                    Alpha((38 + 70 * powered) * intensity * glowGain)), 11.2));
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(glowColor,
                    Alpha(82 * powered * intensity * glowGain)), 9.8));

            MediaColor darkMaterial = MixColor(dimColor,
                MediaColor.FromRgb(18, 24, 26), 0.46);
            MediaColor litMaterial = MixColor(emissionColor,
                MediaColor.FromRgb(250, 253, 252), 0.56);
            MediaColor poweredMaterial = MixColor(darkMaterial, litMaterial,
                0.24 + 0.76 * powered);
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(darkMaterial, Alpha(242 * intensity)),
                    bodyWidth + 1.15));
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(poweredMaterial,
                    Alpha((182 + 73 * powered) * intensity)), bodyWidth));
            MediaColor poweredCore = MixColor(emissionColor,
                MediaColor.FromRgb(253, 255, 255), visual.CoreWhite);
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(poweredCore,
                    Alpha((5 + 235 * powered) * intensity)),
                    bodyWidth - 2.25));
            DrawDynamicRing(dc, ringGeometry,
                NewPen(WithAlpha(MediaColor.FromRgb(255, 255, 255),
                    Alpha(205 * powered * intensity)), 1.65));
        }

        private VisualSnapshot TargetVisual(HaloState value, double localTime)
        {
            VisualSnapshot result = new VisualSnapshot();
            result.Color = StateColor(value);
            result.Breath = StateBreath(value, localTime);
            result.Powered = TargetPowered(value, localTime);
            result.Intensity = 0.50 + result.Breath * 0.18;
            result.BodyWidth = 8.6;
            result.CoreWhite = CoreWhiteFor(value);
            result.GlowGain = GlowGainFor(value);
            if (value == HaloState.Done && steadyDone)
            {
                result.Powered = 0;
                result.Breath = 0.34;
                result.Intensity = 0.56;
            }
            else if (value == HaloState.Attention)
            {
                double pulse = AttentionPulse(localTime);
                result.Powered = 0.10 + 0.90 * pulse;
                result.Breath = 0.28 + 0.72 * pulse;
                result.Intensity = 0.56 + 0.18 * pulse;
                result.BodyWidth = 8.6 + 0.30 * pulse;
            }
            else if (value == HaloState.Error)
            {
                double pulse = ErrorPulse(localTime, errorPresentation);
                result.Powered = errorPresentation == ErrorPresentation.Bright
                    ? 1.0 : errorPresentation == ErrorPresentation.Dim ? 0 : pulse;
                result.Breath = errorPresentation == ErrorPresentation.Dim ? 0.10 : pulse;
                result.Intensity = errorPresentation == ErrorPresentation.Dim
                    ? 0.52 : 0.62 + 0.12 * pulse;
                result.BodyWidth = 8.6 + 0.25 * pulse;
            }
            return result;
        }

        private static VisualSnapshot TransitionVisual(VisualSnapshot from,
            VisualSnapshot to, double progress)
        {
            VisualSnapshot result = new VisualSnapshot();
            double scalarProgress = SmootherStep(Clamp((progress - 0.34) / 0.66, 0, 1));
            result.Color = to.Color;
            result.Powered = TransitionLight(from.Powered, to.Powered, progress);
            result.Breath = Lerp(from.Breath, to.Breath, scalarProgress);
            result.Intensity = Lerp(from.Intensity, to.Intensity, scalarProgress);
            result.BodyWidth = Lerp(from.BodyWidth, to.BodyWidth, scalarProgress);
            result.CoreWhite = Lerp(from.CoreWhite, to.CoreWhite, scalarProgress);
            result.GlowGain = Lerp(from.GlowGain, to.GlowGain, scalarProgress);
            return result;
        }

        private static double TargetPowered(HaloState value, double localTime)
        {
            SharedStateParameters parameters = GeneratedHaloSpec.State(value);
            if (parameters.PoweredMaximum > 0)
            {
                return LivingBreath(localTime, parameters.BreathPeriod,
                    parameters.PoweredMaximum, parameters.PoweredMinimum,
                    parameters.BrightShare);
            }
            return 0;
        }

        private static double CoreWhiteFor(HaloState value)
        {
            return GeneratedHaloSpec.State(value).CoreWhite;
        }

        private static double GlowGainFor(HaloState value)
        {
            return GeneratedHaloSpec.State(value).GlowGain;
        }

        private static StreamGeometry[] CreateDynamicRingGeometry(MediaPoint center,
            double radius, double gapA, double gapB)
        {
            // The visible clearances account for the thick rounded arc caps.
            // Both remain unmistakable at 112 px while retaining unequal sizes.
            const double gapASize = 30;
            const double gapBSize = 22;
            double aEnd = gapA + gapASize / 2;
            double bStart = gapB - gapBSize / 2;
            double bEnd = gapB + gapBSize / 2;
            double aStart = gapA - gapASize / 2;
            return new StreamGeometry[]
            {
                CreateArcGeometry(center, radius, aEnd,
                    PositiveModulo(bStart - aEnd, 360)),
                CreateArcGeometry(center, radius, bEnd,
                    PositiveModulo(aStart - bEnd, 360))
            };
        }

        private static StreamGeometry CreateArcGeometry(MediaPoint center,
            double radius, double startDegrees, double sweepDegrees)
        {
            StreamGeometry geometry = new StreamGeometry();
            using (StreamGeometryContext context = geometry.Open())
            {
                AddArcFigure(context, center, radius, startDegrees,
                    sweepDegrees);
            }
            geometry.Freeze();
            return geometry;
        }

        private static void AddArcFigure(StreamGeometryContext context,
            MediaPoint center, double radius, double startDegrees,
            double sweepDegrees)
        {
            if (sweepDegrees <= 0.001)
            {
                return;
            }
            MediaPoint start = PointOnCircle(center, radius, startDegrees);
            MediaPoint end = PointOnCircle(center, radius,
                startDegrees + sweepDegrees);
            context.BeginFigure(start, false, false);
            context.ArcTo(end, new System.Windows.Size(radius, radius), 0,
                sweepDegrees > 180, SweepDirection.Clockwise, true, false);
        }

        private static void DrawDynamicRing(DrawingContext dc,
            StreamGeometry[] geometry, MediaPen pen)
        {
            for (int i = 0; i < geometry.Length; i++)
            {
                dc.DrawGeometry(null, pen, geometry[i]);
            }
        }

        private void AdvanceAnimation(double delta, double now)
        {
            double targetOrbitVelocity = TargetGapVelocityA(state) *
                GapVelocityEnvelopeA(state, now);
            outerVelocity = Damp(outerVelocity, targetOrbitVelocity, delta, 2.1);
            energy = Damp(energy, TargetEnergy(state), delta, 4.2);
            outerPhase += outerVelocity * delta;

            if (gapRepelling)
            {
                gapRepulsionElapsed += delta;
                double progress = Clamp(gapRepulsionElapsed /
                    Math.Max(0.01, gapRepulsionDuration), 0, 1);
                gapSeparation = Lerp(gapRepulsionStart,
                    GeneratedHaloSpec.MaximumGapSeparation,
                    MagneticRepulsionEase(progress));
                innerPhase = outerPhase + gapSeparation;
                if (progress >= 1)
                {
                    gapRepelling = false;
                    gapSeparation = GeneratedHaloSpec.MaximumGapSeparation;
                    innerPhase = outerPhase + gapSeparation;
                    smallGapAnchor = innerPhase;
                    smallGapDriftElapsed = 0;
                    smallGapInertiaOffset = 0;
                    smallGapInertiaVelocity =
                        RepulsionExitVelocityFromOrbit(outerVelocity);
                }
            }
            else
            {
                smallGapDriftElapsed += delta;
                smallGapInertiaVelocity *= Math.Exp(
                    -SmallGapInertiaDamping(state) * delta);
                smallGapInertiaOffset += smallGapInertiaVelocity * delta;
                innerPhase = smallGapAnchor +
                    smallGapInertiaOffset +
                    SmallGapDriftOffset(state, smallGapDriftElapsed,
                        gapRepulsionCount);
                gapSeparation = PositiveModulo(innerPhase - outerPhase, 360);
                if (gapSeparation <= 41.5 || gapSeparation > 300)
                {
                    gapSeparation = GeneratedHaloSpec.MinimumGapSeparation;
                    innerPhase = outerPhase + gapSeparation;
                    gapRepelling = true;
                    gapRepulsionElapsed = 0;
                    gapRepulsionStart = gapSeparation;
                    gapRepulsionDuration =
                        RepulsionDurationFromOrbit(outerVelocity);
                    gapRepulsionCount++;
                    smallGapInertiaOffset = 0;
                    smallGapInertiaVelocity = 0;
                }
            }

            if (outerPhase > 36000)
            {
                outerPhase -= 36000;
                innerPhase -= 36000;
            }
        }

        private void DrawAmbientAura(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double sinceState, double transition)
        {
            double breath = StateBreath(state, t);
            double transitionFlash = Math.Sin(Math.PI * transition);
            double intensity = Clamp(displayEnergy * (0.72 + breath * 0.28) +
                transitionFlash * 0.17, 0, 1.4);

            RadialGradientBrush atmosphere = new RadialGradientBrush();
            atmosphere.Center = new MediaPoint(0.5, 0.5);
            atmosphere.GradientOrigin = new MediaPoint(0.5, 0.5);
            atmosphere.RadiusX = atmosphere.RadiusY = 0.5;
            atmosphere.GradientStops.Add(new GradientStop(
                WithAlpha(color, Alpha(16 * intensity)), 0));
            atmosphere.GradientStops.Add(new GradientStop(
                WithAlpha(color, Alpha(10 * intensity)), 0.42));
            atmosphere.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
            dc.DrawEllipse(atmosphere, null, center, 55, 55);

            MediaPen outerGlow = NewPen(WithAlpha(color, Alpha(12 * intensity)), 13);
            MediaPen middleGlow = NewPen(WithAlpha(color, Alpha(20 * intensity)), 7);
            DrawPrecisionSegments(dc, center, 40.2, 0, outerGlow, 1);
            DrawPrecisionSegments(dc, center, 40.2, 0, middleGlow, 1);

            if (state == HaloState.Done && sinceState < 1.8)
            {
                double progress = Clamp(sinceState / 1.8, 0, 1);
                double eased = EaseOutQuint(progress);
                double radius = 40.5 + eased * 18;
                byte alpha = Alpha(82 * Math.Pow(1 - progress, 2.2));
                dc.DrawEllipse(null, NewPen(WithAlpha(color, alpha),
                    0.8 + (1 - progress) * 0.8), center, radius, radius);
            }
        }

        private void DrawMechanicalBase(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t)
        {
            dc.DrawEllipse(null, NewPen(MediaColor.FromArgb(50, 104, 128, 145), 0.55),
                center, 45.4, 45.4);
            dc.DrawEllipse(null, NewPen(MediaColor.FromArgb(35, 94, 118, 134), 0.55),
                center, 35.5, 35.5);

            for (int i = 0; i < 12; i++)
            {
                double angle = -90 + i * 30;
                double length = i % 3 == 0 ? 2.2 : 1.15;
                DrawArc(dc, center, 45.4, angle - length / 2, length,
                    NewPen(MediaColor.FromArgb(i % 3 == 0 ? (byte)66 : (byte)36,
                        132, 155, 170), 0.8));
            }

            RadialGradientBrush glass = new RadialGradientBrush();
            glass.GradientOrigin = new MediaPoint(0.37, 0.31);
            glass.Center = new MediaPoint(0.5, 0.5);
            glass.RadiusX = glass.RadiusY = 0.58;
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(232, 28, 36, 46), 0));
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(247, 8, 13, 19), 0.68));
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(252, 2, 5, 9), 1));
            dc.DrawEllipse(glass, NewPen(MediaColor.FromArgb(92, 113, 139, 157), 0.65),
                center, 28.2, 28.2);

            RadialGradientBrush innerEmission = new RadialGradientBrush();
            innerEmission.GradientOrigin = new MediaPoint(0.44, 0.4);
            innerEmission.GradientStops.Add(new GradientStop(WithAlpha(color,
                Alpha(24 * displayEnergy)), 0));
            innerEmission.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
            dc.DrawEllipse(innerEmission, null, center, 23.5, 23.5);

            System.Windows.Media.LinearGradientBrush lens =
                new System.Windows.Media.LinearGradientBrush(
                MediaColor.FromArgb(42, 255, 255, 255),
                MediaColor.FromArgb(0, 255, 255, 255), 22);
            dc.DrawEllipse(lens, null, new MediaPoint(center.X - 7.2, center.Y - 8.4),
                7.8, 2.35);

            DrawArc(dc, center, 30.7, 202, 72,
                NewPen(MediaColor.FromArgb(34, 161, 183, 197), 0.6));
            DrawArc(dc, center, 30.7, 292, 34,
                NewPen(WithAlpha(color, Alpha(42 * displayEnergy)), 0.65));
        }

        private void DrawPrimaryRing(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double transition)
        {
            double breath = StateBreath(state, t);
            double intensity = Clamp(0.35 + displayEnergy * 0.58 + breath * 0.12, 0, 1.2);
            double microDrift = 0.65 * Math.Sin(t * 0.54) +
                0.24 * Math.Sin(t * 1.31);

            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(MediaColor.FromArgb(118, 26, 35, 43), 3.6), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(15 * intensity)), 9.5), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(34 * intensity)), 4.8), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(208 * intensity)), 2.05), 1);
            DrawPrecisionSegments(dc, center, 39.85, microDrift,
                NewPen(WithAlpha(MixColor(color, MediaColor.FromRgb(239, 251, 255), 0.42),
                    Alpha(132 * intensity)), 0.62), 1);

            if (transition < 0.999)
            {
                double wave = EaseInOutCubic(transition);
                double angle = -92 + wave * 360;
                DrawEnergyPacket(dc, center,
                    MixColor(color, MediaColor.FromRgb(245, 253, 255), 0.72),
                    angle, 40.2, 22, 0.75 + Math.Sin(Math.PI * transition) * 0.25);
            }
        }

        private void DrawStateLayer(DrawingContext dc, MediaPoint center, HaloState layerState,
            MediaColor color, double outer, double inner, double t, double sinceState,
            double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            if (opacity < 0.004)
            {
                return;
            }

            if (layerState == HaloState.Idle)
            {
                double angle = outer + 24 * SoftWave(t / 7.2);
                DrawArc(dc, center, 40.2, angle, 30,
                    NewPen(WithAlpha(color, Alpha(80 * opacity)), 1.15));
                return;
            }

            if (layerState == HaloState.Thinking)
            {
                double thinkingPhase = outer + 13 * Math.Sin(t * 1.07) +
                    4.5 * Math.Sin(t * 2.41);
                DrawEnergyPacket(dc, center, color, thinkingPhase, 40.2, 25,
                    opacity * (0.72 + 0.28 * SoftWave(t / 2.25)));
                DrawEnergyPacket(dc, center, color, thinkingPhase + 156, 40.2, 12,
                    opacity * 0.48);
                DrawArc(dc, center, 33.3, inner + 14, 58,
                    NewPen(WithAlpha(color, Alpha(72 * opacity)), 0.9));
                for (int i = 0; i < 3; i++)
                {
                    double nodePulse = SoftWave(t / 1.65 + i * 0.21);
                    double angle = inner * 0.46 + i * 120 + 9 * Math.Sin(t * 0.8 + i);
                    MediaPoint point = PointOnCircle(center, 33.3, angle);
                    double size = 0.85 + nodePulse * 0.7;
                    dc.DrawEllipse(new SolidColorBrush(WithAlpha(color,
                        Alpha((90 + nodePulse * 130) * opacity))), null,
                        point, size, size);
                }
                return;
            }

            if (layerState == HaloState.Working)
            {
                double drive = 0.8 + 0.2 * SoftWave(t / 0.86);
                DrawEnergyPacket(dc, center, color, outer + 10, 40.2, 39,
                    opacity * drive);
                DrawEnergyPacket(dc, center,
                    MixColor(color, MediaColor.FromRgb(235, 252, 255), 0.55),
                    outer + 184, 40.2, 17, opacity * 0.58);
                for (int i = 0; i < 14; i++)
                {
                    double alpha = 28 + 82 * Math.Pow((i + 1) / 14.0, 1.8);
                    DrawArc(dc, center, 33.3, inner + i * 25.7,
                        i % 2 == 0 ? 10 : 6,
                        NewPen(WithAlpha(color, Alpha(alpha * opacity)), 0.85));
                }
                DrawEnergyPacket(dc, center, color, inner + 72, 33.3, 20,
                    opacity * 0.72);
                return;
            }

            if (layerState == HaloState.Done)
            {
                double arrival = EaseOutBack(Clamp(sinceState / 0.92, 0, 1));
                dc.DrawEllipse(null, NewPen(WithAlpha(color,
                    Alpha(105 * opacity * arrival)), 0.8), center,
                    34.8 + arrival * 1.2, 34.8 + arrival * 1.2);
                DrawArc(dc, center, 33.3, -90, 360 * Clamp(arrival, 0, 1),
                    NewPen(WithAlpha(color, Alpha(88 * opacity)), 0.85));
                return;
            }

            if (layerState == HaloState.Attention)
            {
                double pulse = DoublePulse(t, 1.34);
                double radius = 34.8 + EaseOutCubic(pulse) * 3.5;
                DrawArc(dc, center, radius, -68, 52,
                    NewPen(WithAlpha(color, Alpha((58 + pulse * 152) * opacity)), 1.25));
                DrawArc(dc, center, radius, 112, 52,
                    NewPen(WithAlpha(color, Alpha((58 + pulse * 152) * opacity)), 1.25));
                if (pulse > 0.08)
                {
                    dc.DrawEllipse(null, NewPen(WithAlpha(color,
                        Alpha(42 * pulse * opacity)), 0.7), center,
                        31 + pulse * 10, 31 + pulse * 10);
                }
                return;
            }

            double tremor = 1.6 * Math.Sin(t * 13.1) + 0.8 * Math.Sin(t * 23.7);
            double errorPulse = 0.45 + 0.55 * DoublePulse(t, 1.08);
            double[] starts = new double[] { -82, -8, 61, 135, 218 };
            double[] lengths = new double[] { 42, 27, 49, 34, 31 };
            for (int i = 0; i < starts.Length; i++)
            {
                DrawArc(dc, center, 35.3 + (i % 2) * 0.7,
                    starts[i] + tremor * (i % 2 == 0 ? 1 : -1), lengths[i],
                    NewPen(WithAlpha(color,
                        Alpha((72 + errorPulse * 112) * opacity)), 1.2));
            }
        }

        private void DrawCenter(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double sinceState, double transition)
        {
            double coreBreath = 0.65 + 0.35 * StateBreath(state, t);
            dc.DrawEllipse(null, NewPen(WithAlpha(color,
                Alpha(42 * displayEnergy)), 0.65), center, 9.2, 9.2);

            DrawGlyph(dc, center, previousState, transitionFromColor, t, sinceState,
                1 - transition);
            DrawGlyph(dc, center, state, color, t, sinceState, transition);

            double genericCoreOpacity =
                (UsesGenericCore(previousState) ? 1 - transition : 0) +
                (UsesGenericCore(state) ? transition : 0);
            if (genericCoreOpacity > 0.01)
            {
                double radius = 2.0 + 1.05 * coreBreath;
                RadialGradientBrush core = new RadialGradientBrush();
                core.GradientStops.Add(new GradientStop(
                    MediaColor.FromArgb(Alpha(235 * genericCoreOpacity),
                        245, 253, 255), 0));
                core.GradientStops.Add(new GradientStop(
                    WithAlpha(color, Alpha(205 * displayEnergy *
                        genericCoreOpacity)), 0.4));
                core.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
                dc.DrawEllipse(core, null, center, radius + 1.6, radius + 1.6);
            }
        }

        private static void DrawGlyph(DrawingContext dc, MediaPoint center, HaloState glyphState,
            MediaColor color, double t, double sinceState, double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            if (opacity < 0.01)
            {
                return;
            }

            if (glyphState == HaloState.Done)
            {
                double reveal = EaseOutBack(Clamp(sinceState / 0.72, 0, 1));
                double scale = 0.72 + 0.28 * reveal;
                dc.PushTransform(new ScaleTransform(scale, scale, center.X, center.Y));
                StreamGeometry check = new StreamGeometry();
                using (StreamGeometryContext context = check.Open())
                {
                    context.BeginFigure(new MediaPoint(center.X - 7.3, center.Y + 0.2),
                        false, false);
                    context.LineTo(new MediaPoint(center.X - 2.1, center.Y + 5.3),
                        true, false);
                    context.LineTo(new MediaPoint(center.X + 8.2, center.Y - 7.2),
                        true, false);
                }
                MediaPen checkPen = NewPen(WithAlpha(color,
                    Alpha(228 * opacity * reveal)), 2.15);
                checkPen.LineJoin = PenLineJoin.Round;
                dc.DrawGeometry(null, checkPen, check);
                dc.Pop();
                return;
            }

            if (glyphState == HaloState.Attention || glyphState == HaloState.Error)
            {
                double pulse = glyphState == HaloState.Error
                    ? DoublePulse(t, 1.08) : DoublePulse(t, 1.34);
                SolidColorBrush brush = new SolidColorBrush(WithAlpha(color,
                    Alpha((172 + 60 * pulse) * opacity)));
                dc.DrawRoundedRectangle(brush, null,
                    new Rect(center.X - 1.05, center.Y - 7.2, 2.1, 9.3), 1.1, 1.1);
                dc.DrawEllipse(brush, null, new MediaPoint(center.X, center.Y + 6),
                    1.25, 1.25);
                return;
            }

            if (glyphState == HaloState.Working)
            {
                StreamGeometry diamond = new StreamGeometry();
                using (StreamGeometryContext context = diamond.Open())
                {
                    context.BeginFigure(new MediaPoint(center.X, center.Y - 5.1), false, true);
                    context.LineTo(new MediaPoint(center.X + 5.1, center.Y), true, false);
                    context.LineTo(new MediaPoint(center.X, center.Y + 5.1), true, false);
                    context.LineTo(new MediaPoint(center.X - 5.1, center.Y), true, false);
                }
                dc.DrawGeometry(null, NewPen(WithAlpha(color,
                    Alpha(82 * opacity)), 0.75), diamond);
            }
            else if (glyphState == HaloState.Thinking)
            {
                DrawArc(dc, center, 6.2, 28 + 8 * Math.Sin(t * 0.9), 224,
                    NewPen(WithAlpha(color, Alpha(78 * opacity)), 0.75));
            }
            else
            {
                dc.DrawEllipse(null, NewPen(WithAlpha(color,
                    Alpha(52 * opacity)), 0.65), center, 6.4, 6.4);
            }
        }

        private static void DrawPrecisionSegments(DrawingContext dc, MediaPoint center,
            double radius, double rotation, MediaPen pen, double opacity)
        {
            double[] starts = new double[] { -88, 32, 152 };
            for (int i = 0; i < starts.Length; i++)
            {
                DrawArc(dc, center, radius, starts[i] + rotation, 112, pen);
            }
        }

        private static void DrawEnergyPacket(DrawingContext dc, MediaPoint center,
            MediaColor color, double angle, double radius, double tailLength, double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            const int pieces = 12;
            for (int i = 0; i < pieces; i++)
            {
                double normalized = (i + 1) / (double)pieces;
                double eased = Math.Pow(normalized, 2.35);
                double segmentAngle = angle - tailLength + normalized * tailLength;
                double alpha = 8 + eased * 184;
                DrawArc(dc, center, radius, segmentAngle, Math.Max(1.1,
                    tailLength / pieces * 0.72),
                    NewPen(WithAlpha(color, Alpha(alpha * opacity)),
                        1.15 + eased * 1.35));
            }
            MediaPoint point = PointOnCircle(center, radius, angle);
            dc.DrawEllipse(new SolidColorBrush(WithAlpha(
                MixColor(color, MediaColor.FromRgb(247, 253, 255), 0.72),
                Alpha(232 * opacity))), null, point, 1.55, 1.55);
        }

        private void DrawCount(DrawingContext dc, MediaPoint center, int value)
        {
            MediaPoint badge = new MediaPoint(center.X + 35, center.Y - 31);
            dc.DrawEllipse(new SolidColorBrush(MediaColor.FromArgb(246, 10, 14, 19)),
                NewPen(MediaColor.FromArgb(160, 121, 147, 166), 0.8), badge, 9, 9);
            string text = value > 9 ? "9+" : value.ToString(CultureInfo.InvariantCulture);
            FormattedText formatted = new FormattedText(text, CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"), 9.5,
                System.Windows.Media.Brushes.White, 1.0);
            dc.DrawText(formatted, new MediaPoint(badge.X - formatted.Width / 2,
                badge.Y - formatted.Height / 2 - 0.5));
        }

        private static void DrawArc(DrawingContext dc, MediaPoint center, double radius,
            double startDegrees, double sweepDegrees, MediaPen pen)
        {
            if (sweepDegrees <= 0.001)
            {
                return;
            }
            if (sweepDegrees >= 359.999)
            {
                dc.DrawEllipse(null, pen, center, radius, radius);
                return;
            }
            MediaPoint start = PointOnCircle(center, radius, startDegrees);
            MediaPoint end = PointOnCircle(center, radius, startDegrees + sweepDegrees);
            StreamGeometry geometry = new StreamGeometry();
            using (StreamGeometryContext context = geometry.Open())
            {
                context.BeginFigure(start, false, false);
                context.ArcTo(end, new System.Windows.Size(radius, radius), 0,
                    sweepDegrees > 180, SweepDirection.Clockwise, true, false);
            }
            geometry.Freeze();
            dc.DrawGeometry(null, pen, geometry);
        }

        private static MediaPoint PointOnCircle(MediaPoint center, double radius, double degrees)
        {
            double radians = degrees * Math.PI / 180.0;
            return new MediaPoint(center.X + Math.Cos(radians) * radius,
                center.Y + Math.Sin(radians) * radius);
        }

        private static MediaPen NewPen(MediaColor color, double width)
        {
            MediaPen pen = new MediaPen(new SolidColorBrush(color), width);
            pen.StartLineCap = PenLineCap.Round;
            pen.EndLineCap = PenLineCap.Round;
            return pen;
        }

        private MediaColor AnimatedColor(double time)
        {
            double progress = TransitionProgress(time);
            double colorProgress = SmootherStep(Clamp((progress - 0.18) / 0.56, 0, 1));
            return MixColor(transitionFromColor, StateColor(state), colorProgress);
        }

        private static double TransitionScalar(double from, double to, double progress)
        {
            double blend = SmootherStep(Clamp((progress - 0.42) / 0.58, 0, 1));
            return Lerp(from, to, blend);
        }

        private static double TransitionLight(double from, double to, double progress)
        {
            double low = GeneratedHaloSpec.TransitionLowPowered;
            if (progress < GeneratedHaloSpec.TransitionDimEnd)
            {
                return Lerp(from, Math.Min(from, low),
                    SmootherStep(progress / GeneratedHaloSpec.TransitionDimEnd));
            }
            if (progress < GeneratedHaloSpec.TransitionColorBlendEnd)
            {
                return Math.Min(from, low);
            }
            return Lerp(Math.Min(from, low), to,
                SmootherStep((progress - GeneratedHaloSpec.TransitionColorBlendEnd) /
                    (1 - GeneratedHaloSpec.TransitionColorBlendEnd)));
        }

        private double TransitionProgress(double time)
        {
            if (transitionDuration <= 0)
            {
                return 1;
            }
            return SmootherStep(Clamp((time - transitionStartSeconds) /
                transitionDuration, 0, 1));
        }

        private static double TransitionDuration(HaloState from, HaloState to)
        {
            return GeneratedHaloSpec.TransitionDuration(to);
        }

        private static double TargetGapVelocityA(HaloState value)
        {
            return GeneratedHaloSpec.State(value).OrbitVelocity;
        }

        private static double RepulsionDurationFromOrbit(double orbitVelocity)
        {
            double speed = Clamp(Math.Abs(orbitVelocity),
                GeneratedHaloSpec.RepulsionSpeedMinimum,
                GeneratedHaloSpec.RepulsionSpeedMaximum);
            return Clamp(GeneratedHaloSpec.RepulsionDurationFactor *
                Math.Sqrt(GeneratedHaloSpec.RepulsionReferenceSpeed / speed),
                GeneratedHaloSpec.RepulsionDurationMinimum,
                GeneratedHaloSpec.RepulsionDurationMaximum);
        }

        private static double SmallGapDriftOffset(HaloState value, double time,
            int cycle)
        {
            SharedStateParameters parameters = GeneratedHaloSpec.State(value);
            double amplitude = parameters.DriftAmplitude;
            double period = parameters.DriftPeriod;
            double direction = cycle % 2 == 0 ? 1 : -1;
            double primary = Math.Sin(time * Math.PI * 2 / period);
            double secondary = 0.22 * (Math.Sin(time * Math.PI * 2 /
                (period * 0.43) + 0.8) - Math.Sin(0.8));
            return direction * amplitude * (primary + secondary);
        }

        private static double RepulsionExitVelocityFromOrbit(double orbitVelocity)
        {
            return Clamp(Math.Abs(orbitVelocity) * GeneratedHaloSpec.ExitVelocityScale,
                GeneratedHaloSpec.ExitVelocityMinimum,
                GeneratedHaloSpec.ExitVelocityMaximum);
        }

        private static double SmallGapInertiaDamping(HaloState value)
        {
            return GeneratedHaloSpec.State(value).InertiaDamping;
        }

        private static double MagneticRepulsionEase(double value)
        {
            value = Clamp(value, 0, 1);
            double smoothPush = SmootherStep(value);
            double magneticBias = Math.Sin(value * Math.PI) * 0.055;
            return Clamp(smoothPush + magneticBias, 0, 1);
        }

        private static double GapVelocityEnvelopeA(HaloState value, double time)
        {
            double period = GeneratedHaloSpec.State(value).EnvelopePeriod;
            double primary = SoftWave(time / period);
            double secondary = SoftWave(time / (period * 0.47) + 0.29);
            return 0.18 + 0.92 * Math.Pow(primary, 1.65) + 0.22 * secondary;
        }

        private static void TestGapPhases(HaloState from, HaloState to,
            double time, double transition, out double gapA, out double gapB)
        {
            double velocity = Lerp(TargetGapVelocityA(from),
                TargetGapVelocityA(to), transition);
            double cycleDuration = Lerp(CatchCycleDuration(from),
                CatchCycleDuration(to), transition);
            double cycle = PositiveModulo(time, cycleDuration);
            double cycleStart = time - cycle;
            gapA = TestOrbitPhase(velocity, time);
            double cycleStartA = TestOrbitPhase(velocity, cycleStart);
            double representativeOrbitVelocity = velocity * 0.72;
            double repelDuration =
                RepulsionDurationFromOrbit(representativeOrbitVelocity);
            double repelStart = cycleDuration - repelDuration;
            if (cycle < repelStart)
            {
                HaloState dominant = transition >= 0.5 ? to : from;
                double inertiaVelocity =
                    RepulsionExitVelocityFromOrbit(representativeOrbitVelocity);
                double damping = Lerp(SmallGapInertiaDamping(from),
                    SmallGapInertiaDamping(to), transition);
                double inertiaOffset = inertiaVelocity / damping *
                    (1 - Math.Exp(-damping * cycle));
                double drift = SmallGapDriftOffset(dominant, cycle,
                    (int)Math.Floor(time / cycleDuration));
                gapB = cycleStartA + GeneratedHaloSpec.MaximumGapSeparation +
                    inertiaOffset + drift;
            }
            else
            {
                double repelProgress = (cycle - repelStart) / repelDuration;
                double separation = Lerp(GeneratedHaloSpec.MinimumGapSeparation,
                    GeneratedHaloSpec.MaximumGapSeparation,
                    MagneticRepulsionEase(repelProgress));
                gapB = gapA + separation;
            }
        }

        private static double TestOrbitPhase(double velocity, double time)
        {
            return 97 + velocity * time *
                (0.76 + 0.18 * Math.Sin(time * 0.62)) +
                5 * Math.Sin(time * 0.31);
        }

        private static double CatchCycleDuration(HaloState value)
        {
            switch (value)
            {
                case HaloState.Working: return 2.65;
                case HaloState.Thinking: return 3.8;
                case HaloState.Error: return 3.3;
                case HaloState.Attention: return 4.0;
                case HaloState.Done: return 5.4;
                default: return 5.8;
            }
        }

        public static double DiagnosticGapSeparation(double phase)
        {
            return Lerp(GeneratedHaloSpec.MinimumGapSeparation,
                GeneratedHaloSpec.MaximumGapSeparation,
                MagneticRepulsionEase(Clamp(phase, 0, 1)));
        }

        public static double DiagnosticRepulsionDuration(double orbitVelocity)
        {
            return RepulsionDurationFromOrbit(orbitVelocity);
        }

        public static double DiagnosticBreath(HaloState value, double time)
        {
            return StateBreath(value, time);
        }

        public static double DiagnosticPowered(HaloState value, double time)
        {
            return TargetPowered(value, time);
        }

        public static double DiagnosticAttentionPulse(double time)
        {
            return AttentionPulse(time);
        }

        public static double DiagnosticBrightDuration(HaloState value)
        {
            SharedStateParameters parameters = GeneratedHaloSpec.State(value);
            return parameters.PoweredMaximum > 0
                ? parameters.BreathPeriod * parameters.BrightShare : 0;
        }

        public static double DiagnosticCoreWhite(HaloState value)
        {
            return CoreWhiteFor(value);
        }

        public static double DiagnosticTransitionLight(double from, double to,
            double progress)
        {
            return TransitionLight(from, to, SmootherStep(progress));
        }

        private static double CompletionDoubleFlash(double sinceState)
        {
            double first = Math.Exp(-Math.Pow((sinceState - 0.28) / 0.14, 2));
            double second = Math.Exp(-Math.Pow((sinceState - 0.92) / 0.18, 2));
            return Clamp(first + second * 0.90, 0, 1);
        }

        private static double TargetEnergy(HaloState value)
        {
            switch (value)
            {
                case HaloState.Thinking: return 0.86;
                case HaloState.Working: return 1.0;
                case HaloState.Done: return 0.68;
                case HaloState.Attention: return 0.98;
                case HaloState.Error: return 1.0;
                default: return 0.34;
            }
        }

        private static double StateBreath(HaloState value, double time)
        {
            if (value == HaloState.Attention)
            {
                return 0.18 + 0.82 * AttentionPulse(time);
            }
            if (value == HaloState.Error)
            {
                return ErrorPulse(time, ErrorPresentation.Flashing);
            }
            SharedStateParameters parameters = GeneratedHaloSpec.State(value);
            if (value == HaloState.Idle)
            {
                return parameters.VisualMinimum +
                    (parameters.VisualMaximum - parameters.VisualMinimum) *
                    SoftWave(time / parameters.BreathPeriod);
            }
            return LivingBreath(time, parameters.BreathPeriod,
                parameters.VisualMaximum, parameters.VisualMinimum,
                parameters.BrightShare);
        }

        private static bool UsesGenericCore(HaloState value)
        {
            return value == HaloState.Idle || value == HaloState.Thinking ||
                value == HaloState.Working;
        }

        public static MediaColor StateColor(HaloState state)
        {
            SharedStateParameters parameters = GeneratedHaloSpec.State(state);
            if (state == HaloState.Working)
            {
                // Windows keeps execution blue as saturated as the completed green.
                return MediaColor.FromRgb(39, 161, 211);
            }
            return MediaColor.FromRgb(parameters.Red, parameters.Green, parameters.Blue);
        }

        private static MediaColor WithAlpha(MediaColor color, byte alpha)
        {
            return MediaColor.FromArgb(alpha, color.R, color.G, color.B);
        }

        private static MediaColor MixColor(MediaColor from, MediaColor to, double amount)
        {
            amount = Clamp(amount, 0, 1);
            double r = LinearToSrgb(Lerp(SrgbToLinear(from.R / 255.0),
                SrgbToLinear(to.R / 255.0), amount));
            double g = LinearToSrgb(Lerp(SrgbToLinear(from.G / 255.0),
                SrgbToLinear(to.G / 255.0), amount));
            double b = LinearToSrgb(Lerp(SrgbToLinear(from.B / 255.0),
                SrgbToLinear(to.B / 255.0), amount));
            return MediaColor.FromRgb(Alpha(r * 255), Alpha(g * 255), Alpha(b * 255));
        }

        private static MediaColor AdjustSaturation(MediaColor color, double multiplier)
        {
            double hue;
            double saturation;
            double lightness;
            RgbToHsl(color, out hue, out saturation, out lightness);
            return HslToRgb(hue, Clamp(saturation * multiplier, 0, 1), lightness);
        }

        private static MediaColor MixEmissionColor(MediaColor from, MediaColor to,
            double amount)
        {
            amount = Clamp(amount, 0, 1);
            double fromHue;
            double fromSaturation;
            double fromLightness;
            double toHue;
            double toSaturation;
            double toLightness;
            RgbToHsl(from, out fromHue, out fromSaturation, out fromLightness);
            RgbToHsl(to, out toHue, out toSaturation, out toLightness);

            if (fromSaturation < 0.04)
            {
                fromHue = toHue;
            }
            if (toSaturation < 0.04)
            {
                toHue = fromHue;
            }
            double hueDelta = toHue - fromHue;
            if (hueDelta > 180)
            {
                hueDelta -= 360;
            }
            else if (hueDelta < -180)
            {
                hueDelta += 360;
            }

            if (Math.Abs(hueDelta) > 100)
            {
                MediaColor bridge = MediaColor.FromRgb(218, 241, 248);
                if (amount < 0.5)
                {
                    return MixColor(from, bridge,
                        EaseInOutCubic(amount * 2));
                }
                return MixColor(bridge, to,
                    EaseInOutCubic((amount - 0.5) * 2));
            }

            double hue = PositiveModulo(fromHue + hueDelta * amount, 360);
            double saturation = Lerp(fromSaturation, toSaturation, amount);
            double lightness = Lerp(fromLightness, toLightness, amount);
            return HslToRgb(hue, saturation, lightness);
        }

        private static void RgbToHsl(MediaColor color, out double hue,
            out double saturation, out double lightness)
        {
            double r = color.R / 255.0;
            double g = color.G / 255.0;
            double b = color.B / 255.0;
            double maximum = Math.Max(r, Math.Max(g, b));
            double minimum = Math.Min(r, Math.Min(g, b));
            double delta = maximum - minimum;
            lightness = (maximum + minimum) / 2;
            if (delta < 0.000001)
            {
                hue = 0;
                saturation = 0;
                return;
            }
            saturation = delta / (1 - Math.Abs(2 * lightness - 1));
            if (maximum == r)
            {
                hue = 60 * PositiveModulo((g - b) / delta, 6);
            }
            else if (maximum == g)
            {
                hue = 60 * (((b - r) / delta) + 2);
            }
            else
            {
                hue = 60 * (((r - g) / delta) + 4);
            }
        }

        private static MediaColor HslToRgb(double hue, double saturation,
            double lightness)
        {
            double chroma = (1 - Math.Abs(2 * lightness - 1)) * saturation;
            double segment = hue / 60;
            double x = chroma * (1 - Math.Abs(PositiveModulo(segment, 2) - 1));
            double r1 = 0;
            double g1 = 0;
            double b1 = 0;
            if (segment < 1)
            {
                r1 = chroma; g1 = x;
            }
            else if (segment < 2)
            {
                r1 = x; g1 = chroma;
            }
            else if (segment < 3)
            {
                g1 = chroma; b1 = x;
            }
            else if (segment < 4)
            {
                g1 = x; b1 = chroma;
            }
            else if (segment < 5)
            {
                r1 = x; b1 = chroma;
            }
            else
            {
                r1 = chroma; b1 = x;
            }
            double match = lightness - chroma / 2;
            return MediaColor.FromRgb(Alpha((r1 + match) * 255),
                Alpha((g1 + match) * 255), Alpha((b1 + match) * 255));
        }

        private static double SrgbToLinear(double value)
        {
            return value <= 0.04045 ? value / 12.92 :
                Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        private static double LinearToSrgb(double value)
        {
            value = Clamp(value, 0, 1);
            return value <= 0.0031308 ? value * 12.92 :
                1.055 * Math.Pow(value, 1.0 / 2.4) - 0.055;
        }

        private static double DoublePulse(double time, double period)
        {
            double cycle = PositiveModulo(time, period) / period;
            double first = Math.Exp(-Math.Pow((cycle - 0.13) / 0.055, 2));
            double second = Math.Exp(-Math.Pow((cycle - 0.31) / 0.07, 2));
            return Clamp(first + second * 0.82, 0, 1);
        }

        private static double AttentionPulse(double time)
        {
            double cycle = PositiveModulo(time, GeneratedHaloSpec.AttentionPeriod) /
                GeneratedHaloSpec.AttentionPeriod;
            double first = SmoothPulse(cycle, GeneratedHaloSpec.AttentionFirstCenter,
                GeneratedHaloSpec.AttentionFirstWidth) *
                GeneratedHaloSpec.AttentionFirstStrength;
            double second = SmoothPulse(cycle, GeneratedHaloSpec.AttentionSecondCenter,
                GeneratedHaloSpec.AttentionSecondWidth) *
                GeneratedHaloSpec.AttentionSecondStrength;
            double livingBase = GeneratedHaloSpec.AttentionLivingBase +
                GeneratedHaloSpec.AttentionLivingAmplitude *
                SoftWave(cycle + GeneratedHaloSpec.AttentionLivingPhase);
            return Clamp(livingBase + first + second, 0, 1);
        }

        private static double ErrorPulse(double time, ErrorPresentation presentation)
        {
            if (presentation == ErrorPresentation.Bright)
                return GeneratedHaloSpec.ErrorBrightPower;
            if (presentation == ErrorPresentation.Dim)
                return GeneratedHaloSpec.ErrorDimPower;
            double cycle = PositiveModulo(time, GeneratedHaloSpec.ErrorFlashPeriod);
            double first = Math.Exp(-Math.Pow(
                (cycle - GeneratedHaloSpec.ErrorFirstCenter) /
                GeneratedHaloSpec.ErrorFirstWidth, 2));
            double second = Math.Exp(-Math.Pow(
                (cycle - GeneratedHaloSpec.ErrorSecondCenter) /
                GeneratedHaloSpec.ErrorSecondWidth, 2));
            return Clamp(first + second, 0, 1);
        }

        private static double ThinkingBreath(double time)
        {
            return LivingBreath(time, 5.5, 1.0, 0.26, 0.70);
        }

        private static double LongBrightBreath(double time, double period)
        {
            return LivingBreath(time, period, 1, 0.16, 0.74);
        }

        private static double LivingBreath(double time, double period,
            double maximum, double minimum, double brightShare)
        {
            double phase = PositiveModulo(time, period) / period;
            double center = brightShare + (1 - brightShare) * 0.46;
            double distance = Math.Abs(phase - center);
            distance = Math.Min(distance, 1 - distance);
            double width = Math.Max(0.075, (1 - brightShare) * 0.46);
            double dip = Math.Exp(-Math.Pow(distance / width, 4));
            double micro = 0.018 * Math.Sin(phase * Math.PI * 2) +
                0.009 * Math.Sin(phase * Math.PI * 4 + 0.8);
            return Clamp(maximum - (maximum - minimum) * dip + micro,
                minimum, maximum);
        }

        private static double SmoothPulse(double phase, double center, double width)
        {
            double distance = Math.Abs(phase - center);
            distance = Math.Min(distance, 1 - distance);
            double normalized = Clamp(1 - distance / width, 0, 1);
            return SmootherStep(normalized);
        }

        private static double SoftWave(double phase)
        {
            double cycle = PositiveModulo(phase, 1);
            double triangle = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2;
            return SmootherStep(triangle);
        }

        private static double LampBreath(double time, double period)
        {
            double phase = PositiveModulo(time, period) / period;
            return 0.5 - 0.5 * Math.Cos(phase * Math.PI * 2);
        }

        private static double PositiveModulo(double value, double modulus)
        {
            double result = value % modulus;
            return result < 0 ? result + modulus : result;
        }

        private static double Damp(double current, double target, double delta, double response)
        {
            return target + (current - target) * Math.Exp(-response * delta);
        }

        private static double SmootherStep(double value)
        {
            value = Clamp(value, 0, 1);
            return value * value * value * (value * (value * 6 - 15) + 10);
        }

        private static double EaseInOutCubic(double value)
        {
            value = Clamp(value, 0, 1);
            return value < 0.5 ? 4 * value * value * value :
                1 - Math.Pow(-2 * value + 2, 3) / 2;
        }

        private static double EaseOutCubic(double value)
        {
            value = Clamp(value, 0, 1);
            return 1 - Math.Pow(1 - value, 3);
        }

        private static double EaseOutQuint(double value)
        {
            value = Clamp(value, 0, 1);
            return 1 - Math.Pow(1 - value, 5);
        }

        private static double EaseOutBack(double value)
        {
            value = Clamp(value, 0, 1);
            const double c1 = 1.70158;
            const double c3 = c1 + 1;
            return 1 + c3 * Math.Pow(value - 1, 3) +
                c1 * Math.Pow(value - 1, 2);
        }

        private static double Lerp(double from, double to, double amount)
        {
            return from + (to - from) * amount;
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            return Math.Max(minimum, Math.Min(maximum, value));
        }

        private static byte Alpha(double value)
        {
            return (byte)Math.Max(0, Math.Min(255, Math.Round(value)));
        }
    }
}

