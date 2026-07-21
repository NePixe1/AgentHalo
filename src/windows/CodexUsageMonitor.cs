using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace CodexHalo
{
public enum CodexUsageDataStatus
    {
        NoData,
        Fresh,
        Stale,
        SignInAgain,
        ApiKey
    }

internal sealed class CodexOAuthAccess
    {
        public string SourcePath;
        public string SourceVersion;
        public string AccessToken;
        public string RefreshToken;
        public string AccountId;
        public string AccountKey;
        public DateTime ExpiresUtc;
        public DateTime LastRefreshUtc;
        public Dictionary<string, object> Document;
    }

internal sealed class CodexUsageHttpResponse
    {
        public int StatusCode;
        public string Body;
        public string RetryAfter;
    }

/// <summary>
/// Retrieves Codex quota independently of conversation JSONL. This mirrors the
/// macOS usage-monitoring provider while keeping the Windows UI and context
/// reader platform-native.
/// </summary>
public sealed class CodexUsageMonitor : IDisposable
    {
        private const string OAuthClientId = "app_EMoamEEZ73f0CkXaXp7hrann";
        private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan StaleInterval = TimeSpan.FromMinutes(10);
        private static readonly TimeSpan RefreshWindow = TimeSpan.FromMinutes(5);
        private static readonly Lazy<CodexUsageMonitor> lazyInstance =
            new Lazy<CodexUsageMonitor>(delegate { return new CodexUsageMonitor(); },
                LazyThreadSafetyMode.ExecutionAndPublication);

        private readonly object gate = new object();
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private readonly Timer refreshTimer;
        private readonly Timer localSnapshotTimer;
        private UsageMetrics remoteMetrics;
        private UsageMetrics localMetrics;
        private DateTime remoteRefreshedUtc;
        private string remoteAccountKey;
        private DateTime lastAttemptUtc;
        private DateTime cooldownUntilUtc;
        private bool refreshInFlight;
        private bool localRefreshInFlight;
        private bool disposed;
        private CodexUsageDataStatus status = CodexUsageDataStatus.NoData;

        public static CodexUsageMonitor Instance
        {
            get { return lazyInstance.Value; }
        }

        public event Action Updated;

        private CodexUsageMonitor()
        {
            serializer.MaxJsonLength = Int32.MaxValue;
            LoadMatchingCache();
            refreshTimer = new Timer(delegate { RequestRefresh(); }, null,
                TimeSpan.Zero, RefreshInterval);
            localSnapshotTimer = new Timer(delegate { RequestLocalRefresh(); }, null,
                TimeSpan.Zero, TimeSpan.FromSeconds(3));
        }

        public CodexUsageDataStatus Status
        {
            get
            {
                lock (gate)
                {
                    if (status == CodexUsageDataStatus.Fresh &&
                        remoteRefreshedUtc != DateTime.MinValue &&
                        DateTime.UtcNow - remoteRefreshedUtc > StaleInterval)
                    {
                        status = CodexUsageDataStatus.Stale;
                    }
                    return status;
                }
            }
        }

        public bool IsRefreshing
        {
            get
            {
                lock (gate)
                {
                    return refreshInFlight || localRefreshInFlight;
                }
            }
        }

        public bool TryRead(out UsageMetrics metrics)
        {
            UsageMetrics local = null;
            UsageMetrics remote = null;
            lock (gate)
            {
                if (localMetrics != null)
                {
                    local = Clone(localMetrics);
                }
                if (remoteMetrics != null)
                {
                    remote = Clone(remoteMetrics);
                }
            }
            metrics = Merge(local, remote, DateTime.UtcNow);
            RequestLocalRefresh();
            RequestRefresh();
            return HasAny(metrics);
        }

        public void RequestRefresh()
        {
            lock (gate)
            {
                DateTime now = DateTime.UtcNow;
                if (disposed || refreshInFlight || now < cooldownUntilUtc)
                {
                    return;
                }
                if (lastAttemptUtc != DateTime.MinValue &&
                    now - lastAttemptUtc < RefreshInterval)
                {
                    return;
                }
                lastAttemptUtc = now;
                refreshInFlight = true;
            }
            ThreadPool.QueueUserWorkItem(delegate { RefreshWorker(); });
        }

        internal void RequestRefreshForTest()
        {
            lock (gate)
            {
                lastAttemptUtc = DateTime.MinValue;
            }
            RequestLocalRefresh();
            RequestRefresh();
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed)
                {
                    return;
                }
                disposed = true;
            }
            refreshTimer.Dispose();
            localSnapshotTimer.Dispose();
        }

        private void RequestLocalRefresh()
        {
            lock (gate)
            {
                if (disposed || localRefreshInFlight)
                {
                    return;
                }
                localRefreshInFlight = true;
            }
            ThreadPool.QueueUserWorkItem(delegate
            {
                bool changed = false;
                try
                {
                    UsageMetrics parsed;
                    RateLimitReader.TryRead(out parsed);
                    lock (gate)
                    {
                        changed = !MetricsEqual(localMetrics, parsed);
                        localMetrics = Clone(parsed);
                    }
                }
                catch
                {
                }
                finally
                {
                    lock (gate)
                    {
                        localRefreshInFlight = false;
                    }
                    if (changed)
                    {
                        RaiseUpdated();
                    }
                }
            });
        }

        private void RefreshWorker()
        {
            bool notify = false;
            bool retryForChangedCredentials = false;
            try
            {
                CodexOAuthAccess access = CodexAuthStore.Resolve();
                if (access == null)
                {
                    lock (gate)
                    {
                        status = CodexUsageDataStatus.ApiKey;
                        remoteMetrics = null;
                        remoteAccountKey = null;
                    }
                    notify = true;
                    return;
                }

                LoadCacheForAccess(access);
                if (CodexAuthStore.NeedsRefresh(access, DateTime.UtcNow))
                {
                    string previousAccountKey = access.AccountKey;
                    access = RefreshAccess(access);
                    CodexUsageSnapshotCache.Migrate(previousAccountKey,
                        access.AccountKey);
                }

                CodexUsageHttpResponse response = FetchUsage(access);
                if (response.StatusCode == 401)
                {
                    string previousAccountKey = access.AccountKey;
                    access = RefreshAccess(access);
                    CodexUsageSnapshotCache.Migrate(previousAccountKey,
                        access.AccountKey);
                    response = FetchUsage(access);
                }
                if (response.StatusCode == 401)
                {
                    throw new InvalidOperationException("sign-in-required");
                }
                if (response.StatusCode == 429)
                {
                    DateTime retryAt = ParseRetryAfter(response.RetryAfter,
                        DateTime.UtcNow) ?? DateTime.UtcNow.Add(RefreshInterval);
                    lock (gate)
                    {
                        cooldownUntilUtc = retryAt;
                        MarkStaleLocked();
                    }
                    notify = true;
                    return;
                }
                if (response.StatusCode < 200 || response.StatusCode >= 300)
                {
                    throw new InvalidOperationException("usage-http-" +
                        response.StatusCode.ToString(CultureInfo.InvariantCulture));
                }

                CodexOAuthAccess current = CodexAuthStore.Reload(access.SourcePath);
                if (current == null || !String.Equals(current.SourceVersion,
                    access.SourceVersion, StringComparison.Ordinal))
                {
                    retryForChangedCredentials = true;
                    return;
                }

                UsageMetrics mapped;
                if (!CodexUsageResponseMapper.TryMap(response.Body,
                    DateTime.UtcNow, out mapped))
                {
                    throw new InvalidDataException("invalid usage response");
                }
                DateTime refreshedAt = DateTime.UtcNow;
                CodexUsageSnapshotCache.Store(access.AccountKey, mapped, refreshedAt);
                lock (gate)
                {
                    remoteMetrics = Clone(mapped);
                    remoteRefreshedUtc = refreshedAt;
                    remoteAccountKey = access.AccountKey;
                    status = CodexUsageDataStatus.Fresh;
                    cooldownUntilUtc = DateTime.MinValue;
                }
                notify = true;
            }
            catch (Exception ex)
            {
                lock (gate)
                {
                    if (String.Equals(ex.Message, "sign-in-required",
                        StringComparison.Ordinal))
                    {
                        status = CodexUsageDataStatus.SignInAgain;
                    }
                    else
                    {
                        MarkStaleLocked();
                    }
                }
                SettingsStorage.Log("Codex usage refresh failed: " + SafeError(ex));
                notify = true;
            }
            finally
            {
                lock (gate)
                {
                    refreshInFlight = false;
                    if (retryForChangedCredentials)
                    {
                        lastAttemptUtc = DateTime.MinValue;
                    }
                }
                if (notify)
                {
                    RaiseUpdated();
                }
                if (retryForChangedCredentials)
                {
                    RequestRefresh();
                }
            }
        }

        private void LoadMatchingCache()
        {
            try
            {
                CodexOAuthAccess access = CodexAuthStore.Resolve();
                if (access != null)
                {
                    LoadCacheForAccess(access);
                }
            }
            catch
            {
            }
        }

        private void LoadCacheForAccess(CodexOAuthAccess access)
        {
            lock (gate)
            {
                if (remoteMetrics != null && String.Equals(remoteAccountKey,
                    access.AccountKey, StringComparison.Ordinal))
                {
                    return;
                }
            }
            UsageMetrics cached;
            DateTime refreshedAt;
            if (!CodexUsageSnapshotCache.TryLoad(access.AccountKey,
                out cached, out refreshedAt))
            {
                return;
            }
            lock (gate)
            {
                remoteMetrics = cached;
                remoteRefreshedUtc = refreshedAt;
                remoteAccountKey = access.AccountKey;
                // A disk snapshot is deliberately stale until this process has
                // confirmed it with the provider at least once.
                status = CodexUsageDataStatus.Stale;
            }
        }

        private void MarkStaleLocked()
        {
            status = remoteMetrics == null
                ? CodexUsageDataStatus.NoData : CodexUsageDataStatus.Stale;
        }

        private CodexOAuthAccess RefreshAccess(CodexOAuthAccess expected)
        {
            if (String.IsNullOrWhiteSpace(expected.RefreshToken))
            {
                throw new InvalidOperationException("sign-in-required");
            }
            string form = "grant_type=refresh_token&client_id=" +
                Uri.EscapeDataString(OAuthClientId) + "&refresh_token=" +
                Uri.EscapeDataString(expected.RefreshToken);
            CodexUsageHttpResponse response = SendRequest("POST", "auth.openai.com",
                "/oauth/token", null, "application/x-www-form-urlencoded",
                Encoding.UTF8.GetBytes(form), 15);
            if (response.StatusCode == 400 || response.StatusCode == 401)
            {
                throw new InvalidOperationException("sign-in-required");
            }
            if (response.StatusCode < 200 || response.StatusCode >= 300)
            {
                throw new InvalidOperationException("token-refresh-http-" +
                    response.StatusCode.ToString(CultureInfo.InvariantCulture));
            }
            Dictionary<string, object> root = DeserializeObject(response.Body);
            string accessToken = StringValue(root, "access_token");
            if (String.IsNullOrWhiteSpace(accessToken))
            {
                throw new InvalidDataException("missing refreshed access token");
            }
            string refreshToken = StringValue(root, "refresh_token");
            string idToken = StringValue(root, "id_token");
            CodexOAuthAccess persisted = CodexAuthStore.PersistRotation(expected,
                accessToken, String.IsNullOrEmpty(refreshToken)
                    ? expected.RefreshToken : refreshToken, idToken, DateTime.UtcNow);
            if (persisted != null)
            {
                return persisted;
            }
            return CodexAuthStore.WithRotatedToken(expected, accessToken,
                String.IsNullOrEmpty(refreshToken) ? expected.RefreshToken : refreshToken);
        }

        private static CodexUsageHttpResponse FetchUsage(CodexOAuthAccess access)
        {
            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers["Authorization"] = "Bearer " + access.AccessToken;
            headers["Accept"] = "application/json";
            if (!String.IsNullOrWhiteSpace(access.AccountId))
            {
                headers["ChatGPT-Account-Id"] = access.AccountId;
            }
            return SendRequest("GET", "chatgpt.com", "/backend-api/wham/usage",
                headers, null, null, 10);
        }

        private static CodexUsageHttpResponse SendRequest(string method, string host,
            string path, Dictionary<string, string> headers, string contentType,
            byte[] body, int timeoutSeconds)
        {
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
                "https://" + host + path);
            request.Method = method;
            request.UserAgent = "AgentHalo";
            request.Accept = "application/json";
            request.AllowAutoRedirect = false;
            request.Timeout = timeoutSeconds * 1000;
            request.ReadWriteTimeout = timeoutSeconds * 1000;
            if (!String.IsNullOrEmpty(contentType))
            {
                request.ContentType = contentType;
            }
            if (headers != null)
            {
                foreach (KeyValuePair<string, string> header in headers)
                {
                    if (header.Key == "Authorization")
                    {
                        request.Headers[HttpRequestHeader.Authorization] = header.Value;
                    }
                    else if (header.Key == "Accept")
                    {
                        request.Accept = header.Value;
                    }
                    else
                    {
                        request.Headers[header.Key] = header.Value;
                    }
                }
            }
            if (body != null)
            {
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream())
                {
                    stream.Write(body, 0, body.Length);
                }
            }

            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    return ReadResponse(response);
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response == null)
                {
                    throw;
                }
                using (response)
                {
                    return ReadResponse(response);
                }
            }
        }

        private static CodexUsageHttpResponse ReadResponse(HttpWebResponse response)
        {
            string body = String.Empty;
            using (Stream stream = response.GetResponseStream())
            using (StreamReader reader = new StreamReader(stream ?? Stream.Null,
                Encoding.UTF8, true))
            {
                body = reader.ReadToEnd();
            }
            return new CodexUsageHttpResponse
            {
                StatusCode = (int)response.StatusCode,
                Body = body,
                RetryAfter = response.Headers["Retry-After"]
            };
        }

        private static DateTime? ParseRetryAfter(string value, DateTime nowUtc)
        {
            double seconds;
            if (Double.TryParse(value, NumberStyles.Float,
                CultureInfo.InvariantCulture, out seconds) && seconds >= 0)
            {
                return nowUtc.AddSeconds(seconds);
            }
            DateTime parsed;
            if (DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed))
            {
                return parsed;
            }
            return null;
        }

        private static UsageMetrics Merge(UsageMetrics local, UsageMetrics remote,
            DateTime nowUtc)
        {
            UsageMetrics result = Clone(local) ?? new UsageMetrics
            {
                ContextInputTokens = -1
            };
            if (remote == null)
            {
                return result;
            }
            if (ShouldUseRemote(remote.HasFiveHour, remote.FiveHourResetUtc,
                result.HasFiveHour, result.FiveHourResetUtc, nowUtc))
            {
                result.HasFiveHour = true;
                result.FiveHourUsedPercent = remote.FiveHourUsedPercent;
                result.FiveHourResetUtc = remote.FiveHourResetUtc;
            }
            if (ShouldUseRemote(remote.HasWeekly, remote.WeeklyResetUtc,
                result.HasWeekly, result.WeeklyResetUtc, nowUtc))
            {
                result.HasWeekly = true;
                result.WeeklyUsedPercent = remote.WeeklyUsedPercent;
                result.WeeklyResetUtc = remote.WeeklyResetUtc;
            }
            return result;
        }

        internal static UsageMetrics MergeForTest(UsageMetrics local,
            UsageMetrics remote, DateTime nowUtc)
        {
            return Merge(local, remote, nowUtc);
        }

        private static bool ShouldUseRemote(bool remoteAvailable, DateTime remoteReset,
            bool localAvailable, DateTime localReset, DateTime nowUtc)
        {
            if (!remoteAvailable)
            {
                return false;
            }
            bool remoteCurrent = remoteReset == DateTime.MinValue || remoteReset > nowUtc;
            bool localCurrent = localReset == DateTime.MinValue || localReset > nowUtc;
            return remoteCurrent || !localAvailable || !localCurrent;
        }

        private static UsageMetrics Clone(UsageMetrics source)
        {
            if (source == null)
            {
                return null;
            }
            return new UsageMetrics
            {
                HasFiveHour = source.HasFiveHour,
                HasWeekly = source.HasWeekly,
                HasMonthly = source.HasMonthly,
                FiveHourUsedPercent = source.FiveHourUsedPercent,
                WeeklyUsedPercent = source.WeeklyUsedPercent,
                MonthlyUsedPercent = source.MonthlyUsedPercent,
                FiveHourResetUtc = source.FiveHourResetUtc,
                WeeklyResetUtc = source.WeeklyResetUtc,
                MonthlyResetUtc = source.MonthlyResetUtc,
                ContextInputTokens = source.ContextInputTokens,
                ContextWindowTokens = source.ContextWindowTokens
            };
        }

        private static bool HasAny(UsageMetrics metrics)
        {
            return metrics != null && (metrics.HasFiveHour || metrics.HasWeekly ||
                metrics.HasMonthly || metrics.HasContext);
        }

        private static bool MetricsEqual(UsageMetrics left, UsageMetrics right)
        {
            if (ReferenceEquals(left, right))
            {
                return true;
            }
            if (left == null || right == null)
            {
                return false;
            }
            return left.HasFiveHour == right.HasFiveHour &&
                left.HasWeekly == right.HasWeekly &&
                left.HasMonthly == right.HasMonthly &&
                Math.Abs(left.FiveHourUsedPercent - right.FiveHourUsedPercent) < 0.0001 &&
                Math.Abs(left.WeeklyUsedPercent - right.WeeklyUsedPercent) < 0.0001 &&
                Math.Abs(left.MonthlyUsedPercent - right.MonthlyUsedPercent) < 0.0001 &&
                left.FiveHourResetUtc == right.FiveHourResetUtc &&
                left.WeeklyResetUtc == right.WeeklyResetUtc &&
                left.MonthlyResetUtc == right.MonthlyResetUtc &&
                left.ContextInputTokens == right.ContextInputTokens &&
                left.ContextWindowTokens == right.ContextWindowTokens;
        }

        private void RaiseUpdated()
        {
            Action handler = Updated;
            if (handler != null)
            {
                try
                {
                    handler();
                }
                catch
                {
                }
            }
        }

        private static string SafeError(Exception ex)
        {
            if (ex == null)
            {
                return "unknown";
            }
            return ex.GetType().Name + ": " + ex.Message;
        }

        private static Dictionary<string, object> DeserializeObject(string json)
        {
            JavaScriptSerializer parser = new JavaScriptSerializer();
            parser.MaxJsonLength = Int32.MaxValue;
            return parser.DeserializeObject(json ?? String.Empty)
                as Dictionary<string, object>;
        }

        private static string StringValue(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : String.Empty;
        }
    }

