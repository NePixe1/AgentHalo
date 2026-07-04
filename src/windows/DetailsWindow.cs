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
        private readonly Border switchThumb;
        private readonly TranslateTransform switchThumbTransform;
        private readonly System.Windows.Shapes.Path codexSwitchIcon;
        private readonly Canvas claudeSwitchIcon;
        private readonly StackPanel quotaGroup;
        private readonly StackPanel claudeGroup;
        private readonly Grid dataLayer;
        private readonly Grid claudeProjectRow;
        private readonly Grid claudeModelRow;
        private readonly Grid claudeTokenRow;
        private readonly Border claudeProjectSeparator;
        private readonly Border claudeModelSeparator;
        private readonly TextBlock claudeProjectTitle;
        private readonly TextBlock claudeModelTitle;
        private readonly TextBlock claudeTokenTitle;
        private readonly TextBlock claudeProjectValue;
        private readonly TextBlock claudeModelValue;
        private readonly TextBlock claudeTokenValue;
        private readonly RoundedMeter fiveHourBar;
        private readonly RoundedMeter weekBar;
        private readonly DispatcherTimer quotaTimer;
        private UsageMetrics previewMetrics;
        private ClaudeCodeMetrics previewClaudeMetrics;
        private bool showsMonthly;
        private AgentKind currentAgent;
        private AggregateSnapshot currentAggregate;
        private List<SessionSnapshot> currentSessions;

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
                out switchThumb, out switchThumbTransform,
                out codexSwitchIcon, out claudeSwitchIcon);
            switcher.HorizontalAlignment = HorizontalAlignment.Left;
            switcher.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(switcher);
            contextMeter = new ContextBatteryMeter
            {
                Width = 46,
                Height = 24,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetColumn(contextMeter, 2);
            top.Children.Add(contextMeter);
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

            claudeGroup = new StackPanel();
            claudeProjectRow = CreateInfoRow(L10n.Instance["metadata.project"], out claudeProjectTitle, out claudeProjectValue);
            claudeGroup.Children.Add(claudeProjectRow);
            claudeProjectSeparator = CreateInfoSeparator();
            claudeGroup.Children.Add(claudeProjectSeparator);
            claudeModelRow = CreateInfoRow(L10n.Instance["metadata.model"], out claudeModelTitle, out claudeModelValue);
            claudeGroup.Children.Add(claudeModelRow);
            claudeModelSeparator = CreateInfoSeparator();
            claudeGroup.Children.Add(claudeModelSeparator);
            claudeTokenRow = CreateInfoRow(L10n.Instance["metadata.tokens"], out claudeTokenTitle, out claudeTokenValue);
            claudeTokenValue.FontSize = 11.5;
            claudeTokenValue.FontWeight = FontWeights.SemiBold;
            claudeGroup.Children.Add(claudeTokenRow);

            dataLayer = new Grid();
            dataLayer.Height = 80;
            dataLayer.VerticalAlignment = VerticalAlignment.Top;
            dataLayer.Children.Add(quotaGroup);
            dataLayer.Children.Add(claudeGroup);
            content.Children.Add(dataLayer);

            Grid layers = new Grid();
            layers.Children.Add(content);
            shell.Child = layers;
            Content = shell;
            Closed += delegate { quotaTimer.Stop(); };
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
            quotaGroup.Visibility = currentAgent == AgentKind.Codex
                ? Visibility.Visible : Visibility.Hidden;
            claudeGroup.Visibility = currentAgent == AgentKind.ClaudeCode
                ? Visibility.Visible : Visibility.Hidden;
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
                return aggregate.FocusedAgent == AgentKind.ClaudeCode
                    ? L10n.Instance["status.offline_claude"] : L10n.Instance["status.offline_codex"];
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
            if (action.IndexOf("Writing answer", StringComparison.OrdinalIgnoreCase) >= 0)
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

        private void RefreshSupplementalData()
        {
            if (IsOfflineAggregate(currentAggregate))
            {
                ApplyOfflinePlaceholders();
                return;
            }
            contextMeter.Visibility = Visibility.Visible;
            if (currentAgent == AgentKind.ClaudeCode)
            {
                RefreshClaudeDetails();
            }
            else
            {
                RefreshQuota();
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

        private void ApplyOfflinePlaceholders()
        {
            if (currentAgent == AgentKind.ClaudeCode)
            {
                claudeProjectRow.Visibility = Visibility.Visible;
                claudeProjectSeparator.Visibility = Visibility.Visible;
                claudeModelSeparator.Visibility = Visibility.Visible;
                claudeModelRow.Margin = new Thickness(0);
                claudeTokenRow.Margin = new Thickness(0);
                claudeProjectValue.Text = "--";
                claudeModelValue.Text = "--";
                claudeTokenValue.Text = "--";
            }
            else
            {
                // Codex offline still surfaces the quota rows (rendered as
                // "quota.no_data"); only the context pill should drop out
                // since there's no live session to source a percentage from.
                RefreshQuota();
            }
            // Drop the context pill rather than echoing a percentage from the
            // session that just went offline. Done after RefreshQuota since
            // that path resets context-pill visibility.
            contextMeter.Visibility = Visibility.Collapsed;
        }

        private void RefreshClaudeDetails()
        {
            ClaudeCodeMetrics metrics = previewClaudeMetrics ?? ClaudeCodeMetricsReader.Read();
            SessionSnapshot primary = currentSessions == null ? null :
                currentSessions.FirstOrDefault(delegate(SessionSnapshot session)
                {
                    return session.Agent == AgentKind.ClaudeCode;
                });
            claudeProjectRow.Visibility = Visibility.Visible;
            claudeProjectSeparator.Visibility = Visibility.Visible;
            claudeModelSeparator.Visibility = Visibility.Visible;
            claudeModelRow.Margin = new Thickness(0);
            claudeTokenRow.Margin = new Thickness(0);
            claudeProjectValue.Text = metrics.HasSessionTitle
                ? metrics.SessionTitle
                : DisplayProjectName(primary);
            claudeModelValue.Text = metrics.HasModel ? metrics.Model : L10n.Instance["quota.no_data"];
            claudeTokenValue.Text = metrics.HasTokenUsage
                ? "↑ " + FormatCompactNumber(metrics.InputTokens) +
                  "  ·  ↓ " + FormatCompactNumber(metrics.OutputTokens)
                : L10n.Instance["quota.no_data"];
            SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
        }

        private static string DisplayProjectName(SessionSnapshot snapshot)
        {
            if (snapshot != null)
            {
                string leaf = ProjectLeaf(snapshot.WorkingDirectory);
                if (!String.IsNullOrWhiteSpace(leaf))
                {
                    return leaf;
                }
                if (!String.IsNullOrWhiteSpace(snapshot.ProjectName) &&
                    !String.Equals(snapshot.ProjectName, "Claude Code",
                        StringComparison.OrdinalIgnoreCase))
                {
                    return snapshot.ProjectName;
                }
            }
            return LatestClaudeSessionProjectName();
        }

        private static string LatestClaudeSessionProjectName()
        {
            string sessionsPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".claude", "sessions");
            if (!Directory.Exists(sessionsPath))
            {
                return "Claude Code";
            }
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            foreach (string file in Directory.GetFiles(sessionsPath, "*.json")
                .OrderByDescending(File.GetLastWriteTimeUtc).Take(8))
            {
                try
                {
                    Dictionary<string, object> data =
                        serializer.DeserializeObject(File.ReadAllText(file))
                        as Dictionary<string, object>;
                    if (data == null || !data.ContainsKey("cwd"))
                    {
                        continue;
                    }
                    string leaf = ProjectLeaf(Convert.ToString(data["cwd"],
                        CultureInfo.InvariantCulture));
                    if (!String.IsNullOrWhiteSpace(leaf))
                    {
                        return leaf;
                    }
                }
                catch
                {
                    // Ignore incomplete session files while Claude Code is updating them.
                }
            }
            return "Claude Code";
        }

        private static string ProjectLeaf(string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(workingDirectory))
            {
                return null;
            }
            string trimmed = workingDirectory.TrimEnd(
                Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string leaf = Path.GetFileName(trimmed);
            return String.IsNullOrWhiteSpace(leaf) ? null : leaf;
        }

        private void RefreshQuota()
        {
            UsageMetrics metrics;
            if (previewMetrics != null)
            {
                metrics = previewMetrics;
            }
            else if (!RateLimitReader.TryRead(out metrics))
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
                ApplyPlusQuota(new UsageMetrics { ContextInputTokens = -1 });
                SetContextPercent(false, 0);
            }
        }

        private void SetContextPercent(bool available, double value)
        {
            contextMeter.IsAvailable = available;
            contextMeter.Value = available
                ? Math.Max(0, Math.Min(100, Math.Round(value))) : 0;
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

        private void SelectAgent(AgentKind agent)
        {
            if (AgentSelected != null)
            {
                AgentSelected(agent);
            }
        }

        private void UpdateAgentSwitch()
        {
            bool codex = currentAgent == AgentKind.Codex;
            StyleCodexSwitch(codexSwitch, codexSwitchIcon, codex);
            StyleClaudeSwitch(claudeSwitch, claudeSwitchIcon, !codex);
            MoveSwitchThumb(codex);
        }

        private void MoveSwitchThumb(bool codexSelected)
        {
            double target = codexSelected ? 0 : 48;
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
            icon.Fill = CreateCodexGradientBrush();
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

        private void ApplyQuotaMetrics(UsageMetrics metrics)
        {
            if (metrics.HasPrimary && metrics.HasSecondary)
            {
                ApplyPlusQuota(metrics);
            }
            else if (metrics.HasMonthly)
            {
                ApplyMonthlyQuota(metrics, true);
            }
            else if (metrics.HasContext)
            {
                ApplyMonthlyQuota(metrics, false);
            }
            else
            {
                ApplyPlusQuota(metrics);
            }
        }

        private void ApplyPlusQuota(UsageMetrics metrics)
        {
            showsMonthly = false;
            quotaGroup.VerticalAlignment = VerticalAlignment.Center;
            fiveHourLabel.Text = L10n.Instance["quota.5h"];
            weekLabel.Text = L10n.Instance["quota.weekly"];
            fiveHourRow.Visibility = Visibility.Visible;
            weekRow.Visibility = Visibility.Visible;
            fiveHourRow.Margin = new Thickness(0);
            weekRow.Margin = new Thickness(0, 10, 0, 0);
            ApplyQuota(metrics.HasPrimary, metrics.PrimaryUsedPercent,
                metrics.PrimaryResetUtc, fiveHourValue, fiveHourReset, fiveHourBar);
            ApplyQuota(metrics.HasSecondary, metrics.SecondaryUsedPercent,
                metrics.SecondaryResetUtc, weekValue, weekReset, weekBar);
        }

        private void ApplyMonthlyQuota(UsageMetrics metrics, bool hasMonthlyData)
        {
            showsMonthly = true;
            quotaGroup.VerticalAlignment = VerticalAlignment.Center;
            fiveHourLabel.Text = L10n.Instance["quota.monthly"];
            fiveHourRow.Visibility = Visibility.Visible;
            weekRow.Visibility = Visibility.Collapsed;
            fiveHourRow.Margin = new Thickness(0);
            if (hasMonthlyData)
            {
                ApplyQuota(true, metrics.MonthlyUsedPercent,
                    metrics.MonthlyResetUtc, fiveHourValue, fiveHourReset, fiveHourBar);
            }
            else
            {
                ApplyQuotaPending(fiveHourValue, fiveHourReset, fiveHourBar);
            }
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

        private static void ApplyQuotaPending(TextBlock value, TextBlock reset,
            RoundedMeter bar)
        {
            value.Text = L10n.Instance["quota.waiting_refresh"];
            reset.Text = String.Empty;
            reset.Visibility = Visibility.Collapsed;
            bar.Value = 0;
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
            return local.ToString(format, culture);
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

        private static Border CreateInfoSeparator()
        {
            return new Border
            {
                Height = 1,
                Margin = new Thickness(0, 5, 0, 5),
                Background = new SolidColorBrush(MediaColor.FromArgb(58, 174, 189, 198))
            };
        }

        private static Grid CreateInfoRow(string title, out TextBlock titleBlock, out TextBlock value)
        {
            Grid grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            titleBlock = NewText(title, 12, MediaColor.FromRgb(99, 112, 120),
                FontWeights.Normal, true);
            grid.Children.Add(titleBlock);
            value = NewText(L10n.Instance["quota.no_data"], 12, MediaColor.FromRgb(48, 60, 68),
                FontWeights.SemiBold, true);
            value.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(value, 1);
            grid.Children.Add(value);
            return grid;
        }

        private const string CodexIconPath =
            "M9.064 3.344a4.578 4.578 0 012.285-.312c1 .115 1.891.54 2.673 1.275.01.01.024.017.037.021a.09.09 0 00.043 0 4.55 4.55 0 013.046.275l.047.022.116.057a4.581 4.581 0 012.188 2.399c.209.51.313 1.041.315 1.595a4.24 4.24 0 01-.134 1.223.123.123 0 00.03.115c.594.607.988 1.33 1.183 2.17.289 1.425-.007 2.71-.887 3.854l-.136.166a4.548 4.548 0 01-2.201 1.388.123.123 0 00-.081.076c-.191.551-.383 1.023-.74 1.494-.9 1.187-2.222 1.846-3.711 1.838-1.187-.006-2.239-.44-3.157-1.302a.107.107 0 00-.105-.024c-.388.125-.78.143-1.204.138a4.441 4.441 0 01-1.945-.466 4.544 4.544 0 01-1.61-1.335c-.152-.202-.303-.392-.414-.617a5.81 5.81 0 01-.37-.961 4.582 4.582 0 01-.014-2.298.124.124 0 00.006-.056.085.085 0 00-.027-.048 4.467 4.467 0 01-1.034-1.651 3.896 3.896 0 01-.251-1.192 5.189 5.189 0 01.141-1.6c.337-1.112.982-1.985 1.933-2.618.212-.141.413-.251.601-.33.215-.089.43-.164.646-.227a.098.098 0 00.065-.066 4.51 4.51 0 01.829-1.615 4.535 4.535 0 011.837-1.388zm3.482 10.565a.637.637 0 000 1.272h3.636a.637.637 0 100-1.272h-3.636zM8.462 9.23a.637.637 0 00-1.106.631l1.272 2.224-1.266 2.136a.636.636 0 101.095.649l1.454-2.455a.636.636 0 00.005-.64L8.462 9.23z";

        private const string ClaudeCodeIconPath =
            "M6.9 2.7h10.2c.9 0 1.6.7 1.6 1.6v3.4h2.4c.8 0 1.4.6 1.4 1.4v3.9c0 .8-.6 1.4-1.4 1.4h-2.4v6.9h-3.2v-6.9h-2.1v6.9h-2.8v-6.9H8.5v6.9H5.3v-6.9H2.9c-.8 0-1.4-.6-1.4-1.4V9.1c0-.8.6-1.4 1.4-1.4h2.4V4.3c0-.9.7-1.6 1.6-1.6z";

        private Grid CreateAgentSwitch(out Border codexBorder,
            out Border claudeBorder, out Border thumb,
            out TranslateTransform thumbTransform,
            out System.Windows.Shapes.Path codexIcon,
            out Canvas claudeIcon)
        {
            Grid shell = new Grid();
            shell.Width = 98;
            shell.Height = 32;
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            Border background = new Border
            {
                CornerRadius = new CornerRadius(16),
                Background = new SolidColorBrush(MediaColor.FromRgb(244, 248, 250)),
                BorderBrush = new SolidColorBrush(MediaColor.FromRgb(221, 233, 238)),
                BorderThickness = new Thickness(1)
            };
            Grid.SetColumnSpan(background, 2);
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
            Grid.SetColumnSpan(thumb, 2);
            shell.Children.Add(thumb);

            Grid hitLayer = new Grid();
            hitLayer.ColumnDefinitions.Add(new ColumnDefinition());
            hitLayer.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumnSpan(hitLayer, 2);

            Viewbox codexIconBox = CreateSwitchIcon(CodexIconPath, 24, 24, 21,
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
            shell.Children.Add(hitLayer);
            return shell;
        }

        private static Viewbox CreateSwitchIcon(string pathData, double sourceWidth,
            double sourceHeight, double displaySize,
            out System.Windows.Shapes.Path icon)
        {
            Canvas canvas = new Canvas
            {
                Width = sourceWidth,
                Height = sourceHeight
            };
            icon = new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse(pathData),
                Fill = new SolidColorBrush(MediaColor.FromRgb(18, 42, 58)),
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

        private static MediaBrush CreateCodexGradientBrush()
        {
            System.Windows.Media.LinearGradientBrush brush =
                new System.Windows.Media.LinearGradientBrush();
            brush.StartPoint = new MediaPoint(0, 0);
            brush.EndPoint = new MediaPoint(0, 1);
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromRgb(177, 167, 255), 0));
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromRgb(122, 157, 255), 0.5));
            brush.GradientStops.Add(new GradientStop(
                MediaColor.FromRgb(57, 65, 255), 1));
            return brush;
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
            fiveHourLabel.Text = showsMonthly
                ? L10n.Instance["quota.monthly"]
                : L10n.Instance["quota.5h"];
            weekLabel.Text = L10n.Instance["quota.weekly"];
            claudeProjectTitle.Text = L10n.Instance["metadata.project"];
            claudeModelTitle.Text = L10n.Instance["metadata.model"];
            claudeTokenTitle.Text = L10n.Instance["metadata.tokens"];
            if (currentAggregate != null)
                UpdateContent(currentAggregate, currentSessions);
        }
    }
}
