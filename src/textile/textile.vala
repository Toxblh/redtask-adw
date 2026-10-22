/*
 * Разбор Textile Redmine: блоки (заголовки, цитаты с вложенностью, списки, таблицы, код, картинки, collapse)
 * и инлайн-разметка → Pango markup со ссылками (issue:, note:, user:, http…). Чистая логика без GTK —
 * покрыта tests/test_textile.vala. Порт ui/components/RichText.kt из Android-клиента.
 * Все смещения — в байтах UTF-8 (как у GLib.Regex и string.substring в Vala).
 */
namespace Textile {

    // «Буква» — явным юникод-классом. Каждый маркер — только на границе слова: URL, почта, пути, «2 + 3», «C++» как есть.
    private const string W = """\p{L}\p{N}_""";
    private const string LOGIN = """[a-zA-Z0-9_](?:[a-zA-Z0-9_.\-]*[a-zA-Z0-9_])?""";

    // Предел вложенности цитат и collapse вместе: глубже разбор не идёт — каждый уровень это рекурсия и вложенный виджет.
    public const int MAX_QUOTE_DEPTH = 8;
    private const int MAX_CELLS = 64;
    // ponytail: строка длиннее — без инлайн-разметки, текстом как написана (лог или base64 одной строкой)
    private const int MAX_INLINE = 20000;

    private Regex? _issue; private Regex? _mention; private Regex? _userref; private Regex? _tlink; private Regex? _url;
    private Regex? _bold; private Regex? _italic; private Regex? _strike; private Regex? _under; private Regex? _cite;
    private Regex? _sup; private Regex? _sub; private Regex? _code; private Regex? _macro; private Regex? _img;
    private Regex? _hr; private Regex? _heading; private Regex? _list; private Regex? _bq; private Regex? _collapse;
    private Regex? _toc; private Regex? _entity; private Regex? _preopen; private Regex? _codetag; private Regex? _cellmod;
    private Regex? _cellspan;

    private Regex re (string p, RegexCompileFlags f = 0) {
        try {
            return new Regex (p, f | RegexCompileFlags.OPTIMIZE);
        } catch (RegexError e) {
            error ("textile regex %s: %s", p, e.message);
        }
    }