internal static class CodexAuthStore
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        static CodexAuthStore()
        {
            Serializer.MaxJsonLength = Int32.MaxValue;
        }

        public static CodexOAuthAccess Resolve()
        {
            foreach (string path in AuthPaths())
            {
                CodexOAuthAccess access = Reload(path);
                if (access != null)
                {
                    return access;
                }
            }
            return null;
        }

        public static CodexOAuthAccess Reload(string path)
        {
            try
            {
                if (String.IsNullOrWhiteSpace(path) || !File.Exists(path))
                {
                    return null;
                }
                byte[] bytes = File.ReadAllBytes(path);
                Dictionary<string, object> root = Serializer.DeserializeObject(
                    Encoding.UTF8.GetString(bytes)) as Dictionary<string, object>;
                Dictionary<string, object> tokens = Child(root, "tokens");
                string accessToken = Text(tokens, "access_token");
                if (String.IsNullOrWhiteSpace(accessToken))
                {
                    return null;
                }
                string refreshToken = Text(tokens, "refresh_token");
                string accountId = Text(tokens, "account_id");
                string sourceVersion = Sha256(bytes);
                string accountKey = !String.IsNullOrWhiteSpace(accountId)
                    ? Sha256(accountId)
                    : Sha256(path + "|" + refreshToken + "|" + accessToken);
                return new CodexOAuthAccess
                {
                    SourcePath = path,
                    SourceVersion = sourceVersion,
                    AccessToken = accessToken,
                    RefreshToken = refreshToken,
                    AccountId = accountId,
                    AccountKey = accountKey,
                    ExpiresUtc = JwtExpiry(accessToken),
                    LastRefreshUtc = ParseDate(Text(root, "last_refresh")),
                    Document = root
                };
            }
            catch
            {
                return null;
            }
        }

        public static bool NeedsRefresh(CodexOAuthAccess access, DateTime nowUtc)
        {
            if (access == null)
            {
                return false;
            }
            if (access.ExpiresUtc != DateTime.MinValue)
            {
                return access.ExpiresUtc - nowUtc <= TimeSpan.FromMinutes(5);
            }
            return access.LastRefreshUtc != DateTime.MinValue &&
                nowUtc - access.LastRefreshUtc > TimeSpan.FromDays(8);
        }

        public static CodexOAuthAccess PersistRotation(CodexOAuthAccess expected,
            string accessToken, string refreshToken, string idToken, DateTime refreshedUtc)
        {
            try
            {
                CodexOAuthAccess current = Reload(expected.SourcePath);
                if (current == null || !String.Equals(current.SourceVersion,
                    expected.SourceVersion, StringComparison.Ordinal))
                {
                    return null;
                }
                Dictionary<string, object> root = current.Document;
                Dictionary<string, object> tokens = Child(root, "tokens");
                if (tokens == null)
                {
                    tokens = new Dictionary<string, object>();
                    root["tokens"] = tokens;
                }
                tokens["access_token"] = accessToken;
                if (!String.IsNullOrWhiteSpace(refreshToken))
                {
                    tokens["refresh_token"] = refreshToken;
                }
                if (!String.IsNullOrWhiteSpace(idToken))
                {
                    tokens["id_token"] = idToken;
                }
                root["last_refresh"] = refreshedUtc.ToString("o",
                    CultureInfo.InvariantCulture);
                string compact = Serializer.Serialize(root);
                WriteAtomically(expected.SourcePath, PrettyJson.Format(compact));
                return Reload(expected.SourcePath);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Codex credential writeback failed: " +
                    ex.GetType().Name);
                return null;
            }
        }

        public static CodexOAuthAccess WithRotatedToken(CodexOAuthAccess expected,
            string accessToken, string refreshToken)
        {
            return new CodexOAuthAccess
            {
                SourcePath = expected.SourcePath,
                SourceVersion = expected.SourceVersion,
                AccessToken = accessToken,
                RefreshToken = refreshToken,
                AccountId = expected.AccountId,
                AccountKey = expected.AccountKey,
                ExpiresUtc = JwtExpiry(accessToken),
                LastRefreshUtc = DateTime.UtcNow,
                Document = expected.Document
            };
        }

        private static IEnumerable<string> AuthPaths()
        {
            string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (!String.IsNullOrWhiteSpace(codexHome))
            {
                yield return Path.Combine(codexHome.Trim(), "auth.json");
                yield break;
            }
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            yield return Path.Combine(home, ".config", "codex", "auth.json");
            yield return Path.Combine(home, ".codex", "auth.json");
        }

        private static Dictionary<string, object> Child(
            Dictionary<string, object> parent, string key)
        {
            object value;
            return parent != null && parent.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }

        private static string Text(Dictionary<string, object> parent, string key)
        {
            object value;
            return parent != null && parent.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture).Trim()
                : String.Empty;
        }

        private static DateTime ParseDate(string value)
        {
            DateTime result;
            return DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out result)
                ? result.ToUniversalTime() : DateTime.MinValue;
        }

        private static DateTime JwtExpiry(string token)
        {
            try
            {
                string[] parts = (token ?? String.Empty).Split('.');
                if (parts.Length < 2)
                {
                    return DateTime.MinValue;
                }
                string payload = parts[1].Replace('-', '+').Replace('_', '/');
                while (payload.Length % 4 != 0)
                {
                    payload += "=";
                }
                Dictionary<string, object> root = Serializer.DeserializeObject(
                    Encoding.UTF8.GetString(Convert.FromBase64String(payload)))
                    as Dictionary<string, object>;
                object value;
                double seconds;
                if (root != null && root.TryGetValue("exp", out value) &&
                    Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                        NumberStyles.Float, CultureInfo.InvariantCulture, out seconds))
                {
                    return new DateTime(1970, 1, 1, 0, 0, 0,
                        DateTimeKind.Utc).AddSeconds(seconds);
                }
            }
            catch
            {
            }
            return DateTime.MinValue;
        }

        private static string Sha256(byte[] bytes)
        {
            using (SHA256 hash = SHA256.Create())
            {
                return String.Concat(hash.ComputeHash(bytes).Select(
                    delegate(byte value) { return value.ToString("x2"); }));
            }
        }

        private static string Sha256(string text)
        {
            return Sha256(Encoding.UTF8.GetBytes(text ?? String.Empty));
        }

        private static void WriteAtomically(string path, string content)
        {
            string temporary = path + ".agenthalo.tmp";
            File.WriteAllText(temporary, content, new UTF8Encoding(false));
            try
            {
                File.Replace(temporary, path, null, true);
            }
            catch
            {
                File.Copy(temporary, path, true);
                File.Delete(temporary);
            }
        }
    }

