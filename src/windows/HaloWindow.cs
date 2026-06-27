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
public sealed class HaloWindow : Window
    {
        private const double HaloSize = 112;
        private static readonly int[] HaloScalePresets = { 75, 100, 125 };
        private readonly HaloSettings settings;
        private readonly CodexSessionMonitor monitor;
        private readonly ClaudeHookStatusMonitor claudeMonitor;
        private readonly ClaudeTranscriptSessionMonitor claudeTranscriptMonitor;
        private readonly HaloVisual visual;
        private readonly DetailsWindow details;
        private readonly Forms.NotifyIcon tray;
        private readonly DispatcherTimer foregroundTimer;
        private readonly DispatcherTimer hoverHideTimer;
        private readonly DispatcherTimer performanceTimer;
        private AggregateSnapshot aggregate;
        private AggregateSnapshot displayAggregate;
        private MediaPoint dragStart;
        private MediaPoint windowStart;
        private bool dragging;
        private bool moved;
        private HaloState? demoState;
        private ErrorPresentation? demoErrorPresentation;
        private bool codexWasForeground;
        private DateTime activeErrorUtc;
        private DateTime errorDimmedUtc;
        private ErrorPresentation errorPresentation = ErrorPresentation.Flashing;
        private Forms.ToolStripMenuItem codexAgentItem;
        private Forms.ToolStripMenuItem claudeAgentItem;

        public HaloWindow(HaloSettings appSettings)
        {
            settings = appSettings;
            double initialSize = SizeForScale(settings.HaloScalePercent);
            Width = initialSize;
            Height = initialSize;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = System.Windows.Media.Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = settings.AlwaysOnTop;
            Title = "Agent Halo";

            visual = new HaloVisual();
            Grid hitSurface = new Grid();
            hitSurface.Background = System.Windows.Media.Brushes.Transparent;
            Border centerHitSurface = new Border();
            centerHitSurface.Width = 64;
            centerHitSurface.Height = 64;
            centerHitSurface.CornerRadius = new CornerRadius(32);
            centerHitSurface.HorizontalAlignment = HorizontalAlignment.Center;
            centerHitSurface.VerticalAlignment = VerticalAlignment.Center;
            centerHitSurface.Background = new SolidColorBrush(
                MediaColor.FromArgb(1, 255, 255, 255));
            hitSurface.Children.Add(centerHitSurface);
            hitSurface.Children.Add(visual);
            Content = hitSurface;
            details = new DetailsWindow();
            details.AgentSelected += delegate(AgentKind agent)
            {
                Dispatcher.BeginInvoke(new Action(delegate { SetFocusedAgent(agent); }));
            };
            monitor = new CodexSessionMonitor();
            claudeMonitor = new ClaudeHookStatusMonitor();
            claudeTranscriptMonitor = new ClaudeTranscriptSessionMonitor();
            monitor.Changed += delegate { RefreshState(); };
            foregroundTimer = new DispatcherTimer(DispatcherPriority.Background);
            foregroundTimer.Interval = TimeSpan.FromMilliseconds(300);
            foregroundTimer.Tick += OnForegroundTick;
            hoverHideTimer = new DispatcherTimer();
            hoverHideTimer.Interval = TimeSpan.FromMilliseconds(220);
            hoverHideTimer.Tick += delegate
            {
                hoverHideTimer.Stop();
                if (!IsMouseOver && !details.IsMouseOver)
                {
                    details.Hide();
                }
            };
            string performanceLogPath = Environment.GetEnvironmentVariable(
                "AGENTHALO_PERF_LOG");
            if (!String.IsNullOrWhiteSpace(performanceLogPath))
            {
                performanceTimer = new DispatcherTimer(DispatcherPriority.Background);
                performanceTimer.Interval = TimeSpan.FromSeconds(5);
                performanceTimer.Tick += delegate
                {
                    File.WriteAllText(performanceLogPath,
                        DateTime.Now.ToString("o", CultureInfo.InvariantCulture) +
                        Environment.NewLine + visual.PerformanceSummary,
                        Encoding.UTF8);
                };
            }
            MouseEnter += delegate
            {
                hoverHideTimer.Stop();
                ShowHoverDetails();
            };
            MouseLeave += delegate
            {
                hoverHideTimer.Stop();
                hoverHideTimer.Start();
            };
            details.MouseEnter += delegate { hoverHideTimer.Stop(); };
            details.MouseLeave += delegate
            {
                hoverHideTimer.Stop();
                hoverHideTimer.Start();
            };

            MouseLeftButtonDown += OnMouseDown;
            MouseMove += OnMouseMove;
            MouseLeftButtonUp += OnMouseUp;
            MouseRightButtonUp += delegate
            {
                if (tray.ContextMenuStrip != null)
                {
                    tray.ContextMenuStrip.Show(Forms.Control.MousePosition);
                }
            };
            MouseDoubleClick += OnDoubleClick;
            SourceInitialized += OnSourceInitialized;
            Loaded += OnLoaded;
            Closing += OnClosing;
            SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

            tray = new Forms.NotifyIcon();
            tray.Text = "Agent Halo";
            tray.Icon = CreateTrayIcon(DrawingColor.FromArgb(43, 200, 255));
            tray.Visible = true;
            tray.DoubleClick += delegate
            {
                Dispatcher.BeginInvoke(new Action(ToggleDetails));
            };
            BuildTrayMenu();

            L10n.Instance.LanguageChanged += (s, ev) =>
            {
                Dispatcher.Invoke(new Action(BuildTrayMenu));
            };
        }

        public static bool IsValidScalePercent(int value)
        {
            return HaloScalePresets.Contains(value);
        }

        private static double SizeForScale(int percent)
        {
            return HaloSize * percent / 100.0;
        }

        public static double DiagnosticSizeForScale(int percent)
        {
            return SizeForScale(IsValidScalePercent(percent) ? percent : 100);
        }

        public static bool DiagnosticIsFrameVisible(
            System.Drawing.Rectangle frame,
            IEnumerable<System.Drawing.Rectangle> workingAreas)
        {
            return workingAreas.Any(delegate(System.Drawing.Rectangle area)
            {
                return area.IntersectsWith(frame);
            });
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            ClaudeHookConfigurator.Configure();
            RestorePosition();
            RecoverHaloIfOffscreen();
            monitor.Start();
            RefreshState();
            codexWasForeground = IsCodexForeground();
            foregroundTimer.Start();
            if (performanceTimer != null)
            {
                visual.ResetPerformanceMetrics();
                performanceTimer.Start();
            }
        }

        private void OnDisplaySettingsChanged(object sender, EventArgs e)
        {
            if (!Dispatcher.HasShutdownStarted)
            {
                Dispatcher.BeginInvoke(new Action(RecoverHaloIfOffscreen));
            }
        }

        private void OnForegroundTick(object sender, EventArgs e)
        {
            bool claudeChanged = claudeMonitor.Refresh();
            claudeChanged = claudeTranscriptMonitor.Refresh() || claudeChanged;
            if (claudeChanged && settings.GetFocusedAgent() == AgentKind.ClaudeCode)
            {
                RefreshState();
            }
            bool codexIsForeground = IsCodexForeground();
            if (settings.GetFocusedAgent() == AgentKind.Codex &&
                codexIsForeground && !codexWasForeground && !demoState.HasValue &&
                aggregate != null && aggregate.State == HaloState.Done)
            {
                AcknowledgeCompleted();
            }
            if (aggregate != null && aggregate.State == HaloState.Error)
            {
                if (codexIsForeground)
                {
                    errorPresentation = ErrorPresentation.Bright;
                }
                else if (codexWasForeground)
                {
                    errorPresentation = ErrorPresentation.Dim;
                    errorDimmedUtc = DateTime.UtcNow;
                }
            }
            if (codexIsForeground != codexWasForeground ||
                errorPresentation == ErrorPresentation.Dim)
            {
                RefreshState();
            }
            codexWasForeground = codexIsForeground;
        }

        private static bool IsCodexForeground()
        {
            try
            {
                IntPtr handle = GetForegroundWindow();
                if (handle == IntPtr.Zero)
                {
                    return false;
                }
                uint processId;
                GetWindowThreadProcessId(handle, out processId);
                Process process = Process.GetProcessById((int)processId);
                return process.ProcessName.IndexOf("codex",
                           StringComparison.OrdinalIgnoreCase) >= 0 ||
                       process.MainWindowTitle.IndexOf("codex",
                           StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch
            {
                return false;
            }
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            int style = GetWindowLong(handle, -20);
            SetWindowLong(handle, -20, style | 0x08000000 | 0x00000080);
        }

        private void RestorePosition()
        {
            Rect area = GetWorkAreaDip();
            if (settings.HasPosition)
            {
                Left = Math.Max(area.Left - Width + 24, Math.Min(settings.Left, area.Right - 24));
                Top = Math.Max(area.Top - Height + 24, Math.Min(settings.Top, area.Bottom - 24));
            }
            else
            {
                Left = area.Right - Width - 28;
                Top = area.Top + 110;
            }
        }

        private void RefreshState()
        {
            if (settings.GetFocusedAgent() == AgentKind.ClaudeCode)
            {
                claudeMonitor.Refresh();
                claudeTranscriptMonitor.Refresh();
                aggregate = GetClaudeAggregate();
                if (demoState.HasValue)
                {
                    aggregate.State = demoState.Value;
                    aggregate.Label = CodexSessionMonitor.StateLabel(demoState.Value);
                    aggregate.Detail = "Preview mode";
                }
                int claudeCount = aggregate.Sessions == null ? 0 : aggregate.Sessions.Count;
                bool showClaudeStandby = !demoState.HasValue &&
                    aggregate.State == HaloState.Idle &&
                    ClaudeLiveSessionReader.HasStandbySession();
                visual.SetSteadyDone(showClaudeStandby);
                visual.SetErrorPresentation(demoErrorPresentation ?? ErrorPresentation.Flashing);
                visual.SetState(showClaudeStandby ? HaloState.Done : aggregate.State,
                    showClaudeStandby ? "STANDBY" : aggregate.Label, claudeCount);
                visual.SetAnswerStreaming(false);
                AggregateSnapshot claudeDisplayAggregate = aggregate;
                if (showClaudeStandby)
                {
                    claudeDisplayAggregate = new AggregateSnapshot
                    {
                        State = HaloState.Done,
                        Label = "STANDBY",
                        Detail = L10n.Instance["status.standby_claude"],
                        Sessions = aggregate.Sessions,
                        AnswerStreaming = false,
                        FocusedAgent = AgentKind.ClaudeCode
                    };
                }
                displayAggregate = claudeDisplayAggregate;
                tray.Text = ("Agent Halo · " + claudeDisplayAggregate.Label).Substring(0,
                    Math.Min(63, ("Agent Halo · " + claudeDisplayAggregate.Label).Length));
                details.UpdateContent(claudeDisplayAggregate, aggregate.Sessions);
                UpdateAgentMenuChecks();
                return;
            }

            aggregate = monitor.GetAggregate(settings);
            bool codexRunning = CodexRuntimeReader.IsRunning();
            string appFailure;
            DateTime appFailureUtc;
            if (codexRunning && aggregate.State == HaloState.Idle &&
                CodexFailureReader.TryReadRecent(out appFailure, out appFailureUtc) &&
                appFailureUtc > settings.GetAcknowledgedErrorUtc())
            {
                aggregate.State = HaloState.Error;
                aggregate.Label = CodexSessionMonitor.StateLabel(HaloState.Error);
                aggregate.Detail = appFailure;
                aggregate.Sessions.Add(new SessionSnapshot
                {
                    ThreadId = "codex-app",
                    ProjectName = "Codex",
                    Agent = AgentKind.Codex,
                    State = HaloState.Error,
                    Action = appFailure,
                    LastEventUtc = appFailureUtc,
                    Active = false
                });
            }
            if (aggregate.State == HaloState.Error)
            {
                DateTime previousErrorUtc = activeErrorUtc;
                SessionSnapshot latestError = aggregate.Sessions
                    .Where(delegate(SessionSnapshot session)
                    {
                        return session.State == HaloState.Error;
                    })
                    .OrderByDescending(delegate(SessionSnapshot session)
                    {
                        return session.LastEventUtc;
                    }).FirstOrDefault();
                activeErrorUtc = latestError == null ? DateTime.UtcNow : latestError.LastEventUtc;
                if (activeErrorUtc <= settings.GetAcknowledgedErrorUtc())
                {
                    aggregate.State = HaloState.Idle;
                }
                else if (activeErrorUtc > previousErrorUtc)
                {
                    errorPresentation = IsCodexForeground()
                        ? ErrorPresentation.Bright : ErrorPresentation.Flashing;
                }
                else if (IsCodexForeground())
                {
                    errorPresentation = ErrorPresentation.Bright;
                }
                else if (errorPresentation != ErrorPresentation.Dim)
                {
                    errorPresentation = ErrorPresentation.Flashing;
                }
            }
            if (errorPresentation == ErrorPresentation.Dim &&
                DateTime.UtcNow - errorDimmedUtc >= TimeSpan.FromMinutes(1))
            {
                settings.AcknowledgedErrorAt = activeErrorUtc.ToString("o");
                SettingsStorage.Save(settings);
                errorPresentation = ErrorPresentation.Flashing;
                aggregate.State = HaloState.Idle;
            }
            if (demoState.HasValue)
            {
                aggregate.State = demoState.Value;
                aggregate.Label = CodexSessionMonitor.StateLabel(demoState.Value);
                aggregate.Detail = "Preview mode";
            }
            int count = aggregate.Sessions == null ? 0 : aggregate.Sessions.Count;
            bool showGreenStandby = !demoState.HasValue && codexRunning &&
                aggregate.State == HaloState.Idle;
            visual.SetSteadyDone(showGreenStandby);
            visual.SetErrorPresentation(demoErrorPresentation ?? errorPresentation);
            visual.SetState(showGreenStandby ? HaloState.Done : aggregate.State,
                showGreenStandby ? "STANDBY" : aggregate.Label, count);
            visual.SetAnswerStreaming(false);
            AggregateSnapshot codexDisplayAggregate = aggregate;
            if (showGreenStandby)
            {
                codexDisplayAggregate = new AggregateSnapshot
                {
                    State = HaloState.Done,
                    Label = "STANDBY",
                    Detail = L10n.Instance["status.standby_codex"],
                    Sessions = aggregate.Sessions,
                    AnswerStreaming = false,
                    FocusedAgent = AgentKind.Codex
                };
            }
            displayAggregate = codexDisplayAggregate;
            tray.Text = ("Agent Halo · " + codexDisplayAggregate.Label).Substring(0,
                Math.Min(63, ("Agent Halo · " + codexDisplayAggregate.Label).Length));
            details.UpdateContent(codexDisplayAggregate, monitor.GetAllRecent());
            UpdateAgentMenuChecks();
        }

        private void OnMouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton != MouseButton.Left)
            {
                return;
            }
            dragStart = GetCursorDip();
            windowStart = new MediaPoint(Left, Top);
            dragging = true;
            moved = false;
            CaptureMouse();
        }

        private void OnMouseMove(object sender, MouseEventArgs e)
        {
            if (!dragging || e.LeftButton != MouseButtonState.Pressed)
            {
                return;
            }
            MediaPoint current = GetCursorDip();
            double dx = current.X - dragStart.X;
            double dy = current.Y - dragStart.Y;
            if (Math.Abs(dx) + Math.Abs(dy) > 4)
            {
                moved = true;
            }
            Left = windowStart.X + dx;
            Top = windowStart.Y + dy;
            if (details.IsVisible)
            {
                PositionDetails();
            }
        }

        private void OnMouseUp(object sender, MouseButtonEventArgs e)
        {
            if (!dragging)
            {
                return;
            }
            dragging = false;
            ReleaseMouseCapture();
            if (moved)
            {
                SnapToEdges();
                SavePosition();
            }
        }

        private void OnDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (settings.GetFocusedAgent() == AgentKind.Codex)
            {
                BringCodexForward();
            }
            e.Handled = true;
        }

        private void ToggleDetails()
        {
            if (details.IsVisible)
            {
                details.Hide();
            }
            else
            {
                ShowOrRefreshDetails(true);
            }
        }

        private void ShowHoverDetails()
        {
            ShowOrRefreshDetails(false);
        }

        private void ShowOrRefreshDetails(bool activate)
        {
            AggregateSnapshot detailsAggregate = displayAggregate ?? aggregate;
            if (detailsAggregate == null)
            {
                return;
            }
            if (details.Topmost != Topmost)
            {
                details.Topmost = Topmost;
            }
            details.UpdateContent(detailsAggregate, DetailsSessions(detailsAggregate));
            PositionDetails();
            if (!details.IsVisible)
            {
                details.Show();
                details.UpdateLayout();
            }
            PositionDetails();
            QueueDetailsReposition();
        }

        private void QueueDetailsReposition()
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded,
                new Action(PositionDetails));
            Dispatcher.BeginInvoke(DispatcherPriority.Render,
                new Action(PositionDetails));
        }

        private List<SessionSnapshot> DetailsSessions(AggregateSnapshot detailsAggregate)
        {
            return settings.GetFocusedAgent() == AgentKind.ClaudeCode
                ? (detailsAggregate == null || detailsAggregate.Sessions == null
                    ? new List<SessionSnapshot>() : detailsAggregate.Sessions)
                : monitor.GetAllRecent();
        }

        private void PositionDetails()
        {
            Rect area = GetWorkAreaDip();
            double gap = 10;
            double proposedLeft = Left - details.Width - gap;
            if (proposedLeft < area.Left + 8)
            {
                proposedLeft = Left + Width + gap;
            }
            double detailHeight = GetDetailsHeightForPosition();
            details.Left = Math.Max(area.Left + 8,
                Math.Min(proposedLeft, area.Right - details.Width - 8));
            details.Top = Math.Max(area.Top + 8,
                Math.Min(Top + Height / 2 - detailHeight / 2,
                    area.Bottom - Math.Max(detailHeight, 230) - 8));
        }

        private double GetDetailsHeightForPosition()
        {
            if (details.ActualHeight > 0)
            {
                return details.ActualHeight;
            }
            if (details.DesiredSize.Height > 0)
            {
                return details.DesiredSize.Height;
            }
            if (!Double.IsNaN(details.Height) && details.Height > 0)
            {
                return details.Height;
            }
            return 230;
        }

        private void SnapToEdges()
        {
            Rect area = GetWorkAreaDip();
            const double threshold = 26;
            if (Math.Abs(Left - area.Left) < threshold)
            {
                Left = area.Left + 8;
            }
            if (Math.Abs((Left + Width) - area.Right) < threshold)
            {
                Left = area.Right - Width - 8;
            }
            if (Math.Abs(Top - area.Top) < threshold)
            {
                Top = area.Top + 8;
            }
            if (Math.Abs((Top + Height) - area.Bottom) < threshold)
            {
                Top = area.Bottom - Height - 8;
            }
        }

        private MediaPoint GetCursorDip()
        {
            System.Drawing.Point cursor = Forms.Control.MousePosition;
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source != null && source.CompositionTarget != null)
            {
                System.Windows.Media.Matrix fromDevice =
                    source.CompositionTarget.TransformFromDevice;
                return fromDevice.Transform(new MediaPoint(cursor.X, cursor.Y));
            }
            return new MediaPoint(cursor.X, cursor.Y);
        }

        private Rect GetWorkAreaDip()
        {
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source == null || source.CompositionTarget == null)
            {
                return SystemParameters.WorkArea;
            }

            System.Windows.Media.Matrix toDevice =
                source.CompositionTarget.TransformToDevice;
            System.Windows.Media.Matrix fromDevice =
                source.CompositionTarget.TransformFromDevice;
            MediaPoint centerDip = new MediaPoint(
                Double.IsNaN(Left) ? SystemParameters.WorkArea.Right - 60 : Left + Width / 2,
                Double.IsNaN(Top) ? SystemParameters.WorkArea.Top + 160 : Top + Height / 2);
            MediaPoint centerDevice = toDevice.Transform(centerDip);
            Forms.Screen screen = Forms.Screen.FromPoint(new System.Drawing.Point(
                (int)Math.Round(centerDevice.X), (int)Math.Round(centerDevice.Y)));
            System.Drawing.Rectangle work = screen.WorkingArea;
            MediaPoint topLeft = fromDevice.Transform(new MediaPoint(work.Left, work.Top));
            MediaPoint bottomRight = fromDevice.Transform(new MediaPoint(work.Right, work.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        private Rect GetPrimaryWorkAreaDip()
        {
            Forms.Screen primary = Forms.Screen.PrimaryScreen;
            if (primary == null)
            {
                return SystemParameters.WorkArea;
            }
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source == null || source.CompositionTarget == null)
            {
                return SystemParameters.WorkArea;
            }
            System.Windows.Media.Matrix fromDevice =
                source.CompositionTarget.TransformFromDevice;
            System.Drawing.Rectangle work = primary.WorkingArea;
            MediaPoint topLeft = fromDevice.Transform(
                new MediaPoint(work.Left, work.Top));
            MediaPoint bottomRight = fromDevice.Transform(
                new MediaPoint(work.Right, work.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        private void EscapeOffscreen()
        {
            MoveHaloToPrimaryScreen();
            Topmost = settings.AlwaysOnTop;
            Activate();
        }

        private void MoveHaloToPrimaryScreen()
        {
            Rect area = GetPrimaryWorkAreaDip();
            Left = area.Right - Width - 28;
            Top = area.Top + 28;
            SavePosition();
        }

        private void RecoverHaloIfOffscreen()
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            NativeRect nativeFrame;
            if (handle == IntPtr.Zero || !GetWindowRect(handle, out nativeFrame))
            {
                return;
            }
            System.Drawing.Rectangle frame = System.Drawing.Rectangle.FromLTRB(
                nativeFrame.Left, nativeFrame.Top, nativeFrame.Right, nativeFrame.Bottom);
            IEnumerable<System.Drawing.Rectangle> areas = Forms.Screen.AllScreens
                .Select(delegate(Forms.Screen screen) { return screen.WorkingArea; });
            if (!DiagnosticIsFrameVisible(frame, areas))
            {
                MoveHaloToPrimaryScreen();
            }
        }

        private void SavePosition()
        {
            settings.HasPosition = true;
            settings.Left = Left;
            settings.Top = Top;
            SettingsStorage.Save(settings);
        }

        private void ApplyHaloScale(int percent)
        {
            if (!IsValidScalePercent(percent))
            {
                percent = 100;
            }
            double centerX = Double.IsNaN(Left) ? 0 : Left + Width / 2;
            double centerY = Double.IsNaN(Top) ? 0 : Top + Height / 2;
            double size = SizeForScale(percent);
            Width = size;
            Height = size;
            if (!Double.IsNaN(Left) && !Double.IsNaN(Top))
            {
                Left = centerX - size / 2;
                Top = centerY - size / 2;
                Rect area = GetWorkAreaDip();
                Left = Math.Max(area.Left + 8,
                    Math.Min(Left, area.Right - Width - 8));
                Top = Math.Max(area.Top + 8,
                    Math.Min(Top, area.Bottom - Height - 8));
            }
            settings.HaloScalePercent = percent;
            SavePosition();
            PositionDetails();
        }

        private void AcknowledgeCompleted()
        {
            if (aggregate == null || aggregate.Sessions == null)
            {
                return;
            }
            foreach (SessionSnapshot session in aggregate.Sessions)
            {
                if (session.State == HaloState.Done)
                {
                    settings.Acknowledge(session.ThreadId, session.CompletedUtc);
                }
            }
            SettingsStorage.Save(settings);
            RefreshState();
        }

        private AggregateSnapshot GetClaudeAggregate()
        {
            DateTime now = DateTime.UtcNow;
            List<SessionSnapshot> merged = ClaudeStatusSourceMerger.Merge(
                claudeMonitor.Snapshots(), claudeTranscriptMonitor.Snapshots());
            List<SessionSnapshot> sessions = merged
                .Where(delegate(SessionSnapshot snapshot)
                {
                    if (snapshot.State == HaloState.Done)
                    {
                        return snapshot.CompletedUtc >= now.AddSeconds(-8);
                    }
                    return (snapshot.Active &&
                            snapshot.LastEventUtc >= now.AddMinutes(-10)) ||
                        (snapshot.State == HaloState.Error &&
                         snapshot.LastEventUtc >= now.AddHours(-1));
                })
                .OrderBy(delegate(SessionSnapshot snapshot)
                {
                    return CodexSessionMonitor.StatePriority(snapshot.State);
                })
                .ThenByDescending(delegate(SessionSnapshot snapshot)
                {
                    return snapshot.LastEventUtc;
                })
                .ToList();

            AggregateSnapshot result = new AggregateSnapshot();
            result.FocusedAgent = AgentKind.ClaudeCode;
            result.Sessions = sessions;
            if (settings.Paused)
            {
                result.State = HaloState.Idle;
                result.Label = "PAUSED";
                result.Detail = "Monitoring paused";
                return result;
            }
            if (sessions.Count == 0)
            {
                result.State = HaloState.Idle;
                result.Label = CodexSessionMonitor.StateLabel(HaloState.Idle);
                result.Detail = "Claude Code is not running";
                return result;
            }
            SessionSnapshot primary = sessions[0];
            result.State = primary.State;
            result.Label = CodexSessionMonitor.StateLabel(primary.State);
            result.Detail = sessions.Count == 1
                ? primary.ProjectName + " · " + primary.Action
                : primary.ProjectName + " +" +
                    (sessions.Count - 1).ToString(CultureInfo.InvariantCulture);
            return result;
        }

        private void BuildTrayMenu()
        {
            Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip();
            Forms.ToolStripMenuItem topmost = new Forms.ToolStripMenuItem(L10n.Instance["menu.always_on_top"]);
            topmost.Checked = settings.AlwaysOnTop;
            topmost.CheckOnClick = true;
            topmost.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    settings.AlwaysOnTop = topmost.Checked;
                    Topmost = settings.AlwaysOnTop;
                    details.Topmost = Topmost;
                    SettingsStorage.Save(settings);
                }));
            };
            menu.Items.Add(topmost);

            Forms.ToolStripMenuItem startup = new Forms.ToolStripMenuItem(L10n.Instance["menu.launch_at_startup"]);
            startup.Checked = StartupManager.IsEnabled();
            startup.CheckOnClick = true;
            startup.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    StartupManager.SetEnabled(startup.Checked);
                }));
            };
            menu.Items.Add(startup);

            Forms.ToolStripMenuItem pause = new Forms.ToolStripMenuItem(L10n.Instance["menu.pause_monitor"]);
            pause.Checked = settings.Paused;
            pause.CheckOnClick = true;
            pause.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    settings.Paused = pause.Checked;
                    RefreshState();
                }));
            };
            menu.Items.Add(pause);

            Forms.ToolStripMenuItem agentMenu =
                new Forms.ToolStripMenuItem(L10n.Instance["menu.focus_target"]);
            codexAgentItem = new Forms.ToolStripMenuItem("Codex");
            claudeAgentItem = new Forms.ToolStripMenuItem("Claude Code");
            codexAgentItem.Click += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    SetFocusedAgent(AgentKind.Codex);
                }));
            };
            claudeAgentItem.Click += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    SetFocusedAgent(AgentKind.ClaudeCode);
                }));
            };
            agentMenu.DropDownItems.Add(codexAgentItem);
            agentMenu.DropDownItems.Add(claudeAgentItem);
            menu.Items.Add(agentMenu);

            // Language submenu
            var languageItem = new Forms.ToolStripMenuItem(L10n.Instance["menu.language"]);
            languageItem.DropDownItems.Add(CreateLanguageItem(null));  // Follow System
            languageItem.DropDownItems.Add(CreateLanguageItem("zh"));   // 中文
            languageItem.DropDownItems.Add(CreateLanguageItem("en"));   // English
            menu.Items.Add(languageItem);

            menu.Items.Add(L10n.Instance["menu.escape_offscreen"], null, delegate
            {
                Dispatcher.BeginInvoke(new Action(EscapeOffscreen));
            });

            Forms.ToolStripMenuItem sizeMenu =
                new Forms.ToolStripMenuItem(L10n.Instance["halo.size"]);
            foreach (int percent in HaloScalePresets)
            {
                int selectedPercent = percent;
                Forms.ToolStripMenuItem sizeItem = new Forms.ToolStripMenuItem(
                    percent.ToString(CultureInfo.InvariantCulture) + "%");
                sizeItem.Checked = settings.HaloScalePercent == percent;
                sizeItem.Click += delegate
                {
                    Dispatcher.BeginInvoke(new Action(delegate
                    {
                        ApplyHaloScale(selectedPercent);
                        foreach (Forms.ToolStripItem child in sizeMenu.DropDownItems)
                        {
                            Forms.ToolStripMenuItem candidate =
                                child as Forms.ToolStripMenuItem;
                            if (candidate != null)
                            {
                                candidate.Checked = candidate == sizeItem;
                            }
                        }
                    }));
                };
                sizeMenu.DropDownItems.Add(sizeItem);
            }
            menu.Items.Add(sizeMenu);

            Forms.ToolStripMenuItem preview = new Forms.ToolStripMenuItem(L10n.Instance["menu.preview_status"]);
            AddPreviewItem(preview, L10n.Instance["halo.live_status"], null);
            AddPreviewItem(preview, L10n.Instance["halo.thinking_preview"], HaloState.Thinking);
            AddPreviewItem(preview, L10n.Instance["halo.working_preview"], HaloState.Working);
            AddPreviewItem(preview, L10n.Instance["halo.done_preview"], HaloState.Done);
            AddPreviewItem(preview, L10n.Instance["halo.attention_preview"], HaloState.Attention);
            AddPreviewItem(preview, L10n.Instance["halo.error_flash_preview"], HaloState.Error,
                ErrorPresentation.Flashing);
            AddPreviewItem(preview, L10n.Instance["halo.error_bright_preview"], HaloState.Error,
                ErrorPresentation.Bright);
            AddPreviewItem(preview, L10n.Instance["halo.error_dim_preview"], HaloState.Error,
                ErrorPresentation.Dim);
            AddPreviewItem(preview, L10n.Instance["halo.idle_preview"], HaloState.Idle);
            menu.Items.Add(preview);

            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add(L10n.Instance["menu.quit"], null, delegate
            {
                Dispatcher.BeginInvoke(new Action(Close));
            });
            Win11MenuRenderer.Apply(menu);
            tray.ContextMenuStrip = menu;
            UpdateAgentMenuChecks();
        }

        private void SetFocusedAgent(AgentKind agent)
        {
            if (settings.GetFocusedAgent() != agent)
            {
                settings.SetFocusedAgent(agent);
                SettingsStorage.Save(settings);
            }
            RefreshState();
            if (details.IsVisible)
            {
                AggregateSnapshot detailsAggregate = displayAggregate ?? aggregate;
                details.UpdateContent(detailsAggregate, DetailsSessions(detailsAggregate));
                PositionDetails();
            }
        }

        private void UpdateAgentMenuChecks()
        {
            if (codexAgentItem == null || claudeAgentItem == null)
            {
                return;
            }
            AgentKind focused = settings.GetFocusedAgent();
            codexAgentItem.Checked = focused == AgentKind.Codex;
            claudeAgentItem.Checked = focused == AgentKind.ClaudeCode;
        }

        private void AddPreviewItem(Forms.ToolStripMenuItem parent, string title,
            HaloState? preview)
        {
            AddPreviewItem(parent, title, preview, null);
        }

        private void AddPreviewItem(Forms.ToolStripMenuItem parent, string title,
            HaloState? preview, ErrorPresentation? presentation)
        {
            Forms.ToolStripMenuItem item = new Forms.ToolStripMenuItem(title);
            item.Click += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    demoState = preview;
                    demoErrorPresentation = presentation;
                    RefreshState();
                }));
            };
            parent.DropDownItems.Add(item);
        }

        private Forms.ToolStripMenuItem CreateLanguageItem(string lang)
        {
            string title = lang != null
                ? L10n.Instance["menu.language." + lang]
                : L10n.Instance["menu.language.auto"];
            var item = new Forms.ToolStripMenuItem(title, null, OnLanguageSelected);
            item.Tag = lang;
            string effective = settings.Language ?? L10n.DetectSystemLanguage();
            item.Checked = (lang == effective);
            return item;
        }

        private void OnLanguageSelected(object sender, EventArgs e)
        {
            var item = sender as Forms.ToolStripMenuItem;
            string lang = item?.Tag as string;
            settings.Language = lang;
            SettingsStorage.Save(settings);
            L10n.Instance.SetLanguage(lang);
        }

        private void BringCodexForward()
        {
            try
            {
                Process current = Process.GetCurrentProcess();
                Process candidate = Process.GetProcesses().FirstOrDefault(delegate(Process process)
                {
                    try
                    {
                        return process.Id != current.Id && process.MainWindowHandle != IntPtr.Zero &&
                            (process.ProcessName.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0 ||
                             process.MainWindowTitle.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0);
                    }
                    catch
                    {
                        return false;
                    }
                });
                if (candidate != null)
                {
                    ShowWindow(candidate.MainWindowHandle, 9);
                    SetForegroundWindow(candidate.MainWindowHandle);
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Bring Codex forward failed: " + ex.Message);
            }
        }

        private void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            foregroundTimer.Stop();
            hoverHideTimer.Stop();
            if (performanceTimer != null)
            {
                performanceTimer.Stop();
            }
            SavePosition();
            details.Close();
            monitor.Dispose();
            tray.Visible = false;
            tray.Dispose();
        }

        private static System.Drawing.Icon CreateTrayIcon(DrawingColor color)
        {
            using (Bitmap bitmap = new Bitmap(32, 32))
            using (Graphics graphics = Graphics.FromImage(bitmap))
            using (System.Drawing.Pen glow = new System.Drawing.Pen(
                DrawingColor.FromArgb(80, color), 7))
            using (System.Drawing.Pen ring = new System.Drawing.Pen(color, 3))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(DrawingColor.Transparent);
                graphics.DrawArc(glow, 5, 5, 22, 22, -52, 140);
                graphics.DrawArc(glow, 5, 5, 22, 22, 106, 194);
                graphics.DrawArc(ring, 5, 5, 22, 22, -52, 140);
                graphics.DrawArc(ring, 5, 5, 22, 22, 106, 194);
                IntPtr handle = bitmap.GetHicon();
                try
                {
                    return (System.Drawing.Icon)System.Drawing.Icon.FromHandle(handle).Clone();
                }
                finally
                {
                    DestroyIcon(handle);
                }
            }
        }

        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd,
            out uint processId);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out NativeRect rect);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);
    }
}
