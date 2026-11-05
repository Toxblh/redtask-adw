/* Textile → виджеты: подряд идущий текст (абзацы, списки, код, цитаты, линии) — один FlowView, таблицы/картинки/collapse — свои. */
namespace Redmine {

    /** login и «user#id» → «id|Имя» на всё приложение: упоминания резолвятся один раз (RefData хранит и на диске). */
    private HashTable<string, string>? mention_cache = null;
    /** id → имя, как его пишет сервер (author/journals/watchers.name): упоминание — тем же именем, что и авторы. */
    private HashTable<string, string>? known_names = null;
    /** Номер задачи → «C|O» + подсказка: с сервера (issue_briefs) и, главнее, — открытые в приложении задачи. */
    private HashTable<string, string>? brief_cache = null;
    private HashTable<string, string>? brief_known = null;
    /** Стили ячеек «{background:…}»: правило → класс, все правила — в одном провайдере. */
    private Gtk.CssProvider? cell_css = null;
    private HashTable<string, string>? cell_classes = null;
    private StringBuilder? cell_rules = null;

    public class RichText : Gtk.Box {
        private string text;
        private GenericArray<Json.Object> atts;
        private int quote_depth = 0;
        private bool quotable;
        /** Проект для [[Страница]] без проекта: идентификатор или номер; пусто — такие ссылки в браузер не уходят. */
        public string wiki_project = "";
        /** Ссылка #note-K на комментарий этой же задачи: K — порядковый номер записи журнала. */
        public signal void note_activated (int note);
        /** «Ответить с цитатой» в меню выделения (quotable): выделенный текст, как он виден на экране. */
        public signal void quote_selected (string text);

        public RichText (string text, GenericArray<Json.Object>? attachments = null, bool quotable = false) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.text = text;
            this.quotable = quotable;
            atts = attachments ?? new GenericArray<Json.Object> ();
            init_caches ();
            render ();
            resolve_mentions.begin ();
        }

        private static void init_caches () {
            if (mention_cache != null) return;
            mention_cache = new HashTable<string, string> (str_hash, str_equal);
            known_names = new HashTable<string, string> (str_hash, str_equal);
            brief_cache = new HashTable<string, string> (str_hash, str_equal);
            brief_known = new HashTable<string, string> (str_hash, str_equal);
        }

        /** Имена людей задачи в формате сервера и её статус — до того, как строятся её тексты. */
        public static void learn (Issue i) {
            init_caches ();
            Named?[] people = { i.author, i.assigned_to };
            foreach (var n in people) if (n != null && n.id > 0 && n.name != "") known_names[n.id.to_string ()] = n.name;
            var list = i.watchers;
            foreach (var j in i.journals) list.add (jobj (j, "user"));
            foreach (var o in list) if (o != null && jint (o, "id") > 0 && jstr (o, "name") != "") known_names[jint (o, "id").to_string ()] = jstr (o, "name");
            brief_known[i.id.to_string ()] = "%s|%s: %s (%s)".printf (i.status_closed ? "C" : "O", i.tracker.name, i.subject, i.status.name);
        }

        /**
         * Имя как у сервера: это же id уже встречалось в задаче — оттуда; иначе «Фамилия Имя», как пишет
         * my.basealt.space (user_format lastname_firstname). ponytail: формат других серверов не угадываем.
         */
        private static string server_name (int id, Json.Object p) {
            var known = known_names[id.to_string ()];
            if (known != null) return known;
            var first = jstr (p, "firstname");
            if (first == "") first = jstr (p, "first_name");
            var last = jstr (p, "lastname");
            if (last == "") last = jstr (p, "last_name");
            return (last + " " + first).strip ();
        }

        private string? lookup (string key) {
            if (key.has_prefix ("issue#")) {
                var id = key.substring (6);
                return brief_known[id] ?? brief_cache[id];
            }
            var hit = mention_cache[key];
            if (hit == null) return null;
            // имя могло стать известным позже (открыли задачу, где человек — автор)
            var bar = hit.index_of ("|");
            var known = known_names[hit.substring (0, bar)];
            return known != null ? hit.substring (0, bar + 1) + known : hit;
        }

