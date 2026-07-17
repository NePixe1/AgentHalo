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
public enum AgentKind
    {
        Codex,
        ClaudeCode
    }

public sealed class SessionSnapshot
    {
        public string ThreadId;
        public string ProjectName;
        public string WorkingDirectory;
        public HaloState State;
        public string Action;
        public DateTime LastEventUtc;
        public DateTime CompletedUtc;
        public bool Active;
        public AgentKind Agent;
    }

public sealed class AggregateSnapshot
    {
        public HaloState State;
        public string Label;
        public string Detail;
        public List<SessionSnapshot> Sessions;
        public bool AnswerStreaming;
        public AgentKind FocusedAgent;
    }

public sealed class UsageMetrics
    {
        public bool HasFiveHour;
        public bool HasWeekly;
        public bool HasMonthly;
        public double FiveHourUsedPercent;
        public double WeeklyUsedPercent;
        public double MonthlyUsedPercent;
        public DateTime FiveHourResetUtc;
        public DateTime WeeklyResetUtc;
        public DateTime MonthlyResetUtc;
        public long ContextInputTokens;
        public long ContextWindowTokens;

        public bool HasContext
        {
            get { return ContextInputTokens >= 0 && ContextWindowTokens > 0; }
        }

        public double ContextUsedPercent
        {
            get
            {
                if (!HasContext)
                {
                    return 0;
                }
                return Math.Max(0, Math.Min(100,
                    ContextInputTokens * 100.0 / ContextWindowTokens));
            }
        }
    }

public sealed class ClaudeCodeMetrics
    {
        public bool IsCustomApi;
        public string Model;
        public string SessionTitle;
        public long InputTokens;
        public long OutputTokens;
        public long ContextTokens;
        public long ContextWindowTokens;

        public bool HasModel
        {
            get { return !String.IsNullOrWhiteSpace(Model); }
        }

        public bool HasSessionTitle
        {
            get { return !String.IsNullOrWhiteSpace(SessionTitle); }
        }

        public bool HasTokenUsage
        {
            get { return InputTokens > 0 || OutputTokens > 0; }
        }

        public bool HasContext
        {
            get { return ContextTokens >= 0 && ContextWindowTokens > 0; }
        }

        public double ContextUsedPercent
        {
            get
            {
                if (!HasContext)
                {
                    return 0;
                }
                return Math.Max(0, Math.Min(100,
                    ContextTokens * 100.0 / ContextWindowTokens));
            }
        }
    }
}