    private void init () {
        if (_issue != null) return;
        // #123, #123#note-5, #123-5 (группы 1 и 2); #note-5 — комментарий текущей задачи (группа 3)
        _issue = re ("(?<![" + W + "/#])#(?:(\\d+)(?:(?:#note)?-(\\d+))?|note-(\\d+))(?![" + W + "])");
        // логин не кончается на «.» / «-»: «@ivanov.» в конце фразы — это ivanov
        _mention = re ("(?<![" + W + "@])@(" + LOGIN + ")");
        _userref = re ("(?<![" + W + "/#:.@-])user(?:#(\\d+)|:(" + LOGIN + "))(?![" + W + "])");
        _tlink = re ("\"([^\"\\n]+)\":((?:https?|ftp)://[^\\s<>\"']+|mailto:[^\\s<>\"']+|/[^\\s<>\"']*)");
        _url = re ("https?://[^\\s<>\"']+");
        _bold = re ("(?<![" + W + "*])(\\*\\*?)(?![\\s*])([^*\\n]+?)(?<!\\s)\\1(?![" + W + "*])");
        _italic = re ("(?<![" + W + "])_(?!\\s)([^_\\n]+?)(?<!\\s)_(?![" + W + "])");
        // дефис внутри зачёркнутого — только между буквами: «well-known», «--force», «2020-01-01» как есть
        _strike = re ("(?<![" + W + "-])-(?![\\s-])([^-\\n]+?(?:(?<=[" + W + "])-(?=[" + W + "])[^-\\n]+?){0,20}?)(?<!\\s)-(?![" + W + "-])");
        _under = re ("(?<![" + W + "+])\\+(?![\\s+])([^+\\n]+?)(?<!\\s)\\+(?![" + W + "+])");
        _cite = re ("(?<![" + W + "?])\\?\\?(?![\\s?])([^?\\n]+?)(?<!\\s)\\?\\?(?![" + W + "?])");
        _sup = re ("(?<![" + W + "^])\\^([\\p{L}\\p{N}+\\-]+)\\^(?![" + W + "^])");
        _sub = re ("(?<![" + W + "~])~([\\p{L}\\p{N}+\\-]+)~(?![" + W + "~])");
        // @код@ — тоже на границе слова: «a@b.com or c@d.com» — не код. Длина <code> ограничена (иначе квадрат)
        _code = re ("(?<![" + W + "@])@(?!\\s)([^@\\n]+?)(?<!\\s)@(?![" + W + "@])|`([^`\\n]+?)`|<code>(.{1,1000}?)</code>");
        _macro = re ("\\{\\{([<>]?[a-zA-Z_]\\w*)(?:\\([^)\\n]{0,300}\\))?\\}\\}");
        // !file.png!, !>file.png!, !file.png(alt)!, !{width: Npx}file.png!, !http(s)://…! — имя обязано кончаться расширением картинки
        _img = re ("""(?<![\p{L}\p{N}_!])![<>=]?(?:\{[^}!]*\}|\([^)!]*\))?\.?\s?(https?://[^\s!()]+|[^\s!()/]+\.(?:png|jpe?g|jpe|gif|bmp|webp))\s?(?:\([^)!]*\))?!(?::https?://\S+)?(?![\p{L}\p{N}_])""", RegexCompileFlags.CASELESS);
        _hr = re ("^\\s*(?:-{3,}|\\*{3,})\\s*$");
        // точка обязательна: «h264 codec» — не заголовок
        _heading = re ("^h([1-6])(?:\\([^)]*\\)|\\{[^}]*\\}|[<>=]){0,8}\\.\\s+(.*)");
        // *, **, #, ## — вложенность числом маркеров; «- », «1.» в Redmine Textile не списки
        _list = re ("^(\\s*)([*#]+)\\s+(.*)");
        _bq = re ("^bq\\.\\s+(.*)");
        _collapse = re ("^\\{\\{collapse(?:\\(([^)]*)\\))?\\s*$");
        _toc = re ("^\\s*\\{\\{[<>]?toc\\}\\}\\s*$");
        _entity = re ("&(amp|lt|gt|quot|apos|nbsp|#\\d{1,7}|#[xX][0-9a-fA-F]{1,6});");
        _preopen = re ("<pre(?:\\s[^<>]*)?>");
        _codetag = re ("</?code(?:\\s[^<>]*)?>");
        _cellmod = re ("""^((?:_|\\\d+|/\d+|[<>=^~]|\{[^}]*\}){1,8})\.(?:\s+|$)(.*)""", RegexCompileFlags.DOTALL);
        _cellspan = re ("""\\(\d+)""");
    }

    public Regex mention_re () { init (); return _mention; }
    public Regex image_re () { init (); return _img; }

    // ---- «инертные» символы: содержимое <notextile> и раскодированные сущности уводим в Private Use Area ----

    public string inert (string s) {
        var sb = new StringBuilder.sized (s.length);
        int i = 0;
        unichar c;
        while (s.get_next_char (ref i, out c)) {
            if (c >= '!' && c <= '~' && !c.isalnum ()) sb.append_unichar (c + 0xE000);
            else sb.append_unichar (c);
        }
        return sb.str;
    }

    public string unraw (string s) {
        // U+E021..U+E07E в UTF-8 начинаются с EE 80 / EE 81
        if (!s.contains ("\xee\x80") && !s.contains ("\xee\x81")) return s;
        var sb = new StringBuilder.sized (s.length);
        int i = 0;
        unichar c;
        while (s.get_next_char (ref i, out c)) {
            if (c >= 0xE021 && c <= 0xE07E) sb.append_unichar (c - 0xE000);
            else sb.append_unichar (c);
        }
        return sb.str;
    }

