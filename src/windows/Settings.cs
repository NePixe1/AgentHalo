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
public sealed class HaloSettings
    {
        public bool HasPosition { get; set; }
        public double Left { get; set; }
        public double Top { get; set; }
        public bool AlwaysOnTop { get; set; }
        public bool Paused { get; set; }
        public string InstalledAt { get; set; }
        public Dictionary<string, string> Acknowledged { get; set; }
        public string AcknowledgedErrorAt { get; set; }
        public int HaloScalePercent { get; set; }
        public string FocusedAgent { get; set; }
        public string Language { get; set; }  // null = follow system

        public HaloSettings()
        {
            AlwaysOnTop = true;
            HaloScalePercent = 100;
            FocusedAgent = "codex";
            InstalledAt = DateTime.UtcNow.ToString("o");
            Acknowledged = new Dictionary<string, string>();
            Language = null;  // follow system by default
        }

        public AgentKind GetFocusedAgent()
        {
            return String.Equals(FocusedAgent, "claudeCode",
                StringComparison.OrdinalIgnoreCase)
                ? AgentKind.ClaudeCode : AgentKind.Codex;
        }

        public void SetFocusedAgent(AgentKind agent)
        {
            FocusedAgent = agent == AgentKind.ClaudeCode ? "claudeCode" : "codex";
        }

        public DateTime GetInstalledUtc()
        {
            DateTime parsed;
            if (DateTime.TryParse(InstalledAt, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.UtcNow;
        }

        public DateTime GetAcknowledgedUtc(string threadId)
        {
            string value;
            DateTime parsed;
            if (Acknowledged != null && Acknowledged.TryGetValue(threadId, out value) &&
                DateTime.TryParse(value, CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.MinValue;
        }

        public void Acknowledge(string threadId, DateTime completedUtc)
        {
            if (Acknowledged == null)
            {
                Acknowledged = new Dictionary<string, string>();
            }
            Acknowledged[threadId] = completedUtc.ToUniversalTime().ToString("o");
        }

        public DateTime GetAcknowledgedErrorUtc()
        {
            DateTime parsed;
            return DateTime.TryParse(AcknowledgedErrorAt, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out parsed)
                ? parsed.ToUniversalTime() : DateTime.MinValue;
        }
    }

public static class SettingsStorage
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        public static string AppDirectory
        {
            get
            {
                string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(root, "CodexHalo");
            }
        }

        public static string SettingsPath
        {
            get { return Path.Combine(AppDirectory, "settings.json"); }
        }

        public static HaloSettings Load()
        {
            try
            {
                if (File.Exists(SettingsPath))
                {
                    HaloSettings result = Serializer.Deserialize<HaloSettings>(
                        File.ReadAllText(SettingsPath, Encoding.UTF8));
                    if (result != null)
                    {
                        bool repaired = false;
                        if (result.Acknowledged == null)
                        {
                            result.Acknowledged = new Dictionary<string, string>();
                            repaired = true;
                        }
                        if (String.IsNullOrEmpty(result.InstalledAt))
                        {
                            result.InstalledAt = DateTime.UtcNow.ToString("o");
                            repaired = true;
                        }
                        if (result.Paused)
                        {
                            // Pause is a temporary runtime control. Persisting it
                            // makes the next launch look like a broken monitor.
                            result.Paused = false;
                            repaired = true;
                        }
                        if (!HaloWindow.IsValidScalePercent(result.HaloScalePercent))
                        {
                            result.HaloScalePercent = 100;
                            repaired = true;
                        }
                        if (!String.Equals(result.FocusedAgent, "codex",
                                StringComparison.OrdinalIgnoreCase) &&
                            !String.Equals(result.FocusedAgent, "claudeCode",
                                StringComparison.OrdinalIgnoreCase))
                        {
                            result.FocusedAgent = "codex";
                            repaired = true;
                        }
                        if (repaired)
                        {
                            Save(result);
                        }
                        return result;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Settings load failed: " + ex.Message);
            }
            return new HaloSettings();
        }

        public static void Save(HaloSettings settings)
        {
            try
            {
                Directory.CreateDirectory(AppDirectory);
                string temp = SettingsPath + ".tmp";
                bool runtimePaused = settings.Paused;
                settings.Paused = false;
                string json;
                try
                {
                    json = Serializer.Serialize(settings);
                }
                finally
                {
                    settings.Paused = runtimePaused;
                }
                File.WriteAllText(temp, json, Encoding.UTF8);
                if (File.Exists(SettingsPath))
                {
                    File.Delete(SettingsPath);
                }
                File.Move(temp, SettingsPath);
            }
            catch (Exception ex)
            {
                Log("Settings save failed: " + ex.Message);
            }
        }

        public static void Log(string text)
        {
            try
            {
                Directory.CreateDirectory(AppDirectory);
                File.AppendAllText(Path.Combine(AppDirectory, "halo.log"),
                    DateTime.Now.ToString("s") + " " + text + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}