public static class CodexUsageResponseMapper
    {
        private const double SessionSeconds = 18000;
        private const double WeeklySeconds = 604800;
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();
        private static readonly DateTime UnixEpoch =
            new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        public static bool TryMap(string json, DateTime nowUtc, out UsageMetrics metrics)
        {
            metrics = new UsageMetrics { ContextInputTokens = -1 };
            try
            {
                Dictionary<string, object> root = Serializer.DeserializeObject(json)
                    as Dictionary<string, object>;
                Dictionary<string, object> limits = Child(root, "rate_limit");
                Candidate primary = CandidateFrom(Child(limits, "primary_window"),
                    WindowKind.Session, nowUtc);
                Candidate secondary = CandidateFrom(Child(limits, "secondary_window"),
                    WindowKind.Weekly, nowUtc);
                Candidate[] candidates = new[] { primary, secondary };
                Apply(WindowKind.Session, candidates, metrics);
                Apply(WindowKind.Weekly, candidates, metrics);
                return metrics.HasFiveHour || metrics.HasWeekly;
            }
            catch
            {
                metrics = new UsageMetrics { ContextInputTokens = -1 };
                return false;
            }
        }

        internal static bool TryMapForTest(string json, DateTime nowUtc,
            out UsageMetrics metrics)
        {
            return TryMap(json, nowUtc, out metrics);
        }

        private enum WindowKind
        {
            Unknown,
            Session,
            Weekly
        }

        private sealed class Candidate
        {
            public bool Available;
            public WindowKind ExplicitKind;
            public WindowKind FallbackKind;
            public double UsedPercent;
            public DateTime ResetUtc;
        }

        private static Candidate CandidateFrom(Dictionary<string, object> source,
            WindowKind fallback, DateTime nowUtc)
        {
            Candidate result = new Candidate
            {
                FallbackKind = fallback
            };
            double used;
            if (source == null || !Number(source, "used_percent", out used))
            {
                return result;
            }
            result.Available = true;
            result.UsedPercent = Math.Max(0, Math.Min(100, used));
            double duration;
            if (Number(source, "limit_window_seconds", out duration))
            {
                if (Math.Abs(duration - SessionSeconds) < 1)
                {
                    result.ExplicitKind = WindowKind.Session;
                }
                else if (Math.Abs(duration - WeeklySeconds) < 1)
                {
                    result.ExplicitKind = WindowKind.Weekly;
                }
            }
            result.ResetUtc = ResetDate(source, nowUtc);
            return result;
        }

        private static void Apply(WindowKind kind, Candidate[] candidates,
            UsageMetrics metrics)
        {
            Candidate selected = candidates.FirstOrDefault(delegate(Candidate value)
            {
                return value != null && value.Available && value.ExplicitKind == kind;
            });
            if (selected == null)
            {
                selected = candidates.FirstOrDefault(delegate(Candidate value)
                {
                    return value != null && value.Available &&
                        value.ExplicitKind == WindowKind.Unknown &&
                        value.FallbackKind == kind;
                });
            }
            if (selected == null)
            {
                return;
            }
            if (kind == WindowKind.Session)
            {
                metrics.HasFiveHour = true;
                metrics.FiveHourUsedPercent = selected.UsedPercent;
                metrics.FiveHourResetUtc = selected.ResetUtc;
            }
            else
            {
                metrics.HasWeekly = true;
                metrics.WeeklyUsedPercent = selected.UsedPercent;
                metrics.WeeklyResetUtc = selected.ResetUtc;
            }
        }

        private static DateTime ResetDate(Dictionary<string, object> source,
            DateTime nowUtc)
        {
            object value;
            double number;
            if (source.TryGetValue("reset_at", out value))
            {
                if (Double.TryParse(Convert.ToString(value,
                    CultureInfo.InvariantCulture), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out number))
                {
                    if (number > 1000000000000)
                    {
                        number /= 1000;
                    }
                    return UnixEpoch.AddSeconds(number);
                }
                DateTime parsed;
                if (DateTime.TryParse(Convert.ToString(value,
                    CultureInfo.InvariantCulture), CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out parsed))
                {
                    return parsed;
                }
            }
            if (Number(source, "reset_after_seconds", out number))
            {
                return nowUtc.AddSeconds(number);
            }
            return DateTime.MinValue;
        }

        private static bool Number(Dictionary<string, object> source, string key,
            out double result)
        {
            result = 0;
            object value;
            return source != null && source.TryGetValue(key, out value) && value != null &&
                !(value is bool) && Double.TryParse(Convert.ToString(value,
                    CultureInfo.InvariantCulture), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out result);
        }

        private static Dictionary<string, object> Child(
            Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }
    }