    /** &amp; &lt; &gt; &quot; &apos; &nbsp; &#NNN; &#xHH; → символ, инертный для разметки. Неизвестное — как есть. */
    public string decode_entities (string s) {
        if (!s.contains ("&")) return s;
        init ();
        try {
            return _entity.replace_eval (s, -1, 0, 0, (mi, res) => {
                var e = mi.fetch (1);
                string? v = null;
                switch (e) {
                    case "amp": v = "&"; break;
                    case "lt": v = "<"; break;
                    case "gt": v = ">"; break;
                    case "quot": v = "\""; break;
                    case "apos": v = "'"; break;
                    case "nbsp": v = "\u00A0"; break;
                    default:
                        uint64 cp = 0;
                        bool ok = (e[1] == 'x' || e[1] == 'X')
                            ? uint64.try_parse (e.substring (2), out cp, null, 16)
                            : uint64.try_parse (e.substring (1), out cp);
                        if (ok && cp >= 32 && cp <= 0x10FFFF && ((unichar) cp).validate ()) v = ((unichar) cp).to_string ();
                        break;
                }
                res.append (v != null ? inert (v) : mi.fetch (0));
                return false;
            });
        } catch (RegexError err) {
            return s;
        }
    }

    // ---- строки-блоки ----

    public enum Kind { PLAIN, CODE, RULE, QUOTE, COLLAPSE, HEADING, ITEM, ROW, IMAGE }

    public class Cell : Object {
        public string text;
        public bool header;
        public int span;
        public Cell (string text, bool header = false, int span = 1) { this.text = text; this.header = header; this.span = span; }
    }

    public class Line : Object {
        public Kind kind;
        public string text = "";
        public int level = 0;     // заголовок: 1..6; пункт списка: глубина
        public int number = 0;    // пункт: номер (0 — маркированный)
        public GenericArray<Line>? children = null; // цитата, collapse
        public GenericArray<Cell>? cells = null;    // строка таблицы

        public Line (Kind k, string text = "") { kind = k; this.text = text; }
        public bool is_blank () { return kind == Kind.PLAIN && text.strip () == ""; }
    }

    /** ponytail: режем по «|» в лоб — «|» внутри @кода@ разобьёт ячейку; токенизатор, если встретится */
    public GenericArray<Cell> parse_cells (string line) {
        init ();
        var t = line.strip ();
        if (t.has_prefix ("|")) t = t.substring (1);
        if (t.has_suffix ("|")) t = t.substring (0, t.length - 1);
        var res = new GenericArray<Cell> ();
        foreach (var raw in t.split ("|", MAX_CELLS)) {
            var r = raw.strip ();
            MatchInfo mi;
            if (!_cellmod.match (r, 0, out mi)) { res.add (new Cell (r)); continue; }
            var mods = mi.fetch (1);
            int span = 1;
            MatchInfo sm;
            if (_cellspan.match (mods, 0, out sm)) span = int.parse (sm.fetch (1)).clamp (1, 20);
            res.add (new Cell (mi.fetch (2).strip (), mods.has_prefix ("_") || mods.has_suffix ("_"), span));
        }
        return res;
    }

    /** <notextile>…</notextile> → инертный текст. Руками, а не регуляркой: та на одних открывающих тегах квадратична. */
    private string notextile (string s) {
        const string OPEN = "<notextile>";
        const string CLOSE = "</notextile>";
        var from = s.index_of (OPEN);
        if (from < 0) return s;
        var sb = new StringBuilder.sized (s.length);
        int cur = 0;
        while (from >= 0) {
            var end = s.index_of (CLOSE, from + OPEN.length);
            if (end < 0) break;
            sb.append (s.substring (cur, from - cur));
            sb.append (inert (s.substring (from + OPEN.length, end - from - OPEN.length)));
            cur = end + CLOSE.length;
            from = s.index_of (OPEN, cur);
        }
        sb.append (s.substring (cur));
        return sb.str;
    }

    public GenericArray<Line> parse (string src) {
        init ();
        return parse_block (notextile (src.replace ("\r\n", "\n")).split ("\n"), 0);
    }

