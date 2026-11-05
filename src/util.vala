/* Даты, часы и прочие мелочи без зависимостей от GTK — покрыты tests/. */
namespace Redmine {

    public const int64 HOUR_MS = 3600 * 1000;
    public const int64 DAY_MS = 24 * HOUR_MS;

    /** ISO-время Redmine (Z или смещение; дата без времени — полночь UTC) → мс эпохи; не разобрали — 0. */
    public int64 parse_iso_ms (string? s) {
        if (s == null || s == "") return 0;
        var dt = new DateTime.from_iso8601 (s, new TimeZone.utc ());
        if (dt == null && s.length >= 10) dt = new DateTime.from_iso8601 (s.substring (0, 10) + "T00:00:00Z", null);
        return dt == null ? 0 : dt.to_unix () * 1000 + dt.get_microsecond () / 1000;
    }

    /** Redmine отклоняет updated_on с дробными секундами (422) — только целые секунды и Z. */
    public string iso_seconds (int64 ms) {
        var dt = new DateTime.from_unix_utc (ms / 1000);
        return dt.format ("%Y-%m-%dT%H:%M:%SZ");
    }

    public int64 now_ms () { return get_real_time () / 1000; }

    public string format_hours (double h) {
        if (h == Math.floor (h)) return "%d".printf ((int) h);
        return "%.1f".printf (h).replace (",", ".");
    }

    public DateTime? local_dt (string? iso) {
        var ms = parse_iso_ms (iso);
        if (ms == 0) return null;
        return new DateTime.from_unix_local (ms / 1000);
    }

    /** «12 мар. 2026» — дата без времени (due_date и т. п.) по локали. */
    public string format_date (string? iso) {
        if (iso == null || iso.length < 10) return iso ?? "";
        var dt = new DateTime.from_iso8601 (iso.substring (0, 10) + "T00:00:00", new TimeZone.local ());
        return dt == null ? iso : dt.format ("%-d %b %Y").strip ();
    }

    /** «22 окт» — дата в текущем году без года и без точки сокращения (formatDateShort на Android), иначе format_date. */
    public string format_date_short (string? iso, DateTime? today = null) {
        var t = today ?? new DateTime.now_local ();
        if (iso == null || iso.length < 10 || iso.substring (0, 4) != t.format ("%Y")) return format_date (iso);
        var dt = new DateTime.from_iso8601 (iso.substring (0, 10) + "T00:00:00", new TimeZone.local ());
        if (dt == null) return iso;
        var r = dt.format ("%-d %b").strip ();
        return r.has_suffix (".") ? r.substring (0, r.length - 1) : r;
    }

    public string format_datetime (string? iso) {
        var dt = local_dt (iso);
        return dt == null ? (iso ?? "") : dt.format ("%-d %b %Y, %H:%M").strip ();
    }

    /** «сейчас», «5 мин», «3 ч», «2 д», иначе дата. */
    public string format_relative (string? iso, int64 now = 0) {
        var ms = parse_iso_ms (iso);
        if (ms == 0) return iso ?? "";
        if (now == 0) now = now_ms ();
        var minutes = (now - ms) / 60000;
        if (minutes < 1) return _("now");
        if (minutes < 60) return _("%d min").printf ((int) minutes);
        if (minutes < 60 * 24) return _("%d h").printf ((int) (minutes / 60));
        if (minutes < 60 * 24 * 14) return _("%d d").printf ((int) (minutes / (60 * 24)));
        return new DateTime.from_unix_local (ms / 1000).format ("%-d %b %Y").strip ();
    }

    /** Дата YYYY-MM-DD в прошлом относительно сегодня (по местному времени). */
    public bool is_overdue (string? due, DateTime? today = null) {
        if (due == null || due.length < 10) return false;
        var t = today ?? new DateTime.now_local ();
        return due.substring (0, 10) < t.format ("%Y-%m-%d");
    }

    /** До срока: «сегодня» или «5 д» (просрочено — с минусом), как dueDelta на Android; null — дата не разобралась. */
    public string? due_delta (string? due, DateTime? today = null) {
        if (due == null || due.length < 10) return null;
        var d = new DateTime.from_iso8601 (due.substring (0, 10) + "T00:00:00Z", null);
        var t = today ?? new DateTime.now_local ();
        var t0 = new DateTime.from_iso8601 (t.format ("%Y-%m-%d") + "T00:00:00Z", null);
        if (d == null || t0 == null) return null;
        var days = (int) (d.difference (t0) / TimeSpan.DAY);
        return days == 0 ? _("today") : _("%d d").printf (days);
    }

    public string today_str () { return new DateTime.now_local ().format ("%Y-%m-%d"); }

