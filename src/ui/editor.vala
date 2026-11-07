/* Textile-редактор: панель разметки, предпросмотр, продолжение списков по Enter, Ctrl+B/I, Ctrl+Enter — отправить. */
namespace Redmine {

    public class TextileEditor : Gtk.Box {
        private Gtk.TextView view;
        private Gtk.Stack stack;
        private Gtk.ToggleButton preview_btn;
        private Gtk.Box preview_box;
        public GenericArray<Json.Object> attachments = new GenericArray<Json.Object> ();
        public signal void submit ();
        /** Пишем приватную заметку: поле ввода с янтарным фоном (spec 13). */
        public bool private_tint {
            set { if (value) view.add_css_class ("private-input"); else view.remove_css_class ("private-input"); }
        }
        /** Подсказка @упоминания у каретки (spec 8.1). */
        private MentionSource mentions = new MentionSource ();
        private Gtk.Popover pop;
        private Gtk.ListBox pop_list;
        private GenericArray<Json.Object> pop_items = new GenericArray<Json.Object> ();
        private string? mq = null;

        /** Люди задачи — первыми в подсказке @ и в «Упомянуть». */
        public void set_issue (Issue i) { mentions.set_issue (i); }

        public string text {
            owned get { return view.buffer.text; }
            set { view.buffer.text = value; }
        }

        public TextileEditor (int min_height = 160) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 6);
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            tool (bar, "format-text-bold-symbolic", _("Bold"), () => wrap ("*", "*"));
            tool (bar, "format-text-italic-symbolic", _("Italic"), () => wrap ("_", "_"));
            tool (bar, "format-text-strikethrough-symbolic", _("Strikethrough"), () => wrap ("-", "-"));
            tool (bar, "format-text-plaintext-symbolic", _("Inline Code"), () => wrap ("@", "@"));
            tool (bar, "text-x-generic-symbolic", _("Code Block"), () => block ("<pre>\n", "\n</pre>"));
            tool (bar, "format-indent-more-symbolic", _("Quote"), () => prefix_lines ("> "));
            tool (bar, "view-list-bullet-symbolic", _("Bulleted List"), () => prefix_lines ("* "));
            tool (bar, "view-list-ordered-symbolic", _("Numbered List"), () => prefix_lines ("# "));
            tool (bar, "format-text-rich-symbolic", _("Heading"), () => prefix_lines ("h3. "));
            tool (bar, "insert-link-symbolic", _("Link"), insert_link);
            tool (bar, "mail-forward-symbolic", _("Issue Reference"), pick_issue);
            tool (bar, "avatar-default-symbolic", _("Mention a Person"), pick_person);
            tool (bar, "view-grid-symbolic", _("Table"), () => block ("|_. " + _("Column") + " |_. " + _("Column") + " |\n| | |", ""));
            tool (bar, "insert-image-symbolic", _("Insert Image"), pick_image);
            var scroller = new Gtk.ScrolledWindow () { child = bar, vscrollbar_policy = Gtk.PolicyType.NEVER, hexpand = true };
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            top.append (scroller);
            preview_btn = new Gtk.ToggleButton () { icon_name = "view-reveal-symbolic", tooltip_text = _("Preview") };
            preview_btn.add_css_class ("flat");
            top.append (preview_btn);
            append (top);