    private class Parser {
        public GenericArray<Line> res = new GenericArray<Line> ();
        public int depth;
        public int counters[8];
        public bool fence = false;
        public bool pre = false;

        public Line block (string line) {
            if (_hr.match (line)) return new Line (Kind.RULE);
            if (line.chug ().has_prefix ("|")) {
                var l = new Line (Kind.ROW);
                l.cells = parse_cells (line);
                return l;
            }
            MatchInfo mi;
            if (_heading.match (line, 0, out mi)) {
                for (int k = 0; k < 8; k++) counters[k] = 0;
                var l = new Line (Kind.HEADING, mi.fetch (2).strip ());
                l.level = int.parse (mi.fetch (1));
                return l;
            }
            // сервер — Textile: «# пункт» это нумерованный список, а не markdown-заголовок
            if (_list.match (line, 0, out mi)) {
                var indent = mi.fetch (1);
                var marker = mi.fetch (2);
                var d = int.min (marker.length - 1 + indent.length / 2, 7);
                var l = new Line (Kind.ITEM, mi.fetch (3));
                l.level = d;
                // маркированный пункт обрывает нумерацию своего уровня
                if (marker[marker.length - 1] == '#') { counters[d] = counters[d] + 1; l.number = counters[d]; } else counters[d] = 0;
                for (int k = d + 1; k < 8; k++) counters[k] = 0;
                return l;
            }
            return new Line (Kind.PLAIN, line);
        }

        public void text (string raw) {
            if (raw.strip () == "") { // пустая строка завершает список — нумерация начнётся заново
                for (int k = 0; k < 8; k++) counters[k] = 0;
                res.add (new Line (Kind.PLAIN, ""));
                return;
            }
            var line = decode_entities (raw);
            MatchInfo mi;
            if (!_img.match (line, 0, out mi)) {
                res.add (block (line));
                return;
            }
            string stripped;
            try { stripped = _img.replace (line, -1, 0, ""); } catch (RegexError e) { stripped = line; }
            var b = block (stripped);
            if (b.kind != Kind.PLAIN) { // пункт списка / строка таблицы: картинки сразу под ней
                res.add (b);
                do { res.add (new Line (Kind.IMAGE, mi.fetch (1))); } while (next (mi));
                return;
            }
            // обычный текст режем по макросам — картинка встаёт ровно там, где написана
            int cur = 0;
            do {
                int s, e;
                mi.fetch_pos (0, out s, out e);
                var before = line.substring (cur, s - cur).strip ();
                if (before != "") res.add (new Line (Kind.PLAIN, before));
                res.add (new Line (Kind.IMAGE, mi.fetch (1)));
                cur = e;
            } while (next (mi));
            var rest = line.substring (cur).strip ();
            if (rest != "") res.add (new Line (Kind.PLAIN, rest));
        }

        public void pre_line (string line) {
            var end = line.index_of ("</pre>");
            string code = end < 0 ? line : line.substring (0, end);
            try { code = _codetag.replace (code, -1, 0, ""); } catch (RegexError e) {}
            // <pre><code class="ruby"> — тег подсветки не показываем; пустые строки кода сохраняем
            if (code != "" || line == "") res.add (new Line (Kind.CODE, code));
            if (end >= 0) {
                pre = false;
                var rest = line.substring (end + 6);
                if (rest.strip () != "") text (rest);
            }
        }
    }

    private bool next (MatchInfo mi) {
        try { return mi.next (); } catch (RegexError e) { return false; }
    }

    private GenericArray<Line> nested (string[] q, int depth) {
        if (depth < MAX_QUOTE_DEPTH) return parse_block (q, depth + 1);
        var res = new GenericArray<Line> ();
        foreach (var s in q) res.add (new Line (Kind.PLAIN, decode_entities (s)));
        return res;
    }

    private Line wrap (Kind k, GenericArray<Line> children, string title = "") {
        var l = new Line (k, title);
        l.children = children;
        return l;
    }

