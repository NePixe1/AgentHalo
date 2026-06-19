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
        private readonly TextBlock contextValue;
        private readonly RoundedMeter fiveHourBar;
        private readonly RoundedMeter weekBar;
        private readonly DispatcherTimer quotaTimer;
        private UsageMetrics previewMetrics;

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
            shell.Padding = new Thickness(17, 13, 17, 14);
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
            top.ColumnDefinitions.Add(new ColumnDefinition());
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock brand = NewText("Agent Halo", 11.5, MediaColor.FromRgb(101, 119, 129),
                FontWeights.SemiBold);
            brand.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(brand);
            Border contextPill = new Border
            {
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(8, 3, 8, 3),
                Background = new SolidColorBrush(MediaColor.FromArgb(78, 100, 194, 216)),
                BorderBrush = new SolidColorBrush(MediaColor.FromArgb(80, 83, 174, 197)),
                BorderThickness = new Thickness(1)
            };
            contextValue = NewText("上下文 --", 10.5, MediaColor.FromRgb(53, 125, 145),
                FontWeights.Normal, true);
            contextPill.Child = contextValue;
            Grid.SetColumn(contextPill, 1);
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

            Grid fiveHour = CreateQuotaRow("5 小时额度", out fiveHourReset,
                out fiveHourValue, out fiveHourBar);
            content.Children.Add(fiveHour);
            Grid week = CreateQuotaRow("周额度", out weekReset, out weekValue, out weekBar);
            week.Margin = new Thickness(0, 8, 0, 0);
            content.Children.Add(week);

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
                    RefreshQuota();
                }
            };
            quotaTimer.Start();
        }

        public void UpdateContent(AggregateSnapshot aggregate, List<SessionSnapshot> sessions)
        {
            headline.Text = aggregate.Label;
            MediaColor accent = HaloVisual.StateColor(aggregate.State);
            headline.Foreground = new SolidColorBrush(accent);
            subtitle.Text = FriendlyStatusDetail(aggregate, sessions);
            RefreshQuota();
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
            switch (aggregate.State)
            {
                case HaloState.Thinking: return "正在思考与规划";
                case HaloState.Working: return "正在执行任务";
                case HaloState.Done: return "任务已完成";
                case HaloState.Attention: return "等待你的授权或输入";
                case HaloState.Error:
                    return String.IsNullOrEmpty(aggregate.Detail)
                        ? "任务已中断" : aggregate.Detail;
                default: return "Codex 正在待命";
            }
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
                contextValue.Text = metrics.HasContext
                    ? String.Format(CultureInfo.InvariantCulture, "上下文 {0:0}%",
                        metrics.ContextUsedPercent)
                    : "上下文 --";
            }
            else
            {
                fiveHourValue.Text = "暂无数据";
                weekValue.Text = "暂无数据";
                fiveHourReset.Text = String.Empty;
                weekReset.Text = String.Empty;
                fiveHourReset.Visibility = Visibility.Collapsed;
                weekReset.Visibility = Visibility.Collapsed;
                contextValue.Text = "上下文 --";
                fiveHourBar.Value = 0;
                weekBar.Value = 0;
            }
        }

        public void SetPreviewMetrics(UsageMetrics metrics)
        {
            previewMetrics = metrics;
            RefreshQuota();
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

