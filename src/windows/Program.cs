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
[assembly: System.Reflection.AssemblyTitle("Agent Halo")]
[assembly: System.Reflection.AssemblyDescription("Ambient desktop status light for coding agents")]
[assembly: System.Reflection.AssemblyCompany("Agent Halo")]
[assembly: System.Reflection.AssemblyProduct("Agent Halo")]
[assembly: System.Reflection.AssemblyVersion("0.13.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.13.0.0")]

namespace CodexHalo
{
public static class Program
    {
        private static Mutex mutex;

        [STAThread]
        public static int Main()
        {
            string[] args = Environment.GetCommandLineArgs();
            if (args.Length >= 3 && args[1] == "--claude-hook")
            {
                return ClaudeHookStatusWriter.WriteFromStandardInput(args[2]);
            }
            if (args.Length >= 3 && args[1] == "--self-test")
            {
                return Diagnostics.RunSelfTest(args[2]);
            }
            if (args.Length >= 3 && args[1] == "--snapshot")
            {
                return Diagnostics.WriteLiveSnapshot(args[2]);
            }
            if (args.Length >= 3 && args[1] == "--claude-snapshot")
            {
                return Diagnostics.WriteClaudeSnapshot(args[2]);
            }

            if (args.Length < 2)
            {
                DetachEphemeralConsole();
            }

            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            app.DispatcherUnhandledException += delegate(object sender,
                DispatcherUnhandledExceptionEventArgs e)
            {
                SettingsStorage.Log("Unhandled UI error: " + e.Exception);
                e.Handled = true;
            };

            if (args.Length >= 3 && args[1] == "--render-states")
            {
                int result = Diagnostics.RenderStates(args[2]);
                app.Shutdown(result);
                return result;
            }
            if (args.Length >= 3 && args[1] == "--benchmark")
            {
                Diagnostics.RunBenchmark(args[2]);
                app.Run();
                return 0;
            }

            bool created;
            mutex = new Mutex(true, "Local\\CodexHalo-9A542DB9-A944-4B38-AED0-84BE7419D0BB",
                out created);
            if (!created)
            {
                return 0;
            }

            HaloWindow window = new HaloWindow(SettingsStorage.Load());
            app.ShutdownMode = ShutdownMode.OnMainWindowClose;
            app.MainWindow = window;
            window.Show();
            app.Run();
            GC.KeepAlive(mutex);
            return 0;
        }

        private static void DetachEphemeralConsole()
        {
            try
            {
                IntPtr console = GetConsoleWindow();
                if (console == IntPtr.Zero)
                {
                    return;
                }
                uint[] processes = new uint[8];
                uint count = GetConsoleProcessList(processes, (uint)processes.Length);
                if (count <= 1)
                {
                    ShowWindow(console, 0);
                }
                FreeConsole();
            }
            catch
            {
            }
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("kernel32.dll")]
        private static extern uint GetConsoleProcessList(
            [Out] uint[] processList, uint processCount);

        [DllImport("kernel32.dll")]
        private static extern bool FreeConsole();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}

