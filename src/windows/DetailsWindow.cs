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
                    new SolidColorBrush(MediaColor.FromRgb(73, 174, 201)), null,
                    new Rect(0, 0, Math.Max(height, fill), height), radius, radius);
            }
        }
    }

public sealed class DetailsWindow : Window
    {
        private readonly TextBlock headline;
        private readonly TextBlock subtitle;
        private readonly Border shell;
        private readonly TextBlock fiveHourValue;
        private readonly TextBlock weekValue;
        private readonly TextBlock fiveHourReset;
        private readonly TextBlock weekReset;
        private readonly TextBlock contextLabel;
        private readonly TextBlock contextHundredsDigit;
        private readonly TextBlock contextTensDigit;
        private readonly TextBlock contextOnesDigit;
        private readonly TextBlock contextPercentMark;
        private readonly TextBlock contextUnavailableValue;
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
        private readonly Border claudeSeparator;
        private readonly TextBlock claudeProjectValue;
        private readonly TextBlock claudeModelValue;
        private readonly TextBlock claudeTokenValue;
        private readonly RoundedMeter fiveHourBar;
        private readonly RoundedMeter weekBar;
        private readonly DispatcherTimer quotaTimer;
        private UsageMetrics previewMetrics;
        private ClaudeCodeMetrics previewClaudeMetrics;
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
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;

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
            Border contextPill = new Border
            {
                Width = 90,
                Height = 26,
                CornerRadius = new CornerRadius(13),
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(MediaColor.FromArgb(68, 100, 194, 216)),
                BorderBrush = new SolidColorBrush(MediaColor.FromArgb(70, 83, 174, 197)),
                BorderThickness = new Thickness(1)
            };
            Grid contextGrid = new Grid();
            contextGrid.Width = 74;
            contextGrid.HorizontalAlignment = HorizontalAlignment.Center;
            contextGrid.Margin = new Thickness(7, 0, 7, 0);
            contextGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(38) });
            contextGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2) });
            contextGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
            contextLabel = NewText("上下文", 11.5, MediaColor.FromRgb(53, 125, 145),
                FontWeights.Normal, true);
            contextLabel.HorizontalAlignment = HorizontalAlignment.Right;
            contextLabel.VerticalAlignment = VerticalAlignment.Center;
            contextGrid.Children.Add(contextLabel);
            Grid contextValueGrid = CreateContextValueGrid(out contextHundredsDigit,
                out contextTensDigit, out contextOnesDigit, out contextPercentMark,
                out contextUnavailableValue);
            Grid.SetColumn(contextValueGrid, 2);
            contextGrid.Children.Add(contextValueGrid);
            contextPill.Child = contextGrid;
            Grid.SetColumn(contextPill, 2);
            top.Children.Add(contextPill);
            top.Margin = new Thickness(0, 0, 0, 7);
            content.Children.Add(top);

            headline = NewText("READY", 20, MediaColor.FromRgb(40, 52, 60),
                FontWeights.Bold);
            content.Children.Add(headline);
            subtitle = NewText("Codex is standing by", 13,
                MediaColor.FromRgb(103, 117, 126), FontWeights.Normal, true);
            subtitle.Margin = new Thickness(0, 1, 0, 11);
            content.Children.Add(subtitle);

            quotaGroup = new StackPanel();
            Grid fiveHour = CreateQuotaRow("5 小时额度", out fiveHourReset,
                out fiveHourValue, out fiveHourBar);
            quotaGroup.Children.Add(fiveHour);
            Grid week = CreateQuotaRow("周额度", out weekReset, out weekValue, out weekBar);
            week.Margin = new Thickness(0, 8, 0, 0);
            quotaGroup.Children.Add(week);

            claudeGroup = new StackPanel();
            claudeProjectRow = CreateInfoRow("项目", out claudeProjectValue);
            claudeGroup.Children.Add(claudeProjectRow);
            claudeModelRow = CreateInfoRow("模型", out claudeModelValue);
            claudeModelRow.Margin = new Thickness(0, 8, 0, 0);
            claudeGroup.Children.Add(claudeModelRow);
            claudeSeparator = new Border
            {
                Height = 1,
                Margin = new Thickness(0, 11, 0, 0),
                Background = new SolidColorBrush(MediaColor.FromArgb(68, 174, 189, 198))
            };
            claudeGroup.Children.Add(claudeSeparator);
            claudeTokenRow = CreateInfoRow("Token", out claudeTokenValue);
            claudeTokenRow.Margin = new Thickness(0, 11, 0, 0);
            claudeTokenValue.FontSize = 11.5;
            claudeTokenValue.FontWeight = FontWeights.Medium;
            claudeGroup.Children.Add(claudeTokenRow);

            dataLayer = new Grid();
            dataLayer.Height = 64;
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
            SessionSnapshot active = sessions.FirstOrDefault(delegate(SessionSnapshot session)
            {
                return session.Active;
            });
            string action = active == null ? String.Empty : active.Action;
            if (aggregate.AnswerStreaming ||
                action.IndexOf("Writing answer", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在输出答案";
            }
            if (action.IndexOf("command", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在执行命令";
            }
            if (action.IndexOf("Editing", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在编辑文件";
            }
            if (action.IndexOf("Search", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在搜索信息";
            }
            if (action.IndexOf("Compressing context", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在压缩上下文";
            }
            if (action.IndexOf("Context compacted", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "上下文压缩完成";
            }
            if (action.IndexOf("Awaiting permission", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "等待你的授权";
            }
            if (action.IndexOf("Reviewing result", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在分析结果";
            }
            switch (aggregate.State)
            {
                case HaloState.Thinking: return "正在思考与规划";
                case HaloState.Working: return "正在执行任务";
                case HaloState.Done: return "任务已完成";
                case HaloState.Attention: return "等待你的授权或输入";
                case HaloState.Error:
                    return String.IsNullOrEmpty(aggregate.Detail)
                        ? "任务已中断" : aggregate.Detail;
                default:
                    return aggregate.FocusedAgent == AgentKind.ClaudeCode
                        ? "Claude Code 正在待命" : "Codex 正在待命";
            }
        }

        private void RefreshSupplementalData()
        {
            if (currentAgent == AgentKind.ClaudeCode)
            {
                RefreshClaudeDetails();
            }
            else
            {
                RefreshQuota();
            }
        }

        private void RefreshClaudeDetails()
        {
            ClaudeCodeMetrics metrics = previewClaudeMetrics ?? ClaudeCodeMetricsReader.Read();
            SessionSnapshot primary = currentSessions == null ? null :
                currentSessions.FirstOrDefault(delegate(SessionSnapshot session)
                {
                    return session.Agent == AgentKind.ClaudeCode;
                });
            bool showProject = !metrics.IsCustomApi;
            claudeProjectRow.Visibility = showProject
                ? Visibility.Visible : Visibility.Collapsed;
            claudeModelRow.Margin = showProject
                ? new Thickness(0, 8, 0, 0) : new Thickness(0);
            claudeSeparator.Margin = showProject
                ? new Thickness(0, 11, 0, 0) : new Thickness(0, 11, 0, 0);
            claudeTokenRow.Margin = new Thickness(0, 11, 0, 0);
            claudeProjectValue.Text = primary == null ||
                String.IsNullOrWhiteSpace(primary.ProjectName)
                ? "Claude Code" : primary.ProjectName;
            claudeModelValue.Text = metrics.HasModel ? metrics.Model : "暂无数据";
            claudeTokenValue.Text = metrics.HasTokenUsage
                ? "输入 " + FormatCompactNumber(metrics.InputTokens) +
                  " · 输出 " + FormatCompactNumber(metrics.OutputTokens)
                : "暂无数据";
            SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
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
                ApplyQuota(metrics.HasPrimary, metrics.PrimaryUsedPercent,
                    metrics.PrimaryResetUtc, fiveHourValue, fiveHourReset, fiveHourBar);
                ApplyQuota(metrics.HasSecondary, metrics.SecondaryUsedPercent,
                    metrics.SecondaryResetUtc, weekValue, weekReset, weekBar);
                SetContextPercent(metrics.HasContext, metrics.ContextUsedPercent);
            }
            else
            {
                fiveHourValue.Text = "暂无数据";
                weekValue.Text = "暂无数据";
                fiveHourReset.Text = String.Empty;
                weekReset.Text = String.Empty;
                fiveHourReset.Visibility = Visibility.Collapsed;
                weekReset.Visibility = Visibility.Collapsed;
                SetContextPercent(false, 0);
                fiveHourBar.Value = 0;
                weekBar.Value = 0;
            }
        }

        private void SetContextPercent(bool available, double value)
        {
            contextHundredsDigit.Text = String.Empty;
            contextTensDigit.Text = String.Empty;
            contextOnesDigit.Text = String.Empty;
            contextPercentMark.Text = String.Empty;
            contextUnavailableValue.Visibility = Visibility.Collapsed;
            if (!available)
            {
                contextUnavailableValue.Visibility = Visibility.Visible;
                return;
            }

            int rounded = (int)Math.Round(value);
            rounded = Math.Max(0, Math.Min(100, rounded));
            string digits = rounded.ToString(CultureInfo.InvariantCulture);
            if (digits.Length == 3)
            {
                contextHundredsDigit.Text = digits.Substring(0, 1);
                contextTensDigit.Text = digits.Substring(1, 1);
                contextOnesDigit.Text = digits.Substring(2, 1);
            }
            else if (digits.Length == 2)
            {
                contextTensDigit.Text = digits.Substring(0, 1);
                contextOnesDigit.Text = digits.Substring(1, 1);
            }
            else
            {
                contextOnesDigit.Text = digits;
            }
            contextPercentMark.Text = "%";
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

        private static void ApplyQuota(bool available, double usedPercent,
            DateTime resetUtc, TextBlock value, TextBlock reset, RoundedMeter bar)
        {
            if (!available)
            {
                value.Text = "暂无数据";
                reset.Text = String.Empty;
                reset.Visibility = Visibility.Collapsed;
                bar.Value = 0;
                return;
            }
            if (IsQuotaExpired(resetUtc, DateTime.UtcNow))
            {
                value.Text = "等待 Codex 刷新";
                reset.Text = String.Empty;
                reset.Visibility = Visibility.Collapsed;
                bar.Value = 0;
                return;
            }
            double remaining = Math.Max(0, Math.Min(100, 100 - usedPercent));
            value.Text = String.Format(CultureInfo.InvariantCulture,
                "剩余 {0:0}%", remaining);
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
            return local.Date == DateTime.Now.Date
                ? local.ToString("HH:mm '刷新'", CultureInfo.CurrentCulture)
                : local.ToString("M月d日 HH:mm '刷新'", CultureInfo.CurrentCulture);
        }

        private static Grid CreateQuotaRow(string title, out TextBlock reset,
            out TextBlock value, out RoundedMeter bar)
        {
            Grid grid = new Grid();
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid labels = new Grid();
            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            labels.ColumnDefinitions.Add(new ColumnDefinition());
            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock name = NewText(title, 12, MediaColor.FromRgb(99, 112, 120),
                FontWeights.Normal, true);
            labels.Children.Add(name);
            reset = NewText(String.Empty, 10.5, MediaColor.FromRgb(130, 145, 153),
                FontWeights.Normal, true);
            reset.Margin = new Thickness(6, 1, 6, 0);
            reset.VerticalAlignment = VerticalAlignment.Center;
            reset.Visibility = Visibility.Collapsed;
            Grid.SetColumn(reset, 1);
            labels.Children.Add(reset);
            value = NewText("暂无数据", 12, MediaColor.FromRgb(48, 60, 68),
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

        private static Grid CreateInfoRow(string title, out TextBlock value)
        {
            Grid grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            TextBlock name = NewText(title, 12, MediaColor.FromRgb(99, 112, 120),
                FontWeights.Normal, true);
            grid.Children.Add(name);
            value = NewText("暂无数据", 12, MediaColor.FromRgb(48, 60, 68),
                FontWeights.SemiBold, true);
            value.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(value, 1);
            grid.Children.Add(value);
            return grid;
        }

        private static Grid CreateContextValueGrid(out TextBlock hundreds,
            out TextBlock tens, out TextBlock ones, out TextBlock percent,
            out TextBlock unavailable)
        {
            Grid layer = new Grid
            {
                Width = 34,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid digits = new Grid();
            digits.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
            digits.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
            digits.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
            digits.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(13) });
            hundreds = NewContextDigitText();
            tens = NewContextDigitText();
            ones = NewContextDigitText();
            percent = NewContextDigitText();
            digits.Children.Add(hundreds);
            Grid.SetColumn(tens, 1);
            digits.Children.Add(tens);
            Grid.SetColumn(ones, 2);
            digits.Children.Add(ones);
            Grid.SetColumn(percent, 3);
            percent.HorizontalAlignment = HorizontalAlignment.Left;
            digits.Children.Add(percent);
            layer.Children.Add(digits);

            unavailable = NewText("--", 12.5, MediaColor.FromRgb(45, 118, 139),
                FontWeights.SemiBold, false);
            unavailable.HorizontalAlignment = HorizontalAlignment.Center;
            unavailable.VerticalAlignment = VerticalAlignment.Center;
            unavailable.Visibility = Visibility.Collapsed;
            layer.Children.Add(unavailable);
            return layer;
        }

        private static TextBlock NewContextDigitText()
        {
            TextBlock block = NewText(String.Empty, 12.5,
                MediaColor.FromRgb(45, 118, 139), FontWeights.SemiBold, false);
            block.HorizontalAlignment = HorizontalAlignment.Center;
            block.VerticalAlignment = VerticalAlignment.Center;
            block.TextAlignment = TextAlignment.Center;
            block.TextTrimming = TextTrimming.None;
            block.FontFamily = new System.Windows.Media.FontFamily(
                "Segoe UI Variable Text, Segoe UI");
            Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
            return block;
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
    }
}
