using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace CodexHalo
{
    internal static class StatusTextTransitionChecks
    {
        internal static void Run()
        {
            var title = new TextBlock();
            var detail = new TextBlock();
            var content = new StackPanel();
            content.Children.Add(title);
            content.Children.Add(detail);
            var host = new Window { Content = content, Width = 1, Height = 1,
                Left = -32000, Top = -32000, Opacity = 0,
                ShowActivated = false, ShowInTaskbar = false };
            host.Show();
            try
            {
            var transition = new StatusTextTransition(title, detail);
            transition.Update("THINKING", "Thinking", Colors.Gold, false);
            Check(title.Text == "THINKING" && title.Opacity == 1, "initial content is immediate");
            transition.Update("EXECUTING", "Using tools", Colors.Blue, true);
            Check(title.Text == "THINKING", "no hard text cut at transition start");
            transition.Update("NEEDS YOU", "Waiting", Colors.Purple, true);
            Pump(450);
            Check(title.Text == "NEEDS YOU" && detail.Text == "Waiting", "latest pending state wins");
            Check(((SolidColorBrush)title.Foreground).Color == Colors.Purple, "text and color change together");
            Check(Math.Abs(title.Opacity - 1) < 0.001 && Math.Abs(detail.Opacity - 1) < 0.001, "both lines settle fully visible");
            transition.Update("COMPLETE", "Complete", Colors.Green, true);
            transition.Settle();
            Pump(150);
            Check(title.Text == "COMPLETE" && title.Opacity == 1, "hide cancels stale callbacks");
            transition.Update("OFFLINE", "Offline", Colors.Gray, false);
            Check(title.Text == "OFFLINE" && title.Opacity == 1, "reduced motion updates immediately");
            var page = new TextBlock { Text = "Codex" };
            var stage = new System.Windows.Controls.Grid { Width = 240, Height = 120 };
            stage.Children.Add(page);
            host.Content = stage;
            host.Width = 240;
            host.Height = 120;
            host.UpdateLayout();
            var slide = new AgentContentTransition(stage, page);
            slide.Switch(delegate { page.Text = "Pi"; }, 1, true);
            Pump(40);
            Check(((TranslateTransform)page.RenderTransform).X > 0, "right agent enters from right");
            Check(page.Opacity == 1 && stage.Opacity == 1, "switch never fades content away");
            slide.Switch(delegate { page.Text = "Codex"; }, -1, true);
            Pump(40);
            Check(((TranslateTransform)page.RenderTransform).X < 0, "left agent enters from left");
            Pump(450);
            Check(page.Text == "Codex" && page.Opacity == 1 &&
                ((TranslateTransform)page.RenderTransform).X == 0, "reversed slide settles on latest agent");
            Check(stage.Children.Count == 1, "no outgoing screenshot overlay");
            slide.Switch(delegate { page.Text = "Pi"; }, 1, false);
            Check(page.Text == "Pi" && page.Opacity == 1, "hidden agent switch is immediate");
            }
            finally { host.Close(); }
        }
        private static void Pump(int milliseconds)
        {
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
            timer.Tick += delegate { timer.Stop(); frame.Continue = false; };
            timer.Start();
            Dispatcher.PushFrame(frame);
        }
        private static void Check(bool ok, string message)
        {
            if (!ok) throw new InvalidOperationException("Status transition: " + message);
        }
    }
}