    private GenericArray<Line> parse_block (string[] src, int depth) {
        var p = new Parser ();
        p.depth = depth;
        bool no_close = false; // «}}» ниже нет: не ищем заново на каждой строке «{{collapse»
        // один уровень «>» и один пробел за ним: «> > x» и «>> x» → «> x» — вложенность достанется рекурсии
        int i = 0;
        while (i < src.length) {
            var line = src[i++];
            var t = line.chug ();
            if (p.fence) {
                // закрывающий забор проверяем раньше открывающего
                if (t.has_prefix ("```")) p.fence = false; else p.res.add (new Line (Kind.CODE, line));
            } else if (p.pre) {
                p.pre_line (line);
            } else if (t.has_prefix ("```")) {
                var rest = t.substring (3); // ```lang — язык не показываем
                if (rest.contains ("```")) p.res.add (new Line (Kind.CODE, rest.substring (0, rest.index_of ("```"))));
                else p.fence = true;
            } else if (line.has_prefix (">")) {
                // цитата: все «>»-строки подряд — один блок
                string[] q = { unquote (line, depth) };
                while (i < src.length && src[i].has_prefix (">")) q += unquote (src[i++], depth);
                for (int k = 0; k < 8; k++) p.counters[k] = 0;
                p.res.add (wrap (Kind.QUOTE, nested (q, depth)));
            } else {
                MatchInfo bq;
                MatchInfo? col = null;
                bool is_bq = _bq.match (line, 0, out bq);
                bool is_col = !no_close && _collapse.match (line, 0, out col);
                int close = -1;
                if (is_col) {
                    for (int k = i; k < src.length; k++) if (src[k].has_prefix ("}}")) { close = k; break; }
                    if (close < 0) no_close = true;
                }
                if (is_bq) { // «bq.» действует на абзац — до пустой строки
                    string[] q = { bq.fetch (1) };
                    while (i < src.length && src[i].strip () != "") q += src[i++];
                    for (int k = 0; k < 8; k++) p.counters[k] = 0;
                    p.res.add (wrap (Kind.QUOTE, nested (q, depth)));
                } else if (close >= 0) {
                    var title = (col.fetch (1) ?? "").split (",")[0].strip (); // «показать, скрыть» — первая подпись
                    for (int k = 0; k < 8; k++) p.counters[k] = 0;
                    p.res.add (wrap (Kind.COLLAPSE, nested (src[i:close], depth), unraw (decode_entities (title))));
                    var rest = src[close].substring (2).strip ();
                    i = close + 1;
                    if (rest != "") p.text (rest);
                } else if (_toc.match (line)) {
                    // оглавление не рисуем
                } else {
                    MatchInfo om;
                    if (!_preopen.match (line, 0, out om)) p.text (line);
                    else {
                        int s, e;
                        om.fetch_pos (0, out s, out e);
                        var before = line.substring (0, s);
                        if (before.strip () != "") p.text (before); // текст до <pre> — не код
                        p.pre = true;
                        var after = line.substring (e);
                        if (after != "") p.pre_line (after);
                    }
                }
            }
        }
        return p.res;
    }

    private string unquote (string s, int depth) {
        if (depth >= MAX_QUOTE_DEPTH) {
            int k = 0;
            while (k < s.length && (s[k] == '>' || s[k] == ' ')) k++;
            return s.substring (k);
        }
        var r = s.substring (1);
        return r.has_prefix (" ") ? r.substring (1) : r;
    }

    // ---- группировка в блоки для виджетов ----

    public enum BlockKind { TEXT, TABLE, IMAGE, CODE, LIST, QUOTE, COLLAPSE, RULE }

    public class Block : Object {
        public BlockKind kind;
        public GenericArray<Line> lines = new GenericArray<Line> ();
        /** Перед блоком в исходнике была пустая строка — абзацный отступ. */
        public bool gap;
        public Block (BlockKind k, bool gap) { kind = k; this.gap = gap; }
    }