        private async void resolve_mentions () {
            var s = App.get ().session;
            if (s == null) return;
            bool changed = false;
            foreach (var l in Textile.mention_logins (text)) {
                if (mention_cache.contains (l)) continue;
                Json.Object? p = null;
                if (l.has_prefix ("user#")) {
                    var id = int.parse (l.substring (5));
                    if (known_names.contains (id.to_string ())) {
                        mention_cache[l] = "%d|%s".printf (id, known_names[id.to_string ()]);
                        changed = true;
                        continue;
                    }
                    try { p = yield s.refs.person (id); } catch (Error e) {}
                } else {
                    p = yield s.refs.person_by_login (l);
                }
                if (p == null || jint (p, "id") <= 0) continue;
                var n = server_name (jint (p, "id"), p);
                mention_cache[l] = "%d|%s".printf (jint (p, "id"), n != "" ? n : l);
                changed = true;
            }
            var ids = Textile.issue_ids (text);
            if (ids.length > 0) {
                var briefs = yield s.refs.issue_briefs (ids);
                foreach (var id in ids) {
                    var b = briefs[id];
                    var k = id.to_string ();
                    if (b != null && brief_cache[k] != b) {
                        brief_cache[k] = b;
                        if (!brief_known.contains (k)) changed = true;
                    }
                }
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
                        if (quotable) { flow.enable_quote (); flow.quote_selected.connect ((t) => quote_selected (t)); }
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
                    var ex = new Gtk.Expander (null);
                    // заголовок своим ярлыком с переносом: стандартный — в одну строку и распирает окно на телефоне
                    ex.label_widget = new Gtk.Label (l0.text != "" ? l0.text : _("Show details")) {
                        wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, xalign = 0,
                    };
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

        /** Сетка как у сайта: рамка у каждой ячейки, th — жирный по центру на сером; ширина по содержимому. */
        private Gtk.Widget table (Textile.Block b) {
            var grid = new Gtk.Grid () { column_spacing = 0, row_spacing = 0 };
            grid.add_css_class ("rich-table");
            Textile.layout_table (b.lines);
            bool spans = false;
            foreach (var l in b.lines) foreach (var c in l.cells) spans = spans || c.span > 1 || c.rowspan > 1;
            var cells = spans ? null : new TableCells ();
            int r = 0;
            foreach (var l in b.lines) {
                foreach (var c in l.cells) {
                    var m = Textile.inline_markup (c.text, lookup);
                    var just = c.xalign == 0.5f ? Gtk.Justification.CENTER : (c.xalign == 1 ? Gtk.Justification.RIGHT : Gtk.Justification.LEFT);
                    Gtk.Widget cell;
                    // ячейка в несколько строк (п. 7) — обычный блок текста: списки, ссылки, переносы
                    bool multi = false;
                    if (cells != null) {
                        var ls = Textile.parse (c.text);
                        multi = ls.length > 1 || (ls.length == 1 && ls[0].kind != Textile.Kind.PLAIN);
                    }
                    if (multi || m.contains ("class=\"mention\"")) {
                        // упоминание — пилюля-виджет, а в GtkLabel виджет не вставить: ячейка-FlowView
                        var fv = new FlowView () { hexpand = false, justification = just };
                        // колонка не уже самого длинного слова (п. 7) — слово не рвём
                        if (cells != null) fv.wrap_mode = Gtk.WrapMode.WORD;
                        fv.link_activated.connect (on_link);
                        if (multi || cells != null) fv.add_text (c.text, lookup); else fv.add_cell (m);
                        cell = fv;
                    } else {
                        // пустая ячейка — пробелом: строка «|  |  |» держит высоту строки, как на сайте
                        var lb = label (m != "" ? m : " ");
                        lb.selectable = false;
                        lb.hexpand = false;
                        lb.xalign = c.xalign;
                        lb.justify = just;
                        if (cells != null) {
                            // колонка не уже самого длинного слова (п. 7) — слово не рвём
                            lb.wrap_mode = Pango.WrapMode.WORD;
                        } else {
                            lb.max_width_chars = 40;
                            // без минимальной ширины прокрутка меряет высоту по ширине в букву — таблица вытягивается вниз пустотой
                            lb.width_chars = int.min (c.text.char_count (), 40);
                        }
                        cell = lb;
                    }
                    if (c.header) cell.add_css_class ("rich-th");
                    var cls = cell_class (c);
                    if (cls != null) cell.add_css_class (cls);
                    if (cells != null) cells.add (cell, c.col, r);
                    else grid.attach (cell, c.col, r, c.span, c.rowspan);
                }
                r++;
            }
            if (cells != null) return new Table (cells);
            // не шире содержимого; не влезает — прокрутка вбок, рамка целиком внутри прокрутки
            return new Gtk.ScrolledWindow () {
                child = grid, vscrollbar_policy = Gtk.PolicyType.NEVER, propagate_natural_height = true,
                propagate_natural_width = true, halign = Gtk.Align.START,
            };
        }

        /**
         * Класс со стилем ячейки «{background:#ffc; color:red; font-weight:bold}». Цвета уже проверены разбором,
         * сюда идут пересобранными через Gdk.RGBA. Явный фон без своего цвета текста — с контрастным текстом:
         * светлый фон в тёмной теме иначе получил бы белые буквы.
         */
        private static string? cell_class (Textile.Cell c) {
            var sb = new StringBuilder ();
            Gdk.RGBA bg = {}, fg = {};
            bool has_fg = c.fg != null && fg.parse (c.fg);
            if (c.bg != null && bg.parse (c.bg) && bg.alpha > 0) {
                sb.append ("background-color:%s;".printf (bg.to_string ()));
                if (!has_fg) {
                    var lum = 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue;
                    sb.append (lum > 0.5 ? "color:rgba(0,0,6,0.8);" : "color:#ffffff;");
                }
            }
            if (has_fg) sb.append ("color:%s;".printf (fg.to_string ()));
            if (c.bold) sb.append ("font-weight:bold;");
            if (sb.len == 0) return null;
            if (cell_css == null) {
                cell_css = new Gtk.CssProvider ();
                cell_classes = new HashTable<string, string> (str_hash, str_equal);
                cell_rules = new StringBuilder ();
                Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), cell_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            }
            var cls = cell_classes[sb.str];
            if (cls != null) return cls;
            // ponytail: не больше 256 разных стилей на приложение — дальше ячейки без стиля
            if (cell_classes.size () >= 256) return null;
            cls = "rich-cell-%u".printf (cell_classes.size ());
            cell_classes[sb.str] = cls;
            cell_rules.append (".rich-table > .%s{%s}\n".printf (cls, sb.str));
            cell_css.load_from_string (cell_rules.str);
            return cls;
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
            // «#N#note-K» и «#note-K» — K это порядковый номер записи журнала, как на сайте
            if (uri.has_prefix ("issue:")) {
                var p = uri.substring (6).split (":");
                if (w != null) w.open_link (new ServerLink () { kind = LinkKind.ISSUE, id = int.parse (p[0]), note_index = p.length > 1 ? int.parse (p[1]) : 0 }, true);
                return;
            }
            if (uri.has_prefix ("wiki:")) {
                var rest = uri.substring (5);
                var c = rest.index_of (":");
                var proj = c > 0 ? rest.substring (0, c) : wiki_project;
                if (proj != "" && w != null) w.open_content (new WikiPage (proj, rest.substring (c + 1)));
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
            // своя задача, проект, человек по полному адресу — в приложении
            var sl = s != null ? ServerLink.parse (s.server, target) : null;
            if (sl != null && w != null) {
                w.open_link (sl, true);
                return;
            }
            new Gtk.UriLauncher (target).launch.begin (w, null);
        }
    }
    /** Пилюля упоминания: аватар 18 px и имя; кнопка — Tab/Enter, курсор-указатель, подпись для диктора. */
    public delegate void PillClick ();
    public Gtk.Widget mention_pill (int id, string name, owned PillClick click) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        box.append (Avatars.make (id, name, 18));
        box.append (new Gtk.Label (name));
        var b = new Gtk.Button () { child = box, cursor = new Gdk.Cursor.from_name ("pointer", null), valign = Gtk.Align.BASELINE_CENTER };
        b.add_css_class ("mention-pill");
        b.update_property (Gtk.AccessibleProperty.LABEL, name, -1);
        b.clicked.connect (() => click ());
        return b;
    }

