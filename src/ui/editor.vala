/* Textile-редактор: панель разметки, предпросмотр, продолжение списков по Enter, Ctrl+B/I, Ctrl+Enter — отправить. */
namespace Redmine {

    public class TextileEditor : Gtk.Box {
        private Gtk.TextView view;
        private Gtk.Stack stack;
        private Gtk.ToggleButton preview_btn;
        private Gtk.Box preview_box;
        public GenericArray<Json.Object> attachments = new GenericArray<Json.Object> ();
        public signal void submit ();

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
            var d = new PersonPickerDialog ();
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
                    var sub = new Gtk.Label (i.status.name + " · " + i.project.name + (i.id == exclude ? " · " + _("this issue") : "")) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
                    sub.add_css_class ("dim-label");
                    sub.add_css_class ("caption");
                    b.append (sub);
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

    /** Выбор человека для @упоминания: поиск по началу фамилии/имени/логина (плагин People). */
    public class PersonPickerDialog : Adw.Dialog {
        public signal void picked (string login);
        private Gtk.ListBox list;
        private int gen = 0;

        public PersonPickerDialog () {
            title = _("Mention a Person");
            content_width = 420;
            content_height = 480;
            var entry = new Gtk.SearchEntry () { placeholder_text = _("Name or login"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => { picked ((string) row.get_data<string> ("login")); close (); });
            entry.search_changed.connect (() => search.begin (entry.text));
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (entry);
            box.append (new Gtk.ScrolledWindow () { child = list, vexpand = true });
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = box;
            child = tv;
            focus_widget = entry;
        }

        private async void search (string q) {
            var s = App.get ().session;
            var my = ++gen;
            if (s == null || q.strip ().length < 2) return;
            yield sleep_ms (300);
            if (my != gen) return;
            try {
                var people = yield s.api.search_people (q.strip (), 20);
                if (my != gen) return;
                list.remove_all ();
                foreach (var p in people) {
                    var login = jstr (p, "login");
                    if (login == "") continue;
                    var row = new Gtk.ListBoxRow ();
                    var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) { margin_top = 4, margin_bottom = 4, margin_start = 4 };
                    b.append (Avatars.make (jint (p, "id"), person_short_name (p), 32));
                    var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                    col.append (new Gtk.Label (person_short_name (p)) { xalign = 0 });
                    var l = new Gtk.Label ("@" + login) { xalign = 0 };
                    l.add_css_class ("dim-label");
                    l.add_css_class ("caption");
                    col.append (l);
                    b.append (col);
                    row.child = b;
                    row.set_data<string> ("login", login);
                    list.append (row);
                }
            } catch (Error e) {
                debug ("people: %s", e.message);
            }
        }
    }
}
