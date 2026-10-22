/* Textile → виджеты: абзацы — GtkLabel с Pango markup, цитаты/код/таблицы/картинки — свои блоки. */
namespace Redmine {

    /** login → «id|Имя» на всё приложение: упоминания резолвятся один раз (RefData хранит и на диске). */
    private HashTable<string, string>? mention_cache = null;

    public class RichText : Gtk.Box {
        private string text;
        private GenericArray<Json.Object> atts;
        private int quote_depth = 0;
        /** Ссылка #note-N на комментарий этой же задачи. */
        public signal void note_activated (int note);

        public RichText (string text, GenericArray<Json.Object>? attachments = null) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.text = text;
            atts = attachments ?? new GenericArray<Json.Object> ();
            if (mention_cache == null) mention_cache = new HashTable<string, string> (str_hash, str_equal);
            render ();
            resolve_mentions.begin ();
        }

        private string? lookup (string login) { return mention_cache[login]; }

        private async void resolve_mentions () {
            var s = App.get ().session;
            if (s == null) return;
            bool changed = false;
            foreach (var l in Textile.mention_logins (text)) {
                if (mention_cache.contains (l)) continue;
                var p = yield s.refs.person_by_login (l);
                if (p == null) continue;
                var n = person_short_name (p);
                mention_cache[l] = "%d|%s".printf (jint (p, "id"), n != "" ? n : l);
                changed = true;
            }
            if (changed) render ();
        }

        private void render () {
            Gtk.Widget? c;
            while ((c = get_first_child ()) != null) remove (c);
            build (this, Textile.parse (text), 0);
        }

        private void build (Gtk.Box into, GenericArray<Textile.Line> lines, int depth) {
            Textile.Block? prev = null;
            foreach (var b in Textile.group (lines)) {
                var w = block (b, depth);
                if (w == null) continue;
                // абзац — 10, вокруг «коробок» — 6, иначе вплотную
                var boxed = b.kind == Textile.BlockKind.CODE || b.kind == Textile.BlockKind.QUOTE || b.kind == Textile.BlockKind.COLLAPSE || b.kind == Textile.BlockKind.RULE;
                var prev_boxed = prev != null && (prev.kind == Textile.BlockKind.CODE || prev.kind == Textile.BlockKind.QUOTE || prev.kind == Textile.BlockKind.COLLAPSE || prev.kind == Textile.BlockKind.RULE);
                if (prev != null) w.margin_top = b.gap ? 10 : ((boxed || prev_boxed) ? 6 : 0);
                into.append (w);
                prev = b;
            }
        }

        private Gtk.Label label (string markup) {
            var l = new Gtk.Label (null) {
                use_markup = true, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, xalign = 0, selectable = true,
                hexpand = true,
            };
            l.set_markup (markup);
            l.activate_link.connect (on_link);
            return l;
        }