    /**
     * Подряд идущие текстовые блоки одного Textile — один GtkTextView без своей прокрутки: выделение мышью и
     * клавиатурой, Ctrl+C и «Выделить всё» идут через все абзацы. Стили — общие теги, ссылки — смещения в буфере,
     * фон кода, полоса цитаты и линия рисуются под текстом (snapshot_layer).
     */
    /**
     * Таблица без объединённых ячеек (п. 7): колонки по Textile.table_columns от доступной ширины,
     * не влезает и по самым длинным словам — прокрутка вбок. Высоту считает сама: прокрутка
     * меряет ребёнка без ширины.
     */
    private class Table : Gtk.Widget {
        private Gtk.ScrolledWindow scroll;
        private TableCells cells;

        public Table (TableCells cells) {
            this.cells = cells;
            scroll = new Gtk.ScrolledWindow () { child = cells, vscrollbar_policy = Gtk.PolicyType.NEVER };
            scroll.set_parent (this);
        }

        public override Gtk.SizeRequestMode get_request_mode () { return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH; }

        public override void measure (Gtk.Orientation o, int for_size, out int min, out int nat, out int mb, out int nb) {
            int m, n;
            scroll.measure (o, for_size, out m, out n, null, null);
            mb = nb = -1;
            if (o == Gtk.Orientation.HORIZONTAL) {
                int cm, cn;
                cells.measure (o, -1, out cm, out cn, null, null);
                min = m;
                nat = int.max (m, cn);
            } else {
                min = nat = cells.height_for (for_size);
            }
        }