internal static class CodexUsageSnapshotCache
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        private static string CachePath
        {
            get { return Path.Combine(SettingsStorage.AppDirectory,
                "usage-snapshots-v1.json"); }
        }

        public static bool TryLoad(string accountKey, out UsageMetrics metrics,
            out DateTime refreshedUtc)
        {
            metrics = null;
            refreshedUtc = DateTime.MinValue;
            try
            {
                Dictionary<string, object> root = ReadRoot();
                Dictionary<string, object> accounts = Child(root, "accounts");
                Dictionary<string, object> item = Child(accounts, accountKey);
                if (item == null)
                {
                    return false;
                }
                DateTime parsed;
                if (!DateTime.TryParse(Text(item, "refreshed_at"),
                    CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind,
                    out parsed))
                {
                    return false;
                }
                refreshedUtc = parsed.ToUniversalTime();
                metrics = new UsageMetrics { ContextInputTokens = -1 };
                ReadWindow(Child(item, "session"), true, metrics);
                ReadWindow(Child(item, "weekly"), false, metrics);
                return metrics.HasFiveHour || metrics.HasWeekly;
            }
            catch
            {
                metrics = null;
                refreshedUtc = DateTime.MinValue;
                return false;
            }
        }

        public static void Store(string accountKey, UsageMetrics metrics,
            DateTime refreshedUtc)
        {
            try
            {
                Directory.CreateDirectory(SettingsStorage.AppDirectory);
                Dictionary<string, object> root = ReadRoot();
                root["version"] = 1;
                Dictionary<string, object> accounts = Child(root, "accounts");
                if (accounts == null)
                {
                    accounts = new Dictionary<string, object>();
                    root["accounts"] = accounts;
                }
                Dictionary<string, object> item = new Dictionary<string, object>();
                item["refreshed_at"] = refreshedUtc.ToUniversalTime().ToString("o",
                    CultureInfo.InvariantCulture);
                if (metrics.HasFiveHour)
                {
                    item["session"] = Window(metrics.FiveHourUsedPercent,
                        metrics.FiveHourResetUtc);
                }
                if (metrics.HasWeekly)
                {
                    item["weekly"] = Window(metrics.WeeklyUsedPercent,
                        metrics.WeeklyResetUtc);
                }
                accounts[accountKey] = item;
                string temporary = CachePath + ".tmp";
                File.WriteAllText(temporary, PrettyJson.Format(
                    Serializer.Serialize(root)), new UTF8Encoding(false));
                if (File.Exists(CachePath))
                {
                    File.Delete(CachePath);
                }
                File.Move(temporary, CachePath);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Codex usage cache write failed: " +
                    ex.GetType().Name);
            }
        }

        public static void Migrate(string oldAccountKey, string newAccountKey)
        {
            if (String.IsNullOrWhiteSpace(oldAccountKey) ||
                String.IsNullOrWhiteSpace(newAccountKey) ||
                String.Equals(oldAccountKey, newAccountKey,
                    StringComparison.Ordinal))
            {
                return;
            }
            UsageMetrics metrics;
            DateTime refreshedUtc;
            if (TryLoad(oldAccountKey, out metrics, out refreshedUtc))
            {
                Store(newAccountKey, metrics, refreshedUtc);
            }
        }

        private static Dictionary<string, object> Window(double used,
            DateTime resetUtc)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["used_percent"] = used;
            result["resets_at"] = resetUtc == DateTime.MinValue ? String.Empty :
                resetUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
            return result;
        }

        private static void ReadWindow(Dictionary<string, object> source,
            bool session, UsageMetrics metrics)
        {
            double used;
            if (source == null || !Double.TryParse(Text(source, "used_percent"),
                NumberStyles.Float, CultureInfo.InvariantCulture, out used))
            {
                return;
            }
            DateTime reset;
            DateTime.TryParse(Text(source, "resets_at"), CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out reset);
            if (session)
            {
                metrics.HasFiveHour = true;
                metrics.FiveHourUsedPercent = used;
                metrics.FiveHourResetUtc = reset == DateTime.MinValue
                    ? DateTime.MinValue : reset.ToUniversalTime();
            }
            else
            {
                metrics.HasWeekly = true;
                metrics.WeeklyUsedPercent = used;
                metrics.WeeklyResetUtc = reset == DateTime.MinValue
                    ? DateTime.MinValue : reset.ToUniversalTime();
            }
        }

        private static Dictionary<string, object> ReadRoot()
        {
            if (!File.Exists(CachePath))
            {
                return new Dictionary<string, object>();
            }
            return Serializer.DeserializeObject(File.ReadAllText(CachePath,
                Encoding.UTF8)) as Dictionary<string, object>
                ?? new Dictionary<string, object>();
        }

        private static Dictionary<string, object> Child(
            Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }

        private static string Text(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : String.Empty;
        }
    }

