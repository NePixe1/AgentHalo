using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    public sealed class L10n
    {
        private static readonly L10n _instance = new L10n();
        public static L10n Instance => _instance;

        private static readonly string[] SupportedLanguages = { "zh", "en" };
        private const string FallbackLanguage = "zh";

        private Dictionary<string, string> _translations = new Dictionary<string, string>();
        private string _currentLanguage = FallbackLanguage;

        public string CurrentLanguage => _currentLanguage;

        public event EventHandler LanguageChanged;

        private L10n() { }

        /// <summary>
        /// Configure language. Pass null to follow the system language.
        /// </summary>
        public void SetLanguage(string lang)
        {
            string resolved = ResolveLanguage(lang);
            if (resolved == _currentLanguage) return;
            _currentLanguage = resolved;
            LoadTranslations();
            LanguageChanged?.Invoke(this, EventArgs.Empty);
        }

        public string this[string key]
        {
            get
            {
                string value;
                return _translations.TryGetValue(key, out value) ? value : key;
            }
        }

        public string Format(string key, params object[] args)
        {
            string template = this[key];
            return string.Format(template, args);
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

        private void LoadTranslations()
        {
            string localesDir = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "locales");
            string filePath = Path.Combine(localesDir, _currentLanguage + ".json");

            if (!File.Exists(filePath) && _currentLanguage != FallbackLanguage)
            {
                filePath = Path.Combine(localesDir, FallbackLanguage + ".json");
            }

            if (File.Exists(filePath))
            {
                try
                {
                    string json = File.ReadAllText(filePath, System.Text.Encoding.UTF8);
                    var serializer = new JavaScriptSerializer();
                    _translations = serializer.Deserialize<Dictionary<string, string>>(json)
                        ?? new Dictionary<string, string>();
                    return;
                }
                catch { }
            }
            _translations = new Dictionary<string, string>();
        }
    }
}
