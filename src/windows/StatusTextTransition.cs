using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexHalo
{
    // Both lines share a transition; frequent monitor ticks do not restart it.
    internal sealed class StatusTextTransition
    {
        private readonly TextBlock headline;
        private readonly TextBlock subtitle;
        private string title;
        private string detail;
        private Color color;
        private bool initialized;
        private bool fadingOut;
        private int generation;

        internal StatusTextTransition(TextBlock headline, TextBlock subtitle)
        {
            this.headline = headline;
            this.subtitle = subtitle;
        }

        internal void Update(string nextTitle, string nextDetail, Color nextColor, bool animate)
        {
            bool unchanged = initialized && title == nextTitle && detail == nextDetail && color == nextColor;
            title = nextTitle;
            detail = nextDetail;
            color = nextColor;
            if (!initialized || !animate)
            {
                initialized = true;
                Settle();
                return;
            }
            if (unchanged || fadingOut) return;
            fadingOut = true;
            int ticket = ++generation;
            Fade(0, 100, EasingMode.EaseIn, delegate
            {
                if (ticket != generation) return;
                ApplyText();
                fadingOut = false;
                Fade(1, 230, EasingMode.EaseOut, null);
            });
        }

        internal void Settle()
        {
            generation++;
            fadingOut = false;
            headline.BeginAnimation(UIElement.OpacityProperty, null);
            subtitle.BeginAnimation(UIElement.OpacityProperty, null);
            headline.Opacity = subtitle.Opacity = 1;
            if (initialized) ApplyText();
        }

        private void ApplyText()
        {
            headline.Text = title;
            subtitle.Text = detail;
            headline.Foreground = new SolidColorBrush(color);
        }

        private void Fade(double target, double milliseconds, EasingMode easing, EventHandler completed)
        {
            // Capture the current animated opacity before replacing its clock.
            double from = headline.Opacity;
            headline.BeginAnimation(UIElement.OpacityProperty, null);
            subtitle.BeginAnimation(UIElement.OpacityProperty, null);
            headline.Opacity = subtitle.Opacity = target;
            var animation = new DoubleAnimation(from, target, TimeSpan.FromMilliseconds(milliseconds))
            {
                EasingFunction = new CubicEase { EasingMode = easing },
                FillBehavior = FillBehavior.Stop
            };
            subtitle.BeginAnimation(UIElement.OpacityProperty, animation);
            if (completed != null) animation.Completed += completed;
            headline.BeginAnimation(UIElement.OpacityProperty, animation);
        }
    }
}