        public override void size_allocate (int w, int h, int baseline) { scroll.allocate (w, h, baseline, null); }

        public override void dispose () {
            scroll.unparent ();
            base.dispose ();
        }
    }

    /** Ячейки таблицы сеткой: ширины колонок — Textile.table_columns, высота строки — по самой высокой ячейке. */
    private class TableCells : Gtk.Widget {
        private GenericArray<Gtk.Widget> cells = new GenericArray<Gtk.Widget> ();
        private string[] texts = {};
        private int[] cols = {};
        private int[] rows = {};
        private int ncols = 0;
        private int nrows = 0;
        private double[]? mins = null;
        private double[] maxs;

        construct { add_css_class ("rich-table"); }

        public void add (Gtk.Widget w, int col, int row) {
            w.set_parent (this);
            cells.add (w);
            // замер — по видимому тексту, не по исходнику: «"текст":/длинный/адрес» узкий
            var fv = w as FlowView;
            texts += fv != null ? fv.visible_text () : ((Gtk.Label) w).get_text ();
            cols += col;
            rows += row;
            ncols = int.max (ncols, col + 1);
            nrows = int.max (nrows, row + 1);
        }

        /**
         * min — самое длинное слово, max — вся ячейка; Pango шрифтом самой ячейки (у th он жирный из CSS).
         * Не меньше собственного минимума ячейки: в нём разметка и упоминания-пилюли.
         * ponytail: замер один раз — смена шрифта в системе не пересчитывает, до новой отрисовки текста.
         */
        private void measure_columns () {
            if (mins != null) return;
            mins = new double[ncols];
            maxs = new double[ncols];
            const int PAD = 17; // padding 4px 8px и рамка 1px в style.css (.rich-table > label)
            for (int i = 0; i < cells.length; i++) {
                var w = cells[i];
                int cm, cn, pw, ph, word = 0;
                w.measure (Gtk.Orientation.HORIZONTAL, -1, out cm, out cn, null, null);
                var lay = w.create_pango_layout (texts[i]);
                lay.get_pixel_size (out pw, out ph);
                foreach (var t in texts[i].replace ("\u2028", "\n").split_set (" \n")) {
                    int tw;
                    lay.set_text (t, -1);
                    lay.get_pixel_size (out tw, out ph);
                    word = int.max (word, tw);
                }
                var c = cols[i];
                // TextView держит место под каретку — пара пикселей сверх текста
                if (w is FlowView) { word += 2; pw += 2; }
                mins[c] = double.max (mins[c], int.max (word + PAD, cm));
                maxs[c] = double.max (maxs[c], double.max (pw + PAD, mins[c]));
            }
            for (int c = 0; c < ncols; c++) maxs[c] = double.max (maxs[c], mins[c]);
        }

        private int sum (double[] v) {
            double s = 0;
            foreach (var x in v) s += x;
            return (int) Math.ceil (s);
        }

        /** Левые края колонок при ширине таблицы width; последний элемент — правый край. */
        private int[] edges (int width) {
            measure_columns ();
            bool scroll;
            var ws = Textile.table_columns (mins, maxs, int.max (width, sum (mins)), out scroll);
            var xs = new int[ncols + 1];
            double acc = 0;
            for (int c = 0; c < ncols; c++) {
                acc += ws[c];
                xs[c + 1] = (int) Math.round (acc);
            }
            return xs;
        }

