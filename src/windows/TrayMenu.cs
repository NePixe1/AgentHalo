using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using DrawingColor = System.Drawing.Color;
using MediaColor = System.Windows.Media.Color;
using MediaBrush = System.Windows.Media.Brush;
using MediaPen = System.Windows.Media.Pen;
using MediaPoint = System.Windows.Point;

namespace CodexHalo
{
public sealed class Win11MenuColorTable : Forms.ProfessionalColorTable
    {
        public override DrawingColor MenuItemSelected
        {
            get { return DrawingColor.FromArgb(232, 242, 246); }
        }

        public override DrawingColor MenuItemBorder
        {
            get { return DrawingColor.Transparent; }
        }

        public override DrawingColor ToolStripDropDownBackground
        {
            get { return DrawingColor.FromArgb(250, 252, 253); }
        }

        public override DrawingColor ImageMarginGradientBegin
        {
            get { return ToolStripDropDownBackground; }
        }

        public override DrawingColor ImageMarginGradientMiddle
        {
            get { return ToolStripDropDownBackground; }
        }

        public override DrawingColor ImageMarginGradientEnd
        {
            get { return ToolStripDropDownBackground; }
        }

        public override DrawingColor SeparatorDark
        {
            get { return DrawingColor.FromArgb(223, 229, 232); }
        }

        public override DrawingColor SeparatorLight
        {
            get { return DrawingColor.Transparent; }
        }
    }

public sealed class Win11MenuRenderer : Forms.ToolStripProfessionalRenderer
    {
        private static readonly DrawingColor Surface =
            DrawingColor.FromArgb(250, 252, 253);
        private static readonly DrawingColor Hover =
            DrawingColor.FromArgb(228, 240, 245);
        private static readonly DrawingColor Text =
            DrawingColor.FromArgb(42, 53, 60);
        private static readonly DrawingColor Muted =
            DrawingColor.FromArgb(102, 117, 126);
        private static readonly DrawingColor Accent =
            DrawingColor.FromArgb(48, 169, 205);

        public Win11MenuRenderer() : base(new Win11MenuColorTable())
        {
            RoundedEdges = true;
        }

        protected override void OnRenderToolStripBackground(
            Forms.ToolStripRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = RoundedRectangle(
                new System.Drawing.Rectangle(0, 0,
                    Math.Max(1, e.ToolStrip.Width - 1),
                    Math.Max(1, e.ToolStrip.Height - 1)), 10))
            using (System.Drawing.Brush brush = new SolidBrush(Surface))
            {
                e.Graphics.FillPath(brush, path);
            }
        }

        protected override void OnRenderToolStripBorder(
            Forms.ToolStripRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = RoundedRectangle(
                new System.Drawing.Rectangle(0, 0,
                    Math.Max(1, e.ToolStrip.Width - 1),
                    Math.Max(1, e.ToolStrip.Height - 1)), 10))
            using (System.Drawing.Pen pen = new System.Drawing.Pen(
                DrawingColor.FromArgb(215, 222, 226)))
            {
                e.Graphics.DrawPath(pen, path);
            }
        }

        protected override void OnRenderMenuItemBackground(
            Forms.ToolStripItemRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            DrawingColor color = e.Item.Selected ? Hover : DrawingColor.Transparent;
            if (color.A == 0)
            {
                return;
            }
            System.Drawing.Rectangle bounds = new System.Drawing.Rectangle(
                5, 2, Math.Max(1, e.Item.Width - 10), Math.Max(1, e.Item.Height - 4));
            using (GraphicsPath path = RoundedRectangle(bounds, 7))
            using (System.Drawing.Brush brush = new SolidBrush(color))
            {
                e.Graphics.FillPath(brush, path);
            }
        }

        protected override void OnRenderItemText(Forms.ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item.Enabled ? Text : DrawingColor.FromArgb(155, 164, 169);
            base.OnRenderItemText(e);
        }

        protected override void OnRenderItemCheck(
            Forms.ToolStripItemImageRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float centerX = 15;
            float centerY = e.Item.Height / 2.0f;
            using (System.Drawing.Pen pen = new System.Drawing.Pen(Accent, 1.9f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                e.Graphics.DrawLines(pen, new[]
                {
                    new System.Drawing.PointF(centerX - 4.0f, centerY),
                    new System.Drawing.PointF(centerX - 1.0f, centerY + 3.0f),
                    new System.Drawing.PointF(centerX + 5.0f, centerY - 4.0f)
                });
            }
        }

        protected override void OnRenderArrow(Forms.ToolStripArrowRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float x = e.ArrowRectangle.Left + 3;
            float y = e.ArrowRectangle.Top + e.ArrowRectangle.Height / 2.0f;
            using (System.Drawing.Pen pen = new System.Drawing.Pen(Muted, 1.5f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                e.Graphics.DrawLines(pen, new[]
                {
                    new System.Drawing.PointF(x, y - 3),
                    new System.Drawing.PointF(x + 3, y),
                    new System.Drawing.PointF(x, y + 3)
                });
            }
        }

        protected override void OnRenderSeparator(
            Forms.ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using (System.Drawing.Pen pen = new System.Drawing.Pen(
                DrawingColor.FromArgb(224, 230, 233)))
            {
                e.Graphics.DrawLine(pen, 12, y, Math.Max(12, e.Item.Width - 12), y);
            }
        }

        public static void Apply(Forms.ToolStripDropDown menu)
        {
            menu.Renderer = new Win11MenuRenderer();
            menu.BackColor = Surface;
            menu.ForeColor = Text;
            menu.Font = new System.Drawing.Font("Microsoft YaHei UI", 9.5f,
                System.Drawing.FontStyle.Regular, GraphicsUnit.Point);
            menu.Padding = new Forms.Padding(6);
            menu.DropShadowEnabled = true;
            Forms.ToolStripDropDownMenu dropDownMenu =
                menu as Forms.ToolStripDropDownMenu;
            if (dropDownMenu != null)
            {
                dropDownMenu.ShowImageMargin = false;
                dropDownMenu.ShowCheckMargin = true;
            }
            menu.Opened += delegate { ApplyRoundedRegion(menu); };
            menu.SizeChanged += delegate { ApplyRoundedRegion(menu); };
            foreach (Forms.ToolStripItem item in menu.Items)
            {
                Forms.ToolStripSeparator separator = item as Forms.ToolStripSeparator;
                if (separator != null)
                {
                    separator.AutoSize = false;
                    separator.Height = 9;
                    continue;
                }
                item.Padding = new Forms.Padding(8, 6, 8, 6);
                item.Margin = new Forms.Padding(0);
                Forms.ToolStripMenuItem menuItem = item as Forms.ToolStripMenuItem;
                if (menuItem != null && menuItem.HasDropDownItems)
                {
                    Apply(menuItem.DropDown);
                }
            }
            ApplyRoundedRegion(menu);
        }

        private static void ApplyRoundedRegion(Forms.ToolStripDropDown menu)
        {
            if (menu.Width <= 0 || menu.Height <= 0)
            {
                return;
            }
            using (GraphicsPath path = RoundedRectangle(
                new System.Drawing.Rectangle(0, 0, menu.Width, menu.Height), 10))
            {
                Region previous = menu.Region;
                menu.Region = new Region(path);
                if (previous != null)
                {
                    previous.Dispose();
                }
            }
        }

        private static GraphicsPath RoundedRectangle(
            System.Drawing.Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = Math.Max(2, radius * 2);
            System.Drawing.Rectangle arc = new System.Drawing.Rectangle(
                bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }
    }
}

