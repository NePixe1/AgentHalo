using System;
using System.IO;

namespace CodexHalo
{
    /// <summary>
    /// Canonical paths under %USERPROFILE%\.agent-halo for layout version 2.
    /// Production code must resolve runtime agent data through this type.
    /// Legacy helpers exist only for migration / scrub decisions.
    /// </summary>
    internal static class AgentHaloPaths
    {
        public const int LayoutVersion = 2;

        public static string Root(string userProfile = null)
        {
            return Path.Combine(ResolveUserProfile(userProfile), ".agent-halo");
        }

        public static string LayoutVersionFile(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), ".layout-version");
        }

        public static string BinDirectory(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "bin");
        }

        public static string StateDirectory(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "state");
        }

        public static string LogsDirectory(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "logs");
        }

        public static string CacheDirectory(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "cache");
        }

        public static string ClaudeStatusLog(string userProfile = null)
        {
            return Path.Combine(LogsDirectory(userProfile), "claude-status.jsonl");
        }

        public static string GrokStatusLog(string userProfile = null)
        {
            return Path.Combine(LogsDirectory(userProfile), "grok-status.jsonl");
        }

        public static string ClaudeContextsDirectory(string userProfile = null)
        {
            return Path.Combine(CacheDirectory(userProfile), "claude-contexts");
        }

        public static string UsageSnapshots(string userProfile = null)
        {
            return Path.Combine(CacheDirectory(userProfile), "usage-snapshots-v1.json");
        }

        // MARK: Legacy (migration / scrub only)

        public static string LegacyClaudeStatusLog(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "claude-code-status.jsonl");
        }

        public static string LegacyGrokStatusLog(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "grok-build-status.jsonl");
        }

        public static string LegacyClaudeContextsDirectory(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "claude-code-contexts");
        }

        public static string LegacyClaudeContextFile(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "claude-code-context.json");
        }

        public static string LegacyUsageSnapshotsInAgentHalo(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "usage-snapshots-v1.json");
        }

        public static string LegacyUsageSnapshotsInAppData()
        {
            return Path.Combine(SettingsStorage.AppDirectory, "usage-snapshots-v1.json");
        }

        public static string LegacyAgentHaloHookExe(string userProfile = null)
        {
            return Path.Combine(Root(userProfile), "AgentHaloHook.exe");
        }

        private static string ResolveUserProfile(string userProfile)
        {
            if (!String.IsNullOrEmpty(userProfile))
            {
                return userProfile;
            }
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
    }
}