    public BlockKind kind_of (Line l) {
        switch (l.kind) {
            case Kind.PLAIN: case Kind.HEADING: return BlockKind.TEXT;
            case Kind.ROW: return BlockKind.TABLE;
            case Kind.CODE: return BlockKind.CODE;
            case Kind.ITEM: return BlockKind.LIST;
            case Kind.IMAGE: return BlockKind.IMAGE;
            case Kind.QUOTE: return BlockKind.QUOTE;
            case Kind.COLLAPSE: return BlockKind.COLLAPSE;
            default: return BlockKind.RULE;
        }
    }

    /**
     * Абзац текста, список, таблица, код — подряд идущие строки одного вида; картинка, цитата, collapse, линия —
     * каждая сама по себе. Пустые строки рвут абзац и становятся gap следующего блока.
     */
    public GenericArray<Block> group (GenericArray<Line> lines) {
        var res = new GenericArray<Block> ();
        Block? cur = null;
        bool gap = false;
        foreach (var l in lines) {
            if (l.is_blank ()) {
                gap = res.length > 0;
                cur = null;
                continue;
            }
            var k = kind_of (l);
            bool run = k == BlockKind.TEXT || k == BlockKind.TABLE || k == BlockKind.CODE || k == BlockKind.LIST;
            if (cur != null && run && cur.kind == k) cur.lines.add (l);
            else {
                cur = new Block (k, gap);
                cur.lines.add (l);
                res.add (cur);
                if (!run) cur = null;
            }
            gap = false;
        }
        return res;
    }

    // ---- инлайн → Pango markup ----

    /** login (в нижнем регистре) → «id|Имя» для @упоминаний; неизвестные остаются текстом. */
    public delegate string? MentionLookup (string login);

    /** Логины из @упоминаний и user:login (нижний регистр, без повторов, не больше 20) — кого спрашивать у сервера. */
    public GenericArray<string> mention_logins (string text) {
        init ();
        var res = new GenericArray<string> ();
        var seen = new GenericSet<string> (str_hash, str_equal);
        foreach (var line in text.split ("\n")) {
            var codes = ranges (_code, line);
            MatchInfo? mi = null;
            if (_mention.match (line, 0, out mi)) do {
                int s, e;
                mi.fetch_pos (0, out s, out e);
                bool in_code = false;
                for (int k = 0; k < codes.length; k += 2) if (s >= codes[k] && s < codes[k + 1]) in_code = true;
                var l = mi.fetch (1).down ();
                if (!in_code && !seen.contains (l)) { seen.add (l); res.add (l); }
            } while (next (mi) && res.length < 20);
            if (_userref.match (line, 0, out mi)) do {
                var l = (mi.fetch (2) ?? "").down ();
                if (l != "" && !seen.contains (l)) { seen.add (l); res.add (l); }
            } while (next (mi) && res.length < 20);
            if (res.length >= 20) break;
        }
        return res;
    }

    private int[] ranges (Regex r, string s) {
        int[] res = {};
        MatchInfo mi;
        if (r.match (s, 0, out mi)) do {
            int a, b;
            mi.fetch_pos (0, out a, out b);
            res += a; res += b;
        } while (next (mi));
        return res;
    }

    /** Хвостовая пунктуация — не часть ссылки; «)» срезаем, только если она непарная. */
    public string trim_url (string u) {
        var s = u;
        while (s.length > 0) {
            var c = s[s.length - 1];
            if (".,;:!?".index_of_char (c) >= 0) { s = s.substring (0, s.length - 1); continue; }
            if (c == ')' && count (s, ')') > count (s, '(')) { s = s.substring (0, s.length - 1); continue; }
            break;
        }
        return s;
    }

    private int count (string s, char c) {
        int n = 0;
        for (int i = 0; i < s.length; i++) if (s[i] == c) n++;
        return n;
    }

