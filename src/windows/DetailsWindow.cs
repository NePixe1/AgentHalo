using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
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
public sealed class RoundedMeter : FrameworkElement
    {
        public static readonly DependencyProperty ValueProperty =
            DependencyProperty.Register("Value", typeof(double), typeof(RoundedMeter),
                new FrameworkPropertyMetadata(0.0,
                    FrameworkPropertyMetadataOptions.AffectsRender));

        public double Value
        {
            get { return (double)GetValue(ValueProperty); }
            set { SetValue(ValueProperty, value); }
        }

        protected override System.Windows.Size MeasureOverride(
            System.Windows.Size availableSize)
        {
            return new System.Windows.Size(
                Double.IsInfinity(availableSize.Width) ? 100 : availableSize.Width, 4);
        }

        protected override void OnRender(DrawingContext drawingContext)
        {
            base.OnRender(drawingContext);
            double width = Math.Max(0, ActualWidth);
            double height = Math.Max(0, ActualHeight);
            double radius = height / 2;
            drawingContext.DrawRoundedRectangle(
                new SolidColorBrush(MediaColor.FromArgb(92, 184, 202, 211)), null,
                new Rect(0, 0, width, height), radius, radius);
            double fill = width * Math.Max(0, Math.Min(100, Value)) / 100.0;
            if (fill > 0)
            {
                drawingContext.DrawRoundedRectangle(
                    new SolidColorBrush(MediaColor.FromRgb(64, 105, 132)), null,
                    new Rect(0, 0, Math.Max(height, fill), height), radius, radius);
            }
        }
    }

