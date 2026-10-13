using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexHalo
{
    internal sealed class AgentContentTransition
    {
        private readonly TranslateTransform[] offsets;
        private int generation;
        internal bool IsRunning { get; private set; }

        internal AgentContentTransition(Grid stage, FrameworkElement content,
            params FrameworkElement[] textElements)
        {
            var targets = textElements.Length == 0 ? new[] { content } : textElements;
            offsets = new TranslateTransform[targets.Length];
            for (int i = 0; i < targets.Length; i++)
            {
                offsets[i] = new TranslateTransform();
                targets[i].RenderTransform = offsets[i];
            }
        }

        internal void Switch(Action update, int direction, bool animate)
        {
            // Keep native content opaque; never reveal the background between pages.
            double previous = offsets[0].X;
            Settle();
            update();
            if (!animate || direction == 0) return;
            IsRunning = true;
            int ticket = generation;
            double from = Math.Max(-8, Math.Min(8, previous + Math.Sign(direction) * 8));
            for (int i = 0; i < offsets.Length; i++)
            {
                var animation = new DoubleAnimation(from, 0, TimeSpan.FromMilliseconds(240))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                    FillBehavior = FillBehavior.Stop
                };
                if (i == 0) animation.Completed += delegate
                {
                    if (ticket == generation) Settle();
                };
                offsets[i].BeginAnimation(TranslateTransform.XProperty, animation);
            }
        }

        internal void Settle()
        {
            generation++;
            IsRunning = false;
            foreach (var offset in offsets)
            {
                offset.BeginAnimation(TranslateTransform.XProperty, null);
                offset.X = 0;
            }
        }
    }
}
