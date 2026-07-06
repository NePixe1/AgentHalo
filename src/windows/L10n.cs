using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    public sealed class L10n
    {
        private static readonly L10n _instance = new L10n();
        public static L10n Instance { get { return _instance; } }

        private static readonly string[] SupportedLanguages = { "zh", "en" };
        private const string FallbackLanguage = "zh";

        private readonly object _gate = new object();
        private Dictionary<string, string> _translations = new Dictionary<string, string>();
        private string _currentLanguage = FallbackLanguage;

        public string CurrentLanguage
        {
            get { lock (_gate) { return _currentLanguage; } }
        }

        public event EventHandler LanguageChanged;

        private L10n()
        {
            // Load fallback translations eagerly so call sites work even
            // before someone explicitly calls SetLanguage().
            lock (_gate)
            {
                LoadTranslationsLocked();
            }
        }

        /// <summary>
        /// Configure language. Pass null to follow the system language.
        /// </summary>
        public void SetLanguage(string lang)
        {
            string resolved = ResolveLanguage(lang);
            lock (_gate)
            {
                if (resolved == _currentLanguage) return;
                _currentLanguage = resolved;
                LoadTranslationsLocked();
            }
            EventHandler handler = LanguageChanged;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        public string this[string key]
        {
            get
            {
                string value;
                lock (_gate)
                {
                    if (_translations.TryGetValue(key, out value)) return value;
                }
                #if DEBUG
                Debug.WriteLine("[L10n] missing translation for key: " + key);
                #endif
                return key;
            }
        }

        public string Format(string key, params object[] args)
        {
            string template = this[key];
            if (args == null || args.Length == 0) return template;
            try
            {
                return string.Format(CultureInfo.InvariantCulture, template, args);
            }
            catch (FormatException ex)
            {
                DebugLog("[L10n] format failed for key=" + key +
                    " template=" + template + ": " + ex.Message);
                return template;
            }
        }

        public static string DetectSystemLanguage()
        {
            try
            {
                string culture = CultureInfo.CurrentUICulture.Name; // e.g. "zh-CN", "en-US"
                string code = culture.Split('-')[0].ToLowerInvariant();
                if (SupportedLanguages.Contains(code)) return code;
            }
            catch { }
            return FallbackLanguage;
        }

        private static string ResolveLanguage(string explicitLang)
        {
            if (explicitLang != null && SupportedLanguages.Contains(explicitLang))
                return explicitLang;
            return DetectSystemLanguage();
        }

        // Must be called while holding _gate.
        private void LoadTranslationsLocked()
        {
            string json = LoadEmbeddedJson(_currentLanguage);
            if (json == null && _currentLanguage != FallbackLanguage)
            {
                json = LoadEmbeddedJson(FallbackLanguage);
            }
            if (json == null)
            {
                json = LoadExternalJson(_currentLanguage);
            }
            if (json == null && _currentLanguage != FallbackLanguage)
            {
                json = LoadExternalJson(FallbackLanguage);
            }
            if (json != null)
            {
                try
                {
                    var serializer = new JavaScriptSerializer();
                    _translations = serializer.Deserialize<Dictionary<string, string>>(json)
                        ?? new Dictionary<string, string>();
                    return;
                }
                catch (Exception ex)
                {
                    DebugLog("[L10n] failed to parse translations: " + ex.Message);
                }
            }
            _translations = new Dictionary<string, string>();
        }

        private static string LoadEmbeddedJson(string language)
        {
            try
            {
                string resourceName = "CodexHalo.locales." + language + ".json";
                using (Stream stream = Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream(resourceName))
                {
                    if (stream == null) return null;
                    using (StreamReader reader = new StreamReader(stream,
                        System.Text.Encoding.UTF8))
                    {
                        return reader.ReadToEnd();
                    }
                }
            }
            catch (Exception ex)
            {
                DebugLog("[L10n] failed to load embedded locale " + language +
                    ": " + ex.Message);
                return null;
            }
        }

        private static string LoadExternalJson(string language)
        {
            string localesDir = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "locales");
            string filePath = Path.Combine(localesDir, language + ".json");

            if (File.Exists(filePath))
            {
                try
                {
                    return File.ReadAllText(filePath, System.Text.Encoding.UTF8);
                }
                catch (Exception ex)
                {
                    DebugLog("[L10n] failed to load " + filePath + ": " + ex.Message);
                }
            }
            return null;
        }

        [Conditional("DEBUG")]
        private static void DebugLog(string message)
        {
            Debug.WriteLine(message);
        }
    }
}