    /** Разбор часов «1,5» / «1.5» / «1:30» → часы; не число — -1. */
    public double parse_hours (string s) {
        var t = s.strip ().replace (",", ".");
        if (t.contains (":")) {
            var p = t.split (":");
            int h = 0, m = 0;
            if (p.length == 2 && int.try_parse (p[0], out h) && int.try_parse (p[1], out m) && m >= 0 && m < 60) return h + m / 60.0;
            return -1;
        }
        double d;
        if (!double.try_parse (t, out d) || d <= 0) return -1;
        return d;
    }

    public string human_size (int64 bytes) { return format_size ((uint64) bytes); }

    /**
     * Цитата для ответа (набор quote_reply): «Автор писал(а) в #note-N:» для комментария, «Автор писал(а):» для
     * описания (note = 0); строки с «> », пустая — «>». Пустой (одни пробелы) текст — null. lang — «ru» или «en».
     */
    public string? quote_reply (string author, int note, string text, string lang) {
        var t = text.strip ();
        if (t == "") return null;
        var ru = lang.has_prefix ("ru");
        var sb = new StringBuilder ();
        if (note > 0) sb.append ("%s %s #note-%d:\n".printf (author, ru ? "писал(а) в" : "wrote in", note));
        else sb.append ("%s %s:\n".printf (author, ru ? "писал(а)" : "wrote"));
        foreach (var l in t.split ("\n")) sb.append (l.strip () == "" ? ">\n" : "> " + l + "\n");
        sb.append ("\n");
        return sb.str;
    }

    /** Язык интерфейса для текстов, которые уходят на сервер (шапка цитаты): «ru» или «en». */
    public string ui_lang () {
        return Intl.get_language_names ()[0].has_prefix ("ru") ? "ru" : "en";
    }

    /** Ответ WAF вместо Redmine: просили JSON, пришёл HTML с 200 и без заголовка Rails. */
    public bool waf_challenge (string? accept, uint code, string? content_type, string? request_id) {
        return accept == "application/json" && code == 200 && content_type != null
            && content_type.contains ("html") && request_id == null;
    }

    /** Можно ли отдавать ключ по этому адресу: только хост сервера и без понижения https → http. */
    public bool key_allowed (Uri base_uri, Uri target) {
        return target.get_host () == base_uri.get_host ()
            && (target.get_scheme () == "https" || base_uri.get_scheme () != "https");
    }


    /**
     * Звезда плагина favourites на HTML-странице задачи: 1 — в избранном (ссылка data-method="delete"),
     * 0 — нет (data-method="post"), -1 — ссылки нет: на сайте не вошли (или плагина нет).
     */
    public int fav_link_state (string html, int id) {
        var i = html.index_of ("issue-%d-favourite".printf (id));
        if (i < 0) return -1;
        var end = html.index_of (">", i);
        var tag = end < 0 ? html.substring (i) : html.substring (i, end - i);
        if (tag.contains ("data-method=\"delete\"")) return 1;
        if (tag.contains ("data-method=\"post\"")) return 0;
        return -1;
    }