            view = new Gtk.TextView () {
                wrap_mode = Gtk.WrapMode.WORD_CHAR, top_margin = 8, bottom_margin = 8, left_margin = 8, right_margin = 8,
                accepts_tab = false,
            };
            view.update_property (Gtk.AccessibleProperty.LABEL, _("Text"), -1);
            var sw = new Gtk.ScrolledWindow () { child = view, min_content_height = min_height, vexpand = true };
            sw.add_css_class ("card");
            preview_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 8, margin_end = 8, margin_top = 8, margin_bottom = 8 };
            var psw = new Gtk.ScrolledWindow () { child = preview_box, min_content_height = min_height, vexpand = true };
            psw.add_css_class ("card");
            stack = new Gtk.Stack () { vexpand = true, transition_type = Gtk.StackTransitionType.CROSSFADE };
            stack.add_named (sw, "edit");
            stack.add_named (psw, "preview");
            append (stack);
            preview_btn.toggled.connect (() => {
                if (preview_btn.active) {
                    clear_box (preview_box);
                    if (text.strip () == "") {
                        var l = new Gtk.Label (_("Nothing to preview yet"));
                        l.add_css_class ("dim-label");
                        preview_box.append (l);
                    } else preview_box.append (new RichText (text, attachments));
                    stack.visible_child_name = "preview";
                    preview_btn.tooltip_text = _("Back to Editing");
                } else {
                    stack.visible_child_name = "edit";
                    preview_btn.tooltip_text = _("Preview");
                    view.grab_focus ();
                }
            });

            var keys = new Gtk.EventControllerKey ();
            keys.key_pressed.connect (on_key);
            view.add_controller (keys);

            // список не забирает фокус и ввод: печатаем дальше, пока он открыт (autohide выключен)
            pop_list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.BROWSE, can_focus = false };
            pop_list.row_activated.connect ((r) => accept (r.get_index ()));
            pop = new Gtk.Popover () {
                autohide = false, has_arrow = false, position = Gtk.PositionType.BOTTOM,
                child = new Gtk.ScrolledWindow () {
                    child = pop_list, hscrollbar_policy = Gtk.PolicyType.NEVER, propagate_natural_height = true,
                    max_content_height = 300, width_request = 320,
                },
            };
            pop.set_parent (view);
            view.buffer.notify["cursor-position"].connect (on_cursor);
            view.buffer.changed.connect (on_cursor);
            mentions.results.connect (show_candidates);
        }

        public override void dispose () {
            if (pop != null) { pop.unparent (); pop = null; }
            base.dispose ();
        }

        /** Каретка сдвинулась или текст изменился: запрос @ до неё (набор mention_query). */
        private void on_cursor () {
            if (pop == null) return;
            var buf = view.buffer;
            var q = mention_query (buf.text, buf.cursor_position);
            if (q == mq) return;
            mq = q;
            if (q == null) pop.popdown ();
            mentions.query (q);
        }

        private void show_candidates (GenericArray<Json.Object> people) {
            if (mq == null || pop == null) return;
            pop_list.remove_all ();
            pop_items = people;
            if (people.length == 0) { pop.popdown (); return; }
            foreach (var p in people) pop_list.append (person_row (p));
            pop_list.select_row (pop_list.get_row_at_index (0));
            Gtk.TextIter it;
            view.buffer.get_iter_at_mark (out it, view.buffer.get_insert ());
            Gdk.Rectangle r;
            view.get_iter_location (it, out r);
            int x, y;
            view.buffer_to_window_coords (Gtk.TextWindowType.WIDGET, r.x, r.y, out x, out y);
            pop.pointing_to = { x, y, 1, r.height };
            pop.popup ();
        }

        /** Выбор: «@запрос» перед кареткой → «@login ». Логина человека задачи ещё нет — дождаться. */
        private void accept (int index) {
            if (mq == null || index < 0 || index >= pop_items.length) return;
            var p = pop_items[index];
            var typed = mq.char_count () + 1;
            pop.popdown ();
            mentions.login_of.begin (p, (o, r) => {
                var login = mentions.login_of.end (r);
                if (login == "") return;
                var buf = view.buffer;
                Gtk.TextIter end, start;
                buf.get_iter_at_mark (out end, buf.get_insert ());
                start = end;
                start.backward_chars (typed);
                buf.begin_user_action ();
                buf.delete (ref start, ref end);
                buf.insert (ref start, "@" + login + " ", -1);
                buf.end_user_action ();
            });
        }

        /** Стрелки и Enter выбирают, Esc прячет — только пока список открыт. */
        private bool popup_key (uint keyval) {
            if (pop == null || !pop.visible) return false;
            var row = pop_list.get_selected_row ();
            int i = row != null ? row.get_index () : 0;
            int n = (int) pop_items.length;
            switch (keyval) {
                case Gdk.Key.Escape:
                    pop.popdown ();
                    mentions.query (null); // поздний ответ сервера список не вернёт; новый «@» — вернёт
                    return true;
                case Gdk.Key.Up: case Gdk.Key.KP_Up:
                    pop_list.select_row (pop_list.get_row_at_index ((i - 1 + n) % n));
                    return true;
                case Gdk.Key.Down: case Gdk.Key.KP_Down:
                    pop_list.select_row (pop_list.get_row_at_index ((i + 1) % n));
                    return true;
                case Gdk.Key.Return: case Gdk.Key.KP_Enter: case Gdk.Key.Tab:
                    accept (i);
                    return true;
            }
            return false;
        }

        public void focus_text () {
            view.grab_focus ();
            Gtk.TextIter end;
            view.buffer.get_end_iter (out end);
            view.buffer.place_cursor (end);
        }

        private void tool (Gtk.Box bar, string icon, string tip, owned Callback cb) {
            var b = new Gtk.Button.from_icon_name (icon) { tooltip_text = tip };
            b.add_css_class ("flat");
            b.update_property (Gtk.AccessibleProperty.LABEL, tip, -1);
            b.clicked.connect (() => { if (preview_btn.active) preview_btn.active = false; cb (); view.grab_focus (); });
            bar.append (b);
        }

        private bool on_key (uint keyval, uint code, Gdk.ModifierType state) {
            if (popup_key (keyval)) return true;
            var ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            if (ctrl && (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter)) { submit (); return true; }
            if (ctrl && keyval == Gdk.Key.b) { wrap ("*", "*"); return true; }
            if (ctrl && keyval == Gdk.Key.i) { wrap ("_", "_"); return true; }
            if (!ctrl && (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) && (state & Gdk.ModifierType.SHIFT_MASK) == 0) return continue_list ();
            return false;
        }

        /** Enter в пункте списка/цитаты продолжает его; Enter на пустом пункте — убирает маркер. */
        private bool continue_list () {
            var buf = view.buffer;
            Gtk.TextIter cur, start;
            buf.get_iter_at_mark (out cur, buf.get_insert ());
            start = cur;
            start.set_line_offset (0);
            var line = buf.get_text (start, cur, false);
            MatchInfo mi;
            if (!/^(\s*(?:[*#]+|>+)\s+)/.match (line, 0, out mi)) return false;
            var marker = mi.fetch (1);
            if (line.strip () == marker.strip ()) {
                buf.delete (ref start, ref cur);
                return true;
            }
            buf.insert_at_cursor ("\n" + marker, -1);
            view.scroll_mark_onscreen (buf.get_insert ());
            return true;
        }

        private void wrap (string open, string close) {
            var buf = view.buffer;
            Gtk.TextIter a, b;
            if (buf.get_selection_bounds (out a, out b)) {
                var t = buf.get_text (a, b, false);
                buf.begin_user_action ();
                buf.delete (ref a, ref b);
                buf.insert (ref a, open + t + close, -1);
                buf.end_user_action ();
            } else {
                buf.insert_at_cursor (open + close, -1);
                Gtk.TextIter c;
                buf.get_iter_at_mark (out c, buf.get_insert ());
                c.backward_chars (close.char_count ());
                buf.place_cursor (c);
            }
        }

        /** Блок с новой строки: до него — перевод строки, если курсор не в начале. */
        private void block (string open, string close) {
            var buf = view.buffer;
            Gtk.TextIter a, b;
            string inner = "";
            if (buf.get_selection_bounds (out a, out b)) {
                inner = buf.get_text (a, b, false);
                buf.delete (ref a, ref b);
            }
            Gtk.TextIter c;
            buf.get_iter_at_mark (out c, buf.get_insert ());
            var lead = c.starts_line () ? "" : "\n";
            buf.insert_at_cursor (lead + open + inner + close + "\n", -1);
        }

        private void prefix_lines (string p) {
            var buf = view.buffer;
            Gtk.TextIter a, b;
            if (!buf.get_selection_bounds (out a, out b)) {
                buf.get_iter_at_mark (out a, buf.get_insert ());
                b = a;
            }
            a.set_line_offset (0);
            if (!b.ends_line ()) b.forward_to_line_end ();
            var t = buf.get_text (a, b, false);
            var sb = new StringBuilder ();
            var lines = t.split ("\n");
            for (int i = 0; i < lines.length; i++) {
                sb.append (p + lines[i]);
                if (i < lines.length - 1) sb.append_c ('\n');
            }
            buf.begin_user_action ();
            buf.delete (ref a, ref b);
            buf.insert (ref a, sb.str, -1);
            buf.end_user_action ();
        }

        public void insert (string s) { view.buffer.insert_at_cursor (s, -1); }

        private void insert_link () {
            var d = new Adw.AlertDialog (_("Insert Link"), null);
            var box = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            box.add_css_class ("boxed-list");
            var url = new Adw.EntryRow () { title = _("Address"), input_purpose = Gtk.InputPurpose.URL };
            var label = new Adw.EntryRow () { title = _("Link text (optional)") };
            Gtk.TextIter a, b;
            if (view.buffer.get_selection_bounds (out a, out b)) label.text = view.buffer.get_text (a, b, false);
            box.append (url);
            box.append (label);
            d.extra_child = box;
            d.add_response ("cancel", _("_Cancel"));
            d.add_response ("insert", _("_Insert"));
            d.set_response_appearance ("insert", Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "insert";
            d.response.connect ((r) => {
                if (r != "insert" || url.text.strip () == "") return;
                Gtk.TextIter x, y;
                if (view.buffer.get_selection_bounds (out x, out y)) view.buffer.delete (ref x, ref y);
                var t = label.text.strip ();
                insert (t != "" ? "\"%s\":%s".printf (t, url.text.strip ()) : url.text.strip ());
            });
            d.present (this);
        }

        private void pick_issue () {
            var d = new IssuePickerDialog (_("Issue Reference"));
            d.picked.connect ((i) => insert ("#%d".printf (i.id)));
            d.present (this);
        }

        private void pick_person () {
            var d = new PersonPickerDialog (mentions);
            d.picked.connect ((login) => insert ("@" + login + " "));
            d.present (this);
        }

        private void pick_image () {
            var imgs = new GenericArray<string> ();
            foreach (var a in attachments) if (is_image_name (jstr (a, "filename"))) imgs.add (jstr (a, "filename"));
            if (imgs.length == 0) {
                insert ("!file.png!");
                return;
            }
            var d = new Adw.AlertDialog (_("Insert Image"), _("Images attached to the issue"));
            var list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            list.add_css_class ("boxed-list");
            foreach (var n in imgs) {
                var r = new Adw.ActionRow () { title = Markup.escape_text (n), activatable = true };
                r.activated.connect (() => { insert ("!" + n + "!"); d.close (); });
                list.append (r);
            }
            d.extra_child = list;
            d.add_response ("cancel", _("_Cancel"));
            d.present (this);
        }
    }

    /** Выбор задачи: номер (можно с #) или текст из темы. */
    public class IssuePickerDialog : Adw.Dialog {
        public signal void picked (Issue issue);
        private Gtk.ListBox list;
        private int gen = 0;
        public int exclude = 0;

        public IssuePickerDialog (string title) {
            this.title = title;
            content_width = 480;
            content_height = 520;
            var entry = new Gtk.SearchEntry () { placeholder_text = _("Issue number or subject"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => {
                var i = row.get_data<Issue> ("issue");
                if (i != null) { picked (i); close (); }
            });
            entry.search_changed.connect (() => search.begin (entry.text));
            entry.activate.connect (() => { var r = list.get_row_at_index (0); if (r != null) list.row_activated (r); });
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (entry);
            box.append (new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER });
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = box;
            child = tv;
            focus_widget = entry;
        }

        private async void search (string q) {
            var s = App.get ().session;
            var my = ++gen;
            if (s == null) return;
            if (q.strip () == "") { list.remove_all (); return; }
            yield sleep_ms (300);
            if (my != gen) return;
            try {
                var found = yield s.api.find_issues (q, 20);
                if (my != gen) return;
                list.remove_all ();
                foreach (var i in found) {
                    var row = new Gtk.ListBoxRow ();
                    var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
                    b.append (new Gtk.Label ("#%d %s".printf (i.id, i.subject)) { xalign = 0, wrap = true, lines = 2, ellipsize = Pango.EllipsizeMode.END });
                    b.append (status_line (i.status.name, i.status_closed, i.project.name + (i.id == exclude ? " · " + _("this issue") : "")));
                    row.child = b;
                    row.sensitive = i.id != exclude;
                    row.set_data<Issue> ("issue", i);
                    list.append (row);
                }
            } catch (Error e) {
                debug ("picker: %s", e.message);
            }
        }
    }

    /** Строка человека: аватар, имя, @login. */
    Gtk.ListBoxRow person_row (Json.Object p) {
        var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) { margin_top = 4, margin_bottom = 4, margin_start = 4, margin_end = 4 };
        b.append (Avatars.make (jint (p, "id"), jstr (p, "name"), 28));
        var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { valign = Gtk.Align.CENTER };
        col.append (new Gtk.Label (jstr (p, "name")) { xalign = 0, ellipsize = Pango.EllipsizeMode.END });
        if (jstr (p, "login") != "") {
            var l = new Gtk.Label ("@" + jstr (p, "login")) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            l.add_css_class ("dim-label");
            l.add_css_class ("caption");
            col.append (l);
        }
        b.append (col);
        return new Gtk.ListBoxRow () { child = b, can_focus = false };
    }

    /**
     * Кандидаты @упоминания (spec 8): люди задачи (исполнитель, автор, авторы комментариев от свежих, наблюдатели),
     * затем все встреченные сотрудники. Отбор локальный на каждый символ (набор mention_candidates), people.json?search=
     * — через 150 мс после последнего символа, его ответ дополняет тот же список; ответ на устаревший запрос не показывается.
     */
    public class MentionSource : Object {
        /** Все встреченные сотрудники {id, name, login} — на процесс. */
        private static GenericArray<Json.Object>? known = null;
        private GenericArray<Json.Object> participants = new GenericArray<Json.Object> ();
        private string? current = null;
        private uint timer = 0;
        private int gen = 0;
        public signal void results (GenericArray<Json.Object> people);

        construct { if (known == null) known = new GenericArray<Json.Object> (); }

        public MentionSource.like (MentionSource other) { participants = other.participants; }

        private static Json.Object person (int id, string name, string login) {
            var o = new Json.Object ();
            o.set_int_member ("id", id);
            o.set_string_member ("name", name);
            o.set_string_member ("login", login);
            return o;
        }

        /** Сотрудник в общий кэш; известный — дополнить логином. */
        private static void learn (int id, string name, string login) {
            foreach (var k in known) if (jint (k, "id") == id) {
                if (jstr (k, "login") == "" && login != "") k.set_string_member ("login", login);
                return;
            }
            known.add (person (id, name, login));
        }

        public void set_issue (Issue i) {
            var res = new GenericArray<Json.Object> ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            Named?[] head = { i.assigned_to, i.author };
            foreach (var n in head) if (n != null && n.id > 0 && !seen.contains (n.id)) { seen.add (n.id); res.add (person (n.id, n.name, "")); }
            var js = i.journals;
            for (int k = js.length - 1; k >= 0; k--) {
                var u = jobj (js[k], "user");
                var id = jint (u, "id");
                if (id > 0 && !seen.contains (id)) { seen.add (id); res.add (person (id, jstr (u, "name"), "")); }
            }
            foreach (var w in i.watchers) {
                var id = jint (w, "id");
                if (id > 0 && !seen.contains (id)) { seen.add (id); res.add (person (id, jstr (w, "name"), "")); }
            }
            participants = res;
            foreach (var p in res) login_of.begin (p);
        }

        /** Логин человека: из кэша сотрудников, иначе people/:id или users/:id (справочники кэшируют на сутки). */
        public async string login_of (Json.Object p) {
            var login = jstr (p, "login");
            if (login != "") return login;
            var id = jint (p, "id");
            foreach (var k in known) if (jint (k, "id") == id && jstr (k, "login") != "") login = jstr (k, "login");
            var s = App.get ().session;
            if (login == "" && s != null) {
                try { login = jstr (yield s.refs.person (id), "login"); } catch (Error e) {}
                if (login == "") try { login = jstr (yield s.refs.user (id), "login"); } catch (Error e) {}
            }
            if (login == "") return "";
            p.set_string_member ("login", login);
            learn (id, jstr (p, "name"), login);
            if (current != null) results (local (current));
            return login;
        }

        private GenericArray<Json.Object> local (string q) { return mention_candidates (participants, known, q, 8); }

        /** null — подсказки нет: таймер и поздние ответы гасятся. */
        public void query (string? q) {
            current = q;
            gen++;
            if (timer != 0) { Source.remove (timer); timer = 0; }
            if (q == null) return;
            results (local (q));
            if (q == "") return;
            var my = gen;
            timer = Timeout.add (150, () => { timer = 0; fetch.begin (q, my); return Source.REMOVE; });
        }

        private async void fetch (string q, int my) {
            var s = App.get ().session;
            if (s == null) return;
            try {
                foreach (var p in yield s.api.search_people (q, 20)) {
                    var first = jstr (p, "firstname") != "" ? jstr (p, "firstname") : jstr (p, "first_name");
                    var last = jstr (p, "lastname") != "" ? jstr (p, "lastname") : jstr (p, "last_name");
                    // имя как пишет сервер в задачах: «Фамилия Имя»
                    learn (jint (p, "id"), (last + " " + first).strip (), jstr (p, "login"));
                }
            } catch (Error e) {
                debug ("people: %s", e.message);
                return;
            }
            if (my == gen) results (local (q));
        }
    }

    /** «Упомянуть» (spec 8.2): тот же список с полем поиска; пусто — люди задачи. */
    public class PersonPickerDialog : Adw.Dialog {
        public signal void picked (string login);
        private Gtk.ListBox list;
        private GenericArray<Json.Object> items = new GenericArray<Json.Object> ();
        private MentionSource src;

        public PersonPickerDialog (MentionSource from) {
            title = _("Mention a Person");
            content_width = 420;
            content_height = 480;
            src = new MentionSource.like (from);
            var entry = new Gtk.SearchEntry () { placeholder_text = _("Name or login"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => pick (row.get_index ()));
            entry.search_changed.connect (() => src.query (entry.text.strip ()));
            entry.activate.connect (() => pick (0));
            src.results.connect ((people) => {
                items = people;
                list.remove_all ();
                foreach (var p in people) {
                    var r = person_row (p);
                    r.can_focus = true;
                    list.append (r);
                }
            });
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (entry);
            box.append (new Gtk.ScrolledWindow () { child = list, vexpand = true });
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = box;
            child = tv;
            focus_widget = entry;
            src.query ("");
        }

        private void pick (int i) {
            if (i < 0 || i >= items.length) return;
            src.login_of.begin (items[i], (o, r) => {
                var login = src.login_of.end (r);
                if (login == "") return;
                picked (login);
                close ();
            });
        }
    }
}
