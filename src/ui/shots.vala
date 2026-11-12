namespace Redmine {
    /**
     * Скриншоты для README/metainfo и визуальной проверки: REDTASK_SHOT=путь.png — через REDTASK_SHOT_DELAY мс
     * окно рендерится само в PNG (Wayland не даёт снимать чужие окна) и приложение выходит.
     * REDTASK_SHOT_SIZE=ШxВ, REDTASK_SHOT_ISSUE=номер — открыть задачу, REDTASK_SHOT_SECTION=имя раздела.
     * REDTASK_SHOT_PERSON=id — открыть карточку человека. REDTASK_SHOT_LINK=адрес — открыть как ссылку своего сервера.
     * REDTASK_SHOT_FULL=1 — ещё и экран задачи (или текст REDTASK_SHOT_TEXT) целиком, без обрезки прокруткой: путь.png.full.png.
     * REDTASK_SHOT_WIDE=N — печать виджетов шире N (min или выделенная ширина): кто распирает окно на телефоне.
     * REDTASK_SHOT_COPY=1 — в каждом тексте задачи «Выделить всё» + Ctrl+C и печать того, что легло в буфер обмена.
     * REDTASK_SHOT_TEXT=файл — вместо окна только этот Textile (таблицы, разметка).
     * REDTASK_SHOT_SCROLL=px — прокрутка открытой задачи.
     * REDTASK_SHOT_TYPE=текст — набрать в редакторе открытого диалога.
     * REDTASK_SHOT_MORE=1 — выбрать второй аватар исполнителя доски и открыть «+N».
     * REDTASK_SHOT_REFRESH=1 — обновить всё за 150 мс до снимка (спиннеры «Обновить»).
     * REDTASK_SHOT_PRIVATE=1 — с REDTASK_SHOT_TYPE: включить «Приватная заметка» в диалоге.
     * REDTASK_SHOT_SWITCH=N — щелчок по N-му разделу боковой панели после остальных шагов.
 * REDTASK_SHOT_CLEAR=N — с REDTASK_SHOT_ACTION=app.preferences: очистить N-ю категорию кэша (5 — всё).
 * REDTASK_SHOT_DEMO=1 — демо-режим (spec 6) вместо входа; вход в настройках и связке ключей не меняется.
     */
    namespace Shots {
        private Gtk.Widget? text_shot = null;

        public void schedule (Window w) {
            // мигающий курсор в поле ввода держит окно в перерисовке — снимок выходит пустым
            Gtk.Settings.get_default ().gtk_cursor_blink = false;
            var size = Environment.get_variable ("REDTASK_SHOT_SIZE") ?? "1200x760";
            var wh = size.split ("x");
            w.set_default_size (int.parse (wh[0]), int.parse (wh[1]));
            var delay = int.parse (Environment.get_variable ("REDTASK_SHOT_DELAY") ?? "6000");
            // REDTASK_SHOT_SET=ключ=значение-GVariant;… — настройки на этот снимок (в песочнице dev.sh они не сохраняются)
            foreach (var kv in (Environment.get_variable ("REDTASK_SHOT_SET") ?? "").split (";")) {
                var eq = kv.index_of ("=");
                if (eq < 0) continue;
                try {
                    Prefs.get_default ().s.set_value (kv.substring (0, eq), Variant.parse (null, kv.substring (eq + 1)));
                } catch (Error e) { warning ("shot: %s: %s", kv, e.message); }
            }
            var text_file = Environment.get_variable ("REDTASK_SHOT_TEXT");
            if (text_file != null) Timeout.add (delay / 2, () => {
                try {
                    string t;
                    FileUtils.get_contents (text_file, out t);
                    var rt = new RichText (t) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 12 };
                    w.content = new Gtk.ScrolledWindow () { child = rt, hscrollbar_policy = Gtk.PolicyType.NEVER };
                    text_shot = rt;
                } catch (Error e) { warning ("shot: %s", e.message); }
                return Source.REMOVE;
            });
            Timeout.add (delay / 2, () => {
                var sec = Environment.get_variable ("REDTASK_SHOT_SECTION");
                if (sec != null) w.show_section (sec);
                // REDTASK_SHOT_LINK=адрес своего сервера — как ссылка снаружи: проект (/roadmap, /wiki, /files), веха, вики
                var link = Environment.get_variable ("REDTASK_SHOT_LINK");
                var sl = link != null ? ServerLink.parse (App.get ().session.server, link) : null;
                if (sl != null) w.open_link (sl);
                // REDTASK_SHOT_SUBTASKS=номер — подзадачи доской (spec 3.3)
                var sub = Environment.get_variable ("REDTASK_SHOT_SUBTASKS");
                if (sub != null) w.open_content (new VersionPage.subtasks (int.parse (sub), ""));
                var issue = Environment.get_variable ("REDTASK_SHOT_ISSUE");
                if (issue != null) w.open_issue (int.parse (issue));
                return Source.REMOVE;
            });
            // REDTASK_SHOT_SWITCH=N — как щелчок по N-му разделу боковой панели (0 — «Мои»)
            var sw = Environment.get_variable ("REDTASK_SHOT_SWITCH");
            if (sw != null) Timeout.add (delay * 3 / 4, () => {
                var sb = find_sidebar (w);
                if (sb != null) { sb.selected = int.parse (sw); sb.activated (int.parse (sw)); }
                return Source.REMOVE;
            });
            // REDTASK_SHOT_SCROLL=px — прокрутить открытую задачу (миниатюры видимых строк, низ страницы)
            var scroll = Environment.get_variable ("REDTASK_SHOT_SCROLL");
            if (scroll != null) Timeout.add (delay * 7 / 10, () => {
                var page = w.visible_issue ();
                var clamp = page != null ? find_clamp (page) : null;
                var scr = clamp?.get_ancestor (typeof (Gtk.ScrolledWindow)) as Gtk.ScrolledWindow;
                if (scr != null) scr.vadjustment.value = double.parse (scroll);
                debug ("shot: scroll %s page=%s clamp=%s sw=%s upper=%f", scroll, (page != null).to_string (), (clamp != null).to_string (), (scr != null).to_string (), scr != null ? scr.vadjustment.upper : 0);
                return Source.REMOVE;
            });
            // REDTASK_SHOT_PERSON=id — карточка человека
            var person = Environment.get_variable ("REDTASK_SHOT_PERSON");
            if (person != null) Timeout.add (delay * 3 / 4, () => { new PersonCard (int.parse (person)).present (w); return Source.REMOVE; });
            // REDTASK_SHOT_ACTION=issue.edit | win.new-issue | app.preferences — открыть диалог для снимка
            var action = Environment.get_variable ("REDTASK_SHOT_ACTION");
            if (action != null) Timeout.add (delay * 3 / 4, () => {
                var page = w.visible_issue ();
                if (action.has_prefix ("issue.") && page != null) {
                    if (!page.activate_action (action, null)) warning ("shot: action %s not found", action);
                }
                else if (action.has_prefix ("app.")) w.application.activate_action (action.substring (4), null);
                if (Environment.get_variable ("REDTASK_SHOT_CLOSE") != null) Timeout.add (2000, () => {
                    debug ("shot: closing dialog %s", (w.visible_dialog != null).to_string ());
                    w.visible_dialog?.force_close ();
                    return Source.REMOVE;
                });
                else w.activate_action (action, null);
                return Source.REMOVE;
            });
            // REDTASK_SHOT_TYPE=текст — набрать в редакторе открытого диалога (подсказка @)
            var type = Environment.get_variable ("REDTASK_SHOT_TYPE");
            if (type != null) Timeout.add (delay * 85 / 100, () => {
                var tv = find_textview (w.visible_dialog);
                if (tv != null) { tv.grab_focus (); tv.buffer.insert_at_cursor (type, -1); }
                // REDTASK_SHOT_PRIVATE=1 — ещё и включить «Приватная заметка» (ничего не отправляется)
                if (Environment.get_variable ("REDTASK_SHOT_PRIVATE") != null) {
                    var sr = find_switch_row (w.visible_dialog);
                    if (sr != null) sr.active = true;
                }
                return Source.REMOVE;
            });
            // REDTASK_SHOT_MORE=1 — открыть «+N» исполнителей на экране вехи (список в .popover.png)
            if (Environment.get_variable ("REDTASK_SHOT_MORE") != null) Timeout.add (delay * 85 / 100, () => {
                var mb = find_more (w);
                // без ввода пользователя композитор не даёт захват — список без autohide
                debug ("shot: more %s", (mb != null).to_string ());
                // и выбрать второй аватар — видно кольцо выбора и приглушение остальных
                var second = mb?.get_parent ()?.get_first_child ()?.get_next_sibling () as Gtk.ToggleButton;
                if (second != null) second.active = true;
                if (mb != null) { mb.popover.autohide = false; mb.popover.popup (); }
                return Source.REMOVE;
            });
            // REDTASK_SHOT_REFRESH=1 — «Обновить» (Ctrl+R) за 150 мс до снимка: в шапках — спиннер (spec 12)
            if (Environment.get_variable ("REDTASK_SHOT_REFRESH") != null) Timeout.add (delay - 150, () => {
                w.activate_action ("refresh", null);
                return Source.REMOVE;
            });
            int ticks = 0;
            w.add_tick_callback ((wd, clock) => { ticks++; return Source.CONTINUE; });
            Timeout.add (delay - 1000, () => { ticks = 0; return Source.REMOVE; });
            if (Environment.get_variable ("REDTASK_SHOT_COPY") != null) Timeout.add (delay - 1500, () => {
                var page = w.visible_issue ();
                if (page != null) copy_all.begin (page);
                return Source.REMOVE;
            });
            Timeout.add (delay, () => {
                debug ("shot: frames in the last second: %d", ticks);
                save (w, Environment.get_variable ("REDTASK_SHOT"));
                var page = w.visible_issue ();
                var clamp = Environment.get_variable ("REDTASK_SHOT_FULL") == null ? null : text_shot ?? (page != null ? find_clamp (page) : null);
                if (clamp != null) save (clamp, Environment.get_variable ("REDTASK_SHOT") + ".full.png");
                var wp = w.visible_dialog == null ? find_popover (w) : null;
                if (wp != null) save (wp, Environment.get_variable ("REDTASK_SHOT") + ".popover.png");
                var d = w.visible_dialog;
                if (d != null) {
                    debug ("shot: dialog %s %dx%d mapped=%s", d.get_type ().name (), d.get_width (), d.get_height (), d.get_mapped ().to_string ());
                    save (d, Environment.get_variable ("REDTASK_SHOT") + ".dialog.png");
                    // всплывающий список (подсказка @) — своя поверхность, в снимок окна не попадает
                    var pop = find_popover (d);
                    if (pop != null) save (pop, Environment.get_variable ("REDTASK_SHOT") + ".popover.png");
                }
                // REDTASK_SHOT_WIDE=N — кто требует ширину больше N: виновник окна, вылезающего за экран телефона
                var wide = Environment.get_variable ("REDTASK_SHOT_WIDE");
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

        private Adw.SwitchRow? find_switch_row (Gtk.Widget? w) {
            if (w == null) return null;
            if (w is Adw.SwitchRow) return (Adw.SwitchRow) w;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_switch_row (c);
                if (r != null) return r;
            }
            return null;
        }

        private Gtk.TextView? find_textview (Gtk.Widget? w) {
            if (w == null) return null;
            if (w is Gtk.TextView && ((Gtk.TextView) w).editable) return (Gtk.TextView) w;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_textview (c);
                if (r != null) return r;
            }
            return null;
        }

        private Gtk.MenuButton? find_more (Gtk.Widget w) {
            var mb = w as Gtk.MenuButton;
            if (mb != null && mb.get_mapped () && mb.has_css_class ("avatar-more")) return mb;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_more (c);
                if (r != null) return r;
            }
            return null;
        }

        private Gtk.Popover? find_popover (Gtk.Widget w) {
            if (w is Gtk.Popover && w.get_mapped ()) return (Gtk.Popover) w;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_popover (c);
                if (r != null) return r;
            }
            return null;
        }

        private Adw.Sidebar? find_sidebar (Gtk.Widget w) {
            if (w is Adw.Sidebar) return (Adw.Sidebar) w;
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var r = find_sidebar (c);
                if (r != null) return r;
            }
            return null;
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