        private int[] row_heights (int[] xs) {
            var hs = new int[nrows];
            for (int i = 0; i < cells.length; i++) {
                int m, n;
                cells[i].measure (Gtk.Orientation.VERTICAL, xs[cols[i] + 1] - xs[cols[i]], out m, out n, null, null);
                hs[rows[i]] = int.max (hs[rows[i]], m);
            }
            return hs;
        }

        private int content_height (int width) {
            var hs = row_heights (edges (width));
            int h = 0;
            foreach (var x in hs) h += x;
            return h;
        }

        /** Высота с рамкой таблицы (1px сверху и слева) при внешней ширине width; -1 — по самым длинным ячейкам. */
        public int height_for (int width) {
            measure_columns ();
            return content_height (width < 0 ? sum (maxs) : width - 1) + 1;
        }

        public override Gtk.SizeRequestMode get_request_mode () { return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH; }

        public override void measure (Gtk.Orientation o, int for_size, out int min, out int nat, out int mb, out int nb) {
            measure_columns ();
            mb = nb = -1;
            if (o == Gtk.Orientation.HORIZONTAL) {
                min = sum (mins);
                nat = sum (maxs);
            } else if (for_size < 0) {
                // прокрутка меряет без ширины — высоту даёт Table по настоящей ширине
                min = nat = 0;
            } else {
                min = nat = content_height (for_size);
            }
        }

        public override void size_allocate (int w, int h, int baseline) {
            var xs = edges (w);
            var hs = row_heights (xs);
            var ys = new int[nrows + 1];
            for (int r = 0; r < nrows; r++) ys[r + 1] = ys[r] + hs[r];
            for (int i = 0; i < cells.length; i++) {
                var c = cols[i];
                var r = rows[i];
                cells[i].allocate (xs[c + 1] - xs[c], hs[r], -1, new Gsk.Transform ().translate ({ xs[c], ys[r] }));
            }
        }

        public override void dispose () {
            foreach (var w in cells) w.unparent ();
            cells.length = 0;
            base.dispose ();
        }
    }

    public class FlowView : Gtk.TextView {
        private const int QUOTE_INDENT = 13; // полоса 3 + отступ 10, как .rich-quote
        private const int MARK = 22;         // место под маркер списка
        private static Gtk.TextTagTable? shared = null;

        private class Deco { public int kind; public int first; public int last; public int x; public int above; }
        private class Link { public int start; public int end; public string href; public string? title; }
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
            // подсказка ссылки на задачу («Трекер: тема (Статус)»), как title на сайте; только мышью
            has_tooltip = true;
            query_tooltip.connect ((x, y, kb, tip) => {
                if (kb) return false;
                var l = link_at (x, y);
                if (l == null || l.title == null) return false;
                // ссылка на задачу: статус в подсказке — цветной пилюлей (PARITY 0)
                string text;
                bool c;
                if (!l.href.has_prefix ("issue:")) { tip.set_text (l.title); return true; }
                var st = brief_status (l.title, out text, out c);
                if (st == null) { tip.set_text (l.title); return true; }
                Gtk.TextIter it;
                buffer.get_iter_at_offset (out it, l.start);
                var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                b.append (new Gtk.Label (text) { wrap = true, max_width_chars = 60, xalign = 0 });
                b.append (status_pill (st, it.has_tag (shared.lookup ("closed"))));
                tip.set_custom (b);
                return true;
            });
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
            // ссылка на закрытую задачу — серая и зачёркнутая, поверх цвета ссылки
            shared.add (new Gtk.TextTag ("closed") { strikethrough = true });
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
            shared.lookup ("closed").foreground_rgba = dim;
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

        private void put (string text, string[] tags, string? href = null, string? title = null) {
            if (text == "") return;
            if ("mention" in tags && href != null) { put_mention (text, href); return; }
            int s = end_offset ();
            Gtk.TextIter e;
            buffer.get_end_iter (out e);
            buffer.insert (ref e, text, -1);
            int z = end_offset ();
            foreach (var t in tags) tag_range (shared.lookup (t), s, z);
            if (href != null) links.add (new Link () { start = s, end = z, href = href, title = title });
        }

