namespace Redmine {
    /**
     * Скриншоты для README/metainfo и визуальной проверки: REDMINE_ADW_SHOT=путь.png — через REDMINE_ADW_SHOT_DELAY мс
     * окно рендерится само в PNG (Wayland не даёт снимать чужие окна) и приложение выходит.
     * REDMINE_ADW_SHOT_SIZE=ШxВ, REDMINE_ADW_SHOT_ISSUE=номер — открыть задачу, REDMINE_ADW_SHOT_SECTION=имя раздела.
     * REDMINE_ADW_SHOT_PERSON=id — открыть карточку человека. REDMINE_ADW_SHOT_LINK=адрес — открыть как ссылку своего сервера.
     * REDMINE_ADW_SHOT_FULL=1 — ещё и экран задачи целиком, без обрезки прокруткой: путь.png.full.png.
     * REDMINE_ADW_SHOT_WIDE=N — печать виджетов шире N (min или выделенная ширина): кто распирает окно на телефоне.
     * REDMINE_ADW_SHOT_COPY=1 — в каждом тексте задачи «Выделить всё» + Ctrl+C и печать того, что легло в буфер обмена.
     */
    namespace Shots {
        public void schedule (Window w) {
            // мигающий курсор в поле ввода держит окно в перерисовке — снимок выходит пустым
            Gtk.Settings.get_default ().gtk_cursor_blink = false;
            var size = Environment.get_variable ("REDMINE_ADW_SHOT_SIZE") ?? "1200x760";
            var wh = size.split ("x");
            w.set_default_size (int.parse (wh[0]), int.parse (wh[1]));
            var delay = int.parse (Environment.get_variable ("REDMINE_ADW_SHOT_DELAY") ?? "6000");
            // REDMINE_ADW_SHOT_SET=ключ=значение-GVariant;… — настройки на этот снимок (в песочнице dev.sh они не сохраняются)
            foreach (var kv in (Environment.get_variable ("REDMINE_ADW_SHOT_SET") ?? "").split (";")) {
                var eq = kv.index_of ("=");
                if (eq < 0) continue;
                try {
                    Prefs.get_default ().s.set_value (kv.substring (0, eq), Variant.parse (null, kv.substring (eq + 1)));
                } catch (Error e) { warning ("shot: %s: %s", kv, e.message); }
            }
            Timeout.add (delay / 2, () => {
                var sec = Environment.get_variable ("REDMINE_ADW_SHOT_SECTION");
                if (sec != null) w.show_section (sec);
                // REDMINE_ADW_SHOT_LINK=адрес своего сервера — как ссылка снаружи: проект (/roadmap, /wiki, /files), веха, вики
                var link = Environment.get_variable ("REDMINE_ADW_SHOT_LINK");
                var sl = link != null ? ServerLink.parse (App.get ().session.server, link) : null;
                if (sl != null) w.open_link (sl);
                var issue = Environment.get_variable ("REDMINE_ADW_SHOT_ISSUE");
                if (issue != null) w.open_issue (int.parse (issue));
                return Source.REMOVE;
            });
            // REDMINE_ADW_SHOT_PERSON=id — карточка человека
            var person = Environment.get_variable ("REDMINE_ADW_SHOT_PERSON");
            if (person != null) Timeout.add (delay * 3 / 4, () => { new PersonCard (int.parse (person)).present (w); return Source.REMOVE; });
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
            if (Environment.get_variable ("REDMINE_ADW_SHOT_COPY") != null) Timeout.add (delay - 1500, () => {
                var page = w.visible_issue ();
                if (page != null) copy_all.begin (page);
                return Source.REMOVE;
            });
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
                // REDMINE_ADW_SHOT_WIDE=N — кто требует ширину больше N: виновник окна, вылезающего за экран телефона
                var wide = Environment.get_variable ("REDMINE_ADW_SHOT_WIDE");
                if (wide != null) dump_wide (w, int.parse (wide), 0);
                w.application.quit ();
                return Source.REMOVE;
            });
        }

        private void dump_wide (Gtk.Widget wd, int limit, int depth) {
            int min, nat, mb, nb;
            wd.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, out mb, out nb);
            var l = wd as Gtk.Label;
            var extra = l != null ? " «%s»".printf (l.label.substring (0, int.min (60, l.label.length))) : "";
            if (min > limit || wd.get_width () > limit) print ("%s%s .%s min=%d w=%d%s\n", string.nfill (depth, ' '), wd.get_type ().name (), string.joinv (".", wd.get_css_classes ()), min, wd.get_width (), extra);
            for (var c = wd.get_first_child (); c != null; c = c.get_next_sibling ()) dump_wide (c, limit, depth + 1);
        }

        private async void copy_all (Gtk.Widget page) {
            var views = new GenericArray<Gtk.TextView> ();
            collect (page, views);
            foreach (var v in views) {
                if (!v.get_mapped ()) continue;
                // как пользователь: Ctrl+A, Ctrl+C — сигналами самого TextView
                v.select_all (true);
                v.copy_clipboard ();
                try {
                    print ("=== copy %d chars ===\n%s\n", v.buffer.get_char_count (), yield v.get_clipboard ().read_text_async (null));
                } catch (Error e) { warning ("copy: %s", e.message); }
                v.select_all (false);
            }
        }

        private void collect (Gtk.Widget w, GenericArray<Gtk.TextView> res) {
            if (w is FlowView) { res.add ((Gtk.TextView) w); return; }
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) collect (c, res);
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