        private Gtk.Widget? block (Textile.Block b, int depth) {
            switch (b.kind) {
                case Textile.BlockKind.TEXT:
                    return label (Textile.text_markup (b.lines, lookup));
                case Textile.BlockKind.LIST:
                    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                    foreach (var l in b.lines) {
                        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_start = 4 + l.level * 18 };
                        var mark = new Gtk.Label (l.number > 0 ? "%d.".printf (l.number) : "•") { valign = Gtk.Align.START, xalign = 1, width_chars = 2 };
                        mark.add_css_class ("dim-label");
                        row.append (mark);
                        row.append (label (Textile.inline_markup (l.text, lookup)));
                        box.append (row);
                    }
                    return box;
                case Textile.BlockKind.CODE:
                    var sb = new StringBuilder ();
                    for (int i = 0; i < b.lines.length; i++) {
                        sb.append (Textile.unraw (b.lines[i].text));
                        if (i < b.lines.length - 1) sb.append_c ('\n');
                    }
                    var code = new Gtk.Label (sb.str) { xalign = 0, selectable = true };
                    code.add_css_class ("monospace");
                    var sw = new Gtk.ScrolledWindow () {
                        child = code, vscrollbar_policy = Gtk.PolicyType.NEVER, propagate_natural_height = true,
                    };
                    sw.add_css_class ("rich-code");
                    return sw;
                case Textile.BlockKind.QUOTE:
                    var q = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                    q.add_css_class ("rich-quote");
                    // приглушаем один раз: вложенный dim-label множит прозрачность, и вложенная цитата почти не видна
                    if (quote_depth == 0) q.add_css_class ("dim-label");
                    quote_depth++;
                    build (q, b.lines[0].children, depth + 1);
                    quote_depth--;
                    return q;
                case Textile.BlockKind.COLLAPSE:
                    var l0 = b.lines[0];
                    var ex = new Gtk.Expander (l0.text != "" ? l0.text : _("Show details"));
                    var inner = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_top = 6 };
                    build (inner, l0.children, depth + 1);
                    ex.child = inner;
                    return ex;
                case Textile.BlockKind.RULE:
                    return new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
                case Textile.BlockKind.IMAGE:
                    return image (b.lines[0].text);
                case Textile.BlockKind.TABLE:
                    return table (b);
            }
            return null;
        }

        private Gtk.Widget table (Textile.Block b) {
            var grid = new Gtk.Grid () { column_spacing = 0, row_spacing = 0 };
            grid.add_css_class ("rich-table");
            Textile.layout_table (b.lines);
            int r = 0;
            foreach (var l in b.lines) {
                foreach (var c in l.cells) {
                    var m = Textile.inline_markup (c.text, lookup);
                    var cell = label (c.header ? "<b>" + m + "</b>" : m);
                    cell.selectable = false;
                    cell.hexpand = false;
                    cell.xalign = c.xalign;
                    cell.max_width_chars = 40;
                    // без минимальной ширины прокрутка меряет высоту по ширине в букву — таблица вытягивается вниз пустотой
                    cell.width_chars = int.min (c.text.char_count (), 40);
                    grid.attach (cell, c.col, r, c.span, c.rowspan);
                }
                r++;
            }
            return new Gtk.ScrolledWindow () { child = grid, vscrollbar_policy = Gtk.PolicyType.NEVER, propagate_natural_height = true };
        }

        private Gtk.Widget image (string ref_name) {
            var pic = new Gtk.Picture () { can_shrink = true, content_fit = Gtk.ContentFit.SCALE_DOWN, halign = Gtk.Align.START, height_request = 48 };
            pic.add_css_class ("rich-image");
            var att = ref_name.has_prefix ("http") ? null : resolve_attachment (ref_name, atts);
            var btn = new Gtk.Button () { child = pic, halign = Gtk.Align.START, tooltip_text = ref_name };
            btn.add_css_class ("flat");
            if (att == null) {
                // внешняя картинка: ключ ей не отдаём; без вложения — просто ссылка
                var l = label ("<a href=\"%s\">%s</a>".printf (Markup.escape_text (ref_name), Markup.escape_text (Path.get_basename (ref_name))));
                return l;
            }
            btn.clicked.connect (() => open_attachment.begin (this, att));
            load_attachment_texture.begin (att, false, null, (o, res) => {
                var t = load_attachment_texture.end (res);
                if (t == null) return;
                pic.paintable = t;
                // не шире колонки и не выше 360 px — крупное открывается по клику
                var hgt = int.min (360, t.get_height ());
                pic.height_request = hgt;
            });
            return btn;
        }

        private bool on_link (Gtk.Label l, string uri) {
            var w = win_of (this);
            if (uri.has_prefix ("issue:")) {
                var p = uri.substring (6).split (":");
                if (w != null) w.open_issue (int.parse (p[0]), p.length > 1 ? int.parse (p[1]) : 0, true);
                return true;
            }
            if (uri.has_prefix ("note:")) {
                note_activated (int.parse (uri.substring (5)));
                return true;
            }
            if (uri.has_prefix ("user:")) {
                new PersonDialog (int.parse (uri.substring (5))).present (this);
                return true;
            }
            var s = App.get ().session;
            var target = uri;
            // ссылка от корня сервера («/people/107»)
            if (uri.has_prefix ("/") && s != null) target = s.server + uri;
            // своя задача по полному адресу — открываем в приложении
            MatchInfo? mi = null;
            if (s != null && target.has_prefix (s.server) && /\/issues\/(\d+)(?:#note-(\d+))?$/.match (target, 0, out mi)) {
                if (w != null) w.open_issue (int.parse (mi.fetch (1)), mi.get_match_count () > 2 ? int.parse (mi.fetch (2)) : 0, true);
                return true;
            }
            new Gtk.UriLauncher (target).launch.begin (w, null);
            return true;
        }
    }

    /** Карточка человека: имя, логин, должность, отдел, почта; «Открыть профиль в Redmine». */
    public class PersonDialog : Adw.Dialog {
        public PersonDialog (int user_id) {
            title = _("Person");
            content_width = 420;
            var page = new Adw.PreferencesPage ();
            var group = new Adw.PreferencesGroup ();
            page.add (group);
            var top = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) { margin_top = 12, margin_bottom = 12 };
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            var spinner = new Adw.Spinner () { height_request = 32 };
            top.append (spinner);
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (top);
            box.append (page);
            tv.content = box;
            child = tv;
            load.begin (user_id, top, spinner, group);
        }

        private async void load (int id, Gtk.Box top, Adw.Spinner spinner, Adw.PreferencesGroup group) {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var p = yield s.refs.person (id);
                top.remove (spinner);
                var name = person_short_name (p);
                top.append (Avatars.make (id, name, 80));
                var title_l = new Gtk.Label (name) { wrap = true, justify = Gtk.Justification.CENTER };
                title_l.add_css_class ("title-2");
                top.append (title_l);
                void row (Adw.PreferencesGroup g, string t, string v) {
                    if (v == "") return;
                    var r = new Adw.ActionRow () { title = t, subtitle = v, subtitle_selectable = true };
                    r.add_css_class ("property");
                    g.add (r);
                }
                row (group, _("Login"), jstr (p, "login"));
                row (group, _("Job title"), jstr (p, "job_title"));
                row (group, _("Department"), jstr (jobj (p, "department"), "name"));
                var mail = jstr (p, "email") != "" ? jstr (p, "email") : jstr (p, "mail");
                row (group, _("Email"), mail);
                row (group, _("Personnel number"), jstr (p, "personnel_number"));
                var open = new Adw.ButtonRow () { title = _("Open Profile in Redmine"), end_icon_name = "adw-external-link-symbolic" };
                open.activated.connect (() => new Gtk.UriLauncher (s.server + "/people/%d".printf (id)).launch.begin (get_root () as Gtk.Window, null));
                group.add (open);
            } catch (Error e) {
                top.remove (spinner);
                var l = new Gtk.Label (e.message) { wrap = true };
                l.add_css_class ("error");
                top.append (l);
            }
        }
    }
}