        /**
         * @упоминание — пилюлей с аватаром, как на телефоне. Имя — в данных якоря: его берёт copy_clipboard.
         */
        private void put_mention (string name, string href) {
            Gtk.TextIter e;
            buffer.get_end_iter (out e);
            var anchor = new Gtk.TextChildAnchor ();
            anchor.set_data<string> ("name", name);
            buffer.insert_child_anchor (e, anchor);
            add_child_at_anchor (mention_pill (int.parse (href.substring (5)), name, () => link_activated (href)), anchor);
            // пробел нулевой ширины: строка из одной пилюли иначе без высоты шрифта под базовой линией — низ обрезан
            buffer.get_end_iter (out e);
            buffer.insert (ref e, "\u200B", -1);
        }

        /** Ячейка таблицы как блок Textile: абзацы и списки; ширину даёт таблица. ponytail: таблица и картинка внутри ячейки не рисуются. */
        public void add_text (string text, Textile.MentionLookup? lookup) {
            Textile.Block? prev = null;
            foreach (var b in Textile.group (Textile.parse (text))) {
                if (!Textile.is_flow (b)) continue;
                add_block (b, 0, Textile.gap_before (prev, b), lookup);
                prev = b;
            }
        }

        /** Ячейка таблицы с упоминанием: текст и ширина по содержимому (TextView сам ширину не просит). */
        public void add_cell (string markup) {
            put_markup (markup);
            int anchors = 0;
            var sb = new StringBuilder ();
            Gtk.TextIter it;
            buffer.get_start_iter (out it);
            for (; !it.is_end (); it.forward_char ()) {
                var anc = it.get_child_anchor ();
                if (anc != null) { anchors++; sb.append (anc.get_data<string> ("name") ?? ""); }
                else sb.append_unichar (it.get_char ());
            }
            int w, h;
            create_pango_layout (sb.str).get_pixel_size (out w, out h);
            // аватар 18 + промежуток и поля пилюли — на каждое упоминание
            width_request = int.min (w + anchors * 30 + 2, 360);
        }

        private void put_markup (string markup, string[] extra = {}) {
            foreach (var r in Textile.markup_runs (markup)) {
                var t = r.tags;
                foreach (var x in extra) t += x;
                put (r.text, t, r.href, r.title);
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
                        // перенос внутри пункта — U+2028: та же строка буфера, висячий отступ не сбивается
                        put_markup (Textile.inline_markup (l.text.replace ("\n", "\u2028"), lookup));
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

        /** Выделенное, как видно на экране: пилюли упоминаний — их именами, а не U+FFFC. */
        private string selected_text () {
            Gtk.TextIter a, z;
            if (!buffer.get_selection_bounds (out a, out z)) return "";
            return text_between (a, z);
        }

        public string visible_text () {
            Gtk.TextIter a, z;
            buffer.get_bounds (out a, out z);
            return text_between (a, z);
        }

        private string text_between (Gtk.TextIter a, Gtk.TextIter z) {
            var sb = new StringBuilder ();
            for (var it = a; it.compare (z) < 0; it.forward_char ()) {
                var anc = it.get_child_anchor ();
                if (anc != null) sb.append (anc.get_data<string> ("name") ?? "");
                else if (it.get_char () != 0x200B) sb.append_unichar (it.get_char ());
            }
            return sb.str;
        }

        public override void copy_clipboard () {
            if (buffer.has_selection) get_clipboard ().set_text (selected_text ());
        }

        public signal void quote_selected (string text);

        /** Пункт «Ответить с цитатой» в контекстном меню, пока есть выделение. */
        public void enable_quote () {
            var a = new SimpleAction ("quote", null);
            a.set_enabled (false);
            a.activate.connect (() => quote_selected (selected_text ()));
            buffer.notify["has-selection"].connect (() => a.set_enabled (buffer.has_selection));
            var g = new SimpleActionGroup ();
            g.add_action (a);
            insert_action_group ("rich", g);
            var item = new MenuItem (_("_Reply with Quote"), "rich.quote");
            item.set_attribute_value ("hidden-when", new Variant.string ("action-disabled"));
            var m = new Menu ();
            m.append_item (item);
            extra_menu = m;
        }

        private string? href_of (int offset) {
            foreach (var l in links) if (offset >= l.start && offset < l.end) return l.href;
            return null;
        }

        private Link? link_at (double x, double y) {
            int bx, by;
            window_to_buffer_coords (Gtk.TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            Gtk.TextIter it;
            if (!get_iter_at_location (out it, bx, by)) return null;
            int o = it.get_offset ();
            foreach (var l in links) if (o >= l.start && o < l.end) return l;
            return null;
        }

        private string? href_at (double x, double y) { return link_at (x, y)?.href; }

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
