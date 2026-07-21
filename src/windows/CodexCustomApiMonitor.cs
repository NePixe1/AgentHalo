using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace CodexHalo
{
internal sealed class CodexProviderProfile
    {
        public string Model;
        public string ProviderId;
        public string ProviderName;
        public string BaseUrl;
        public bool IsCustomApi;
    }

internal static class CodexProviderProfileReader
    {
        public static CodexProviderProfile Read()
        {
            string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            string path = String.IsNullOrWhiteSpace(codexHome)
                ? Path.Combine(Environment.GetFolderPath(
                    Environment.SpecialFolder.UserProfile), ".codex", "config.toml")
                : Path.Combine(codexHome, "config.toml");
            return Read(path);
        }

        internal static CodexProviderProfile Read(string path)
        {
            CodexProviderProfile profile = new CodexProviderProfile();
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return profile;
            }
            try
            {
                string section = String.Empty;
                Dictionary<string, Dictionary<string, string>> providers =
                    new Dictionary<string, Dictionary<string, string>>(
                        StringComparer.OrdinalIgnoreCase);
                foreach (string raw in File.ReadAllLines(path))
                {
                    string line = RemoveComment(raw).Trim();
                    if (line.Length == 0)
                    {
                        continue;
                    }
                    if (line.StartsWith("[", StringComparison.Ordinal) &&
                        line.EndsWith("]", StringComparison.Ordinal))
                    {
                        section = line.Substring(1, line.Length - 2).Trim();
                        continue;
                    }
                    int equals = line.IndexOf('=');
                    if (equals <= 0)
                    {
                        continue;
                    }
                    string key = line.Substring(0, equals).Trim();
                    string value = ParseValue(line.Substring(equals + 1));
                    if (section.Length == 0)
                    {
                        if (String.Equals(key, "model", StringComparison.OrdinalIgnoreCase))
                        {
                            profile.Model = value;
                        }
                        else if (String.Equals(key, "model_provider",
                            StringComparison.OrdinalIgnoreCase))
                        {
                            profile.ProviderId = value;
                        }
                        continue;
                    }
                    const string prefix = "model_providers.";
                    if (!section.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    string providerId = section.Substring(prefix.Length).Trim().Trim('"', '\'');
                    Dictionary<string, string> values;
                    if (!providers.TryGetValue(providerId, out values))
                    {
                        values = new Dictionary<string, string>(
                            StringComparer.OrdinalIgnoreCase);
                        providers[providerId] = values;
                    }
                    values[key] = value;
                }

                Dictionary<string, string> selected;
                if (!String.IsNullOrWhiteSpace(profile.ProviderId) &&
                    providers.TryGetValue(profile.ProviderId, out selected))
                {
                    string value;
                    if (selected.TryGetValue("name", out value) ||
                        selected.TryGetValue("display_name", out value))
                    {
                        profile.ProviderName = value;
                    }
                    if (selected.TryGetValue("base_url", out value))
                    {
                        profile.BaseUrl = value;
                    }
                }
                profile.IsCustomApi = IsCustomProvider(profile.ProviderId,
                    profile.BaseUrl);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Codex provider config read failed: " + ex.Message);
            }
            return profile;
        }

        internal static bool IsCustomProvider(string providerId, string baseUrl)
        {
            if (!String.IsNullOrWhiteSpace(baseUrl))
            {
                Uri uri;
                if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out uri))
                {
                    return true;
                }
                string host = uri.Host ?? String.Empty;
                bool officialHost = host.Equals("openai.com",
                        StringComparison.OrdinalIgnoreCase) ||
                    host.EndsWith(".openai.com", StringComparison.OrdinalIgnoreCase) ||
                    host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
                    host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase);
                if (!officialHost)
                {
                    return true;
                }
            }
            if (String.IsNullOrWhiteSpace(providerId))
            {
                return false;
            }
            string normalized = providerId.Trim().ToLowerInvariant();
            return normalized != "openai" && normalized != "chatgpt" &&
                normalized != "openai-chatgpt";
        }

        private static string RemoveComment(string line)
        {
            bool quoted = false;
            char quote = '\0';
            for (int i = 0; i < line.Length; i++)
            {
                char current = line[i];
                if ((current == '"' || current == '\'') &&
                    (i == 0 || line[i - 1] != '\\'))
                {
                    if (!quoted)
                    {
                        quoted = true;
                        quote = current;
                    }
                    else if (current == quote)
                    {
                        quoted = false;
                    }
                }
                else if (current == '#' && !quoted)
                {
                    return line.Substring(0, i);
                }
            }
            return line;
        }

        private static string ParseValue(string value)
        {
            string trimmed = value.Trim();
            if (trimmed.Length >= 2 &&
                ((trimmed[0] == '"' && trimmed[trimmed.Length - 1] == '"') ||
                 (trimmed[0] == '\'' && trimmed[trimmed.Length - 1] == '\'')))
            {
                trimmed = trimmed.Substring(1, trimmed.Length - 2);
            }
            return trimmed.Replace("\\\"", "\"").Replace("\\\\", "\\");
        }
    }