internal static class PrettyJson
    {
        public static string Format(string compact)
        {
            if (String.IsNullOrEmpty(compact))
            {
                return compact;
            }
            StringBuilder output = new StringBuilder(compact.Length + 128);
            bool inString = false;
            bool escaped = false;
            int depth = 0;
            for (int index = 0; index < compact.Length; index++)
            {
                char value = compact[index];
                if (inString)
                {
                    output.Append(value);
                    if (escaped)
                    {
                        escaped = false;
                    }
                    else if (value == '\\')
                    {
                        escaped = true;
                    }
                    else if (value == '"')
                    {
                        inString = false;
                    }
                    continue;
                }
                if (value == '"')
                {
                    inString = true;
                    output.Append(value);
                }
                else if (value == '{' || value == '[')
                {
                    output.Append(value);
                    depth++;
                    if (index + 1 < compact.Length &&
                        !((value == '{' && compact[index + 1] == '}') ||
                          (value == '[' && compact[index + 1] == ']')))
                    {
                        NewLine(output, depth);
                    }
                }
                else if (value == '}' || value == ']')
                {
                    depth = Math.Max(0, depth - 1);
                    if (index > 0 && !((value == '}' && compact[index - 1] == '{') ||
                        (value == ']' && compact[index - 1] == '[')))
                    {
                        NewLine(output, depth);
                    }
                    output.Append(value);
                }
                else if (value == ',')
                {
                    output.Append(value);
                    NewLine(output, depth);
                }
                else if (value == ':')
                {
                    output.Append(": ");
                }
                else if (!Char.IsWhiteSpace(value))
                {
                    output.Append(value);
                }
            }
            return output.ToString();
        }

        private static void NewLine(StringBuilder output, int depth)
        {
            output.AppendLine();
            output.Append(' ', depth * 2);
        }
    }
}
