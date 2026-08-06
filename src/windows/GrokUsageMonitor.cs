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
    public enum GrokUsageDataStatus
    {
        NoData,
        Fresh,
        Stale,
        SignInAgain,
        ApiKey
    }

    internal sealed class GrokOAuthAccess
    {
        public string SourcePath;
        public string SourceVersion;
        public string EntryKey;
        public string AccessToken;
        public string RefreshToken;
        public string ClientId;
        public string AccountKey;
        public DateTime ExpiresUtc;
    }

    internal sealed class GrokUsageHttpResponse
    {
        public int StatusCode;
        public string Body;
        public string RetryAfter;
    }

    /// <summary>
    /// Grok CLI OAuth credentials under ~/.grok/auth.json (multi-entry map).
    /// Persist updates one entry only; corrupt files are never overwritten.
    /// </summary>
    public static class GrokAuthStore
    {
        public static readonly TimeSpan RefreshWindow = TimeSpan.FromMinutes(5);
        public const string DefaultClientId = "b1a00492-073a-47ea-816f-4c329264a828";

        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        static GrokAuthStore()
        {
            Serializer.MaxJsonLength = Int32.MaxValue;
        }

        internal static GrokOAuthAccess Resolve()
        {
            return ResolveFromHome(DefaultHome());
        }

        internal static GrokOAuthAccess ResolveFromHome(string home)
        {
            string path = AuthPath(home);
            return Reload(path);
        }

        internal static GrokOAuthAccess Reload(string path)
        {
            try
            {
                Dictionary<string, object> root;
                if (!TryReadObject(path, out root))
                {
                    return null;
                }
                foreach (string entryKey in root.Keys.OrderBy(delegate(string key)
                {
                    return key;
                }, StringComparer.Ordinal))
                {
                    Dictionary<string, object> entry = Child(root, entryKey);
                    string accessToken = Text(entry, "key");
                    if (String.IsNullOrWhiteSpace(accessToken))
                    {
                        continue;
                    }
                    return MakeAccess(path, entryKey, entry, accessToken);
                }
            }
            catch
            {
            }
            return null;
        }

        internal static bool NeedsRefresh(GrokOAuthAccess access, DateTime nowUtc)
        {
            if (access == null || access.ExpiresUtc == DateTime.MinValue)
            {
                return false;
            }
            return access.ExpiresUtc - nowUtc <= RefreshWindow;
        }

        internal static bool Persist(GrokOAuthAccess expected, string newAccess,
            string newRefresh, DateTime? expiresAt)
        {
            if (expected == null || String.IsNullOrWhiteSpace(expected.SourcePath))
            {
                return false;
            }
            Dictionary<string, object> root;
            if (!TryReadObject(expected.SourcePath, out root))
            {
                // Present but unparseable: refuse so other accounts are not wiped.
                if (File.Exists(expected.SourcePath))
                {
                    throw new InvalidDataException("invalid Grok auth.json");
                }
                return false;
            }

            string matchKey = null;
            Dictionary<string, object> matchEntry = null;
            foreach (string entryKey in root.Keys.OrderBy(delegate(string key)
            {
                return key;
            }, StringComparer.Ordinal))
            {
                Dictionary<string, object> entry = Child(root, entryKey);
                if (entry == null)
                {
                    continue;
                }
                if (String.Equals(Text(entry, "key"), expected.AccessToken,
                    StringComparison.Ordinal))
                {
                    matchKey = entryKey;
                    matchEntry = entry;
                    break;
                }
            }
            if (matchKey == null || matchEntry == null)
            {
                return false;
            }

            string currentVersion = SourceVersion(matchKey, matchEntry);
            if (!String.Equals(currentVersion, expected.SourceVersion,
                StringComparison.Ordinal))
            {
                return false;
            }

            matchEntry["key"] = newAccess;
            if (!String.IsNullOrWhiteSpace(newRefresh))
            {
                matchEntry["refresh_token"] = newRefresh;
            }
            if (expiresAt.HasValue)
            {
                matchEntry["expires_at"] = expiresAt.Value.ToUniversalTime().ToString(
                    "o", CultureInfo.InvariantCulture);
            }
            root[matchKey] = matchEntry;
            string compact = Serializer.Serialize(root);
            WriteAtomically(expected.SourcePath, PrettyJson.Format(compact));
            return true;
        }

        /// <summary>
        /// Diagnostics / unit-test entry: rotate by old access token under a home root.
        /// Returns false on missing entry; throws on corrupt present file.
        /// </summary>
        public static bool PersistForTest(string home, string oldAccessToken,
            string newAccess, string newRefresh, DateTime expiresAt)
        {
            string path = AuthPath(home);
            Dictionary<string, object> root;
            if (!TryReadObject(path, out root))
            {
                if (File.Exists(path))
                {
                    throw new InvalidDataException("invalid Grok auth.json");
                }
                return false;
            }

            GrokOAuthAccess expected = null;
            foreach (string entryKey in root.Keys.OrderBy(delegate(string key)
            {
                return key;
            }, StringComparer.Ordinal))
            {
                Dictionary<string, object> entry = Child(root, entryKey);
                if (String.Equals(Text(entry, "key"), oldAccessToken,
                    StringComparison.Ordinal))
                {
                    expected = MakeAccess(path, entryKey, entry, oldAccessToken);
                    break;
                }
            }
            if (expected == null)
            {
                return false;
            }
            return Persist(expected, newAccess, newRefresh, expiresAt);
        }

        private static GrokOAuthAccess MakeAccess(string path, string entryKey,
            Dictionary<string, object> entry, string accessToken)
        {
            string refresh = Text(entry, "refresh_token");
            if (String.IsNullOrWhiteSpace(refresh))
            {
                refresh = Text(entry, "refresh");
            }
            DateTime entryExpires = ParseDate(Text(entry, "expires_at"));
            if (entryExpires == DateTime.MinValue)
            {
                entryExpires = ParseDate(Text(entry, "expires"));
            }
            DateTime jwtExpires = JwtExpiry(accessToken);
            DateTime expiresUtc = DateTime.MinValue;
            if (entryExpires != DateTime.MinValue && jwtExpires != DateTime.MinValue)
            {
                expiresUtc = entryExpires < jwtExpires ? entryExpires : jwtExpires;
            }
            else if (entryExpires != DateTime.MinValue)
            {
                expiresUtc = entryExpires;
            }
            else
            {
                expiresUtc = jwtExpires;
            }

            string userId = Text(entry, "user_id");
            string email = Text(entry, "email");
            string identity = !String.IsNullOrWhiteSpace(userId) ? userId
                : (!String.IsNullOrWhiteSpace(email) ? email : entryKey);

            return new GrokOAuthAccess
            {
                SourcePath = path,
                SourceVersion = SourceVersion(entryKey, entry),
                EntryKey = entryKey,
                AccessToken = accessToken,
                RefreshToken = refresh,
                ClientId = ClientIdFor(entryKey, entry),
                AccountKey = Sha256Hex(identity),
                ExpiresUtc = expiresUtc
            };
        }

        public static string ClientIdFor(string entryKey, Dictionary<string, object> entry)
        {
            string oidc = Text(entry, "oidc_client_id");
            if (!String.IsNullOrWhiteSpace(oidc))
            {
                return oidc;
            }
            if (!String.IsNullOrEmpty(entryKey))
            {
                int sep = entryKey.LastIndexOf("::", StringComparison.Ordinal);
                if (sep >= 0 && sep + 2 < entryKey.Length)
                {
                    string suffix = entryKey.Substring(sep + 2).Trim();
                    if (!String.IsNullOrEmpty(suffix))
                    {
                        return suffix;
                    }
                }
            }
            return DefaultClientId;
        }

        private static bool TryReadObject(string path, out Dictionary<string, object> root)
        {
            root = null;
            try
            {
                if (String.IsNullOrWhiteSpace(path) || !File.Exists(path))
                {
                    return false;
                }
                string text = File.ReadAllText(path, Encoding.UTF8);
                object parsed = Serializer.DeserializeObject(text);
                root = parsed as Dictionary<string, object>;
                return root != null;
            }
            catch
            {
                root = null;
                return false;
            }
        }

        private static string AuthPath(string home)
        {
            string root = String.IsNullOrWhiteSpace(home) ? DefaultHome() : home.Trim();
            return Path.Combine(root, ".grok", "auth.json");
        }

        private static string DefaultHome()
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        private static string SourceVersion(string entryKey, Dictionary<string, object> entry)
        {
            // Stable digest of identity fields only (never log tokens).
            StringBuilder sb = new StringBuilder();
            sb.Append(entryKey ?? String.Empty).Append('|');
            sb.Append(Text(entry, "key")).Append('|');
            sb.Append(Text(entry, "refresh_token")).Append('|');
            sb.Append(Text(entry, "refresh")).Append('|');
            sb.Append(Text(entry, "expires_at")).Append('|');
            sb.Append(Text(entry, "expires")).Append('|');
            sb.Append(Text(entry, "user_id")).Append('|');
            sb.Append(Text(entry, "email")).Append('|');
            sb.Append(Text(entry, "oidc_client_id"));
            return Sha256Hex(sb.ToString());
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

        private static string Sha256Hex(string text)
        {
            using (SHA256 hash = SHA256.Create())
            {
                return String.Concat(hash.ComputeHash(
                    Encoding.UTF8.GetBytes(text ?? String.Empty)).Select(
                    delegate(byte value) { return value.ToString("x2"); }));
            }
        }

        private static void WriteAtomically(string path, string content)
        {
            string directory = Path.GetDirectoryName(path);
            if (!String.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }
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

    /// <summary>
    /// Official xAI Grok CLI HTTP surfaces only (token + billing + settings).
    /// </summary>
    public static class GrokUsageHttp
    {
        public const string DefaultClientId = GrokAuthStore.DefaultClientId;
        public const string TokenAuthHeader = "xai-grok-cli";

        internal static GrokUsageHttpResponse RefreshToken(string refreshToken,
            string clientId, UsageFocusLease lease)
        {
            UsageFocusGate.ThrowIfInactive(lease);
            string form = "grant_type=refresh_token&client_id=" +
                Uri.EscapeDataString(clientId ?? DefaultClientId) +
                "&refresh_token=" + Uri.EscapeDataString(refreshToken ?? String.Empty);
            return SendRequest(lease, "POST", "auth.x.ai", "/oauth2/token", null,
                "application/x-www-form-urlencoded", Encoding.UTF8.GetBytes(form), 15);
        }

        internal static GrokUsageHttpResponse FetchBilling(
            string accessToken, UsageFocusLease lease)
        {
            UsageFocusGate.ThrowIfInactive(lease);
            return SendRequest(lease, "GET", "cli-chat-proxy.grok.com",
                "/v1/billing?format=credits", AuthHeaders(accessToken), null, null, 10);
        }

        private static Dictionary<string, string> AuthHeaders(string accessToken)
        {
            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers["Authorization"] = "Bearer " +
                (accessToken ?? String.Empty).Trim();
            headers["X-XAI-Token-Auth"] = TokenAuthHeader;
            headers["Accept"] = "application/json";
            return headers;
        }

        private static GrokUsageHttpResponse SendRequest(
            UsageFocusLease lease, string method, string host,
            string path, Dictionary<string, string> headers, string contentType,
            byte[] body, int timeoutSeconds)
        {
            UsageFocusGate.ThrowIfInactive(lease);
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
            if (!UsageFocusGate.RegisterRequest(lease, request))
            {
                throw new OperationCanceledException(
                    "usage provider is no longer focused");
            }
            try
            {
                if (body != null)
                {
                    request.ContentLength = body.Length;
                    try
                    {
                        using (Stream stream = request.GetRequestStream())
                        {
                            stream.Write(body, 0, body.Length);
                        }
                    }
                    catch (Exception ex)
                    {
                        UsageFocusGate.ThrowIfInactive(lease, ex);
                        throw;
                    }
                }

                try
                {
                    using (HttpWebResponse response =
                        (HttpWebResponse)request.GetResponse())
                    {
                        return ReadResponse(response);
                    }
                }
                catch (WebException ex)
                {
                    HttpWebResponse response = ex.Response as HttpWebResponse;
                    if (response == null)
                    {
                        UsageFocusGate.ThrowIfInactive(lease, ex);
                        throw;
                    }
                    using (response)
                    {
                        return ReadResponse(response);
                    }
                }
            }
            finally
            {
                UsageFocusGate.UnregisterRequest(request);
            }
        }

        private static GrokUsageHttpResponse ReadResponse(HttpWebResponse response)
        {
            string body = String.Empty;
            using (Stream stream = response.GetResponseStream())
            using (StreamReader reader = new StreamReader(stream ?? Stream.Null,
                Encoding.UTF8, true))
            {
                body = reader.ReadToEnd();
            }
            return new GrokUsageHttpResponse
            {
                StatusCode = (int)response.StatusCode,
                Body = body,
                RetryAfter = response.Headers["Retry-After"]
            };
        }
    }

    /// <summary>
    /// Maps Grok credits billing JSON into <see cref="UsageMetrics"/> (weekly only).
    /// Absent creditUsagePercent is 0 (proto-JSON); non-weekly periods do not fake weekly.
    /// </summary>
    public static class GrokUsageResponseMapper
    {
        public const string WeeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY";
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        static GrokUsageResponseMapper()
        {
            Serializer.MaxJsonLength = Int32.MaxValue;
        }

        public static bool TryMap(string body, out UsageMetrics metrics)
        {
            metrics = new UsageMetrics { ContextInputTokens = -1 };
            try
            {
                Dictionary<string, object> root = Serializer.DeserializeObject(
                    body ?? String.Empty) as Dictionary<string, object>;
                Dictionary<string, object> config = Child(root, "config");
                Dictionary<string, object> period = Child(config, "currentPeriod");
                if (config == null || period == null)
                {
                    return false;
                }
                string periodType = Text(period, "type");
                if (String.IsNullOrWhiteSpace(periodType))
                {
                    return false;
                }
                DateTime start = ParseDate(Text(period, "start"));
                DateTime end = ParseDate(Text(period, "end"));
                if (start == DateTime.MinValue || end == DateTime.MinValue || end <= start)
                {
                    return false;
                }

                double percent;
                object rawPercent;
                if (config.TryGetValue("creditUsagePercent", out rawPercent) &&
                    rawPercent != null)
                {
                    if (!TryNumber(rawPercent, out percent))
                    {
                        return false;
                    }
                }
                else
                {
                    percent = 0;
                }

                if (String.Equals(periodType.Trim(), WeeklyPeriodType,
                    StringComparison.Ordinal))
                {
                    metrics.HasWeekly = true;
                    metrics.WeeklyUsedPercent = Math.Max(0, Math.Min(100, percent));
                    metrics.WeeklyResetUtc = end;
                }
                // Non-weekly: success with empty weekly window (do not mislabel).
                return true;
            }
            catch
            {
                metrics = new UsageMetrics { ContextInputTokens = -1 };
                return false;
            }
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
            if (String.IsNullOrWhiteSpace(value))
            {
                return DateTime.MinValue;
            }
            string normalized = value.Trim();
            if (normalized.EndsWith(" UTC", StringComparison.Ordinal))
            {
                normalized = normalized.Substring(0, normalized.Length - 3).TrimEnd() + "Z";
            }
            DateTime result;
            if (DateTime.TryParse(normalized, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out result))
            {
                return result.ToUniversalTime();
            }
            return DateTime.MinValue;
        }

        private static bool TryNumber(object value, out double number)
        {
            number = 0;
            if (value == null || value is bool)
            {
                return false;
            }
            if (value is double)
            {
                number = (double)value;
                return !Double.IsNaN(number) && !Double.IsInfinity(number);
            }
            if (value is float)
            {
                number = (float)value;
                return !Double.IsNaN(number) && !Double.IsInfinity(number);
            }
            if (value is int)
            {
                number = (int)value;
                return true;
            }
            if (value is long)
            {
                number = (long)value;
                return true;
            }
            if (value is decimal)
            {
                number = (double)(decimal)value;
                return true;
            }
            return Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                NumberStyles.Float, CultureInfo.InvariantCulture, out number) &&
                !Double.IsNaN(number) && !Double.IsInfinity(number);
        }
    }

    /// <summary>
    /// Polls Grok weekly OAuth credits independently of session lifecycle.
    /// Mirrors <see cref="CodexUsageMonitor"/> (5 min timer, 10 min stale, Updated).
    /// Usage failures never affect the halo ring lifecycle.
    /// </summary>
    public sealed class GrokUsageMonitor : IDisposable
    {
        private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan StaleInterval = TimeSpan.FromMinutes(10);
        private static readonly Lazy<GrokUsageMonitor> lazyInstance =
            new Lazy<GrokUsageMonitor>(delegate { return new GrokUsageMonitor(); },
                LazyThreadSafetyMode.ExecutionAndPublication);

        private readonly object gate = new object();
        private readonly Timer refreshTimer;
        private UsageMetrics remoteMetrics;
        private DateTime remoteRefreshedUtc;
        private DateTime lastAttemptUtc;
        private DateTime cooldownUntilUtc;
        private bool refreshInFlight;
        private bool active;
        private bool disposed;
        private GrokUsageDataStatus status = GrokUsageDataStatus.NoData;

        public static GrokUsageMonitor Instance
        {
            get { return lazyInstance.Value; }
        }

        public event Action Updated;

        private GrokUsageMonitor()
        {
            refreshTimer = new Timer(delegate { RequestRefresh(); }, null,
                Timeout.Infinite, Timeout.Infinite);
        }

        internal bool IsActiveForTest
        {
            get
            {
                lock (gate)
                {
                    return active;
                }
            }
        }

        internal void SetActive(bool value)
        {
            bool requestNow = false;
            lock (gate)
            {
                if (disposed || active == value)
                {
                    return;
                }
                active = value;
                if (active)
                {
                    int interval = (int)RefreshInterval.TotalMilliseconds;
                    refreshTimer.Change(interval, interval);
                    requestNow = true;
                }
                else
                {
                    refreshTimer.Change(Timeout.Infinite, Timeout.Infinite);
                }
            }
            if (requestNow)
            {
                RequestRefresh();
            }
        }

        public GrokUsageDataStatus Status
        {
            get
            {
                lock (gate)
                {
                    if (status == GrokUsageDataStatus.Fresh &&
                        remoteRefreshedUtc != DateTime.MinValue &&
                        DateTime.UtcNow - remoteRefreshedUtc > StaleInterval)
                    {
                        status = GrokUsageDataStatus.Stale;
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
                    return refreshInFlight;
                }
            }
        }

        public bool TryRead(out UsageMetrics metrics)
        {
            lock (gate)
            {
                metrics = Clone(remoteMetrics);
            }
            RequestRefresh();
            return metrics != null && metrics.HasWeekly;
        }

        public void RequestRefresh()
        {
            UsageFocusLease lease = null;
            lock (gate)
            {
                DateTime now = DateTime.UtcNow;
                if (disposed || !active || refreshInFlight ||
                    now < cooldownUntilUtc ||
                    !UsageFocusGate.TryAcquire(AgentKind.Grok, out lease))
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
            ThreadPool.QueueUserWorkItem(delegate { RefreshWorker(lease); });
        }

        internal void RequestRefreshForTest()
        {
            lock (gate)
            {
                lastAttemptUtc = DateTime.MinValue;
            }
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
                active = false;
                disposed = true;
            }
            refreshTimer.Dispose();
        }

        private void RefreshWorker(UsageFocusLease lease)
        {
            bool notify = false;
            bool cancelledByFocus = false;
            try
            {
                UsageFocusGate.ThrowIfInactive(lease);
                GrokOAuthAccess access = GrokAuthStore.Resolve();
                if (access == null)
                {
                    lock (gate)
                    {
                        status = GrokUsageDataStatus.SignInAgain;
                        remoteMetrics = null;
                    }
                    notify = true;
                    return;
                }

                if (GrokAuthStore.NeedsRefresh(access, DateTime.UtcNow))
                {
                    access = RefreshAccess(access, lease);
                }

                GrokUsageHttpResponse response = GrokUsageHttp.FetchBilling(
                    access.AccessToken, lease);
                if (response.StatusCode == 401)
                {
                    access = RefreshAccess(access, lease);
                    response = GrokUsageHttp.FetchBilling(
                        access.AccessToken, lease);
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

                UsageMetrics mapped;
                if (!GrokUsageResponseMapper.TryMap(response.Body, out mapped))
                {
                    throw new InvalidDataException("invalid usage response");
                }
                UsageFocusGate.ThrowIfInactive(lease);
                DateTime refreshedAt = DateTime.UtcNow;
                lock (gate)
                {
                    remoteMetrics = Clone(mapped);
                    remoteRefreshedUtc = refreshedAt;
                    status = GrokUsageDataStatus.Fresh;
                    cooldownUntilUtc = DateTime.MinValue;
                }
                notify = true;
            }
            catch (OperationCanceledException)
            {
                cancelledByFocus = true;
            }
            catch (Exception ex)
            {
                if (!UsageFocusGate.IsCurrent(lease))
                {
                    cancelledByFocus = true;
                }
                else
                {
                    lock (gate)
                    {
                        if (String.Equals(ex.Message, "sign-in-required",
                            StringComparison.Ordinal))
                        {
                            status = GrokUsageDataStatus.SignInAgain;
                        }
                        else
                        {
                            MarkStaleLocked();
                        }
                    }
                    SettingsStorage.Log("Grok usage refresh failed: " + SafeError(ex));
                    notify = true;
                }
            }
            finally
            {
                bool restartAfterFocusCancellation;
                lock (gate)
                {
                    refreshInFlight = false;
                    if (cancelledByFocus)
                    {
                        lastAttemptUtc = DateTime.MinValue;
                    }
                    restartAfterFocusCancellation =
                        cancelledByFocus && active;
                }
                if (notify && UsageFocusGate.IsCurrent(lease))
                {
                    RaiseUpdated();
                }
                if (restartAfterFocusCancellation)
                {
                    RequestRefresh();
                }
            }
        }

        private GrokOAuthAccess RefreshAccess(
            GrokOAuthAccess expected, UsageFocusLease lease)
        {
            UsageFocusGate.ThrowIfInactive(lease);
            if (String.IsNullOrWhiteSpace(expected.RefreshToken))
            {
                throw new InvalidOperationException("sign-in-required");
            }
            GrokUsageHttpResponse response = GrokUsageHttp.RefreshToken(
                expected.RefreshToken,
                String.IsNullOrWhiteSpace(expected.ClientId)
                    ? GrokUsageHttp.DefaultClientId : expected.ClientId,
                lease);
            UsageFocusGate.ThrowIfInactive(lease);
            if (response.StatusCode == 400 || response.StatusCode == 401)
            {
                throw new InvalidOperationException("sign-in-required");
            }
            if (response.StatusCode < 200 || response.StatusCode >= 300)
            {
                throw new InvalidOperationException("token-refresh-http-" +
                    response.StatusCode.ToString(CultureInfo.InvariantCulture));
            }
            JavaScriptSerializer parser = new JavaScriptSerializer();
            parser.MaxJsonLength = Int32.MaxValue;
            Dictionary<string, object> root = parser.DeserializeObject(
                response.Body ?? String.Empty) as Dictionary<string, object>;
            string accessToken = StringValue(root, "access_token");
            if (String.IsNullOrWhiteSpace(accessToken))
            {
                throw new InvalidDataException("missing refreshed access token");
            }
            string refreshToken = StringValue(root, "refresh_token");
            if (String.IsNullOrEmpty(refreshToken))
            {
                refreshToken = expected.RefreshToken;
            }
            DateTime? expiresAt = null;
            object expiresIn;
            double seconds;
            if (root != null && root.TryGetValue("expires_in", out expiresIn) &&
                Double.TryParse(Convert.ToString(expiresIn, CultureInfo.InvariantCulture),
                    NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) &&
                seconds > 0)
            {
                expiresAt = DateTime.UtcNow.AddSeconds(seconds);
            }

            try
            {
                bool persisted = UsageFocusGate.RunCredentialWrite(
                    lease, delegate
                    {
                        return GrokAuthStore.Persist(
                            expected, accessToken, refreshToken, expiresAt);
                    });
                if (persisted)
                {
                    GrokOAuthAccess reloaded = GrokAuthStore.Reload(expected.SourcePath);
                    if (reloaded != null)
                    {
                        return reloaded;
                    }
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                // Never log tokens; continue with in-memory rotation.
                SettingsStorage.Log("Grok credential writeback failed: " +
                    ex.GetType().Name);
            }

            return new GrokOAuthAccess
            {
                SourcePath = expected.SourcePath,
                SourceVersion = expected.SourceVersion,
                EntryKey = expected.EntryKey,
                AccessToken = accessToken,
                RefreshToken = refreshToken,
                ClientId = expected.ClientId,
                AccountKey = expected.AccountKey,
                ExpiresUtc = expiresAt ?? DateTime.MinValue
            };
        }

        private void MarkStaleLocked()
        {
            status = remoteMetrics == null
                ? GrokUsageDataStatus.NoData : GrokUsageDataStatus.Stale;
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

        private static string StringValue(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : String.Empty;
        }
    }
}
