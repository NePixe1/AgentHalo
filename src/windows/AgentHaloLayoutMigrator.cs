using System;
using System.IO;

namespace CodexHalo
{
    /// <summary>
    /// Idempotent best-effort migration of %USERPROFILE%\.agent-halo to layout v2.
    /// Moves data into logs/cache, relocates AppData usage-snapshots into cache/,
    /// deletes legacy flat files and AgentHaloHook.exe. Never touches settings.json
    /// or halo.log under LocalAppData\CodexHalo.
    /// </summary>
    internal static class AgentHaloLayoutMigrator
    {
        public static void MigrateIfNeeded(
            string userProfile = null,
            string legacyAppDataUsagePath = null)
        {
            try
            {
                EnsureLayoutDirectories(userProfile);

                if (ReadVersion(userProfile) >= AgentHaloPaths.LayoutVersion)
                {
                    ScrubLegacyDataPaths(userProfile, legacyAppDataUsagePath);
                    return;
                }

                MoveOrReplace(
                    AgentHaloPaths.LegacyClaudeStatusLog(userProfile),
                    AgentHaloPaths.ClaudeStatusLog(userProfile));
                MoveOrReplace(
                    AgentHaloPaths.LegacyGrokStatusLog(userProfile),
                    AgentHaloPaths.GrokStatusLog(userProfile));
                MoveDirectoryContents(
                    AgentHaloPaths.LegacyClaudeContextsDirectory(userProfile),
                    AgentHaloPaths.ClaudeContextsDirectory(userProfile));
                MoveOrReplace(
                    AgentHaloPaths.LegacyUsageSnapshotsInAgentHalo(userProfile),
                    AgentHaloPaths.UsageSnapshots(userProfile));

                string appDataUsage = legacyAppDataUsagePath ??
                    AgentHaloPaths.LegacyUsageSnapshotsInAppData();
                MoveOrReplace(appDataUsage, AgentHaloPaths.UsageSnapshots(userProfile));

                RemoveIfExists(AgentHaloPaths.LegacyClaudeContextFile(userProfile));
                RemoveEmptyDirectoryIfExists(
                    AgentHaloPaths.LegacyClaudeContextsDirectory(userProfile));
                RemoveIfExists(AgentHaloPaths.LegacyAgentHaloHookExe(userProfile));

                WriteLayoutVersion(AgentHaloPaths.LayoutVersion, userProfile);
                ScrubLegacyDataPaths(userProfile, legacyAppDataUsagePath);
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

        private static void WriteLayoutVersion(int version, string userProfile)
        {
            try
            {
                string path = AgentHaloPaths.LayoutVersionFile(userProfile);
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, version.ToString() + Environment.NewLine);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: write version failed: " + ex.Message);
            }
        }

        private static void EnsureLayoutDirectories(string userProfile)
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
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: ensure dirs failed: " + ex.Message);
            }
        }

        private static void ScrubLegacyDataPaths(
            string userProfile,
            string legacyAppDataUsagePath)
        {
            RemoveIfExists(AgentHaloPaths.LegacyClaudeStatusLog(userProfile));
            RemoveIfExists(AgentHaloPaths.LegacyGrokStatusLog(userProfile));
            RemoveIfExists(AgentHaloPaths.LegacyUsageSnapshotsInAgentHalo(userProfile));
            RemoveIfExists(AgentHaloPaths.LegacyClaudeContextFile(userProfile));
            RemoveDirectoryTreeIfExists(
                AgentHaloPaths.LegacyClaudeContextsDirectory(userProfile));
            RemoveIfExists(AgentHaloPaths.LegacyAgentHaloHookExe(userProfile));

            string appDataUsage = legacyAppDataUsagePath ??
                AgentHaloPaths.LegacyUsageSnapshotsInAppData();
            // If new cache already has usage (or we just moved it), drop AppData leftover.
            // Safe even when new is missing: scrub only when AppData file still exists
            // after migration pass; if move failed, leave AppData for next retry.
            if (File.Exists(AgentHaloPaths.UsageSnapshots(userProfile)))
            {
                RemoveIfExists(appDataUsage);
            }
        }

        private static void MoveOrReplace(string from, string to)
        {
            try
            {
                bool fromExists = File.Exists(from);
                bool toExists = File.Exists(to);
                if (toExists)
                {
                    if (fromExists)
                    {
                        RemoveIfExists(from);
                    }
                    return;
                }
                if (!fromExists)
                {
                    return;
                }

                string parent = Path.GetDirectoryName(to);
                if (!String.IsNullOrEmpty(parent))
                {
                    Directory.CreateDirectory(parent);
                }

                try
                {
                    File.Move(from, to);
                    return;
                }
                catch
                {
                    // Fall through to copy+delete.
                }

                File.Copy(from, to, true);
                RemoveIfExists(from);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: move failed " + from + " -> " + to +
                    ": " + ex.Message);
            }
        }

        private static void MoveDirectoryContents(string from, string to)
        {
            try
            {
                if (!Directory.Exists(from))
                {
                    return;
                }
                Directory.CreateDirectory(to);
                foreach (string child in Directory.GetFileSystemEntries(from))
                {
                    string name = Path.GetFileName(child);
                    string dest = Path.Combine(to, name);
                    if (Directory.Exists(child))
                    {
                        MoveDirectoryContents(child, dest);
                        RemoveEmptyDirectoryIfExists(child);
                    }
                    else
                    {
                        MoveOrReplace(child, dest);
                    }
                }
                RemoveEmptyDirectoryIfExists(from);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: move dir failed " + from + ": " +
                    ex.Message);
            }
        }

        private static void RemoveIfExists(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: remove failed " + path + ": " +
                    ex.Message);
            }
        }

        private static void RemoveDirectoryTreeIfExists(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log(
                    "AgentHaloLayoutMigrator: remove dir failed " + path + ": " +
                    ex.Message);
            }
        }

        private static void RemoveEmptyDirectoryIfExists(string path)
        {
            try
            {
                if (!Directory.Exists(path))
                {
                    return;
                }
                if (Directory.GetFileSystemEntries(path).Length == 0)
                {
                    Directory.Delete(path, false);
                }
            }
            catch
            {
            }
        }
    }
}
