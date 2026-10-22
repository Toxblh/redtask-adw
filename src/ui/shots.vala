namespace Redmine {
    /**
     * Скриншоты для README/metainfo и визуальной проверки: REDMINE_ADW_SHOT=путь.png — через REDMINE_ADW_SHOT_DELAY мс
     * окно рендерится само в PNG (Wayland не даёт снимать чужие окна) и приложение выходит.
     * REDMINE_ADW_SHOT_SIZE=ШxВ, REDMINE_ADW_SHOT_ISSUE=номер — открыть задачу, REDMINE_ADW_SHOT_SECTION=имя раздела.
     */
    namespace Shots {
        public void schedule (Window w) {
            var size = Environment.get_variable ("REDMINE_ADW_SHOT_SIZE") ?? "1200x760";
            var wh = size.split ("x");
            w.set_default_size (int.parse (wh[0]), int.parse (wh[1]));
            var delay = int.parse (Environment.get_variable ("REDMINE_ADW_SHOT_DELAY") ?? "6000");
            Timeout.add (delay / 2, () => {
                var sec = Environment.get_variable ("REDMINE_ADW_SHOT_SECTION");
                if (sec != null) w.show_section (sec);
                var issue = Environment.get_variable ("REDMINE_ADW_SHOT_ISSUE");
                if (issue != null) w.open_issue (int.parse (issue));
                return Source.REMOVE;
            });
            Timeout.add (delay, () => {
                save (w, Environment.get_variable ("REDMINE_ADW_SHOT"));
                w.application.quit ();
                return Source.REMOVE;
            });
        }

        public void save (Gtk.Widget w, string path) {
            var paintable = new Gtk.WidgetPaintable (w);
            var snap = new Gtk.Snapshot ();
            paintable.snapshot (snap, w.get_width (), w.get_height ());
            var node = snap.to_node ();
            if (node == null) { warning ("shot: empty render node"); return; }
            var tex = w.get_native ().get_renderer ().render_texture (node, null);
            tex.save_to_png (path);
        }
    }
}
