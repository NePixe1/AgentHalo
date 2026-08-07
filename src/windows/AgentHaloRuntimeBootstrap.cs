using System;
using System.Diagnostics;
using System.IO;

namespace CodexHalo
{
    /// <summary>
    /// Single launch-time upgrade entry point (Windows).
    /// Order: migrate data → stage stable hook binaries → rewrite Claude/Grok hooks
    /// only when unhealthy. Mirrors macOS AgentHaloRuntimeBootstrap.
    /// </summary>
    internal static class AgentHaloRuntimeBootstrap
    {
        public static void Bootstrap(string userProfile = null, string sourceExecutable = null)
        {
            string home = String.IsNullOrEmpty(userProfile)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                : userProfile;

            AgentHaloLayoutMigrator.MigrateIfNeeded(home);

            string exe = sourceExecutable;
            if (String.IsNullOrEmpty(exe))
            {
                try
                {
                    exe = Process.GetCurrentProcess().MainModule.FileName;
                }
                catch (Exception ex)
                {
                    SettingsStorage.Log(
                        "AgentHaloRuntimeBootstrap: resolve exe failed: " + ex.Message);
                }
            }

            if (!String.IsNullOrEmpty(exe) && File.Exists(exe))
            {
                try
                {
                    AgentHaloBinaryStaging.StageStatusHookEverywhere(exe, home);
                }
                catch (Exception ex)
                {
                    SettingsStorage.Log(
                        "AgentHaloRuntimeBootstrap: hook stage failed: " + ex.Message);
                }
            }

            // Prefer the stable staged path for settings so install-dir moves
            // do not strand hooks; fall back to the running exe if stage failed.
            string hookExe = AgentHaloPaths.StatusHookExe(home);
            if (!File.Exists(hookExe))
            {
                hookExe = exe;
            }
            if (!String.IsNullOrEmpty(hookExe))
            {
                ClaudeHookConfigurator.Configure(home, hookExe);
                GrokHookConfigurator.Configure(home, hookExe);
            }

            // Pi loads TypeScript extensions directly from ~/.pi/agent/extensions.
            // The source is embedded in AgentHalo.exe, so installed builds do not
            // depend on repository or docs files at runtime.
            PiExtensionConfigurator.Configure(home);

            // Settings now point at bin\status-hook.exe — drop unreferenced
            // root-level AgentHaloHook.exe leftovers.
            AgentHaloBinaryStaging.ScrubUnreferencedLegacyBinaries(home);
        }
    }
}
