using System;
using System.IO;

namespace CodexHalo
{
    /// <summary>
    /// Atomic install helpers for staged hook binaries under %USERPROFILE%\.agent-halo.
    /// Mirrors macOS upgrade invariants: never leave a advertised path missing.
    /// </summary>
    internal static class AgentHaloBinaryStaging
    {
        public static void StageExecutable(string source, string destination)
        {
            if (String.IsNullOrEmpty(source) || !File.Exists(source))
            {
                throw new FileNotFoundException("source executable missing", source);
            }

            string parent = Path.GetDirectoryName(destination);
            if (!String.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            string temp = Path.Combine(
                parent ?? Path.GetTempPath(),
                ".staging-" + Path.GetFileName(destination) + "-" +
                Guid.NewGuid().ToString("N"));
            try
            {
                File.Copy(source, temp, true);
                if (File.Exists(destination))
                {
                    // Atomic replace on same volume when possible.
                    try
                    {
                        File.Replace(temp, destination, null);
                        temp = null;
                        return;
                    }
                    catch
                    {
                        // Fall through: overwrite copy (still no delete-first gap
                        // for the destination path itself).
                        File.Copy(temp, destination, true);
                        return;
                    }
                }
                File.Move(temp, destination);
                temp = null;
            }
            finally
            {
                if (temp != null)
                {
                    try { File.Delete(temp); }
                    catch { }
                }
            }
        }

        /// <summary>
        /// Stage current AgentHalo.exe to the preferred bin\status-hook.exe only.
        /// Configurators rewrite settings to this path on launch.
        /// </summary>
        public static void StageStatusHookEverywhere(
            string sourceExecutable,
            string userProfile = null)
        {
            StageExecutable(sourceExecutable, AgentHaloPaths.StatusHookExe(userProfile));
        }

        /// <summary>
        /// After settings point at bin\status-hook.exe, remove unreferenced
        /// root-level AgentHaloHook.exe leftovers.
        /// </summary>
        public static void ScrubUnreferencedLegacyBinaries(string userProfile = null)
        {
            try
            {
                string legacy = AgentHaloPaths.LegacyAgentHaloHookExe(userProfile);
                if (!File.Exists(legacy))
                {
                    return;
                }
                string home = String.IsNullOrEmpty(userProfile)
                    ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                    : userProfile;
                string settings = Path.Combine(home, ".claude", "settings.json");
                if (File.Exists(settings))
                {
                    string text = File.ReadAllText(settings);
                    if (text.IndexOf("AgentHaloHook.exe", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        return;
                    }
                }
                File.Delete(legacy);
                SettingsStorage.Log(
                    "AgentHaloBinaryStaging: removed unreferenced " + legacy);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloBinaryStaging: legacy scrub failed: " + ex.Message);
            }
        }

        /// <summary>
        /// Extract the executable token from a hook command, handling quotes.
        /// </summary>
        public static string CommandExecutablePath(string command)
        {
            if (String.IsNullOrWhiteSpace(command))
            {
                return String.Empty;
            }
            string trimmed = command.Trim();
            if (trimmed.StartsWith("\"", StringComparison.Ordinal))
            {
                int end = trimmed.IndexOf('"', 1);
                if (end > 1)
                {
                    return trimmed.Substring(1, end - 1);
                }
            }
            int space = trimmed.IndexOf(' ');
            return space < 0 ? trimmed : trimmed.Substring(0, space);
        }

        public static bool CommandPointsToLiveExecutable(string command)
        {
            string path = CommandExecutablePath(command);
            if (String.IsNullOrEmpty(path))
            {
                return false;
            }
            try
            {
                return File.Exists(path);
            }
            catch
            {
                return false;
            }
        }
    }
}
