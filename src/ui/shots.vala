namespace Redmine {
    /**
     * Скриншоты для README/metainfo и визуальной проверки: REDMINE_ADW_SHOT=путь.png — через REDMINE_ADW_SHOT_DELAY мс
     * окно рендерится само в PNG (Wayland не даёт снимать чужие окна) и приложение выходит.
     * REDMINE_ADW_SHOT_SIZE=ШxВ, REDMINE_ADW_SHOT_ISSUE=номер — открыть задачу, REDMINE_ADW_SHOT_SECTION=имя раздела.
     * REDMINE_ADW_SHOT_FULL=1 — ещё и экран задачи целиком, без обрезки прокруткой: путь.png.full.png.
     */
    namespace Shots {
        public void schedule (Window w) {
            // мигающий курсор в поле ввода держит окно в перерисовке — снимок выходит пустым
            Gtk.Settings.get_default ().gtk_cursor_blink = false;
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
            // REDMINE_ADW_SHOT_ACTION=issue.edit | win.new-issue | app.preferences — открыть диалог для снимка
            var action = Environment.get_variable ("REDMINE_ADW_SHOT_ACTION");
            if (action != null) Timeout.add (delay * 3 / 4, () => {
                var page = w.visible_issue ();
                if (action.has_prefix ("issue.") && page != null) {
                    if (!page.activate_action (action, null)) warning ("shot: action %s not found", action);
                }
                else if (action.has_prefix ("app.")) w.application.activate_action (action.substring (4), null);
                if (Environment.get_variable ("REDMINE_ADW_SHOT_CLOSE") != null) Timeout.add (2000, () => {
                    debug ("shot: closing dialog %s", (w.visible_dialog != null).to_string ());
                    w.visible_dialog?.force_close ();
                    return Source.REMOVE;
                });
                else w.activate_action (action, null);
                return Source.REMOVE;
            });
            int ticks = 0;
            w.add_tick_callback ((wd, clock) => { ticks++; return Source.CONTINUE; });
            Timeout.add (delay - 1000, () => { ticks = 0; return Source.REMOVE; });
            Timeout.add (delay, () => {
                debug ("shot: frames in the last second: %d", ticks);
                save (w, Environment.get_variable ("REDMINE_ADW_SHOT"));
                var page = w.visible_issue ();
                var clamp = page != null && Environment.get_variable ("REDMINE_ADW_SHOT_FULL") != null ? find_clamp (page) : null;
                if (clamp != null) save (clamp, Environment.get_variable ("REDMINE_ADW_SHOT") + ".full.png");
                var d = w.visible_dialog;
                if (d != null) {
                    debug ("shot: dialog %s %dx%d mapped=%s", d.get_type ().name (), d.get_width (), d.get_height (), d.get_mapped ().to_string ());
                    save (d, Environment.get_variable ("REDMINE_ADW_SHOT") + ".dialog.png");
                }
                w.application.quit ();
                return Source.REMOVE;
            });
        }

        private Gtk.Widget? find_clamp (Gtk.Widget w) {
            if (w is Adw.Clamp && w.parent is Gtk.Viewport && w.get_mapped ()) return w;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_clamp (c);
                if (r != null) return r;
            }
            return null;
        }

        public void save (Gtk.Widget w, string path) {
            debug ("shot: %s %dx%d mapped=%s toplevels=%u", w.get_type ().name (), w.get_width (), w.get_height (), w.get_mapped ().to_string (), Gtk.Window.get_toplevels ().get_n_items ());
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