    /** CSRF-токен Rails из <meta name="csrf-token">; null — его нет. */
    public string? csrf_token (string html) {
        MatchInfo m;
        if (/<meta name="csrf-token" content="([^"]+)"/.match (html, 0, out m)) return m.fetch (1);
        return null;
    }

    /** Миграция: локальные избранные, которых нет на сервере, без повторов, в прежнем порядке. */
    public int[] fav_to_migrate (int[] local, GenericSet<int> server) {
        var seen = new GenericSet<int> (direct_hash, direct_equal);
        int[] res = {};
        foreach (var id in local) if (id > 0 && !server.contains (id) && !seen.contains (id)) { seen.add (id); res += id; }
        return res;
    }

    /** Откуда миниатюра в строке вложения (spec 4.1): "server" — картинки и PDF, "embedded" — ODF/OOXML из скачанного файла, иначе "none". */
    public string thumbnail_source (string filename, string content_type) {
        var n = filename.down ();
        var ext = n.contains (".") ? n.substring (n.last_index_of (".") + 1) : "";
        if (content_type.has_prefix ("image/") || content_type == "application/pdf"
            || ext in new string[] { "png", "jpg", "jpeg", "jpe", "gif", "bmp", "webp", "pdf" }) return "server";
        if (ext in new string[] { "odt", "ods", "odp", "odg", "docx", "xlsx", "pptx" }) return "embedded";
        return "none";
    }

    uint32 le (uint8[] d, size_t at, int n) {
        uint32 v = 0;
        for (int k = n - 1; k >= 0; k--) v = (v << 8) | d[at + k];
        return v;
    }

    /** Запись миниатюры в zip: имя, смещение локального заголовка в файле, размеры и метод сжатия. */
    public class ZipEntry : Object {
        public string name;
        public int64 local_offset;
        public uint32 compressed_size;
        public uint32 size;
        public uint32 method;
    }

    /**
     * Запись миниатюры по хвосту файла размера size (Range: bytes=-N, spec 4.1, набор zip_tail): EOCD,
     * центральный каталог целиком в хвосте; ODF — Thumbnails/thumbnail.png, OOXML — docProps/thumbnail.jpeg|jpg|png.
     */
    public ZipEntry? zip_tail_entry (int64 size, Bytes tail) {
        unowned uint8[] d = tail.get_data ();
        size_t len = d.length;
        int64 base_off = size - (int64) len;
        if (len < 22 || base_off < 0) return null;
        // конец центрального каталога: с конца, комментарий до 64 КБ
        size_t eocd = 0;
        bool found = false;
        for (size_t at = len - 22; ; at--) {
            if (le (d, at, 4) == 0x06054b50) { eocd = at; found = true; break; }
            if (at == 0 || len - at > 22 + 65535) break;
        }
        if (!found) return null;
        var count = le (d, eocd + 10, 2);
        var cd = (int64) le (d, eocd + 16, 4) - base_off;
        if (cd < 0) return null;
        size_t at = (size_t) cd;
        string[] want = { "Thumbnails/thumbnail.png", "docProps/thumbnail.jpeg", "docProps/thumbnail.jpg", "docProps/thumbnail.png" };
        int best = want.length;
        ZipEntry? res = null;
        for (uint k = 0; k < count; k++) {
            if (at + 46 > len || le (d, at, 4) != 0x02014b50) return null;
            var nlen = le (d, at + 28, 2);
            if (at + 46 + nlen > len) return null;
            for (int w = 0; w < best; w++) if (nlen == want[w].length && Memory.cmp (&d[at + 46], want[w], nlen) == 0) {
                best = w;
                res = new ZipEntry () {
                    name = want[w], method = le (d, at + 10, 2), compressed_size = le (d, at + 20, 4),
                    size = le (d, at + 24, 4), local_offset = le (d, at + 42, 4),
                };
            }
            at += 46 + nlen + le (d, at + 30, 2) + le (d, at + 32, 2);
        }
        return res;
    }

    /** Данные записи по байтам от её локального заголовка: stored или deflate; не сходится — null. */
    public Bytes? zip_entry_data (ZipEntry e, Bytes local) {
        unowned uint8[] d = local.get_data ();
        size_t len = d.length;
        if (len < 30 || le (d, 0, 4) != 0x04034b50) return null;
        size_t start = 30 + le (d, 26, 2) + le (d, 28, 2);
        if (start + e.compressed_size > len) return null;
        var raw = new Bytes (d[start : start + e.compressed_size]);
        if (e.method == 0) return raw;
        if (e.method != 8) return null;
        try {
            var conv = new ConverterInputStream (new MemoryInputStream.from_bytes (raw), new ZlibDecompressor (ZlibCompressorFormat.RAW));
            var out = new MemoryOutputStream.resizable ();
            out.splice (conv, OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET);
            var res = out.steal_as_bytes ();
            return res.get_size () == e.size ? res : null;
        } catch (Error err) {
            return null;
        }
    }

    /** Встроенная миниатюра ODF/OOXML (spec 4.1) из целого файла; нет или не zip — null. */
    public Bytes? embedded_thumbnail (Bytes data) {
        var e = zip_tail_entry (data.get_size (), data);
        if (e == null || e.local_offset >= data.get_size ()) return null;
        return zip_entry_data (e, data.slice ((size_t) e.local_offset, data.get_size ()));
    }
}

namespace Redmine {
    /** Заголовок search.json «Трекер #N (Статус): тема» → «Трекер #N: тема» и статус; не тот формат — как есть, status = null. */
    public string split_search_status (string title, out string? status) {
        status = null;
        MatchInfo mi;
        if (!/^(.*?#\d+) \((.+?)\): (.*)$/s.match (title, 0, out mi)) return title;
        status = mi.fetch (2);
        return mi.fetch (1) + ": " + mi.fetch (3);
    }

    /** Сводка ссылки #N «C|Трекер: тема (Статус)» → подсказка без статуса, статус и закрытость; без «(…)» в конце — null. */
    public string? brief_status (string brief, out string text, out bool closed) {
        closed = brief.has_prefix ("C|");
        text = brief.length > 1 && brief[1] == '|' ? brief.substring (2) : brief;
        var p = text.last_index_of (" (");
        if (p < 0 || !text.has_suffix (")")) return null;
        var st = text.substring (p + 2, text.length - p - 3);
        text = text.substring (0, p);
        return st;
    }
}