public sealed class ContextBatteryMeter : FrameworkElement
    {
        public static readonly DependencyProperty ValueProperty =
            DependencyProperty.Register("Value", typeof(double),
                typeof(ContextBatteryMeter),
                new FrameworkPropertyMetadata(0.0,
                    FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty IsAvailableProperty =
            DependencyProperty.Register("IsAvailable", typeof(bool),
                typeof(ContextBatteryMeter),
                new FrameworkPropertyMetadata(false,
                    FrameworkPropertyMetadataOptions.AffectsRender));

        public double Value
        {
            get { return (double)GetValue(ValueProperty); }
            set { SetValue(ValueProperty, value); }
        }

        public bool IsAvailable
        {
            get { return (bool)GetValue(IsAvailableProperty); }
            set { SetValue(IsAvailableProperty, value); }
        }

        protected override System.Windows.Size MeasureOverride(
            System.Windows.Size availableSize)
        {
            return new System.Windows.Size(
                Double.IsInfinity(availableSize.Width) ? 46 : availableSize.Width,
                Double.IsInfinity(availableSize.Height) ? 24 : availableSize.Height);
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            double width = Math.Max(1, ActualWidth);
            double height = Math.Max(1, ActualHeight);
            double radius = Math.Min(8, height * 0.34);
            Rect rect = new Rect(0.5, 0.5, width - 1, height - 1);
            double value = Math.Max(0, Math.Min(100, Value));
            MediaColor fillColor = MediaColor.FromRgb(224, 240, 252);

            dc.DrawRoundedRectangle(new SolidColorBrush(fillColor),
                new MediaPen(new SolidColorBrush(
                    MediaColor.FromArgb(72, 174, 205, 224)), 1),
                rect, radius, radius);

            string text = IsAvailable
                ? Math.Min(99, (int)Math.Round(value)).ToString(
                    CultureInfo.InvariantCulture) + "%"
                : "--";
            double fontSize = 15.2;
            FormattedText formatted = new FormattedText(text,
                CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(new System.Windows.Media.FontFamily(
                    "Segoe UI Variable Display, Segoe UI"),
                    FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                fontSize, new SolidColorBrush(MediaColor.FromRgb(64, 105, 132)),
                VisualTreeHelper.GetDpi(this).PixelsPerDip);
            formatted.TextAlignment = TextAlignment.Center;
            dc.DrawText(formatted, new MediaPoint(width / 2,
                (height - formatted.Height) / 2 - 0.5));
        }
    }

public sealed class DetailsWindow : Window
    {
        private readonly TextBlock headline;
        private readonly TextBlock subtitle;
        private readonly Border shell;
        private readonly TextBlock fiveHourLabel;
        private readonly TextBlock fiveHourValue;
        private readonly TextBlock weekLabel;
        private readonly TextBlock weekValue;
        private readonly TextBlock fiveHourReset;
        private readonly TextBlock weekReset;
        private readonly Grid fiveHourRow;
        private readonly Grid weekRow;
        private readonly ContextBatteryMeter contextMeter;
        private readonly Border codexSwitch;
        private readonly Border claudeSwitch;
        private readonly Border grokSwitch;
        private readonly Border switchThumb;
        private readonly TranslateTransform switchThumbTransform;
        private readonly System.Windows.Shapes.Path codexSwitchIcon;
        private readonly Canvas claudeSwitchIcon;
        private readonly System.Windows.Shapes.Path grokSwitchIcon;
        private readonly StackPanel quotaGroup;
        private readonly Grid dataLayer;
        /// <summary>Fixed-height session body host (Scheme B). Mirrors macOS H_body ≈ 72.</summary>
        private readonly Grid sessionBodySlot;
        private readonly Border emptyBody;
        private readonly TextBlock emptyBodyText;
        private readonly Border sessionCard;
        private readonly TextBlock sessionCardTitle;
        private readonly TextBlock sessionCardModel;
        private readonly TextBlock sessionCardTokens;
        private readonly Border apiKeyChip;
        private readonly TextBlock apiKeyChipText;
        private readonly RoundedMeter fiveHourBar;
        private readonly RoundedMeter weekBar;
        /// <summary>Session body slot height; keep dataLayer (80) so OAuth/session heights match.</summary>
        private const double SessionBodyHeight = 72;
        private readonly DispatcherTimer quotaTimer;
        private UsageMetrics previewMetrics;
        private ClaudeCodeMetrics previewClaudeMetrics;
        private CodexCustomApiMetrics previewCodexCustomMetrics;
        private AgentKind currentAgent;
        private AggregateSnapshot currentAggregate;
        private List<SessionSnapshot> currentSessions;
        /// <summary>
        /// Last live context percent soft-held after the aggregate enters STANDBY.
        /// </summary>
        private double? heldContextPercent;
        private DateTime? contextHoldExpiresUtc;
        private AgentKind? contextHoldAgent;

        /// <summary>
        /// After COMPLETE settles into STANDBY, keep the last live context percent
        /// for this long before hiding. OFFLINE still clears immediately.
        /// Matches macOS <c>DetailsPanel.standbyContextHoldDuration</c>.
        /// </summary>
        internal static readonly TimeSpan StandbyContextHoldDuration =
            TimeSpan.FromSeconds(12);

        public event Action<AgentKind> AgentSelected;

        public DetailsWindow()
        {
            Width = 320;
            SizeToContent = SizeToContent.Height;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = System.Windows.Media.Brushes.Transparent;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            SourceInitialized += OnSourceInitialized;

            shell = new Border();
            shell.CornerRadius = new CornerRadius(16);
            shell.Padding = new Thickness(17, 13, 17, 10);
            shell.Background = CreateFallbackGlassBrush();
            shell.BorderBrush = new SolidColorBrush(
                MediaColor.FromArgb(46, 183, 199, 207));
            shell.BorderThickness = new Thickness(1);
            shell.Margin = new Thickness(9);
            shell.Effect = new DropShadowEffect
            {
                BlurRadius = 18,
                ShadowDepth = 0,
                Direction = 270,
                Opacity = 0.12,
                Color = MediaColor.FromRgb(151, 174, 184)
            };

            StackPanel content = new StackPanel();
            Grid top = new Grid();
            top.Height = 32;
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition());
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid switcher = CreateAgentSwitch(out codexSwitch, out claudeSwitch,
                out grokSwitch, out switchThumb, out switchThumbTransform,
                out codexSwitchIcon, out claudeSwitchIcon, out grokSwitchIcon);
            switcher.HorizontalAlignment = HorizontalAlignment.Left;
            switcher.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(switcher);
            contextMeter = new ContextBatteryMeter
            {
                Width = 46,
                Height = 24,
                VerticalAlignment = VerticalAlignment.Center
            };
            apiKeyChip = CreateAPIKeyChip(out apiKeyChipText);
            StackPanel topRight = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center
            };
            topRight.Children.Add(contextMeter);
            topRight.Children.Add(apiKeyChip);
            Grid.SetColumn(topRight, 2);
            top.Children.Add(topRight);
            top.Margin = new Thickness(0, 0, 0, 7);
            content.Children.Add(top);

            headline = NewText("OFFLINE", 20, MediaColor.FromRgb(40, 52, 60),
                FontWeights.Bold);
            content.Children.Add(headline);
            subtitle = NewText(L10n.Instance["status.offline_codex"], 13,
                MediaColor.FromRgb(103, 117, 126), FontWeights.Normal, true);
            subtitle.Margin = new Thickness(0, 1, 0, 13);
            content.Children.Add(subtitle);

            quotaGroup = new StackPanel();
            fiveHourRow = CreateQuotaRow(L10n.Instance["quota.5h"], out fiveHourLabel,
                out fiveHourReset, out fiveHourValue, out fiveHourBar);
            quotaGroup.Children.Add(fiveHourRow);
            weekRow = CreateQuotaRow(L10n.Instance["quota.weekly"], out weekLabel, out weekReset,
                out weekValue, out weekBar);
            weekRow.Margin = new Thickness(0, 8, 0, 0);
            quotaGroup.Children.Add(weekRow);

            sessionBodySlot = CreateSessionBodySlot(
                out emptyBody, out emptyBodyText,
                out sessionCard, out sessionCardTitle,
                out sessionCardModel, out sessionCardTokens);
            sessionBodySlot.Visibility = Visibility.Collapsed;

            dataLayer = new Grid();
            dataLayer.Height = 80;
            dataLayer.VerticalAlignment = VerticalAlignment.Top;
            dataLayer.Children.Add(quotaGroup);
            dataLayer.Children.Add(sessionBodySlot);
            content.Children.Add(dataLayer);

            Grid layers = new Grid();
            layers.Children.Add(content);
            shell.Child = layers;
            Content = shell;
            Closed += delegate
            {
                quotaTimer.Stop();
                CodexUsageMonitor.Instance.Updated -= OnCodexUsageUpdated;
                GrokUsageMonitor.Instance.Updated -= OnGrokUsageUpdated;
            };
            quotaTimer = new DispatcherTimer();
            quotaTimer.Interval = TimeSpan.FromSeconds(3);
            quotaTimer.Tick += delegate
            {
                if (IsVisible)
                {
                    RefreshSupplementalData();
                }
            };
            quotaTimer.Start();
            CodexUsageMonitor.Instance.Updated += OnCodexUsageUpdated;
            GrokUsageMonitor.Instance.Updated += OnGrokUsageUpdated;

            L10n.Instance.LanguageChanged += (s, ev) =>
            {
                Dispatcher.Invoke(() => RefreshAllText());
            };
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            int style = GetWindowLong(handle, -20);
            SetWindowLong(handle, -20, style | 0x08000000 | 0x00000080);
        }

        public void UpdateContent(AggregateSnapshot aggregate, List<SessionSnapshot> sessions)
        {
            currentAggregate = aggregate;
            currentSessions = sessions ?? new List<SessionSnapshot>();
            currentAgent = aggregate.FocusedAgent;
            UpdateAgentSwitch();
            headline.Text = aggregate.Label;
            MediaColor accent = HaloVisual.StateColor(aggregate.State);
            headline.Foreground = new SolidColorBrush(accent);
            subtitle.Text = FriendlyStatusDetail(aggregate, sessions);
            RefreshSupplementalData();
        }

        private static string FriendlyStatusDetail(AggregateSnapshot aggregate,
            List<SessionSnapshot> sessions)
        {
            if (aggregate.State == HaloState.Idle)
            {
                if (String.Equals(aggregate.Label, "PAUSED",
                    StringComparison.OrdinalIgnoreCase))
                {
                    return L10n.Instance["status.paused"];
                }
                if (aggregate.FocusedAgent == AgentKind.ClaudeCode)
                {
                    return L10n.Instance["status.offline_claude"];
                }
                if (aggregate.FocusedAgent == AgentKind.Grok)
                {
                    return L10n.Instance["status.offline_grok"];
                }
                return L10n.Instance["status.offline_codex"];
            }
            if (String.Equals(aggregate.Label, "STANDBY",
                StringComparison.OrdinalIgnoreCase) &&
                !String.IsNullOrWhiteSpace(aggregate.Detail))
            {
                return aggregate.Detail;
            }
            SessionSnapshot active = sessions.FirstOrDefault(delegate(SessionSnapshot session)
            {
                return session.Active;
            });
            string action = active == null ? String.Empty : active.Action;
            if (action.IndexOf("Writing answer", StringComparison.OrdinalIgnoreCase) >= 0 ||
                action.IndexOf("Generating response", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.writing_answer"];
            }
            if (action.IndexOf("command", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.running_command"];
            }
            if (action.IndexOf("Editing", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.editing_files"];
            }
            if (action.IndexOf("Search", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.searching"];
            }
            if (action.IndexOf("Compressing context", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.compressing_context"];
            }
            if (action.IndexOf("Context compacted", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.context_compacted"];
            }
            if (action.IndexOf("Awaiting permission", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.awaiting_permission"];
            }
            if (action.IndexOf("Reviewing result", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return L10n.Instance["status.reviewing_result"];
            }
            switch (aggregate.State)
            {
                case HaloState.Thinking: return L10n.Instance["status.thinking"];
                case HaloState.Working: return L10n.Instance["status.working"];
                case HaloState.Done: return L10n.Instance["status.done"];
                case HaloState.Attention: return L10n.Instance["status.attention"];
                case HaloState.Error:
                    return String.IsNullOrEmpty(aggregate.Detail)
                        ? L10n.Instance["status.error"] : aggregate.Detail;
                default:
                    return String.IsNullOrEmpty(aggregate.Detail)
                        ? L10n.Instance["status.unknown"] : aggregate.Detail;
            }
        }

        /// <summary>
        /// Test hook for offline / idle status detail copy (Grok parity).
        /// </summary>
        internal static string FriendlyStatusDetailForTest(
            AggregateSnapshot aggregate, List<SessionSnapshot> sessions)
        {
            return FriendlyStatusDetail(aggregate,
                sessions ?? new List<SessionSnapshot>());
        }

        private void RefreshSupplementalData()
        {
            if (IsOfflineAggregate(currentAggregate))
            {
                ApplyOfflinePlaceholders();
                return;
            }
            if (currentAgent == AgentKind.ClaudeCode)
            {
                RefreshClaudeDetails();
            }
            else if (currentAgent == AgentKind.Grok)
            {
                RefreshGrokDetails();
            }
            else
            {
                RefreshCodexDetails();
            }
        }

        private static bool IsOfflineAggregate(AggregateSnapshot aggregate)
        {
            // Mirrors the macOS check: an idle ring labeled OFFLINE means we
            // have no live session, so any project/model/token/context values
            // would be stale carry-over from the previous run.
            return aggregate != null
                && aggregate.State == HaloState.Idle
                && String.Equals(aggregate.Label, "OFFLINE",
                    StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsStandbyAggregate(AggregateSnapshot aggregate)
        {
            return aggregate != null
                && String.Equals(aggregate.Label, "STANDBY",
                    StringComparison.OrdinalIgnoreCase);
        }

        private void ApplyOfflinePlaceholders()
        {
            heldContextPercent = null;
            contextHoldExpiresUtc = null;
            CodexCustomApiMetrics codexMetrics = currentAgent == AgentKind.Codex
                ? ReadCodexCustomMetrics() : null;
            if (currentAgent == AgentKind.ClaudeCode ||
                (codexMetrics != null && codexMetrics.IsCustomApi))
            {
                // Scheme B: offline empty rectangle — never three rows of "--".
                ShowAPIKeySessionBody(true, null, null, null);
            }
            else if (currentAgent == AgentKind.Grok)
            {
                RefreshGrokDetails();
            }
            else
            {
                // RefreshQuota may try to set context from cached usage metrics;
                // offline must still drop the pill (and clear hold state).
                RefreshQuota();
            }
            // Drop the context pill rather than echoing a percentage from the
            // session that just went offline. Done after RefreshQuota since
            // that path may reset context-pill visibility.
            heldContextPercent = null;
            contextHoldExpiresUtc = null;
            contextMeter.IsAvailable = false;
            contextMeter.Value = 0;
            contextMeter.Visibility = Visibility.Collapsed;
        }

        private void RefreshClaudeDetails()
        {
            ClaudeCodeMetrics metrics = previewClaudeMetrics ?? ClaudeCodeMetricsReader.Read();
            string title = metrics.HasSessionTitle ? metrics.SessionTitle : null;
            string model = metrics.HasModel ? metrics.Model : null;
            string tokens = FormatTokenPair(metrics.HasTokenUsage,
                metrics.InputTokens, metrics.OutputTokens);
            ShowAPIKeySessionBody(false, title, model, tokens);
            SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
        }

        private void RefreshCodexDetails()
        {
            CodexCustomApiMetrics metrics = ReadCodexCustomMetrics();
            if (metrics != null && metrics.IsCustomApi)
            {
                ApplyCodexCustomMetrics(metrics);
                return;
            }
            RefreshQuota();
        }

        /// <summary>
        /// Weekly OAuth credits from <see cref="GrokUsageMonitor"/> only (no 5h row).
        /// Context pill is disk-backed (signals.json / live updates.jsonl) and only
        /// surfaces while a real Grok session (not the "grok" placeholder) is
        /// displayed. STANDBY soft-holds via <see cref="ApplyContextSource"/>;
        /// OFFLINE clears immediately in <see cref="ApplyOfflinePlaceholders"/>.
        /// </summary>
        private void RefreshGrokDetails()
        {
            // Grok on Windows is OAuth weekly only — no API Key chip / session body.
            HideAPIKeySessionChrome();
            quotaGroup.Visibility = Visibility.Visible;
            fiveHourRow.Visibility = Visibility.Collapsed;
            weekRow.Visibility = Visibility.Visible;
            weekRow.Margin = new Thickness(0);
            weekLabel.Text = L10n.Instance["quota.weekly"];
            quotaGroup.VerticalAlignment = VerticalAlignment.Center;

            UsageMetrics metrics;
            if (!GrokUsageMonitor.Instance.TryRead(out metrics) || metrics == null)
            {
                metrics = new UsageMetrics { ContextInputTokens = -1 };
            }

            ApplyQuota(metrics.HasWeekly, metrics.WeeklyUsedPercent,
                metrics.WeeklyResetUtc, weekValue, weekReset, weekBar);

            if (GrokUsageMonitor.Instance.Status == GrokUsageDataStatus.SignInAgain)
            {
                // Same warning slot pattern as Codex L10n keys (provider-specific copy).
                weekValue.Text = L10n.Instance["usage.warning.sign_in_grok"];
                weekReset.Text = String.Empty;
                weekReset.Visibility = Visibility.Collapsed;
                weekBar.Value = 0;
            }

            SessionSnapshot primary = FindDisplayedGrokSession(currentSessions);
            GrokSessionContextSnapshot context = null;
            if (primary != null)
            {
                string cwd = String.IsNullOrEmpty(primary.WorkingDirectory)
                    ? null : primary.WorkingDirectory;
                context = new GrokSessionContextReader().Read(primary.ThreadId, cwd);
            }
            if (context != null)
            {
                SetContextPercent(true, context.ContextUsedPercent);
            }
            else
            {
                SetContextPercent(false, 0);
            }
        }

        /// <summary>
        /// Real Grok thread currently shown in the details aggregate — not the
        /// "grok" placeholder used when session id is unknown.
        /// </summary>
        private static SessionSnapshot FindDisplayedGrokSession(
            List<SessionSnapshot> sessions)
        {
            if (sessions == null)
            {
                return null;
            }
            return sessions.FirstOrDefault(delegate(SessionSnapshot session)
            {
                return session != null
                    && session.Agent == AgentKind.Grok
                    && !String.IsNullOrEmpty(session.ThreadId)
                    && !String.Equals(session.ThreadId, "grok",
                        StringComparison.Ordinal);
            });
        }

        private CodexCustomApiMetrics ReadCodexCustomMetrics()
        {
            if (previewCodexCustomMetrics != null)
            {
                return previewCodexCustomMetrics;
            }
            if (previewMetrics != null)
            {
                return new CodexCustomApiMetrics { IsCustomApi = false };
            }
            return CodexCustomApiMetricsReader.Read(currentSessions);
        }

        private void ApplyCodexCustomMetrics(CodexCustomApiMetrics metrics)
        {
            // No separate Project row (Scheme B): card title uses the best
            // available session label — custom Codex currently surfaces project leaf.
            string title = metrics.HasProject ? metrics.ProjectName : null;
            string model = metrics.HasModel ? metrics.Model : null;
            string tokens = FormatTokenPair(metrics.HasTokenUsage,
                metrics.InputTokens, metrics.OutputTokens);
            ShowAPIKeySessionBody(false, title, model, tokens);
            SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
        }

        private void RefreshQuota()
        {
            HideAPIKeySessionChrome();
            quotaGroup.Visibility = Visibility.Visible;
            UsageMetrics metrics;
            if (previewMetrics != null)
            {
                metrics = previewMetrics;
            }
            else if (!CodexUsageMonitor.Instance.TryRead(out metrics))
            {
                metrics = null;
            }
            if (metrics != null)
            {
                ApplyQuotaMetrics(metrics);
                SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
            }
            else
            {
                ApplyQuotaMetrics(new UsageMetrics { ContextInputTokens = -1 });
                SetContextPercent(false, 0);
            }
        }

        private void OnCodexUsageUpdated()
        {
            if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
            {
                return;
            }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (IsVisible && currentAgent == AgentKind.Codex &&
                    previewMetrics == null)
                {
                    RefreshCodexDetails();
                }
            }));
        }

        private void OnGrokUsageUpdated()
        {
            if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
            {
                return;
            }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (IsVisible && currentAgent == AgentKind.Grok)
                {
                    RefreshGrokDetails();
                }
            }));
        }

        private void SetContextPercent(bool available, double value)
        {
            ApplyContextSource(available ? (double?)value : null);
        }

        /// <summary>
        /// Apply a live (or missing) context reading through the shared
        /// STANDBY soft-hold state machine used on macOS.
        /// </summary>
        private void ApplyContextSource(double? sourcePercent)
        {
            ApplyContextSource(sourcePercent, DateTime.UtcNow);
        }

        internal void ApplyContextSource(double? sourcePercent, DateTime nowUtc)
        {
            bool isOffline = IsOfflineAggregate(currentAggregate);
            bool isStandby = IsStandbyAggregate(currentAggregate);

            if (contextHoldAgent.HasValue && contextHoldAgent.Value != currentAgent)
            {
                heldContextPercent = null;
                contextHoldExpiresUtc = null;
            }
            contextHoldAgent = currentAgent;

            // STANDBY ignores frozen disk/usage occupancy so the pill does not
            // stick forever while the agent process is merely idle. Soft-hold
            // the last live percent instead (Codex / Claude parity with macOS).
            double? livePercent = (isOffline || isStandby) ? null : sourcePercent;

            ContextDisplayResolution resolved = ResolveContextDisplay(
                livePercent,
                isOffline,
                isStandby,
                heldContextPercent,
                contextHoldExpiresUtc,
                nowUtc,
                StandbyContextHoldDuration);

            heldContextPercent = resolved.HeldPercent;
            contextHoldExpiresUtc = resolved.HoldExpiresUtc;

            if (resolved.DisplayPercent.HasValue)
            {
                contextMeter.Visibility = Visibility.Visible;
                contextMeter.IsAvailable = true;
                contextMeter.Value = Math.Max(0, Math.Min(100,
                    Math.Round(resolved.DisplayPercent.Value)));
            }
            else
            {
                contextMeter.Visibility = Visibility.Collapsed;
                contextMeter.IsAvailable = false;
                contextMeter.Value = 0;
            }
        }

        /// <summary>
        /// Pure display/hold state machine for the context pill.
        /// Live percent: show and remember for a future STANDBY hold.
        /// STANDBY + remembered percent: keep showing until holdDuration elapses.
        /// OFFLINE: clear immediately (no hold).
        /// </summary>
        internal static ContextDisplayResolution ResolveContextDisplay(
            double? livePercent,
            bool isOffline,
            bool isStandby,
            double? heldPercent,
            DateTime? holdExpiresUtc,
            DateTime nowUtc,
            TimeSpan holdDuration)
        {
            if (isOffline)
            {
                return new ContextDisplayResolution();
            }
            if (livePercent.HasValue)
            {
                return new ContextDisplayResolution
                {
                    DisplayPercent = livePercent,
                    HeldPercent = livePercent,
                    HoldExpiresUtc = null
                };
            }
            if (isStandby && heldPercent.HasValue)
            {
                DateTime expires = holdExpiresUtc.HasValue
                    ? holdExpiresUtc.Value
                    : nowUtc.Add(holdDuration);
                if (nowUtc < expires)
                {
                    return new ContextDisplayResolution
                    {
                        DisplayPercent = heldPercent,
                        HeldPercent = heldPercent,
                        HoldExpiresUtc = expires
                    };
                }
            }
            return new ContextDisplayResolution();
        }

        internal sealed class ContextDisplayResolution
        {
            public double? DisplayPercent;
            public double? HeldPercent;
            public DateTime? HoldExpiresUtc;
        }

        public void SetPreviewMetrics(UsageMetrics metrics)
        {
            previewMetrics = metrics;
            RefreshQuota();
        }

        public void SetPreviewClaudeMetrics(ClaudeCodeMetrics metrics)
        {
            previewClaudeMetrics = metrics;
            RefreshClaudeDetails();
        }

        public void SetPreviewCodexCustomMetrics(CodexCustomApiMetrics metrics)
        {
            previewCodexCustomMetrics = metrics;
            RefreshCodexDetails();
        }

        private void SelectAgent(AgentKind agent)
        {
            if (AgentSelected != null)
            {
                AgentSelected(agent);
            }
        }

        private void UpdateAgentSwitch()
        {
            StyleCodexSwitch(codexSwitch, codexSwitchIcon,
                currentAgent == AgentKind.Codex);
            StyleClaudeSwitch(claudeSwitch, claudeSwitchIcon,
                currentAgent == AgentKind.ClaudeCode);
            StyleGrokSwitch(grokSwitch, grokSwitchIcon,
                currentAgent == AgentKind.Grok);
            MoveSwitchThumb(currentAgent);
        }

        private void MoveSwitchThumb(AgentKind agent)
        {
            // Three equal columns (~48.67 each) on a 146-wide track; thumb is 44
            // with 3px inset. Index 0/1/2 → 0 / 48 / 96.
            double target = 0;
            if (agent == AgentKind.ClaudeCode)
            {
                target = 48;
            }
            else if (agent == AgentKind.Grok)
            {
                target = 96;
            }
            if (!IsVisible)
            {
                switchThumbTransform.X = target;
                return;
            }
            DoubleAnimation animation = new DoubleAnimation
            {
                To = target,
                Duration = TimeSpan.FromMilliseconds(180),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            switchThumbTransform.BeginAnimation(TranslateTransform.XProperty,
                animation, HandoffBehavior.SnapshotAndReplace);
        }

        private static void StyleCodexSwitch(Border border,
            System.Windows.Shapes.Path icon, bool selected)
        {
            border.Opacity = selected ? 1.0 : 0.58;
            icon.Fill = System.Windows.Media.Brushes.Black;
        }

        private static void StyleClaudeSwitch(Border border,
            Canvas icon, bool selected)
        {
            border.Opacity = selected ? 1.0 : 0.58;
            MediaColor body = selected
                ? MediaColor.FromRgb(217, 119, 87)
                : MediaColor.FromRgb(112, 132, 143);
            foreach (UIElement child in icon.Children)
            {
                System.Windows.Shapes.Shape shape =
                    child as System.Windows.Shapes.Shape;
                if (shape == null)
                {
                    continue;
                }
                string tag = shape.Tag as string;
                shape.Fill = new SolidColorBrush(tag == "eye"
                    ? MediaColor.FromRgb(17, 17, 17)
                    : body);
            }
        }

        private static void StyleGrokSwitch(Border border,
            System.Windows.Shapes.Path icon, bool selected)
        {
            border.Opacity = selected ? 1.0 : 0.58;
            icon.Fill = new SolidColorBrush(MediaColor.FromRgb(17, 17, 17));
        }

        private void ApplyQuotaMetrics(UsageMetrics metrics)
        {
            quotaGroup.VerticalAlignment = VerticalAlignment.Center;
            fiveHourLabel.Text = L10n.Instance["quota.5h"];
            weekLabel.Text = L10n.Instance["quota.weekly"];
            fiveHourRow.Visibility = Visibility.Visible;
            weekRow.Visibility = Visibility.Visible;
            fiveHourRow.Margin = new Thickness(0);
            weekRow.Margin = new Thickness(0, 8, 0, 0);
            ApplyQuota(metrics.HasFiveHour, metrics.FiveHourUsedPercent,
                metrics.FiveHourResetUtc, fiveHourValue, fiveHourReset, fiveHourBar);
            ApplyQuota(metrics.HasWeekly, metrics.WeeklyUsedPercent,
                metrics.WeeklyResetUtc, weekValue, weekReset, weekBar);
        }

        private static void ApplyQuota(bool available, double usedPercent,
            DateTime resetUtc, TextBlock value, TextBlock reset, RoundedMeter bar)
        {
            if (!available)
            {
                value.Text = L10n.Instance["quota.no_data"];
                reset.Text = String.Empty;
                reset.Visibility = Visibility.Collapsed;
                bar.Value = 0;
                return;
            }
            if (IsQuotaExpired(resetUtc, DateTime.UtcNow))
            {
                value.Text = L10n.Instance["quota.waiting_refresh"];
                reset.Text = String.Empty;
                reset.Visibility = Visibility.Collapsed;
                bar.Value = 0;
                return;
            }
            double remaining = Math.Max(0, Math.Min(100, 100 - usedPercent));
            value.Text = L10n.Instance.Format("quota.remaining", (int)Math.Round(remaining));
            reset.Text = FormatResetTime(resetUtc);
            reset.Visibility = String.IsNullOrEmpty(reset.Text)
                ? Visibility.Collapsed : Visibility.Visible;
            bar.Value = remaining;
        }

        public static bool IsQuotaExpired(DateTime resetUtc, DateTime nowUtc)
        {
            return resetUtc != DateTime.MinValue && nowUtc >= resetUtc.ToUniversalTime();
        }

        public static string FormatResetTime(DateTime resetUtc)
        {
            if (resetUtc == DateTime.MinValue)
            {
                return String.Empty;
            }
            DateTime local = resetUtc.ToLocalTime();
            var culture = new CultureInfo(L10n.Instance["date.culture"]);
            var format = local.Date == DateTime.Now.Date
                ? L10n.Instance["date.today_format"]
                : L10n.Instance["date.other_format"];
            return L10n.Instance.Format("quota.resets", local.ToString(format, culture));
        }

        private static Grid CreateQuotaRow(string title, out TextBlock name,
            out TextBlock reset, out TextBlock value, out RoundedMeter bar)
        {
            Grid grid = new Grid();
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid labels = new Grid();
            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            labels.ColumnDefinitions.Add(new ColumnDefinition());
            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            name = NewText(title, 12, MediaColor.FromRgb(99, 112, 120),
                FontWeights.Normal, true);
            labels.Children.Add(name);
            reset = NewText(String.Empty, 10.5, MediaColor.FromRgb(130, 145, 153),
                FontWeights.Normal, true);
            reset.Margin = new Thickness(6, 1, 6, 0);
            reset.VerticalAlignment = VerticalAlignment.Center;
            reset.Visibility = Visibility.Collapsed;
            Grid.SetColumn(reset, 1);
            labels.Children.Add(reset);
            value = NewText(L10n.Instance["quota.no_data"], 12, MediaColor.FromRgb(48, 60, 68),
                FontWeights.SemiBold, true);
            value.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(value, 2);
            labels.Children.Add(value);
            grid.Children.Add(labels);
            bar = new RoundedMeter
            {
                Height = 4,
                Margin = new Thickness(0, 5, 0, 0)
            };
            Grid.SetRow(bar, 1);
            grid.Children.Add(bar);
            return grid;
        }

        /// <summary>
        /// Scheme B session body: API Key chip + fixed-height empty XOR session card.
        /// </summary>
        private void ShowAPIKeySessionBody(bool offline, string title, string model,
            string tokens)
        {
            quotaGroup.Visibility = Visibility.Hidden;
            apiKeyChip.Visibility = Visibility.Visible;
            apiKeyChipText.Text = L10n.Instance["access.mode.api_key"];
            sessionBodySlot.Visibility = Visibility.Visible;

            if (offline)
            {
                emptyBody.Visibility = Visibility.Visible;
                sessionCard.Visibility = Visibility.Collapsed;
                emptyBodyText.Text = "○ " + L10n.Instance["session.empty.api_key"];
                // Clear hidden card fields so a11y / subsequent reads do not
                // leak the previous session title, model, or tokens.
                sessionCardTitle.Text = "--";
                sessionCardTitle.ToolTip = null;
                sessionCardModel.Text = "--";
                sessionCardTokens.Text = "↑ --  ·  ↓ --";
                return;
            }
            emptyBody.Visibility = Visibility.Collapsed;
            sessionCard.Visibility = Visibility.Visible;
            sessionCardTitle.Text = String.IsNullOrEmpty(title) ? "--" : title;
            sessionCardTitle.ToolTip = String.IsNullOrEmpty(title) ? null : title;
            sessionCardModel.Text = String.IsNullOrEmpty(model) ? "--" : model;
            sessionCardTokens.Text = String.IsNullOrEmpty(tokens)
                ? "↑ --  ·  ↓ --" : tokens;
        }

        private void HideAPIKeySessionChrome()
        {
            apiKeyChip.Visibility = Visibility.Collapsed;
            sessionBodySlot.Visibility = Visibility.Collapsed;
        }

        private static string FormatTokenPair(bool hasUsage, long inputTokens,
            long outputTokens)
        {
            if (!hasUsage)
            {
                return "↑ --  ·  ↓ --";
            }
            return "↑ " + FormatCompactNumber(inputTokens) +
                "  ·  ↓ " + FormatCompactNumber(outputTokens);
        }

        private static Border CreateAPIKeyChip(out TextBlock label)
        {
            System.Windows.Shapes.Ellipse dot = new System.Windows.Shapes.Ellipse
            {
                Width = 6,
                Height = 6,
                Fill = new SolidColorBrush(MediaColor.FromArgb(191, 42, 111, 143)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 5, 0)
            };
            label = NewText(L10n.Instance["access.mode.api_key"], 10.5,
                MediaColor.FromRgb(42, 111, 143), FontWeights.SemiBold, true);
            label.VerticalAlignment = VerticalAlignment.Center;
            StackPanel content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center
            };
            content.Children.Add(dot);
            content.Children.Add(label);
            return new Border
            {
                Height = 22,
                CornerRadius = new CornerRadius(11),
                Padding = new Thickness(8, 0, 8, 0),
                Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(
                    MediaColor.FromArgb(26, 52, 158, 199)),
                BorderBrush = new SolidColorBrush(
                    MediaColor.FromArgb(56, 52, 158, 199)),
                BorderThickness = new Thickness(1),
                Child = content,
                Visibility = Visibility.Collapsed
            };
        }

        private static Grid CreateSessionBodySlot(
            out Border emptyHost, out TextBlock emptyText,
            out Border card, out TextBlock title,
            out TextBlock model, out TextBlock tokens)
        {
            Grid slot = new Grid
            {
                Height = SessionBodyHeight,
                VerticalAlignment = VerticalAlignment.Center
            };

            // Empty: dashed rounded rect + centered copy.
            Grid emptyInner = new Grid();
            System.Windows.Shapes.Rectangle dash = new System.Windows.Shapes.Rectangle
            {
                RadiusX = 12,
                RadiusY = 12,
                Stroke = new SolidColorBrush(
                    MediaColor.FromArgb(72, 130, 150, 165)),
                StrokeThickness = 1,
                StrokeDashArray = new DoubleCollection { 4, 3 },
                Fill = new SolidColorBrush(MediaColor.FromArgb(115, 255, 255, 255))
            };
            emptyText = NewText(String.Empty, 12,
                MediaColor.FromRgb(109, 129, 144), FontWeights.Normal, true);
            emptyText.HorizontalAlignment = HorizontalAlignment.Center;
            emptyText.VerticalAlignment = VerticalAlignment.Center;
            emptyText.TextAlignment = TextAlignment.Center;
            emptyInner.Children.Add(dash);
            emptyInner.Children.Add(emptyText);
            emptyHost = new Border
            {
                Child = emptyInner,
                Visibility = Visibility.Collapsed
            };
            slot.Children.Add(emptyHost);

            // Session card: title + model chip + tokens, vertically centered.
            title = NewText("--", 13, MediaColor.FromRgb(30, 44, 54),
                FontWeights.SemiBold, true);
            title.TextTrimming = TextTrimming.CharacterEllipsis;
            title.Margin = new Thickness(0, 0, 0, 8);

            model = NewText("--", 11, MediaColor.FromRgb(77, 97, 112),
                FontWeights.Medium, true);
            model.VerticalAlignment = VerticalAlignment.Center;
            model.TextTrimming = TextTrimming.CharacterEllipsis;
            Border modelChip = new Border
            {
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(7, 2, 7, 2),
                Background = new SolidColorBrush(
                    MediaColor.FromArgb(15, 30, 44, 54)),
                BorderBrush = new SolidColorBrush(
                    MediaColor.FromArgb(20, 30, 44, 54)),
                BorderThickness = new Thickness(0.5),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center,
                MaxWidth = 160,
                Child = model
            };

            tokens = NewText("↑ --  ·  ↓ --", 11.5,
                MediaColor.FromRgb(64, 90, 110), FontWeights.Medium, true);
            tokens.HorizontalAlignment = HorizontalAlignment.Right;
            tokens.VerticalAlignment = VerticalAlignment.Center;
            tokens.TextAlignment = TextAlignment.Right;

            Grid footer = new Grid();
            footer.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star)
            });
            footer.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = GridLength.Auto
            });
            footer.Children.Add(modelChip);
            Grid.SetColumn(tokens, 1);
            footer.Children.Add(tokens);

            StackPanel cardContent = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Center
            };
            cardContent.Children.Add(title);
            cardContent.Children.Add(footer);

            card = new Border
            {
                CornerRadius = new CornerRadius(12),
                Background = new SolidColorBrush(
                    MediaColor.FromArgb(158, 255, 255, 255)),
                BorderBrush = new SolidColorBrush(
                    MediaColor.FromArgb(46, 140, 160, 175)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12, 0, 12, 0),
                Child = cardContent,
                Visibility = Visibility.Collapsed
            };
            slot.Children.Add(card);
            return slot;
        }

        private const string OpenAiBlossomIconPath =
            "M249.176 323.434V298.276C249.176 296.158 249.971 294.569 251.825 293.509L302.406 264.381C309.29 260.409 317.5 258.555 325.973 258.555C357.75 258.555 377.877 283.185 377.877 309.399C377.877 311.253 377.877 313.371 377.611 315.49L325.178 284.771C322.001 282.919 318.822 282.919 315.645 284.771L249.176 323.434ZM367.283 421.415V361.301C367.283 357.592 365.694 354.945 362.516 353.092L296.048 314.43L317.763 301.982C319.617 300.925 321.206 300.925 323.058 301.982L373.639 331.112C388.205 339.586 398.003 357.592 398.003 375.069C398.003 395.195 386.087 413.733 367.283 421.412V421.415ZM233.553 368.452L211.838 355.742C209.986 354.684 209.19 353.095 209.19 350.975V292.718C209.19 264.383 230.905 242.932 260.301 242.932C271.423 242.932 281.748 246.641 290.49 253.26L238.321 283.449C235.146 285.303 233.555 287.951 233.555 291.659V368.455L233.553 368.452ZM280.292 395.462L249.176 377.985V340.913L280.292 323.436L311.407 340.913V377.985L280.292 395.462ZM300.286 475.968C289.163 475.968 278.837 472.259 270.097 465.64L322.264 435.449C325.441 433.597 327.03 430.949 327.03 427.239V350.445L349.011 363.155C350.865 364.213 351.66 365.802 351.66 367.922V426.179C351.66 454.514 329.679 475.965 300.286 475.965V475.968ZM237.525 416.915L186.944 387.785C172.378 379.31 162.582 361.305 162.582 343.827C162.582 323.436 174.763 305.164 193.563 297.485V357.861C193.563 361.571 195.154 364.217 198.33 366.071L264.535 404.467L242.82 416.915C240.967 417.972 239.377 417.972 237.525 416.915ZM234.614 460.343C204.689 460.343 182.71 437.833 182.71 410.028C182.71 407.91 182.976 405.792 183.238 403.672L235.405 433.863C238.582 435.715 241.763 435.715 244.938 433.863L311.407 395.466V420.622C311.407 422.742 310.612 424.331 308.758 425.389L258.179 454.519C251.293 458.491 243.083 460.343 234.611 460.343H234.614ZM300.286 491.854C332.329 491.854 359.073 469.082 365.167 438.892C394.825 431.211 413.892 403.406 413.892 375.073C413.892 356.535 405.948 338.529 391.648 325.552C392.972 319.991 393.766 314.43 393.766 308.87C393.766 271.003 363.048 242.666 327.562 242.666C320.413 242.666 313.528 243.723 306.644 246.109C294.725 234.457 278.307 227.042 260.301 227.042C228.258 227.042 201.513 249.815 195.42 280.004C165.761 287.685 146.694 315.49 146.694 343.824C146.694 362.362 154.638 380.368 168.938 393.344C167.613 398.906 166.819 404.467 166.819 410.027C166.819 447.894 197.538 476.231 233.024 476.231C240.172 476.231 247.058 475.173 253.943 472.788C265.859 484.441 282.278 491.854 300.286 491.854Z";

        private const string ClaudeCodeIconPath =
            "M6.9 2.7h10.2c.9 0 1.6.7 1.6 1.6v3.4h2.4c.8 0 1.4.6 1.4 1.4v3.9c0 .8-.6 1.4-1.4 1.4h-2.4v6.9h-3.2v-6.9h-2.1v6.9h-2.8v-6.9H8.5v6.9H5.3v-6.9H2.9c-.8 0-1.4-.6-1.4-1.4V9.1c0-.8.6-1.4 1.4-1.4h2.4V4.3c0-.9.7-1.6 1.6-1.6z";

        // From src/shared/assets/agent-switch/grok.svg (fill #111111).
        private const string GrokIconPath =
            "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815";

        private Grid CreateAgentSwitch(out Border codexBorder,
            out Border claudeBorder, out Border grokBorder, out Border thumb,
            out TranslateTransform thumbTransform,
            out System.Windows.Shapes.Path codexIcon,
            out Canvas claudeIcon,
            out System.Windows.Shapes.Path grokIcon)
        {
            Grid shell = new Grid();
            shell.Width = 146;
            shell.Height = 32;
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            Border background = new Border
            {
                CornerRadius = new CornerRadius(16),
                Background = new SolidColorBrush(MediaColor.FromRgb(244, 248, 250)),
                BorderBrush = new SolidColorBrush(MediaColor.FromRgb(221, 233, 238)),
                BorderThickness = new Thickness(1)
            };
            Grid.SetColumnSpan(background, 3);
            shell.Children.Add(background);

            thumbTransform = new TranslateTransform();
            thumb = new Border
            {
                Width = 44,
                Height = 26,
                CornerRadius = new CornerRadius(13),
                Margin = new Thickness(3),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(MediaColor.FromRgb(225, 249, 255)),
                BorderBrush = new SolidColorBrush(MediaColor.FromRgb(183, 235, 246)),
                BorderThickness = new Thickness(1),
                RenderTransform = thumbTransform,
                Effect = new DropShadowEffect
                {
                    BlurRadius = 10,
                    ShadowDepth = 0,
                    Opacity = 0.12,
                    Color = MediaColor.FromRgb(66, 178, 205)
                }
            };
            Grid.SetColumnSpan(thumb, 3);
            shell.Children.Add(thumb);

            Grid hitLayer = new Grid();
            hitLayer.ColumnDefinitions.Add(new ColumnDefinition());
            hitLayer.ColumnDefinitions.Add(new ColumnDefinition());
            hitLayer.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumnSpan(hitLayer, 3);

            Viewbox codexIconBox = CreateSwitchIcon(OpenAiBlossomIconPath, 18,
                out codexIcon);
            codexBorder = new Border
            {
                Background = System.Windows.Media.Brushes.Transparent,
                Child = codexIconBox,
                Cursor = System.Windows.Input.Cursors.Hand,
                Padding = new Thickness(0)
            };
            codexBorder.MouseLeftButtonUp += delegate { SelectAgent(AgentKind.Codex); };
            hitLayer.Children.Add(codexBorder);

            Viewbox claudeIconBox = CreateClaudeCodeSwitchIcon(22,
                out claudeIcon);
            claudeBorder = new Border
            {
                Background = System.Windows.Media.Brushes.Transparent,
                Child = claudeIconBox,
                Cursor = System.Windows.Input.Cursors.Hand,
                Padding = new Thickness(0)
            };
            claudeBorder.MouseLeftButtonUp += delegate { SelectAgent(AgentKind.ClaudeCode); };
            Grid.SetColumn(claudeBorder, 1);
            hitLayer.Children.Add(claudeBorder);

            Viewbox grokIconBox = CreateSwitchIcon(GrokIconPath, 18, out grokIcon);
            // grok.svg uses fill-rule="evenodd"; WPF Geometry.Parse defaults to Nonzero.
            SetGeometryFillRule(grokIcon.Data, FillRule.EvenOdd);
            grokBorder = new Border
            {
                Background = System.Windows.Media.Brushes.Transparent,
                Child = grokIconBox,
                Cursor = System.Windows.Input.Cursors.Hand,
                Padding = new Thickness(0)
            };
            grokBorder.MouseLeftButtonUp += delegate { SelectAgent(AgentKind.Grok); };
            Grid.SetColumn(grokBorder, 2);
            hitLayer.Children.Add(grokBorder);
            shell.Children.Add(hitLayer);
            return shell;
        }

        private static Viewbox CreateSwitchIcon(string pathData, double displaySize,
            out System.Windows.Shapes.Path icon)
        {
            Geometry geometry = Geometry.Parse(pathData).Clone();
            System.Windows.Rect bounds = geometry.Bounds;
            geometry.Transform = new TranslateTransform(-bounds.X, -bounds.Y);
            Canvas canvas = new Canvas
            {
                Width = bounds.Width,
                Height = bounds.Height
            };
            icon = new System.Windows.Shapes.Path
            {
                Data = geometry,
                Fill = System.Windows.Media.Brushes.Black,
                Stretch = Stretch.None
            };
            canvas.Children.Add(icon);
            Viewbox viewbox = new Viewbox
            {
                Width = displaySize,
                Height = displaySize,
                Stretch = Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = canvas
            };
            return viewbox;
        }

        private static void SetGeometryFillRule(Geometry geometry, FillRule fillRule)
        {
            if (geometry == null)
            {
                return;
            }
            PathGeometry pathGeometry = geometry as PathGeometry;
            if (pathGeometry != null)
            {
                pathGeometry.FillRule = fillRule;
                return;
            }
            StreamGeometry streamGeometry = geometry as StreamGeometry;
            if (streamGeometry != null)
            {
                streamGeometry.FillRule = fillRule;
            }
        }

        private static Viewbox CreateClaudeCodeSwitchIcon(double displaySize,
            out Canvas icon)
        {
            icon = new Canvas
            {
                Width = 24,
                Height = 24
            };
            System.Windows.Shapes.Path body = new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse(ClaudeCodeIconPath),
                Fill = new SolidColorBrush(MediaColor.FromRgb(217, 119, 87)),
                Stretch = Stretch.None
            };
            icon.Children.Add(body);
            System.Windows.Shapes.Rectangle leftEye =
                new System.Windows.Shapes.Rectangle
                {
                    Width = 2.25,
                    Height = 2.6,
                    RadiusX = 0.25,
                    RadiusY = 0.25,
                    Fill = new SolidColorBrush(MediaColor.FromRgb(17, 17, 17)),
                    Tag = "eye"
                };
            Canvas.SetLeft(leftEye, 7.7);
            Canvas.SetTop(leftEye, 8);
            icon.Children.Add(leftEye);
            System.Windows.Shapes.Rectangle rightEye =
                new System.Windows.Shapes.Rectangle
                {
                    Width = 2.25,
                    Height = 2.6,
                    RadiusX = 0.25,
                    RadiusY = 0.25,
                    Fill = new SolidColorBrush(MediaColor.FromRgb(17, 17, 17)),
                    Tag = "eye"
                };
            Canvas.SetLeft(rightEye, 14.05);
            Canvas.SetTop(rightEye, 8);
            icon.Children.Add(rightEye);
            return new Viewbox
            {
                Width = displaySize,
                Height = displaySize,
                Stretch = Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = icon
            };
        }

        private static string FormatCompactNumber(long value)
        {
            if (value >= 1000)
            {
                double thousands = value / 1000.0;
                return thousands >= 10
                    ? String.Format(CultureInfo.InvariantCulture, "{0:0}k", thousands)
                    : String.Format(CultureInfo.InvariantCulture, "{0:0.#}k", thousands);
            }
            return value.ToString(CultureInfo.InvariantCulture);
        }

        private static MediaBrush CreateFallbackGlassBrush()
        {
            System.Windows.Media.LinearGradientBrush brush =
                new System.Windows.Media.LinearGradientBrush();
            brush.StartPoint = new MediaPoint(0, 0);
            brush.EndPoint = new MediaPoint(0, 1);
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromArgb(244, 255, 255, 255), 0));
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromArgb(235, 250, 252, 253), 0.58));
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromArgb(241, 255, 255, 255), 1));
            return brush;
        }

        private static TextBlock NewText(string text, double size, MediaColor color,
            FontWeight weight)
        {
            return NewText(text, size, color, weight, false);
        }

        private static TextBlock NewText(string text, double size, MediaColor color,
            FontWeight weight, bool chineseUi)
        {
            TextBlock block = new TextBlock
            {
                Text = text,
                FontFamily = new System.Windows.Media.FontFamily(
                    chineseUi ? "Microsoft YaHei UI" : "Segoe UI Variable Text"),
                FontSize = size,
                FontWeight = weight,
                Foreground = new SolidColorBrush(color),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            block.Language = System.Windows.Markup.XmlLanguage.GetLanguage(
                chineseUi ? "zh-CN" : "en-US");
            TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(block, TextRenderingMode.Auto);
            return block;
        }

        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        private void RefreshAllText()
        {
            fiveHourLabel.Text = L10n.Instance["quota.5h"];
            weekLabel.Text = L10n.Instance["quota.weekly"];
            apiKeyChipText.Text = L10n.Instance["access.mode.api_key"];
            if (currentAggregate != null)
                UpdateContent(currentAggregate, currentSessions);
        }
    }
}