public static class CodexCustomApiMetricsReader
    {
        public static CodexCustomApiMetrics Read(IList<SessionSnapshot> sessions)
        {
            return Read(sessions, CodexProviderProfileReader.Read(),
                CodexUsageMonitor.Instance.Status);
        }

        internal static CodexCustomApiMetrics Read(IList<SessionSnapshot> sessions,
            CodexProviderProfile profile, CodexUsageDataStatus usageStatus)
        {
            SessionSnapshot snapshot = sessions == null ? null : sessions
                .Where(delegate(SessionSnapshot item)
                {
                    return item != null && item.Agent == AgentKind.Codex;
                })
                .OrderByDescending(delegate(SessionSnapshot item) { return item.Active; })
                .ThenByDescending(delegate(SessionSnapshot item) { return item.LastEventUtc; })
                .FirstOrDefault();
            profile = profile ?? new CodexProviderProfile();
            string provider = snapshot != null &&
                !String.IsNullOrWhiteSpace(snapshot.ModelProvider)
                ? snapshot.ModelProvider : profile.ProviderId;
            bool custom = profile.IsCustomApi ||
                CodexProviderProfileReader.IsCustomProvider(provider, profile.BaseUrl) ||
                usageStatus == CodexUsageDataStatus.ApiKey;
            CodexCustomApiMetrics metrics = new CodexCustomApiMetrics
            {
                IsCustomApi = custom,
                Provider = !String.IsNullOrWhiteSpace(profile.ProviderName)
                    ? profile.ProviderName : provider,
                Model = snapshot != null && !String.IsNullOrWhiteSpace(snapshot.ModelName)
                    ? snapshot.ModelName : profile.Model,
                ProjectName = ProjectName(snapshot),
                InputTokens = snapshot == null ? 0 : snapshot.TurnInputTokens,
                CachedInputTokens = snapshot == null ? 0 : snapshot.TurnCachedInputTokens,
                OutputTokens = snapshot == null ? 0 : snapshot.TurnOutputTokens,
                ContextTokens = snapshot == null ? -1 : snapshot.ContextInputTokens,
                ContextWindowTokens = snapshot == null ? 0 : snapshot.ContextWindowTokens
            };
            return metrics;
        }

        private static string ProjectName(SessionSnapshot snapshot)
        {
            if (snapshot == null)
            {
                return String.Empty;
            }
            if (!String.IsNullOrWhiteSpace(snapshot.WorkingDirectory))
            {
                string trimmed = snapshot.WorkingDirectory.TrimEnd(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string leaf = Path.GetFileName(trimmed);
                if (!String.IsNullOrWhiteSpace(leaf))
                {
                    return leaf;
                }
            }
            return String.Equals(snapshot.ProjectName, "Codex",
                StringComparison.OrdinalIgnoreCase) ? String.Empty : snapshot.ProjectName;
        }
    }
}