    private class Span {
        public int start;
        public int end; // исключительно
        public string kind;
        public string text;
        public string payload;
        public string tag; // для стиля: «b», «i»…
        public Span (int s, int e, string kind, string text, string payload = "", string tag = "") {
            start = s; end = e; this.kind = kind; this.text = text; this.payload = payload; this.tag = tag;
        }
    }

    private string esc (string s) { return Markup.escape_text (unraw (s)); }

    /**
     * Строка → Pango markup. «Атомы» (упоминание, ссылка, код, #задача, макрос) внутри не разбираются; стили — обёртки,
     * их содержимое разбирается этой же функцией. Побеждает начавшийся левее; при равенстве — атом.
     */
    public string inline_markup (string line, MentionLookup? lookup = null, int depth = 0) {
        init ();
        if (line.length > MAX_INLINE || depth > 6) return esc (line);
        var spans = new GenericArray<Span> ();
        MatchInfo? mi = null;
        int s, e;
        if (lookup != null && _mention.match (line, 0, out mi)) do {
            var hit = lookup (mi.fetch (1).down ());
            if (hit != null) {
                mi.fetch_pos (0, out s, out e);
                var bar = hit.index_of ("|");
                spans.add (new Span (s, e, "mention", hit.substring (bar + 1), hit.substring (0, bar)));
            }
        } while (next (mi));
        if (_userref.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            var id = mi.fetch (1) ?? "";
            var login = mi.fetch (2) ?? "";
            string? hit = (lookup != null && login != "") ? lookup (login.down ()) : null;
            if (hit != null) {
                var bar = hit.index_of ("|");
                spans.add (new Span (s, e, "mention", hit.substring (bar + 1), hit.substring (0, bar)));
            } else if (id != "") {
                spans.add (new Span (s, e, "person", mi.fetch (0), id)); // имени не знаем — ссылка как написана
            }
        } while (next (mi));
        if (_tlink.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            var raw = mi.fetch (2);
            var u = trim_url (raw);
            if (u != "") spans.add (new Span (s, e - (raw.length - u.length), "url", mi.fetch (1), u));
        } while (next (mi));
        if (_code.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            bool hit = false;
            foreach (var x in spans) if (x.start < e && s < x.end) hit = true;
            if (!hit) {
                string body = "";
                for (int g = 1; g <= 3; g++) { var v = mi.fetch (g); if (v != null && v != "") { body = v; break; } }
                spans.add (new Span (s, e, "code", body));
            }
        } while (next (mi));
        if (_url.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            var u = trim_url (mi.fetch (0));
            if (free (spans, s)) spans.add (new Span (s, s + u.length, "url", u, u));
        } while (next (mi));
        if (_issue.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            if (free (spans, s)) {
                var id = mi.fetch (1) ?? "";
                var note = mi.fetch (2) ?? "";
                var bare = mi.fetch (3) ?? "";
                if (bare != "") spans.add (new Span (s, e, "note", mi.fetch (0), bare));
                else spans.add (new Span (s, e, "issue", mi.fetch (0), id + (note != "" ? ":" + note : "")));
            }
        } while (next (mi));
        if (_macro.match (line, 0, out mi)) do {
            mi.fetch_pos (0, out s, out e);
            if (free (spans, s)) spans.add (new Span (s, e, "macro", mi.fetch (1)));
        } while (next (mi));
        add_style (spans, _bold, line, 2, "b");
        add_style (spans, _italic, line, 1, "i");
        add_style (spans, _strike, line, 1, "s");
        add_style (spans, _under, line, 1, "u");
        add_style (spans, _cite, line, 1, "i");
        add_style (spans, _sup, line, 1, "sup");
        add_style (spans, _sub, line, 1, "sub");
        // сортировка устойчивая: при равном начале атом (добавлен раньше) идёт раньше стиля
        spans.sort_values_with_data ((a, b) => a.start - b.start);

        var sb = new StringBuilder ();
        int cursor = 0;
        foreach (var sp in spans) {
            if (sp.start < cursor) continue;
            sb.append (esc (line.substring (cursor, sp.start - cursor)));
            switch (sp.kind) {
                case "code":
                    sb.append ("<span font_family=\"monospace\" bgcolor=\"#808080\" bgalpha=\"18%\">" + esc (sp.text) + "</span>");
                    break;
                case "url":
                    sb.append ("<a href=\"" + Markup.escape_text (unraw (sp.payload)) + "\">" + esc (sp.text) + "</a>");
                    break;
                case "issue":
                    sb.append ("<a href=\"issue:" + sp.payload + "\">" + esc (sp.text) + "</a>");
                    break;
                case "note":
                    sb.append ("<a href=\"note:" + sp.payload + "\">" + esc (sp.text) + "</a>");
                    break;
                case "person":
                    sb.append ("<a href=\"user:" + sp.payload + "\">" + esc (sp.text) + "</a>");
                    break;
                case "mention":
                    sb.append ("<a href=\"user:" + sp.payload + "\">@" + esc (sp.text) + "</a>");
                    break;
                case "macro": // оглавление не рисуем; прочие макросы — приглушённой подписью
                    if (!sp.text.has_suffix ("toc")) sb.append ("<span size=\"small\" alpha=\"60%\">" + esc (sp.text) + "</span>");
                    break;
                default:
                    sb.append ("<" + sp.tag + ">" + inline_markup (sp.text, lookup, depth + 1) + "</" + sp.tag + ">");
                    break;
            }
            cursor = sp.end;
        }
        if (cursor < line.length) sb.append (esc (line.substring (cursor)));
        return sb.str;
    }

