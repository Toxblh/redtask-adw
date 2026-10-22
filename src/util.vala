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

    /** Цитата для ответа: «Автор wrote:» и строки с «> ». */
    public string quote_reply (string author, string text, string wrote) {
        var sb = new StringBuilder ();
        sb.append ("%s %s:\n".printf (author, wrote));
        foreach (var l in text.strip ().split ("\n")) sb.append (l.strip () == "" ? ">\n" : "> " + l + "\n");
        sb.append ("\n");
        return sb.str;
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

}
