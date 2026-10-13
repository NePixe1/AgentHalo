using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexHalo
{
    internal static class SessionPanelLayoutChecks
    {
        internal static void Run()
        {
            Border empty, card;
            TextBlock emptyText, title, model, input, output;
            Grid footer;
            var slot = DetailsWindow.CreateSessionBodySlot(out empty, out emptyText,
                out card, out title, out model, out input, out output, out footer);
            card.Visibility = Visibility.Visible;
            title.Text = "A long task title that must stay on one line and be truncated";
            model.Text = "DeepSeek-V4.1-Flash";
            input.Text = DetailsWindow.FormatTokenChip(true, true, 1500);
            output.Text = DetailsWindow.FormatTokenChip(false, true, 2200);
            Check(input.Text == "↑ 1.5k" && output.Text == "↓ 2.2k", "separate token formatting");
            Check(DetailsWindow.FormatTokenChip(true, false, 123) == "↑ --", "missing usage is not zero");
            Check(DetailsWindow.FormatTokenChip(false, true, 0) == "↓ 0", "valid zero remains visible");
            Layout(slot);
            var divider = (Border)slot.Children[0];
            var modelChip = (Border)model.Parent;
            var inputChip = (Border)input.Parent;
            var outputChip = (Border)output.Parent;
            Check(card.BorderThickness == new Thickness(0) && card.Padding == new Thickness(0) && card.Background == null,
                "task area has no nested card frame or inset");
            Check(X(title, slot) == 0 && X(modelChip, slot) == 0 && X(divider, slot) == 0,
                "title, model chip and divider share left edge");
            Check(Math.Abs(X(outputChip, slot) + outputChip.ActualWidth - 266) < 0.01,
                "output chip aligns with content right edge");
            Check(modelChip.ActualHeight == 22 && inputChip.ActualHeight == 22 && outputChip.ActualHeight == 22,
                "all metadata chips have identical height");
            Check(Y(title, slot) - Y(divider, slot) == 8 && title.Margin.Bottom == 8,
                "tight divider-to-title and title-to-metadata spacing");
            Check(Math.Abs(Y(footer, slot) + footer.ActualHeight - 59) < 0.01,
                "metadata ends at the slot bottom without hidden trailing space");
            var inputColor = ((SolidColorBrush)input.Foreground).Color;
            var outputColor = ((SolidColorBrush)output.Foreground).Color;
            Check(inputColor != outputColor && inputChip.Background != null && outputChip.Background != null,
                "input and output have distinct colored chips");
            model.Text = "A very long provider and model label that should never push tokens out";
            input.Text = DetailsWindow.FormatTokenChip(true, true, 9876543);
            output.Text = DetailsWindow.FormatTokenChip(false, true, 8765432);
            Layout(slot);
            Check(X(modelChip, slot) + modelChip.ActualWidth <= X(inputChip, slot) &&
                X(outputChip, slot) + outputChip.ActualWidth <= 266.01, "long model and usage do not overlap");
            double dividerY = Y(divider, slot), titleY = Y(title, slot);
            card.Visibility = Visibility.Collapsed;
            empty.Visibility = Visibility.Visible;
            emptyText.Text = "No session";
            Layout(slot);
            Check(divider.Visibility == Visibility.Visible && Y(divider, slot) == dividerY,
                "empty state keeps the same divider");
            Check(X(emptyText, slot) == 0 && Y(emptyText, slot) == titleY && slot.ActualHeight == 59,
                "empty state shares populated text origin and height");
            Check(empty.Background == null && empty.BorderThickness == new Thickness(0) &&
                ((Grid)empty.Child).Children.Count == 1, "empty state has no legacy dashed frame");
            Check(((SolidColorBrush)divider.Background).Color == Color.FromRgb(190, 205, 215),
                "divider contrast is retained");
        }
        private static void Layout(FrameworkElement element)
        {
            element.Measure(new Size(266, 59));
            element.Arrange(new Rect(0, 0, 266, 59));
            element.UpdateLayout();
        }
        private static double X(FrameworkElement element, FrameworkElement root)
        { return element.TransformToAncestor(root).Transform(new Point()).X; }
        private static double Y(FrameworkElement element, FrameworkElement root)
        { return element.TransformToAncestor(root).Transform(new Point()).Y; }
        private static void Check(bool value, string message)
        { if (!value) throw new Exception("Session panel: " + message); }
    }
}