    private bool free (GenericArray<Span> spans, int at) {
        foreach (var x in spans) if (at >= x.start && at < x.end) return false;
        return true;
    }

    private void add_style (GenericArray<Span> spans, Regex r, string line, int group, string tag) {
        MatchInfo mi;
        if (r.match (line, 0, out mi)) do {
            int s, e;
            mi.fetch_pos (0, out s, out e);
            spans.add (new Span (s, e, "style", mi.fetch (group), "", tag));
        } while (next (mi));
    }

    /** Текстовый блок (абзац и заголовки) → markup; строки через перевод строки. */
    public string text_markup (GenericArray<Line> lines, MentionLookup? lookup = null) {
        var sb = new StringBuilder ();
        for (int i = 0; i < lines.length; i++) {
            var l = lines[i];
            if (l.kind == Kind.HEADING) {
                var size = l.level == 1 ? "x-large" : (l.level == 2 ? "large" : "medium");
                sb.append ("<span size=\"" + size + "\" weight=\"bold\">" + inline_markup (l.text, lookup) + "</span>");
            } else {
                sb.append (inline_markup (l.text, lookup));
            }
            if (i < lines.length - 1) sb.append_c ('\n');
        }
        return sb.str;
    }

    // ---- превью без разметки (уведомления) ----

    /** «!img.png!» → «img.png», «bq. текст» → «текст», «*жирный*» → «жирный»; до 140 символов. */
    public string preview (string note) {
        init ();
        string s = note;
        try {
            s = new Regex ("</?(?:pre|code|notextile)[^>]*>").replace (s, -1, 0, "");
            s = new Regex ("""!(?:\{[^}]*\})?([^!\s]+)!""").replace (s, -1, 0, "\\1");
            s = new Regex ("\"([^\"\\n]+)\":\\S+").replace (s, -1, 0, "\\1");
            s = new Regex ("""^\s*(?:(?:bq|p|pre|h[1-6])\.\s+|>+\s?|[*#]+\s+)""", RegexCompileFlags.MULTILINE).replace (s, -1, 0, "");
            s = new Regex ("""(?<![\p{L}\p{N}])([*_@])(\S(?:[^\n]*?\S)?)\1(?![\p{L}\p{N}])""").replace (s, -1, 0, "\\2");
            s = new Regex ("\\s+").replace (s, -1, 0, " ");
        } catch (RegexError e) {}
        s = s.strip ();
        if (s.char_count () > 140) s = s.substring (0, s.index_of_nth_char (140));
        return s;
    }
}
