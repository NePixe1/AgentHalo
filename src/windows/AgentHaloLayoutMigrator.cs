using System;
using System.IO;

namespace CodexHalo
{
    /// <summary>
    /// Idempotent best-effort migration of %USERPROFILE%\.agent-halo to layout v2.
    /// Moves data into logs/cache, relocates AppData usage-snapshots into cache/,
    /// deletes legacy flat **data** files. Never deletes staged binaries
    /// (AgentHaloHook.exe / bin\status-hook.exe) — configurators keep those as
    /// upgrade-compat mirrors so mid-session hooks do not fail with "not found".
    /// Never touches settings.json or halo.log under LocalAppData\CodexHalo.
    /// </summary>
    internal static class AgentHaloLayoutMigrator
    {
        public static void MigrateIfNeeded(
            string userProfile = null,
            string legacyAppDataUsagePath = null)
        {
            try
            {
                if (!EnsureLayoutDirectories(userProfile))
                {
                    return;
                }

                int currentVersion = ReadVersion(userProfile);
                bool migrated = true;
                migrated = MoveOrReplace(
                    AgentHaloPaths.LegacyClaudeStatusLog(userProfile),
                    AgentHaloPaths.ClaudeStatusLog(userProfile)) && migrated;
                migrated = MoveOrReplace(
                    AgentHaloPaths.LegacyGrokStatusLog(userProfile),
                    AgentHaloPaths.GrokStatusLog(userProfile)) && migrated;
                migrated = MoveDirectoryContents(
                    AgentHaloPaths.LegacyClaudeContextsDirectory(userProfile),
                    AgentHaloPaths.ClaudeContextsDirectory(userProfile)) && migrated;
                migrated = MoveOrReplace(
                    AgentHaloPaths.LegacyUsageSnapshotsInAgentHalo(userProfile),
                    AgentHaloPaths.UsageSnapshots(userProfile)) && migrated;

                string appDataUsage = legacyAppDataUsagePath ??
                    AgentHaloPaths.LegacyUsageSnapshotsInAppData();
                migrated = MoveOrReplace(
                    appDataUsage,
                    AgentHaloPaths.UsageSnapshots(userProfile)) && migrated;

                migrated = RemoveIfExists(
                    AgentHaloPaths.LegacyClaudeContextFile(userProfile)) && migrated;
                migrated = RemoveEmptyDirectoryIfExists(
                    AgentHaloPaths.LegacyClaudeContextsDirectory(userProfile)) && migrated;
                // Intentionally keep LegacyAgentHaloHookExe — mid-session hooks
                // may still invoke it until settings are rewritten + reloaded.

                if (!migrated)
                {
                    SettingsStorage.Log(
                        "AgentHaloLayoutMigrator: migration incomplete; " +
                        "preserving legacy data for retry");
                    return;
                }

                if (currentVersion < AgentHaloPaths.LayoutVersion)
                {
                    if (!WriteLayoutVersion(AgentHaloPaths.LayoutVersion, userProfile))
                    {
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("AgentHaloLayoutMigrator failed: " + ex.Message);
            }
        }

        private static int ReadVersion(string userProfile)
        {
            try
            {
                string path = AgentHaloPaths.LayoutVersionFile(userProfile);
                if (!File.Exists(path))
                {
                    return 0;
                }
                string raw = File.ReadAllText(path).Trim();
                int version;
                return Int32.TryParse(raw, out version) ? version : 0;
            }
            catch
            {
                return 0;
            }
        }

        private static bool WriteLayoutVersion(int version, string userProfile)
        {
            try
            {
                string path = AgentHaloPaths.LayoutVersionFile(userProfile);
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, version.ToString() + Environment.NewLine);
                return true;
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: write version failed: " + ex.Message);
                return false;
            }
        }

        private static bool EnsureLayoutDirectories(string userProfile)
        {
            try
            {
                Directory.CreateDirectory(AgentHaloPaths.Root(userProfile));
                Directory.CreateDirectory(AgentHaloPaths.BinDirectory(userProfile));
                Directory.CreateDirectory(AgentHaloPaths.StateDirectory(userProfile));
                Directory.CreateDirectory(AgentHaloPaths.LogsDirectory(userProfile));
                Directory.CreateDirectory(AgentHaloPaths.CacheDirectory(userProfile));
                Directory.CreateDirectory(
                    AgentHaloPaths.ClaudeContextsDirectory(userProfile));
                return true;
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: ensure dirs failed: " + ex.Message);
                return false;
            }
        }

        private static bool MoveOrReplace(string from, string to)
        {
            try
            {
                bool fromExists = File.Exists(from);
                bool toExists = File.Exists(to);
                if (toExists)
                {
                    if (fromExists)
                    {
                        return RemoveIfExists(from);
                    }
                    return true;
                }
                if (!fromExists)
                {
                    return true;
                }

                string parent = Path.GetDirectoryName(to);
                if (!String.IsNullOrEmpty(parent))
                {
                    Directory.CreateDirectory(parent);
                }

                try
                {
                    File.Move(from, to);
                    return File.Exists(to);
                }
                catch
                {
                    // Fall through to copy+delete.
                }

                File.Copy(from, to, true);
                if (!File.Exists(to))
                {
                    return false;
                }
                return RemoveIfExists(from);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: move failed " + from + " -> " + to +
                    ": " + ex.Message);
                return false;
            }
        }

        private static bool MoveDirectoryContents(string from, string to)
        {
            try
            {
                if (!Directory.Exists(from))
                {
                    return !File.Exists(from);
                }
                Directory.CreateDirectory(to);
                bool succeeded = true;
                foreach (string child in Directory.GetFileSystemEntries(from))
                {
                    string name = Path.GetFileName(child);
                    string dest = Path.Combine(to, name);
                    if (Directory.Exists(child))
                    {
                        succeeded = MoveDirectoryContents(child, dest) && succeeded;
                        succeeded = RemoveEmptyDirectoryIfExists(child) && succeeded;
                    }
                    else
                    {
                        succeeded = MoveOrReplace(child, dest) && succeeded;
                    }
                }
                return RemoveEmptyDirectoryIfExists(from) && succeeded;
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: move dir failed " + from + ": " +
                    ex.Message);
                return false;
            }
        }

        private static bool RemoveIfExists(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
                return true;
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: remove failed " + path + ": " +
                    ex.Message);
                return false;
            }
        }

        private static bool RemoveEmptyDirectoryIfExists(string path)
        {
            try
            {
                if (!Directory.Exists(path))
                {
                    return !File.Exists(path);
                }
                if (Directory.GetFileSystemEntries(path).Length == 0)
                {
                    Directory.Delete(path, false);
                    return true;
                }
                return false;
            }
            catch
            {
                return false;
            }
        }
    }
}
