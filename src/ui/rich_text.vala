/* Textile → виджеты: подряд идущий текст (абзацы, списки, код, цитаты, линии) — один FlowView, таблицы/картинки/collapse — свои. */
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
            FlowView? flow = null;
            foreach (var b in Textile.group (lines)) {
                var gap = Textile.gap_before (prev, b);
                prev = b;
                // подряд идущий текст — в один TextView, чтобы выделение шло через абзацы
                // картинка не из вложений — просто ссылка, тоже текстом
                if (Textile.is_flow (b) || (b.kind == Textile.BlockKind.IMAGE && external_image (b.lines[0].text))) {
                    if (flow == null) {
                        flow = new FlowView (quote_depth > 0) { margin_top = gap };
                        flow.link_activated.connect (on_link);
                        into.append (flow);
                        gap = 0;
                    }
                    flow.add_block (b, 0, gap, lookup);
                    continue;
                }
                flow = null;
                var w = block (b, depth);
                w.margin_top = gap;
                into.append (w);
            }
        }

        private Gtk.Label label (string markup) {
            var l = new Gtk.Label (null) {
                use_markup = true, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, xalign = 0, selectable = true,
                hexpand = true,
            };
            l.set_markup (markup);
            l.activate_link.connect ((uri) => { on_link (uri); return true; });
            return l;
        }

        /** Таблица, картинка, collapse и цитата с ними — отдельные виджеты между TextView. */
        private Gtk.Widget block (Textile.Block b, int depth) {
            switch (b.kind) {
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
                case Textile.BlockKind.IMAGE:
                    return image (b.lines[0].text);
                default:
                    return table (b);
            }
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

        private bool external_image (string ref_name) {
            return ref_name.has_prefix ("http") || resolve_attachment (ref_name, atts) == null;
        }

        private Gtk.Widget image (string ref_name) {
            var pic = new Gtk.Picture () { can_shrink = true, content_fit = Gtk.ContentFit.SCALE_DOWN, halign = Gtk.Align.START, height_request = 48 };
            pic.add_css_class ("rich-image");
            var att = resolve_attachment (ref_name, atts);
            var btn = new Gtk.Button () { child = pic, halign = Gtk.Align.START, tooltip_text = ref_name };
            btn.add_css_class ("flat");
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

        private void on_link (string uri) {
            var w = win_of (this);
            if (uri.has_prefix ("issue:")) {
                var p = uri.substring (6).split (":");
                if (w != null) w.open_issue (int.parse (p[0]), p.length > 1 ? int.parse (p[1]) : 0, true);
                return;
            }
            if (uri.has_prefix ("note:")) {
                note_activated (int.parse (uri.substring (5)));
                return;
            }
            if (uri.has_prefix ("user:")) {
                new PersonCard (int.parse (uri.substring (5))).present (this);
                return;
            }
            var s = App.get ().session;
            var target = uri;
            // ссылка от корня сервера («/people/107»)
            if (uri.has_prefix ("/") && s != null) target = s.server + uri;
            // своя задача по полному адресу — открываем в приложении
            MatchInfo? mi = null;
            if (s != null && target.has_prefix (s.server) && /\/issues\/(\d+)(?:#note-(\d+))?$/.match (target, 0, out mi)) {
                if (w != null) w.open_issue (int.parse (mi.fetch (1)), mi.get_match_count () > 2 ? int.parse (mi.fetch (2)) : 0, true);
                return;
            }
            new Gtk.UriLauncher (target).launch.begin (w, null);
        }
    }
    /**
     * Подряд идущие текстовые блоки одного Textile — один GtkTextView без своей прокрутки: выделение мышью и
     * клавиатурой, Ctrl+C и «Выделить всё» идут через все абзацы. Стили — общие теги, ссылки — смещения в буфере,
     * фон кода, полоса цитаты и линия рисуются под текстом (snapshot_layer).
     */
    public class FlowView : Gtk.TextView {
        private const int QUOTE_INDENT = 13; // полоса 3 + отступ 10, как .rich-quote
        private const int MARK = 22;         // место под маркер списка
        private static Gtk.TextTagTable? shared = null;

        private class Deco { public int kind; public int first; public int last; public int x; public int above; }
        private class Link { public int start; public int end; public string href; }
        private GenericArray<Deco> decos = new GenericArray<Deco> ();
        private GenericArray<Link> links = new GenericArray<Link> ();
        private bool in_dim;

        public signal void link_activated (string uri);

        /*
         * GtkTextView не умеет «высоту по ширине»: отдаёт высоту раскладки при прошлой ширине (до первого размещения —
         * при ширине 1, по букве в строке), и лента прыгает и раскладывается дважды. Раскладываем на запрошенную ширину
         * сразу при измерении: тот же size_allocate самого TextView, с высотой «всё на экране».
         */
        private int laid_width = -1;

        public override Gtk.SizeRequestMode get_request_mode () { return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH; }

        public override void measure (Gtk.Orientation o, int for_size, out int min, out int nat, out int min_b, out int nat_b) {
            if (o == Gtk.Orientation.VERTICAL && for_size > 0 && for_size != laid_width) {
                laid_width = for_size;
                base.size_allocate (for_size, 1 << 20, -1);
            }
            base.measure (o, for_size, out min, out nat, out min_b, out nat_b);
            min_b = nat_b = -1;
        }

        public override void size_allocate (int width, int height, int baseline) {
            laid_width = width;
            base.size_allocate (width, height, baseline);
        }

        /** in_dim — уже внутри приглушённой цитаты-виджета: цитаты здесь второй раз не тускнеют. */
        public FlowView (bool in_dim = false) {
            Object (buffer: new Gtk.TextBuffer (tags ()), editable: false, cursor_visible: false,
                    wrap_mode: Gtk.WrapMode.WORD_CHAR, hexpand: true);
            this.in_dim = in_dim;
            add_css_class ("rich-flow");
            var click = new Gtk.GestureClick ();
            click.released.connect ((n, x, y) => {
                if (buffer.has_selection) return;
                var h = href_at (x, y);
                if (h != null) link_activated (h);
            });
            add_controller (click);
            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect ((x, y) => set_cursor_from_name (href_at (x, y) != null ? "pointer" : "text"));
            add_controller (motion);
            // Enter на ссылке под кареткой — как щелчок; каретка видна, пока фокус здесь
            var key = new Gtk.EventControllerKey ();
            key.key_pressed.connect ((kv, code, mods) => {
                if (kv != Gdk.Key.Return && kv != Gdk.Key.KP_Enter) return false;
                Gtk.TextIter it;
                buffer.get_iter_at_mark (out it, buffer.get_insert ());
                var h = href_of (it.get_offset ());
                if (h != null) link_activated (h);
                return h != null;
            });
            add_controller (key);
            var focus = new Gtk.EventControllerFocus ();
            focus.enter.connect (() => cursor_visible = true);
            focus.leave.connect (() => cursor_visible = false);
            add_controller (focus);
        }

        /** Теги на все FlowView: цвета следят за темой и акцентом. */
        private static Gtk.TextTagTable tags () {
            if (shared != null) return shared;
            shared = new Gtk.TextTagTable ();
            shared.add (new Gtk.TextTag ("b") { weight = 700 });
            shared.add (new Gtk.TextTag ("i") { style = Pango.Style.ITALIC });
            shared.add (new Gtk.TextTag ("s") { strikethrough = true });
            shared.add (new Gtk.TextTag ("u") { underline = Pango.Underline.SINGLE });
            shared.add (new Gtk.TextTag ("sup") { rise = 4 * Pango.SCALE, scale = 0.75 });
            shared.add (new Gtk.TextTag ("sub") { rise = -2 * Pango.SCALE, scale = 0.75 });
            shared.add (new Gtk.TextTag ("code") { family = "monospace", background_rgba = { 0.5f, 0.5f, 0.5f, 0.18f } });
            shared.add (new Gtk.TextTag ("pre") { family = "monospace", wrap_mode = Gtk.WrapMode.CHAR });
            shared.add (new Gtk.TextTag ("h1") { scale = 1.44, weight = 700 });
            shared.add (new Gtk.TextTag ("h2") { scale = 1.2, weight = 700 });
            shared.add (new Gtk.TextTag ("h3") { weight = 700 });
            shared.add (new Gtk.TextTag ("rule") { scale = 0.1 });
            // порядок = приоритет: ссылка в цитате остаётся цветом акцента
            shared.add (new Gtk.TextTag ("dim"));
            shared.add (new Gtk.TextTag ("macro") { scale = 0.833 });
            shared.add (new Gtk.TextTag ("link") { underline = Pango.Underline.SINGLE });
            var sm = Adw.StyleManager.get_default ();
            sm.notify["dark"].connect (paint);
            sm.notify["high-contrast"].connect (paint);
            sm.notify["accent-color"].connect (paint);
            paint ();
            return shared;
        }

        private static void paint () {
            var sm = Adw.StyleManager.get_default ();
            // --window-fg-color Adwaita и прозрачность .dim-label (--dim-opacity)
            Gdk.RGBA fg = sm.dark ? Gdk.RGBA () { red = 1, green = 1, blue = 1, alpha = 1 } : Gdk.RGBA () { red = 0, green = 0, blue = 6 / 255f, alpha = 0.8f };
            var dim = fg;
            dim.alpha *= sm.high_contrast ? 0.9f : 0.55f;
            var macro = fg;
            macro.alpha *= 0.6f;
            shared.lookup ("dim").foreground_rgba = dim;
            shared.lookup ("macro").foreground_rgba = macro;
            shared.lookup ("link").foreground_rgba = sm.get_accent_color ().to_standalone_rgba (sm.dark);
        }

        /** Тег абзаца по значению (отступы, интервалы): общий, создаётся по первому требованию. */
        private Gtk.TextTag para_tag (string name, int left, int right, int indent, int above, int below) {
            var t = shared.lookup (name);
            if (t != null) return t;
            t = new Gtk.TextTag (name);
            if (left >= 0) t.left_margin = left;
            if (right >= 0) t.right_margin = right;
            if (indent != 0) t.indent = indent;
            if (above >= 0) t.pixels_above_lines = above;
            if (below >= 0) t.pixels_below_lines = below;
            shared.add (t);
            return t;
        }

        private int end_offset () {
            Gtk.TextIter e;
            buffer.get_end_iter (out e);
            return e.get_offset ();
        }

        private void tag_range (Gtk.TextTag t, int from, int to) {
            Gtk.TextIter a, z;
            buffer.get_iter_at_offset (out a, from);
            buffer.get_iter_at_offset (out z, to);
            buffer.apply_tag (t, a, z);
        }

        /** Новый абзац (строка буфера); возвращает его начало. */
        private int begin () {
            if (buffer.get_char_count () > 0) {
                Gtk.TextIter e;
                buffer.get_end_iter (out e);
                buffer.insert (ref e, "\n", 1);
            }
            return end_offset ();
        }

        private int line_of (int offset) {
            Gtk.TextIter it;
            buffer.get_iter_at_offset (out it, offset);
            return it.get_line ();
        }

        private void put (string text, string[] tags, string? href = null) {
            if (text == "") return;
            int s = end_offset ();
            Gtk.TextIter e;
            buffer.get_end_iter (out e);
            buffer.insert (ref e, text, -1);
            int z = end_offset ();
            foreach (var t in tags) tag_range (shared.lookup (t), s, z);
            if (href != null) links.add (new Link () { start = s, end = z, href = href });
        }

        private void put_markup (string markup, string[] extra = {}) {
            foreach (var r in Textile.markup_runs (markup)) {
                var t = r.tags;
                foreach (var x in extra) t += x;
                put (r.text, t, r.href);
            }
        }

        /** Интервал над первой строкой абзаца [from, …). */
        private void above (int from, int px) {
            if (px <= 0) return;
            Gtk.TextIter a, z;
            buffer.get_iter_at_offset (out a, from);
            z = a;
            if (!z.ends_line ()) z.forward_to_line_end ();
            if (a.equal (z)) z.forward_char ();
            buffer.apply_tag (para_tag ("pa%d".printf (px), -1, -1, 0, px, -1), a, z);
        }

        public void add_block (Textile.Block b, int q, int gap, Textile.MentionLookup? lookup) {
            int left = q * QUOTE_INDENT;
            switch (b.kind) {
                case Textile.BlockKind.TEXT:
                    int s = begin ();
                    put_markup (Textile.text_markup (b.lines, lookup));
                    tag_range (para_tag ("m%d".printf (left), left, -1, 0, -1, -1), s, end_offset ());
                    above (s, gap);
                    break;
                case Textile.BlockKind.LIST:
                    for (int i = 0; i < b.lines.length; i++) {
                        var l = b.lines[i];
                        int s = begin ();
                        put (l.number > 0 ? "%d.\t".printf (l.number) : "•\t", { "dim" });
                        put_markup (Textile.inline_markup (l.text, lookup));
                        int m = left + 4 + l.level * 18;
                        // висячий отступ: маркер с края, перенос строки — под текстом; табуляция ровняет «•» и «10.»
                        var t = para_tag ("li%d".printf (m), m, -1, -MARK, -1, -1);
                        if (t.tabs == null) {
                            var tabs = new Pango.TabArray (1, true);
                            tabs.set_tab (0, Pango.TabAlign.LEFT, MARK);
                            t.tabs = tabs;
                        }
                        tag_range (t, s, end_offset ());
                        above (s, i == 0 ? gap : 2);
                    }
                    break;
                case Textile.BlockKind.CODE:
                    int s = begin ();
                    var sb = new StringBuilder ();
                    for (int i = 0; i < b.lines.length; i++) {
                        sb.append (Textile.unraw (b.lines[i].text));
                        if (i < b.lines.length - 1) sb.append_c ('\n');
                    }
                    put (sb.str, { "pre" });
                    tag_range (para_tag ("c%d".printf (left), left + 10, 10, 0, -1, -1), s, end_offset ());
                    above (s, gap + 8);
                    // нижний отступ фона — у последней строки
                    Gtk.TextIter a, z;
                    buffer.get_end_iter (out z);
                    a = z;
                    a.set_line_offset (0);
                    if (a.equal (z)) { put (" ", { "pre" }); buffer.get_end_iter (out z); }
                    buffer.apply_tag (para_tag ("pb8", -1, -1, 0, -1, 8), a, z);
                    decos.add (new Deco () { kind = 0, first = line_of (s), last = line_of (end_offset ()), x = left, above = gap });
                    break;
                case Textile.BlockKind.IMAGE: // внешняя картинка: ключ ей не отдаём — ссылкой
                    var name = b.lines[0].text;
                    int s = begin ();
                    put (Path.get_basename (name), { "link" }, name);
                    tag_range (para_tag ("m%d".printf (left), left, -1, 0, -1, -1), s, end_offset ());
                    above (s, gap);
                    break;
                case Textile.BlockKind.RULE:
                    int s = begin ();
                    put (" ", { "rule" });
                    above (s, gap);
                    decos.add (new Deco () { kind = 2, first = line_of (s), last = line_of (s), x = left, above = gap });
                    break;
                case Textile.BlockKind.QUOTE:
                    int s = end_offset () + (buffer.get_char_count () > 0 ? 1 : 0);
                    Textile.Block? prev = null;
                    foreach (var c in Textile.group (b.lines[0].children)) {
                        add_block (c, q + 1, prev == null ? gap : Textile.gap_before (prev, c), lookup);
                        prev = c;
                    }
                    if (prev == null) break;
                    if (q == 0 && !in_dim) tag_range (shared.lookup ("dim"), s, end_offset ());
                    decos.add (new Deco () { kind = 1, first = line_of (s), last = line_of (end_offset ()), x = left, above = gap });
                    break;
            }
        }

        private string? href_of (int offset) {
            foreach (var l in links) if (offset >= l.start && offset < l.end) return l.href;
            return null;
        }

        private string? href_at (double x, double y) {
            int bx, by;
            window_to_buffer_coords (Gtk.TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            Gtk.TextIter it;
            if (!get_iter_at_location (out it, bx, by)) return null;
            return href_of (it.get_offset ());
        }

        public override void snapshot_layer (Gtk.TextViewLayer layer, Gtk.Snapshot snap) {
            if (layer != Gtk.TextViewLayer.BELOW_TEXT || decos.length == 0) return;
            var fg = get_color ();
            int w = get_width ();
            foreach (var d in decos) {
                Gtk.TextIter a, z;
                buffer.get_iter_at_line (out a, d.first);
                buffer.get_iter_at_line (out z, d.last);
                int y0, h0, y1, h1;
                get_line_yrange (a, out y0, out h0);
                get_line_yrange (z, out y1, out h1);
                float top = y0 + d.above, bottom = y1 + h1;
                var c = fg;
                switch (d.kind) {
                    case 0: // фон кода, как .rich-code
                        c.alpha *= 0.06f;
                        var r = Gsk.RoundedRect ();
                        r.init_from_rect ({ { d.x, top }, { w - d.x, bottom - top } }, 6);
                        snap.push_rounded_clip (r);
                        snap.append_color (c, r.bounds);
                        snap.pop ();
                        break;
                    case 1: // полоса цитаты; приглушена, как и текст
                        c.alpha *= in_dim ? 0.25f : 0.14f;
                        snap.append_color (c, { { d.x, top }, { 3, bottom - top } });
                        break;
                    default:
                        c.alpha *= 0.15f;
                        snap.append_color (c, { { d.x, top + (bottom - top) / 2 }, { w - d.x, 1 } });
                        break;
                }
            }
        }
    }
}
