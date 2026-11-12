/*
 * Демо-режим (spec 6): выдуманный Redmine в памяти по адресу DemoServer.BASE. Подставляется транспортом —
 * Client.raw/get_range отвечают отсюда, API и экраны о демо не знают; в сеть не уходит ни один запрос
 * (чужой хост — тоже 404 отсюда). Правки живут до перезапуска процесса. Язык данных — язык интерфейса.
 * Данные и маршруты — 1:1 с Android (DemoServer.kt) и iOS (DemoServer.swift).
 */
namespace Redmine {

    public class DemoResp {
        public uint code;
        public string type;
        public Bytes body;
        public string? location = null;
        public DemoResp (uint code, string type, Bytes body) { this.code = code; this.type = type; this.body = body; }
    }

    public class DemoServer : Object {
        public const string BASE = "https://redmine.example.com";
        public const string KEY = "demo";
        public const int ME = 1;
        private const string HOST = "redmine.example.com";

        private static DemoDB? db = null;

        public static bool is_demo (string base_url) {
            var b = base_url;
            while (b.has_suffix ("/")) b = b.substring (0, b.length - 1);
            return b == BASE;
        }

        /** Язык данных — язык интерфейса: ru, если перевод выбран по русской локали. */
        public static bool ui_ru () {
            var names = Intl.get_language_names ();
            return names.length > 0 && names[0].has_prefix ("ru");
        }

        /** Свежие данные (вход в демо, тесты). */
        public static void reset (bool ru) { db = new DemoDB (ru); }

        private static DemoDB get_db () {
            if (db == null) db = new DemoDB (ui_ru ());
            return db;
        }

        public static void set_favorite (int id, bool on) {
            if (on) get_db ().favorites.add (id); else get_db ().favorites.remove (id);
        }

        /** Код, Content-Type и тело ответа на запрос; url — полный адрес. */
        public static DemoResp handle (string method, string url, Bytes? body) {
            Uri u;
            try {
                u = Uri.parse (url, UriFlags.ENCODED_QUERY);
            } catch (Error e) {
                return DemoDB.not_found ();
            }
            if (u.get_host () != HOST) return DemoDB.not_found ();
            return get_db ().handle (method, u, body);
        }
    }

    /** Логин для русских имён: «Алексей Морозов» → «amorozov». */
    public string demo_translit (string first, string last) {
        const string[] FROM = { "а", "б", "в", "г", "д", "е", "ё", "ж", "з", "и", "й", "к", "л", "м", "н", "о", "п", "р", "с", "т",
                                "у", "ф", "х", "ц", "ч", "ш", "щ", "ы", "э", "ю", "я" };
        const string[] TO = { "a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t",
                              "u", "f", "kh", "ts", "ch", "sh", "sch", "y", "e", "yu", "ya" };
        var f = first.down ();
        var s = (f.length > 0 ? f.substring (0, f.index_of_nth_char (1)) : "") + last.down ();
        var sb = new StringBuilder ();
        int i = 0;
        unichar c;
        while (s.get_next_char (ref i, out c)) {
            var ch = c.to_string ();
            for (int k = 0; k < FROM.length; k++) if (FROM[k] == ch) { sb.append (TO[k]); break; }
        }
        return sb.str;
    }

    private class DemoUpload {
        public string filename;
        public string? type;
        public Bytes data;
        public DemoUpload (string filename, string? type, Bytes data) { this.filename = filename; this.type = type; this.data = data; }
    }

    private class DemoWiki {
        public string title;
        public string? parent;
        public string text;
        public DemoWiki (string title, string? parent, string text) { this.title = title; this.parent = parent; this.text = text; }
    }

    private class DemoDB {
        const string JSON_TYPE = "application/json; charset=utf-8";

        bool ru;
        int me = DemoServer.ME;
        GenericArray<Json.Object> people = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> projects = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> statuses = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> priorities = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> trackers = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> activities = new GenericArray<Json.Object> ();
        /** Вехи по проектам; all_versions — все подряд. */
        HashTable<int, GenericArray<Json.Object>> versions = new HashTable<int, GenericArray<Json.Object>> (direct_hash, direct_equal);
        GenericArray<Json.Object> all_versions = new GenericArray<Json.Object> ();
        HashTable<int, GenericArray<DemoWiki>> wiki = new HashTable<int, GenericArray<DemoWiki>> (direct_hash, direct_equal);
        HashTable<int, GenericArray<Json.Object>> project_files = new HashTable<int, GenericArray<Json.Object>> (direct_hash, direct_equal);
        GenericArray<Json.Object> issues = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> relations = new GenericArray<Json.Object> ();
        GenericArray<Json.Object> time = new GenericArray<Json.Object> ();
        public GenericSet<int> favorites = new GenericSet<int> (direct_hash, direct_equal);
        HashTable<int, DemoUpload> files = new HashTable<int, DemoUpload> (direct_hash, direct_equal);
        HashTable<string, DemoUpload> uploads = new HashTable<string, DemoUpload> (str_hash, str_equal);
        int next_id = 2000;
        /** Сохранённые запросы (spec 17): {id, name, is_public, project_id} и их параметры формы. */
        GenericArray<Json.Object> queries = new GenericArray<Json.Object> ();
        HashTable<int, Query> query_params = new HashTable<int, Query> (direct_hash, direct_equal);
        int next_query = 10;
        const string CSRF = "demo-csrf-token";

        public DemoDB (bool ru) {
            this.ru = ru;
            fill ();
            seed_queries ();
        }

        int new_id () { return ++next_id; }
        string t (string en, string ru_) { return ru ? ru_ : en; }

        // ---------- JSON ----------

        static Json.Node node_of (Json.Object o) { var n = new Json.Node (Json.NodeType.OBJECT); n.set_object (o); return n; }

        static Json.Array arr (GenericArray<Json.Object> list) {
            var a = new Json.Array ();
            foreach (var o in list) a.add_object_element (clone (o));
            return a;
        }

        static Json.Object clone (Json.Object o) {
            return json_parse (json_to_string (node_of (o))).get_object ();
        }

        static Json.Object nm (int id, string name) {
            var o = new Json.Object ();
            o.set_int_member ("id", id);
            o.set_string_member ("name", name);
            return o;
        }

        static Json.Object ref_id (int id) { var o = new Json.Object (); o.set_int_member ("id", id); return o; }

        Json.Object? person (int id) {
            foreach (var p in people) if (jint (p, "id") == id) return p;
            return null;
        }

        string short_name (int id) {
            var p = person (id);
            return p == null ? "#%d".printf (id) : (jstr (p, "firstname") + " " + jstr (p, "lastname")).strip ();
        }

        string login_of (int id) { return jstr (person (id), "login"); }

        Json.Object user (int id) {
            var p = person (id);
            var o = new Json.Object ();
            o.set_int_member ("id", id);
            o.set_string_member ("login", jstr (p, "login"));
            o.set_string_member ("firstname", jstr (p, "firstname"));
            o.set_string_member ("lastname", jstr (p, "lastname"));
            o.set_string_member ("mail", jstr (p, "email"));
            return o;
        }

        /** «@логин» для упоминания. */
        string at (int id) { return "@" + login_of (id); }
        Json.Object named (int id) { return nm (id, short_name (id)); }

        Json.Object status (int id) {
            foreach (var s in statuses) if (jint (s, "id") == id) return clone (s);
            return clone (statuses[0]);
        }

        Json.Object by_id (GenericArray<Json.Object> list, int id) {
            foreach (var x in list) if (jint (x, "id") == id) return nm (id, jstr (x, "name"));
            return nm (id, "");
        }

        Json.Object priority (int id) { return by_id (priorities, id); }
        Json.Object tracker (int id) { return by_id (trackers, id); }
        Json.Object project_ref (int id) { return by_id (projects, id); }

        Json.Object? version_ref (int id) {
            foreach (var v in all_versions) if (jint (v, "id") == id) return nm (id, jstr (v, "name"));
            return null;
        }

        Json.Object role (int person) {
            switch (person) {
                case 2: case 8: return nm (1, t ("Manager", "Менеджер"));
                case 4: return nm (4, t ("Designer", "Дизайнер"));
                case 5: return nm (5, t ("Tester", "Тестировщик"));
                case 6: return nm (6, t ("Support", "Поддержка"));
                default: return nm (3, t ("Developer", "Разработчик"));
            }
        }

        Json.Object? issue (int id) {
            foreach (var i in issues) if (jint (i, "id") == id) return i;
            return null;
        }

        // ---------- ответы ----------

        public static DemoResp not_found () { return raw_text (404, "{\"errors\":[\"Not found\"]}"); }
        static DemoResp forbidden () { return raw_text (403, "{\"errors\":[]}"); }
        static DemoResp no_content () { return new DemoResp (204, JSON_TYPE, new Bytes (new uint8[0])); }
        static DemoResp raw_text (uint code, string text) { return new DemoResp (code, JSON_TYPE, new Bytes (text.data)); }
        static DemoResp raw (Json.Object o, uint code = 200) { return raw_text (code, json_to_string (node_of (o))); }

        static DemoResp wrap (string key, Json.Object v, uint code = 200) {
            var o = new Json.Object ();
            o.set_object_member (key, v);
            return raw (o, code);
        }

        /** Конверт {"key": [..][, "total_count": N]}. */
        static DemoResp ok (string key, Json.Array v, int total = -1) {
            var o = new Json.Object ();
            o.set_array_member (key, v);
            if (total >= 0) o.set_int_member ("total_count", total);
            return raw (o);
        }

        DemoResp unprocessable (string msg) {
            var o = new Json.Object ();
            var a = new Json.Array ();
            a.add_string_element (msg);
            o.set_array_member ("errors", a);
            return raw (o, 422);
        }

        // поля тела запроса: как в Android — число и строкой, пустая строка — null
        static int? fint (Json.Object f, string k) {
            if (!f.has_member (k)) return null;
            var n = f.get_member (k);
            if (n.get_node_type () != Json.NodeType.VALUE) return null;
            if (n.get_value_type () == typeof (int64)) return (int) n.get_int ();
            if (n.get_value_type () == typeof (double)) return (int) n.get_double ();
            int v = 0;
            if (n.get_value_type () == typeof (string) && int.try_parse (n.get_string (), out v)) return v;
            return null;
        }

        static string? fstr (Json.Object f, string k) {
            if (!f.has_member (k)) return null;
            var n = f.get_member (k);
            return n.get_node_type () == Json.NodeType.VALUE && n.get_value_type () == typeof (string) ? n.get_string () : null;
        }

        static double? fdouble (Json.Object f, string k) {
            if (!f.has_member (k)) return null;
            var n = f.get_member (k);
            if (n.get_node_type () != Json.NodeType.VALUE) return null;
            if (n.get_value_type () == typeof (int64)) return (double) n.get_int ();
            if (n.get_value_type () == typeof (double)) return n.get_double ();
            double v = 0;
            if (n.get_value_type () == typeof (string) && double.try_parse (n.get_string (), out v)) return v;
            return null;
        }

        static bool? fbool (Json.Object f, string k) {
            if (!f.has_member (k)) return null;
            var n = f.get_member (k);
            if (n.get_node_type () != Json.NodeType.VALUE) return null;
            if (n.get_value_type () == typeof (bool)) return n.get_boolean ();
            if (n.get_value_type () == typeof (string) && (n.get_string () == "true" || n.get_string () == "false")) return n.get_string () == "true";
            return null;
        }

        static Json.Object fobj (Json.Object f, string k) { return jobj (f, k) ?? new Json.Object (); }

        static int? num (string? s) {
            int v = 0;
            return s != null && int.try_parse (s, out v) ? (int?) v : null;
        }

        static string strip_json (string s) { return s.has_suffix (".json") ? s.substring (0, s.length - 5) : s; }

        // ---------- маршруты ----------

        public DemoResp handle (string method, Uri u, Bytes? body) {
            var q = new Query ();
            foreach (var kv in (u.get_query () ?? "").split ("&")) {
                if (kv == "") continue;
                var eq = kv.index_of ("=");
                var k = eq < 0 ? kv : kv.substring (0, eq);
                var v = eq < 0 ? "" : kv.substring (eq + 1);
                q.add (Uri.unescape_string (k.replace ("+", " ")) ?? k, Uri.unescape_string (v.replace ("+", " ")) ?? v);
            }
            string[] parts = {};
            foreach (var s in u.get_path ().split ("/")) if (s != "") parts += s;
            Json.Object f = new Json.Object ();
            if (body != null && body.get_size () > 0) {
                var n = json_parse (bytes_text (body));
                if (n != null && n.get_node_type () == Json.NodeType.OBJECT) f = n.get_object ();
            }
            var first = parts.length > 0 ? parts[0] : "";
            var p1 = parts.length > 1 ? parts[1] : null;
            var p2 = parts.length > 2 ? parts[2] : null;
            int? id = p1 != null ? num (strip_json (p1)) : null;
            bool json1 = p1 != null && p1.has_suffix (".json");

            switch (method + " " + first) {
                case "GET users":
                    if (p1 == "current.json") {
                        var o = user (me);
                        o.set_boolean_member ("admin", true);
                        o.set_array_member ("memberships", new Json.Array ());
                        return wrap ("user", o);
                    }
                    if (id != null && person (id) != null) return wrap ("user", user (id));
                    return not_found ();
                case "GET roles":
                    var r = nm (id ?? 0, "Developer");
                    r.set_array_member ("permissions", new Json.Array ());
                    return wrap ("role", r);
                case "GET issue_statuses.json": return ok ("issue_statuses", arr (statuses));
                case "GET trackers.json": return ok ("trackers", arr (trackers));
                case "GET enumerations":
                    if (parts[parts.length - 1] == "issue_priorities.json") return ok ("issue_priorities", arr (priorities));
                    return ok ("time_entry_activities", arr (activities));
                case "GET custom_fields.json": return forbidden ();
                case "GET projects.json": return ok ("projects", arr (projects), (int) projects.length);
                case "GET projects": return project (parts);
                case "GET versions":
                    foreach (var v in all_versions) if (jint (v, "id") == id) return wrap ("version", clone (v));
                    return not_found ();
                case "GET issues.json": return list (q);
                // HTML-страница задачи (веб-форма, избранное) — «нет»
                case "GET issues":
                    if (p1 == null) return html (catalog_html ());
                    var i = id != null && json1 ? issue (id) : null;
                    return i != null ? wrap ("issue", full (i)) : not_found ();
                case "PUT issues":
                    if (id == null || issue (id) == null) return not_found ();
                    update (id, fobj (f, "issue"));
                    return no_content ();
                case "POST issues.json": return wrap ("issue", full (create (fobj (f, "issue"))), 201);
                case "POST issues":
                    if (p2 == "watchers.json") {
                        var who = fint (f, "user_id");
                        var i = id != null ? issue (id) : null;
                        if (i != null && who != null) {
                            bool has = false;
                            foreach (var w in jarr (i, "watchers")) if (jint (w, "id") == who) has = true;
                            if (!has) append (i, "watchers", named (who));
                        }
                        return no_content ();
                    }
                    if (p2 == "relations.json") {
                        var rel = fobj (f, "relation");
                        var to = fint (rel, "issue_to_id");
                        if (id == null || to == null || issue (to) == null) return unprocessable (t ("Related issue not found", "Связанная задача не найдена"));
                        relations.add (relation (new_id (), id, to, fstr (rel, "relation_type") ?? "relates", fint (rel, "delay")));
                        return no_content ();
                    }
                    return not_found ();
                case "DELETE issues":
                    if (p2 == "watchers" && parts.length > 3) {
                        var who = num (strip_json (parts[3]));
                        var i = id != null ? issue (id) : null;
                        if (i != null) {
                            var keep = new GenericArray<Json.Object> ();
                            foreach (var w in jarr (i, "watchers")) if (jint (w, "id") != who) keep.add (w);
                            i.set_array_member ("watchers", arr (keep));
                        }
                    }
                    return no_content ();
                case "DELETE relations":
                    for (int k = (int) relations.length - 1; k >= 0; k--) if (jint (relations[k], "id") == id) relations.remove_index (k);
                    return no_content ();
                case "PUT journals":
                    var j = fobj (f, "journal");
                    edit_journal (id ?? 0, fstr (j, "notes") ?? "", fbool (j, "private_notes"));
                    return no_content ();
                case "GET time_entries.json":
                    var list = new GenericArray<Json.Object> ();
                    var iid = num (first_val (q, "issue_id"));
                    var from = first_val (q, "from");
                    foreach (var e in time) {
                        if (iid != null && jint (jobj (e, "issue"), "id") != iid) continue;
                        if (from != null && jstr (e, "spent_on") < from) continue;
                        list.add (e);
                    }
                    list.sort ((a, b) => -strcmp (jstr (a, "created_on"), jstr (b, "created_on")));
                    return ok ("time_entries", arr (page (list, q)), (int) list.length);
                case "POST time_entries.json":
                    var e = fobj (f, "time_entry");
                    var eid = fint (e, "issue_id");
                    var i = eid != null ? issue (eid) : null;
                    if (i == null) return unprocessable ("Issue is invalid");
                    time.add (entry (new_id (), i, me, fdouble (e, "hours") ?? 0.0, fint (e, "activity_id") ?? 8, fstr (e, "comments") ?? "", fstr (e, "spent_on") ?? day (0), 0));
                    recount_time (jint (i, "id"));
                    return raw_text (201, "{}");
                case "PUT time_entries":
                    var e = fobj (f, "time_entry");
                    Json.Object? te = null;
                    foreach (var x in time) if (jint (x, "id") == id) te = x;
                    if (te == null) return not_found ();
                    var h = fdouble (e, "hours");
                    if (h != null) te.set_double_member ("hours", h);
                    var a = fint (e, "activity_id");
                    if (a != null) te.set_object_member ("activity", by_id (activities, a));
                    var c = fstr (e, "comments");
                    if (c != null) te.set_string_member ("comments", c);
                    var so = fstr (e, "spent_on");
                    if (so != null) te.set_string_member ("spent_on", so);
                    recount_time (jint (jobj (te, "issue"), "id"));
                    return no_content ();
                case "DELETE time_entries":
                    int iid = 0;
                    for (int k = (int) time.length - 1; k >= 0; k--) if (jint (time[k], "id") == id) {
                        iid = jint (jobj (time[k], "issue"), "id");
                        time.remove_index (k);
                    }
                    if (iid != 0) recount_time (iid);
                    return no_content ();
                case "GET search.json":
                    var s = (first_val (q, "q") ?? "").down ();
                    var found = new GenericArray<Json.Object> ();
                    foreach (var i in issues)
                        if (s == "" || s in jstr (i, "subject").down () || s in jstr (i, "description").down ()) found.add (i);
                    found.sort ((a, b) => -strcmp (jstr (a, "updated_on"), jstr (b, "updated_on")));
                    var res = new Json.Array ();
                    foreach (var i in page (found, q)) {
                        var o = new Json.Object ();
                        var st = jobj (i, "status");
                        o.set_int_member ("id", jint (i, "id"));
                        o.set_string_member ("title", "%s #%d (%s): %s".printf (jstr (jobj (i, "tracker"), "name"), jint (i, "id"), jstr (st, "name"), jstr (i, "subject")));
                        o.set_string_member ("type", jbool (st, "is_closed") ? "issue-closed" : "issue");
                        o.set_string_member ("url", "%s/issues/%d".printf (DemoServer.BASE, jint (i, "id")));
                        var d = jstr (i, "description");
                        o.set_string_member ("description", d.char_count () > 200 ? d.substring (0, d.index_of_nth_char (200)) : d);
                        o.set_string_member ("datetime", jstr (i, "updated_on"));
                        res.add_object_element (o);
                    }
                    var resp = new Json.Object ();
                    resp.set_array_member ("results", res);
                    resp.set_int_member ("total_count", found.length);
                    return raw (resp);
                case "GET attachments":
                    var fid = num (p2);
                    var file = fid != null ? files[fid] : null;
                    if (parts.length > 3 && (p1 == "thumbnail" || p1 == "download") && file != null) {
                        if (p1 == "thumbnail" && !(file.type ?? "").has_prefix ("image/")) return not_found ();
                        return new DemoResp (200, file.type ?? "application/octet-stream", file.data);
                    }
                    foreach (var i in issues) foreach (var a in jarr (i, "attachments")) if (jint (a, "id") == id) return wrap ("attachment", clone (a));
                    foreach (var l in project_files.get_values ()) foreach (var a in l) if (jint (a, "id") == id) return wrap ("attachment", clone (a));
                    return not_found ();
                case "DELETE attachments":
                    foreach (var i in issues) {
                        var keep = new GenericArray<Json.Object> ();
                        foreach (var a in jarr (i, "attachments")) if (jint (a, "id") != id) keep.add (a);
                        i.set_array_member ("attachments", arr (keep));
                    }
                    return no_content ();
                case "POST uploads.json":
                    var token = "demo-%d".printf (new_id ());
                    uploads[token] = new DemoUpload (first_val (q, "filename") ?? "file", null, body ?? new Bytes (new uint8[0]));
                    return raw_text (201, "{\"upload\":{\"token\":\"%s\"}}".printf (token));
                case "GET people.json":
                    var s = (first_val (q, "search") ?? "").down ();
                    var found = new GenericArray<Json.Object> ();
                    foreach (var pp in people)
                        if (s == "" || jstr (pp, "firstname").down ().has_prefix (s) || jstr (pp, "lastname").down ().has_prefix (s) || jstr (pp, "login").down ().has_prefix (s))
                            found.add (pp);
                    var lim = num (first_val (q, "limit")) ?? 25;
                    var res = new GenericArray<Json.Object> ();
                    for (int k = 0; k < found.length && k < lim; k++) res.add (found[k]);
                    return ok ("people", arr (res));
                // HTML-страница /people/:id (аватар) — «нет»: экраны берут запасной путь (инициалы)
                case "GET queries.json":
                    var qa = new Json.Array ();
                    foreach (var x in page (queries, q)) qa.add_object_element (clone (x));
                    return ok ("queries", qa, (int) queries.length);
                case "GET queries":
                    // форма «новый запрос» и правка — токен CSRF
                    if (p1 == "new" || (id != null && p2 == "edit" && query_params[id] != null)) return html (form_html ());
                    return not_found ();
                case "POST queries": return save_query (null, id, body);
                case "POST projects":
                    if (parts.length == 3 && parts[2] == "queries") {
                        foreach (var x in projects) if (jint (x, "id").to_string () == parts[1] || jstr (x, "identifier") == parts[1]) return save_query (x, null, body);
                    }
                    return not_found ();
                case "GET roles.json":
                    var ra = new Json.Array ();
                    foreach (var pid in new int[] { 2, 3, 4, 5, 6 }) ra.add_object_element (role (pid));
                    return ok ("roles", ra);
                case "GET people":
                    if (json1 && id != null && person (id) != null) return wrap ("person", clone (person (id)));
                    return not_found ();
                // HTML-страницы (People, веб-форма, CSV, избранное, ZenEdit) — «нет»
                default:
                    return not_found ();
            }
        }

        static string bytes_text (Bytes b) {
            var copy = new uint8[b.get_size () + 1];
            Memory.copy (copy, b.get_data (), b.get_size ());
            copy[b.get_size ()] = 0;
            return (string) copy;
        }

        static string? first_val (Query q, string k) {
            for (int i = 0; i < q.keys.length; i++) if (q.keys[i] == k) return q.vals[i];
            return null;
        }

        static GenericArray<Json.Object> page (GenericArray<Json.Object> all, Query q) {
            var off = num (first_val (q, "offset")) ?? 0;
            var lim = num (first_val (q, "limit")) ?? 25;
            var res = new GenericArray<Json.Object> ();
            for (int k = off; k < all.length && k < off + lim; k++) res.add (all[k]);
            return res;
        }

        static void append (Json.Object o, string key, Json.Object item) {
            if (!o.has_member (key) || o.get_member (key).get_node_type () != Json.NodeType.ARRAY) o.set_array_member (key, new Json.Array ());
            o.get_array_member (key).add_object_element (item);
        }

        DemoResp project (string[] parts) {
            if (parts.length < 2) return not_found ();
            var key = strip_json (parts[1]);
            Json.Object? pr = null;
            foreach (var x in projects) if (jint (x, "id").to_string () == key || jstr (x, "identifier") == key) pr = x;
            if (pr == null) return not_found ();
            var pid = jint (pr, "id");
            switch (parts.length > 2 ? parts[2] : "") {
                case "versions.json": return ok ("versions", arr (versions[pid] ?? new GenericArray<Json.Object> ()));
                case "issue_categories.json": return ok ("issue_categories", new Json.Array ());
                case "memberships.json":
                    var a = new Json.Array ();
                    foreach (var p in people) {
                        var m = new Json.Object ();
                        var uid = jint (p, "id");
                        m.set_int_member ("id", uid);
                        m.set_object_member ("user", named (uid));
                        var roles = new Json.Array ();
                        roles.add_object_element (role (uid));
                        m.set_array_member ("roles", roles);
                        a.add_object_element (m);
                    }
                    return ok ("memberships", a, (int) people.length);
                case "files.json": return ok ("files", arr (project_files[pid] ?? new GenericArray<Json.Object> ()));
                case "wiki":
                    var pages = wiki[pid];
                    if (pages == null) return forbidden ();
                    var name = parts.length > 3 ? strip_json (parts[3]) : "";
                    if (name == "index") {
                        var a = new Json.Array ();
                        foreach (var w in pages) {
                            var o = new Json.Object ();
                            o.set_string_member ("title", w.title);
                            if (w.parent != null) {
                                var par = new Json.Object ();
                                par.set_string_member ("title", w.parent);
                                o.set_object_member ("parent", par);
                            }
                            o.set_int_member ("version", 1);
                            o.set_string_member ("updated_on", iso (600));
                            a.add_object_element (o);
                        }
                        return ok ("wiki_pages", a);
                    }
                    foreach (var w in pages) if (w.title == name) {
                        var o = new Json.Object ();
                        o.set_string_member ("title", w.title);
                        o.set_string_member ("text", w.text);
                        o.set_int_member ("version", 3);
                        o.set_object_member ("author", named (8));
                        o.set_string_member ("updated_on", iso (600));
                        return wrap ("wiki_page", o);
                    }
                    return not_found ();
                case "": return wrap ("project", clone (pr));
                case "issues": return html (catalog_html ());
                case "queries": return parts.length > 3 && parts[3] == "new" ? html (form_html ()) : not_found ();
                default: return not_found ();
            }
        }

        // ---------- фильтры и запросы (spec 17) ----------

        static DemoResp html (string text) { return new DemoResp (200, "text/html; charset=utf-8", new Bytes (text.data)); }

        static string form_html () {
            return "<html><head><meta name=\"csrf-token\" content=\"%s\" /></head><body><form id=\"query_form\"></form></body></html>".printf (CSRF);
        }

        Json.Object flt (string name, string type, GenericArray<Json.Object>? values = null, bool remote = false) {
            var o = new Json.Object ();
            o.set_string_member ("type", type);
            o.set_string_member ("name", name);
            if (remote) o.set_boolean_member ("remote", true);
            if (values != null) {
                var a = new Json.Array ();
                foreach (var v in values) {
                    var pair = new Json.Array ();
                    pair.add_string_element (jstr (v, "name"));
                    pair.add_string_element (jint (v, "id").to_string ());
                    a.add_array_element (pair);
                }
                o.set_array_member ("values", a);
            }
            return o;
        }

        static Json.Array strs (string csv) {
            var a = new Json.Array ();
            foreach (var x in csv.split (" ")) a.add_string_element (x);
            return a;
        }

        /** Скрипт страницы задач Redmine: availableFilters, operatorLabels, operatorByType. */
        string catalog_html () {
            var f = new Json.Object ();
            f.set_object_member ("status_id", flt (t ("Status", "Статус"), "list_status", null, true));
            f.set_object_member ("tracker_id", flt (t ("Tracker", "Трекер"), "list", trackers));
            f.set_object_member ("priority_id", flt (t ("Priority", "Приоритет"), "list", priorities));
            f.set_object_member ("assigned_to_id", flt (t ("Assignee", "Назначена"), "list_optional", null, true));
            f.set_object_member ("author_id", flt (t ("Author", "Автор"), "list", null, true));
            f.set_object_member ("watcher_id", flt (t ("Watcher", "Наблюдатель"), "list", null, true));
            f.set_object_member ("subject", flt (t ("Subject", "Тема"), "text"));
            f.set_object_member ("updated_on", flt (t ("Updated", "Обновлена"), "date_past"));
            f.set_object_member ("created_on", flt (t ("Created", "Создана"), "date_past"));
            f.set_object_member ("due_date", flt (t ("Due date", "Срок завершения"), "date"));
            var by = new Json.Object ();
            by.set_array_member ("list_status", strs ("o = ! c *"));
            by.set_array_member ("list", strs ("= !"));
            by.set_array_member ("list_optional", strs ("= ! !* *"));
            by.set_array_member ("text", strs ("~ !~ ^ $ !* *"));
            by.set_array_member ("date_past", strs (">t- <t- ><t- t- t ld w lw l2w m lm y >= <= >< !* *"));
            by.set_array_member ("date", strs ("<t+ >t+ ><t+ t+ nd t ld nw w lw l2w nm m lm y >t- <t- ><t- t- = >= <= >< !* *"));
            string[] ops = { "=", "!", "o", "c", "*", "!*", "~", "!~", "^", "$", ">t-", "<t-", "><t-", "t-", "t", "ld", "w", "lw", "l2w", "m", "lm", "y",
                             ">=", "<=", "><", "<t+", ">t+", "><t+", "t+", "nd", "nw", "nm" };
            string[] en = { "is", "is not", "open", "closed", "any", "none", "contains", "doesn't contain", "starts with", "ends with",
                            "less than days ago", "more than days ago", "in the past", "days ago", "today", "yesterday", "this week", "last week",
                            "last 2 weeks", "this month", "last month", "this year", ">=", "<=", "between", "in less than", "in more than",
                            "in the next", "in", "tomorrow", "next week", "next month" };
            string[] ru_ = { "соответствует", "не соответствует", "открыто", "закрыто", "все", "отсутствует", "содержит", "не содержит",
                             "начинается с", "заканчивается на", "менее чем дней(я) назад", "более чем дней(я) назад", "в прошлом", "дней(я) назад",
                             "сегодня", "вчера", "на этой неделе", "на прошлой неделе", "последние 2 недели", "в этом месяце", "в прошлом месяце",
                             "в этом году", ">=", "<=", "между", "менее чем через", "более чем через", "в следующие", "через", "завтра",
                             "на следующей неделе", "в следующем месяце" };
            var labels = new Json.Object ();
            for (int k = 0; k < ops.length; k++) labels.set_string_member (ops[k], ru ? ru_[k] : en[k]);
            return "<html><head><meta name=\"csrf-token\" content=\"%s\" /></head><body><script>\n//<![CDATA[\n".printf (CSRF)
                + "var availableFilters = " + json_to_string (node_of (f)) + ";\n"
                + "var operatorLabels = " + json_to_string (node_of (labels)) + ";\n"
                + "var operatorByType = " + json_to_string (node_of (by)) + ";\n//]]>\n</script></body></html>";
        }

        void seed_queries () {
            var a = new Query ().add ("f[]", "status_id").add ("op[status_id]", "o").add ("f[]", "tracker_id").add ("op[tracker_id]", "=").add ("v[tracker_id][]", "1");
            add_query (t ("Open bugs", "Открытые ошибки"), true, null, a);
            var b = new Query ().add ("f[]", "status_id").add ("op[status_id]", "o").add ("f[]", "priority_id").add ("op[priority_id]", "=")
                .add ("v[priority_id][]", "3").add ("v[priority_id][]", "4").add ("v[priority_id][]", "5").add ("sort", "priority:desc");
            add_query (t ("Urgent work", "Срочное"), false, null, b);
            var c = new Query ().add ("f[]", "status_id").add ("op[status_id]", "*").add ("f[]", "updated_on").add ("op[updated_on]", ">t-").add ("v[updated_on][]", "7");
            add_query (t ("Mobile: this week", "Мобильное: за неделю"), true, 1, c);
        }

        int add_query (string name, bool is_public, int? project_id, Query p, int id = 0) {
            if (id == 0) id = ++next_query;
            var o = new Json.Object ();
            o.set_int_member ("id", id);
            o.set_string_member ("name", name);
            o.set_boolean_member ("is_public", is_public);
            if (project_id != null) o.set_int_member ("project_id", project_id); else o.set_null_member ("project_id");
            for (int k = 0; k < (int) queries.length; k++) if (jint (queries[k], "id") == id) { queries[k] = o; query_params[id] = p; return id; }
            queries.add (o);
            query_params[id] = p;
            return id;
        }

        /** Веб-форма запроса: новый (project — или null), правка (_method=patch) и удаление (_method=delete) по id. */
        DemoResp save_query (Json.Object? project, int? id, Bytes? body) {
            var form = new Query ();
            foreach (var kv in (body != null ? bytes_text (body) : "").split ("&")) {
                if (kv == "") continue;
                var eq = kv.index_of ("=");
                var k = Uri.unescape_string ((eq < 0 ? kv : kv.substring (0, eq)).replace ("+", " ")) ?? "";
                form.add (k, eq < 0 ? "" : Uri.unescape_string (kv.substring (eq + 1).replace ("+", " ")) ?? "");
            }
            if (first_val (form, "authenticity_token") != CSRF) return new DemoResp (422, "text/html", new Bytes ("Invalid token".data));
            var method = first_val (form, "_method") ?? "post";
            if (id != null && query_params[id] == null) return not_found ();
            if (method == "delete") {
                for (int k = (int) queries.length - 1; k >= 0; k--) if (jint (queries[k], "id") == id) queries.remove_index (k);
                query_params.remove (id);
                return new DemoResp (302, "text/html", new Bytes (new uint8[0])) { location = DemoServer.BASE + "/issues" };
            }
            var name = (first_val (form, "query[name]") ?? "").strip ();
            string? invalid = name == "" ? t ("Name cannot be blank", "Название не может быть пустым")
                : (name.char_count () > 255 ? t ("Name is too long (maximum is 255 characters)", "Название слишком длинное (максимум 255 символов)") : null);
            if (invalid != null) return html ("<div id=\"errorExplanation\"><ul><li>%s</li></ul></div>".printf (invalid));
            var p = new Query ();
            var sort = new GenericArray<string> ();
            for (int k = 0; k < form.keys.length; k++) {
                var key = form.keys[k];
                if (key == "f[]" || key.has_prefix ("op[") || key.has_prefix ("v[")) p.add (key, form.vals[k]);
                if (key.has_prefix ("query[sort_criteria]")) {
                    if (k + 1 < form.keys.length && form.keys[k + 1] == key) { sort.add (form.vals[k] + ":" + form.vals[k + 1]); k++; }
                }
            }
            if (sort.length > 0) p.add ("sort", string.joinv (",", sort.data));
            int? pid = project != null && first_val (form, "query_is_for_all") != "1" ? (int?) jint (project, "id") : null;
            if (id != null && project == null) foreach (var x in queries) if (jint (x, "id") == id && !x.get_member ("project_id").is_null ())
                pid = first_val (form, "query_is_for_all") == "1" ? null : (int?) jint (x, "project_id");
            var nid = add_query (name, first_val (form, "query[visibility]") != "0", pid, p, id ?? 0);
            var where = project != null ? "/projects/" + jstr (project, "identifier") : "";
            return new DemoResp (302, "text/html", new Bytes (new uint8[0])) { location = DemoServer.BASE + where + "/issues?query_id=%d".printf (nid) };
        }

        // ---------- задачи ----------

        /** Задача с include: подзадачи, связи, разрешённые статусы. */
        Json.Object full (Json.Object i) {
            var o = clone (i);
            var id = jint (i, "id");
            var kids = new GenericArray<Json.Object> ();
            foreach (var x in issues) if (jint (jobj (x, "parent"), "id") == id) kids.add (x);
            kids.sort ((a, b) => jint (a, "id") - jint (b, "id"));
            var ch = new Json.Array ();
            foreach (var x in kids) {
                var c = ref_id (jint (x, "id"));
                c.set_object_member ("tracker", clone (jobj (x, "tracker")));
                c.set_string_member ("subject", jstr (x, "subject"));
                ch.add_object_element (c);
            }
            o.set_array_member ("children", ch);
            var rel = new GenericArray<Json.Object> ();
            foreach (var r in relations) if (jint (r, "issue_id") == id || jint (r, "issue_to_id") == id) rel.add (r);
            o.set_array_member ("relations", arr (rel));
            o.set_array_member ("allowed_statuses", arr (statuses));
            return o;
        }

        /** Как в списке Redmine: без журналов, вложений и наблюдателей. */
        static Json.Object brief (Json.Object i) {
            var o = clone (i);
            o.remove_member ("journals");
            o.remove_member ("attachments");
            o.remove_member ("watchers");
            return o;
        }

        DemoResp list (Query q0) {
            // запрос сервера (spec 17.4): его условия и сортировка — к параметрам
            var q = q0;
            var qid = num (first_val (q0, "query_id"));
            if (qid != null && query_params[qid] != null) {
                q = new Query ().add ("set_filter", "1");
                for (int k = 0; k < q0.keys.length; k++) q.add (q0.keys[k], q0.vals[k]);
                var sp = query_params[qid];
                for (int k = 0; k < sp.keys.length; k++) q.add (sp.keys[k], sp.vals[k]);
            }
            var all = new GenericArray<Json.Object> ();
            foreach (var i in issues) all.add (i);
            string[] fields = {};
            for (int k = 0; k < q.keys.length; k++) if (q.keys[k] == "f[]") fields += q.vals[k];
            // статус: короткая форма или фильтр
            string st;
            if ("status_id" in fields) {
                var op = first_val (q, "op[status_id]") ?? "";
                st = op == "o" ? "open" : (op == "c" ? "closed" : "*");
            } else st = first_val (q, "status_id") ?? (first_val (q, "set_filter") == "1" && fields.length > 0 && !("favourite_state" in fields) && !("project_id" in fields) ? "*" : "open");
            var sn = num (st);
            filter (all, (i) => {
                var closed = jbool (jobj (i, "status"), "is_closed");
                if (st == "open") return !closed;
                if (st == "closed") return closed;
                return sn == null || jint (jobj (i, "status"), "id") == sn;
            });
            var pid = first_val (q, "project_id");
            if (pid != null) foreach (var pr in projects) if (jint (pr, "id").to_string () == pid || jstr (pr, "identifier") == pid) {
                var n = jint (pr, "id");
                filter (all, (i) => jint (jobj (i, "project"), "id") == n);
            }
            var par = num (first_val (q, "parent_id"));
            if (par != null) filter (all, (i) => jint (jobj (i, "parent"), "id") == par);
            var fv = num (first_val (q, "fixed_version_id"));
            if (fv != null) filter (all, (i) => jint (jobj (i, "fixed_version"), "id") == fv);
            if (first_val (q, "assigned_to_id") == "me") filter (all, (i) => jint (jobj (i, "assigned_to"), "id") == me);
            if (first_val (q, "author_id") == "me") filter (all, (i) => jint (jobj (i, "author"), "id") == me);
            if (first_val (q, "watcher_id") == "me") filter (all, (i) => {
                foreach (var w in jarr (i, "watchers")) if (jint (w, "id") == me) return true;
                return false;
            });
            var subj = first_val (q, "subject");
            if (subj != null) {
                var n = (subj.has_prefix ("~") ? subj.substring (1) : subj).down ();
                filter (all, (i) => n in jstr (i, "subject").down ());
            }
            var ids = first_val (q, "issue_id");
            if (ids != null) {
                var set = new GenericSet<int> (direct_hash, direct_equal);
                foreach (var s in ids.split (",")) { var n = num (s.strip ()); if (n != null) set.add (n); }
                filter (all, (i) => set.contains (jint (i, "id")));
            }
            var upd = first_val (q, "updated_on");
            if (upd != null && upd.has_prefix (">=")) {
                var d = parse_iso_ms (upd.substring (2));
                if (d != 0) filter (all, (i) => parse_iso_ms (jstr (i, "updated_on")) >= d);
            }
            foreach (var fl in fields) {
                var v = (first_val (q, "v[%s][]".printf (fl)) ?? "");
                var op = first_val (q, "op[%s]".printf (fl)) ?? "";
                var vals = new GenericSet<string> (str_hash, str_equal);
                for (int k = 0; k < q.keys.length; k++) if (q.keys[k] == "v[%s][]".printf (fl)) vals.add (q.vals[k] == "me" ? me.to_string () : q.vals[k]);
                switch (fl) {
                    case "favourite_state": filter (all, (i) => favorites.contains (jint (i, "id"))); break;
                    case "status_id":
                    case "tracker_id":
                    case "priority_id":
                    case "assigned_to_id":
                    case "author_id":
                        var member = fl.substring (0, fl.length - 3);
                        if (fl == "status_id" && !(op == "=" || op == "!")) break;
                        filter (all, (i) => {
                            var ref_ = jobj (i, member);
                            switch (op) {
                                case "=": return ref_ != null && vals.contains (jint (ref_, "id").to_string ());
                                case "!": return ref_ == null || !vals.contains (jint (ref_, "id").to_string ());
                                case "!*": return ref_ == null;
                                case "*": return ref_ != null;
                                default: return true;
                            }
                        });
                        break;
                    case "watcher_id":
                        filter (all, (i) => {
                            foreach (var w in jarr (i, "watchers")) if (vals.contains (jint (w, "id").to_string ())) return op != "!";
                            return op == "!";
                        });
                        break;
                    case "subject": filter (all, (i) => (v.down () in jstr (i, "subject").down ()) == (op != "!~")); break;
                    case "notes":
                        filter (all, (i) => {
                            foreach (var j in jarr (i, "journals")) if (v.down () in jstr (j, "notes").down ()) return true;
                            return false;
                        });
                        break;
                    case "updated_on":
                    case "created_on":
                        var d = parse_iso_ms (v);
                        if (op == ">t-") d = now_ms () - (int64) (num (v) ?? 0) * DAY_MS;
                        else if (op == "t") d = parse_iso_ms (new DateTime.now_local ().format ("%Y-%m-%dT00:00:00%:z"));
                        else if (op == "w") d = now_ms () - 7 * DAY_MS;
                        else if (op == "m") d = now_ms () - 30 * DAY_MS;
                        var key = fl;
                        if (d != 0) filter (all, (i) => parse_iso_ms (jstr (i, key)) >= d);
                        break;
                    default: break; // project_id=mine — участник всех проектов
                }
            }
            var sort = (first_val (q, "sort") ?? "updated_on:desc").split (",")[0].split (":");
            bool desc = sort.length > 1 && sort[1] == "desc";
            var by = sort[0];
            all.sort_with_data ((a, b) => {
                int c;
                if (by == "id") c = jint (a, "id") - jint (b, "id");
                else if (by == "priority") c = jint (jobj (a, "priority"), "id") - jint (jobj (b, "priority"), "id");
                else {
                    var k = by == "created_on" ? "created_on" : "updated_on";
                    c = strcmp (jstr (a, k), jstr (b, k));
                    if (c == 0) c = jint (a, "id") - jint (b, "id");
                }
                return desc ? -c : c;
            });
            var res = new Json.Array ();
            foreach (var i in page (all, q)) res.add_object_element (brief (i));
            return ok ("issues", res, (int) all.length);
        }

        delegate bool Pred (Json.Object i);

        static void filter (GenericArray<Json.Object> list, Pred keep) {
            for (int k = (int) list.length - 1; k >= 0; k--) if (!keep (list[k])) list.remove_index (k);
        }

        static Json.Object detail (string property, string name, string? old_value, string? new_value) {
            var d = new Json.Object ();
            d.set_string_member ("property", property);
            d.set_string_member ("name", name);
            if (old_value != null) d.set_string_member ("old_value", old_value);
            if (new_value != null) d.set_string_member ("new_value", new_value);
            return d;
        }

        void update (int id, Json.Object f) {
            var i = issue (id);
            if (i == null) return;
            var details = new GenericArray<Json.Object> ();
            var st = fint (f, "status_id");
            if (st != null) {
                attr (details, "status_id", jint (jobj (i, "status"), "id").to_string (), st.to_string ());
                i.set_object_member ("status", status (st));
                if (jbool (jobj (i, "status"), "is_closed")) {
                    i.set_string_member ("closed_on", iso (0));
                    if (st != 6) i.set_int_member ("done_ratio", 100); // закрыта не отказом — сделана
                }
            }
            if (f.has_member ("assigned_to_id")) {
                var v = fint (f, "assigned_to_id");
                var old = jobj (i, "assigned_to");
                attr (details, "assigned_to_id", old != null ? jint (old, "id").to_string () : null, v != null ? v.to_string () : null);
                if (v != null) i.set_object_member ("assigned_to", named (v)); else i.remove_member ("assigned_to");
            }
            var pr = fint (f, "priority_id");
            if (pr != null) { attr (details, "priority_id", jint (jobj (i, "priority"), "id").to_string (), pr.to_string ()); i.set_object_member ("priority", priority (pr)); }
            var tr = fint (f, "tracker_id");
            if (tr != null) { attr (details, "tracker_id", jint (jobj (i, "tracker"), "id").to_string (), tr.to_string ()); i.set_object_member ("tracker", tracker (tr)); }
            var dr = fint (f, "done_ratio");
            if (dr != null) { attr (details, "done_ratio", jint (i, "done_ratio").to_string (), dr.to_string ()); i.set_int_member ("done_ratio", dr); }
            var su = fstr (f, "subject");
            if (su != null) { attr (details, "subject", jstr (i, "subject"), su); i.set_string_member ("subject", su); }
            var de = fstr (f, "description");
            if (de != null) {
                if (!jhas (i, "description") || jstr (i, "description") != de) details.add (detail ("attr", "description", null, null));
                i.set_string_member ("description", de);
            }
            var due = fstr (f, "due_date");
            if (due != null) {
                var old = jhas (i, "due_date") ? jstr (i, "due_date") : null;
                attr (details, "due_date", old, due != "" ? due : null);
                if (due != "") i.set_string_member ("due_date", due); else i.remove_member ("due_date");
            }
            var sd = fstr (f, "start_date");
            if (sd != null) { if (sd != "") i.set_string_member ("start_date", sd); else i.remove_member ("start_date"); }
            if (f.has_member ("estimated_hours")) {
                var e = fdouble (f, "estimated_hours");
                if (e != null) i.set_double_member ("estimated_hours", e); else i.remove_member ("estimated_hours");
            }
            var pv = fbool (f, "is_private");
            if (pv != null) i.set_boolean_member ("is_private", pv);
            if (f.has_member ("fixed_version_id")) {
                var v = fint (f, "fixed_version_id");
                var vr = v != null ? version_ref (v) : null;
                if (vr != null) i.set_object_member ("fixed_version", vr); else i.remove_member ("fixed_version");
            }
            if (f.has_member ("parent_issue_id")) {
                var v = fint (f, "parent_issue_id");
                if (v != null) i.set_object_member ("parent", ref_id (v)); else i.remove_member ("parent");
            }
            foreach (var up in jarr (f, "uploads")) {
                var tok = fstr (up, "token");
                var got = tok != null ? uploads[tok] : null;
                if (got == null) continue;
                uploads.remove (tok);
                var a = attach (new_id (), new DemoUpload (got.filename, fstr (up, "content_type") ?? got.type, got.data), me, 0, fstr (up, "description"));
                append (i, "attachments", a);
                details.add (detail ("attachment", jint (a, "id").to_string (), null, got.filename));
            }
            var notes = fstr (f, "notes") ?? "";
            if (notes != "" || details.length > 0) {
                var j = ref_id (new_id ());
                j.set_object_member ("user", named (me));
                j.set_string_member ("notes", notes);
                j.set_string_member ("created_on", iso (0));
                j.set_boolean_member ("private_notes", fbool (f, "private_notes") ?? false);
                j.set_array_member ("details", arr (details));
                append (i, "journals", j);
            }
            i.set_string_member ("updated_on", iso (0));
        }

        static void attr (GenericArray<Json.Object> details, string name, string? old_value, string? new_value) {
            if (old_value != new_value) details.add (detail ("attr", name, old_value, new_value));
        }

        Json.Object create (Json.Object f) {
            var id = new_id ();
            var i = ref_id (id);
            i.set_object_member ("project", project_ref (fint (f, "project_id") ?? 1));
            i.set_object_member ("tracker", tracker (fint (f, "tracker_id") ?? 3));
            i.set_object_member ("status", status (1));
            i.set_object_member ("priority", priority (fint (f, "priority_id") ?? 2));
            i.set_object_member ("author", named (me));
            i.set_string_member ("subject", fstr (f, "subject") ?? "");
            i.set_string_member ("created_on", iso (0));
            i.set_string_member ("updated_on", iso (0));
            issues.add (i);
            var g = clone (f);
            g.remove_member ("notes");
            update (id, g);
            // поля при создании — не журнал
            i.set_array_member ("journals", new Json.Array ());
            var w = new Json.Array ();
            w.add_object_element (named (me));
            i.set_array_member ("watchers", w);
            return i;
        }

        void edit_journal (int jid, string notes, bool? priv) {
            foreach (var i in issues) {
                var js = jarr (i, "journals");
                for (int n = 0; n < js.length; n++) {
                    var j = js[n];
                    if (jint (j, "id") != jid) continue;
                    if (notes == "" && jarr (j, "details").length == 0) {
                        js.remove_index (n);
                        i.set_array_member ("journals", arr (js));
                    } else {
                        j.set_string_member ("notes", notes);
                        j.set_string_member ("updated_on", iso (0));
                        if (priv != null) j.set_boolean_member ("private_notes", priv);
                    }
                    return;
                }
            }
        }

        void recount_time (int id) {
            double h = 0;
            foreach (var e in time) if (jint (jobj (e, "issue"), "id") == id) h += jdouble (e, "hours");
            var i = issue (id);
            if (i != null) { i.set_double_member ("spent_hours", h); i.set_double_member ("total_spent_hours", h); }
        }

        // ---------- помощники построения ----------

        static string iso (double minutes_ago) {
            return new DateTime.now_utc ().add_seconds (-minutes_ago * 60).format ("%Y-%m-%dT%H:%M:%SZ");
        }

        static string day (int offset) { return new DateTime.now_local ().add_days (offset).format ("%Y-%m-%d"); }

        Json.Object entry (int id, Json.Object issue, int user, double hours, int activity, string comments, string spent_on, double ago) {
            var e = ref_id (id);
            e.set_object_member ("user", named (user));
            e.set_object_member ("activity", by_id (activities, activity));
            e.set_double_member ("hours", hours);
            e.set_string_member ("comments", comments);
            e.set_string_member ("spent_on", spent_on);
            e.set_object_member ("project", clone (jobj (issue, "project")));
            e.set_object_member ("issue", ref_id (jint (issue, "id")));
            e.set_string_member ("created_on", iso (ago));
            return e;
        }

        Json.Object attach (int id, DemoUpload u, int by, double ago, string? description = null) {
            files[id] = u;
            var type = u.type ?? "application/octet-stream";
            var a = ref_id (id);
            a.set_string_member ("filename", u.filename);
            a.set_int_member ("filesize", (int64) u.data.get_size ());
            a.set_string_member ("content_type", type);
            a.set_string_member ("content_url", "%s/attachments/download/%d/%s".printf (DemoServer.BASE, id, u.filename));
            a.set_object_member ("author", named (by));
            a.set_string_member ("created_on", iso (ago));
            a.set_string_member ("description", description ?? "");
            if (type.has_prefix ("image/")) a.set_string_member ("thumbnail_url", "%s/attachments/thumbnail/%d".printf (DemoServer.BASE, id));
            return a;
        }

        static Json.Object relation (int id, int from, int to, string type, int? delay = null) {
            var r = ref_id (id);
            r.set_int_member ("issue_id", from);
            r.set_int_member ("issue_to_id", to);
            r.set_string_member ("relation_type", type);
            if (delay != null) r.set_int_member ("delay", delay);
            return r;
        }

        // ---------- наполнение ----------

        void person_add (int id, string fe, string le, string fr, string lr, string login, string job, string dept, int mgr, string? bio) {
            var lg = ru ? demo_translit (fr, lr) : login;
            var p = ref_id (id);
            p.set_string_member ("login", lg);
            p.set_string_member ("email", lg + "@example.com");
            p.set_string_member ("firstname", ru ? fr : fe);
            p.set_string_member ("lastname", ru ? lr : le);
            p.set_string_member ("job_title", job);
            p.set_object_member ("department", nm (100 + id, dept));
            if (mgr > 0) p.set_int_member ("manager_id", mgr);
            p.set_string_member ("personnel_number", (1040 + id * 7).to_string ());
            if (bio != null) p.set_string_member ("background", bio);
            people.add (p);
        }

        void version (int id, int project, string name, string st, int? due, string desc) {
            var v = nm (id, name);
            v.set_string_member ("status", st);
            if (due != null) { v.set_string_member ("due_date", day (due)); v.set_string_member ("effective_date", day (due)); }
            v.set_string_member ("description", desc);
            v.set_object_member ("project", project_ref (project));
            if (versions[project] == null) versions[project] = new GenericArray<Json.Object> ();
            versions[project].add (v);
            all_versions.add (v);
        }

        void fill () {
            // люди — выдуманные; аватары — инициалы (People-страниц нет)
            person_add (1, "Alex", "Morgan", "Алексей", "Морозов", "amorgan", t ("iOS Developer", "iOS-разработчик"), t ("Mobile Team", "Мобильная разработка"), 2,
                t ("Builds the iPhone and iPad apps. Loves small diffs and fast builds.", "Делает приложения для iPhone и iPad. Любит маленькие диффы и быстрые сборки."));
            person_add (2, "Maria", "Chen", "Мария", "Соколова", "mchen", t ("Head of Engineering", "Руководитель разработки"), t ("Engineering", "Разработка"), 0,
                t ("Leads product engineering across mobile, web and platform teams.", "Руководит разработкой продукта: мобильная команда, сайт и платформа."));
            person_add (3, "David", "Okafor", "Дмитрий", "Орлов", "dokafor", t ("Backend Developer", "Бэкенд-разработчик"), t ("Platform", "Платформа"), 2, null);
            person_add (4, "Sofia", "Rossi", "Анна", "Кузнецова", "srossi", t ("Product Designer", "Дизайнер интерфейсов"), t ("Design", "Дизайн"), 2, null);
            person_add (5, "Liam", "Novak", "Илья", "Волков", "lnovak", t ("QA Engineer", "Инженер по тестированию"), t ("Quality", "Качество"), 2, null);
            person_add (6, "Emma", "Larsen", "Екатерина", "Лебедева", "elarsen", t ("Support Lead", "Руководитель поддержки"), t ("Customer Support", "Поддержка клиентов"), 2, null);
            person_add (7, "Noah", "Fischer", "Никита", "Зайцев", "nfischer", t ("DevOps Engineer", "DevOps-инженер"), t ("Platform", "Платформа"), 3, null);
            person_add (8, "Olivia", "Park", "Ольга", "Белова", "opark", t ("Project Manager", "Менеджер проектов"), t ("Engineering", "Разработка"), 2, null);

            string[] st_names = { t ("New", "Новая"), t ("In Progress", "В работе"), t ("Feedback", "Обратная связь"),
                                  t ("Resolved", "Решена"), t ("Closed", "Закрыта"), t ("Rejected", "Отклонена") };
            for (int k = 0; k < st_names.length; k++) {
                var s = nm (k + 1, st_names[k]);
                s.set_boolean_member ("is_closed", k >= 3);
                statuses.add (s);
            }
            string[] pr_names = { t ("Low", "Низкий"), t ("Normal", "Нормальный"), t ("High", "Высокий"), t ("Urgent", "Срочный"), t ("Immediate", "Немедленный") };
            for (int k = 0; k < pr_names.length; k++) {
                var p = nm (k + 1, pr_names[k]);
                p.set_boolean_member ("is_default", k == 1);
                p.set_boolean_member ("active", true);
                priorities.add (p);
            }
            string[] tr_names = { t ("Bug", "Ошибка"), t ("Feature", "Функция"), t ("Task", "Задача"), t ("Support", "Поддержка") };
            for (int k = 0; k < tr_names.length; k++) trackers.add (nm (k + 1, tr_names[k]));
            string[] act_names = { t ("Development", "Разработка"), t ("Design", "Дизайн"), t ("Testing", "Тестирование"), t ("Meeting", "Совещание") };
            for (int k = 0; k < act_names.length; k++) {
                var a = nm (k + 8, act_names[k]);
                a.set_boolean_member ("is_default", k == 0);
                a.set_boolean_member ("active", true);
                activities.add (a);
            }
            string[] pnames = { t ("Mobile App", "Мобильное приложение"), t ("Website", "Сайт"), t ("Infrastructure", "Инфраструктура"), t ("Customer Support", "Поддержка клиентов") };
            string[] idents = { "mobile", "website", "infra", "support" };
            string[] mods = { "issue_tracking,wiki,files", "issue_tracking,wiki", "issue_tracking,files", "issue_tracking" };
            for (int k = 0; k < 4; k++) {
                var id = k + 1;
                var p = nm (id, pnames[k]);
                p.set_string_member ("identifier", idents[k]);
                p.set_int_member ("status", 1);
                p.set_array_member ("trackers", arr (trackers));
                var em = new Json.Array ();
                var ms = mods[k].split (",");
                for (int m = 0; m < ms.length; m++) em.add_object_element (nm (m + 1, ms[m]));
                p.set_array_member ("enabled_modules", em);
                if (id == 1) p.set_string_member ("description", t ("The iPhone and iPad app. Release notes and the team guide are in the *Wiki*.", "Приложение для iPhone и iPad. Заметки к выпускам и правила команды — в *Вики*."));
                if (id == 2) p.set_string_member ("description", t ("Marketing site and checkout.", "Сайт и оформление заказа."));
                if (id == 1) p.set_string_member ("homepage", "https://redmine.example.com/mobile");
                projects.add (p);
            }
            version (31, 1, "1.4", "closed", -20, t ("Sharing and context menus", "Общий доступ и контекстные меню"));
            version (32, 1, "1.5", "open", 12, t ("Offline mode and crash fixes", "Офлайн-режим и исправления падений"));
            version (34, 1, "1.6", "open", null, t ("Widgets", "Виджеты"));
            version (33, 2, t ("Spring release", "Весенний релиз"), "locked", 20, t ("New pricing page", "Новая страница тарифов"));

            //   id, проект, трекер, статус, приоритет, автор, исполнитель, тема, срок (дни от сегодня), готовность, изменена (мин назад), создана (дни назад)
            add (1240, 1, 1, 2, 4, 5, me, t ("Crash when opening a notification while the app is in the background", "Падение при открытии уведомления, когда приложение в фоне"), 0, 60, 12, 3, 0, { 5, 3, 2 }, 32, 6.0);
            add (1238, 1, 2, 2, 3, 8, me, t ("Offline mode for the issue list", "Офлайн-режим для списка задач"), 5, 40, 45, 9, 0, { 8, 2 }, 32, 24.0);
            add (1239, 1, 3, 1, 2, me, me, t ("Cache issue snapshots on disk", "Кэш снимков задач на диске"), 3, 0, 190, 8, 1238, {}, 32, 8.0);
            add (1241, 1, 3, 2, 2, 8, 3, t ("Sync queue for offline edits", "Очередь синхронизации офлайн-правок"), 6, 20, 260, 8, 1238, { me }, 32);
            add (1236, 1, 1, 3, 3, 6, me, t ("Dark mode: status badges have low contrast", "Тёмная тема: у плашек статуса низкий контраст"), -2, 80, 125, 6, 0, { 6 });
            add (1233, 1, 2, 1, 1, 4, me, t ("Haptic feedback on swipe actions", "Тактильный отклик на свайп-действиях"), null, 0, 1500, 12);
            add (1230, 2, 1, 1, 5, 6, me, t ("Checkout page returns 500 for some coupon codes", "Страница оплаты отдаёт 500 для части промокодов"), 0, 0, 25, 1, 0, { 6, 8 });
            add (1228, 2, 3, 2, 2, 8, me, t ("Update the privacy policy page", "Обновить страницу политики конфиденциальности"), 10, 50, 300, 14, 0, {}, 33);
            add (1225, 3, 3, 3, 2, 7, me, t ("Rotate TLS certificates on staging", "Обновить TLS-сертификаты на стенде"), -1, 90, 1440, 10, 0, { 7 });
            add (1222, 4, 4, 1, 3, 6, me, t ("Customer can’t reset the password from the mobile app", "Клиент не может сбросить пароль из мобильного приложения"), 1, 0, 170, 2, 0, { 6 });
            add (1219, 1, 1, 4, 2, 5, me, t ("Typo on the onboarding screen", "Опечатка на экране онбординга"), null, 100, 2900, 15);
            add (1215, 1, 2, 5, 2, 8, me, t ("Share the issue link from the context menu", "Поделиться ссылкой на задачу из контекстного меню"), null, 100, 5800, 20, 0, {}, 31);
            add (1212, 2, 1, 6, 1, 5, me, t ("Footer overlaps the content in old Safari", "Подвал перекрывает контент в старом Safari"), null, 0, 8700, 21);
            add (1243, 3, 3, 1, 2, 3, 7, t ("Move CI runners to the new cluster", "Перенести CI-раннеры на новый кластер"), 7, 0, 30, 1, 0, { me, 3 });
            add (1242, 2, 2, 2, 3, 8, 4, t ("Redesign the pricing page", "Новый дизайн страницы тарифов"), 9, 30, 55, 5, 0, { me, 8 }, 33);
            add (1235, 3, 1, 2, 4, 7, 3, t ("Nightly backups fail on the reporting database", "Не проходят ночные бэкапы базы отчётов"), -3, 50, 400, 7, 0, { me });
            add (1231, 4, 4, 3, 2, 6, 6, t ("Export invoices to CSV", "Выгрузка счетов в CSV"), null, 70, 720, 9);
            add (1229, 4, 4, 1, 1, 6, 5, t ("Question about notification settings", "Вопрос о настройках уведомлений"), null, 0, 1300, 3);
            add (1226, 2, 3, 5, 2, 8, 4, t ("Prepare banners for the spring campaign", "Подготовить баннеры для весенней кампании"), null, 100, 4300, 18);
            add (1224, 3, 2, 1, 2, 2, 7, t ("Dashboard for API latency", "Дашборд задержек API"), 14, 0, 2000, 11);
            add (1220, 1, 3, 2, 2, 2, 5, t ("Regression test plan for release 1.5", "План регрессионного тестирования релиза 1.5"), 4, 35, 600, 6, 0, { me }, 32);
            add (1217, 3, 1, 6, 1, 7, 7, t ("Disk alert fires on empty volumes", "Ложные алерты о диске на пустых томах"), null, 0, 7000, 16);
            add (1214, 4, 4, 5, 2, 6, 6, t ("Customer asks for a dark theme", "Клиент просит тёмную тему"), null, 100, 9000, 25);
            add (1210, 1, 2, 1, 2, 4, 0, t ("Widgets for the Home Screen", "Виджеты для экрана «Домой»"), null, 0, 3000, 13, 0, { me, 4 }, 34);
            add (1208, 2, 1, 2, 3, 5, 3, t ("Search results ignore diacritics", "Поиск не находит слова с «ё»"), null, 40, 900, 8);
            add (1205, 3, 3, 1, 1, me, 7, t ("Clean up old Docker images", "Почистить старые Docker-образы"), null, 0, 2400, 10);
            favorites.add (1240);
            favorites.add (1238);
            favorites.add (1242);

            issue (1240).set_string_member ("description", crash_description ());
            issue (1238).set_string_member ("description", offline_description ());
            issue (1236).set_string_member ("description", t ("Badges use the status color at 14% opacity — in dark mode the text is hard to read. See the screenshot in #1240 for comparison.",
                "Плашки берут цвет статуса с прозрачностью 14% — в тёмной теме текст читается плохо. Для сравнения — снимок в #1240."));
            issue (1230).set_string_member ("description", t ("Coupons with a percent discount over *50%* fail with HTTP 500. Reported by three customers today.",
                "Промокоды со скидкой больше *50%* падают с HTTP 500. Сегодня написали три клиента."));
            issue (1243).set_string_member ("description", t ("# Drain the old runners\n# Register the new ones\n# Update the pipeline tags\n\nKeep the old cluster for a week as a fallback.",
                "# Вывести старые раннеры\n# Зарегистрировать новые\n# Обновить теги в пайплайнах\n\nСтарый кластер держим неделю как запасной."));
            var shot = attach (501, new DemoUpload ("crash-screenshot.png", "image/png", demo_picture ("⚠", 0xFF3B30)), 3, 180);
            var log = attach (502, new DemoUpload ("crash.log", "text/plain", new Bytes ("Thread 0 Crashed:\n0 RedTask NotificationRouter.open(_:) + 132\n".data)), 3, 180);
            append (issue (1240), "attachments", shot);
            append (issue (1240), "attachments", log);
            // комментарий с картинкой — превью в уведомлении и в колокольчике
            var mock = attach (503, new DemoUpload ("pricing-mockup.png", "image/png", demo_picture ("▦", 0x5856D6)), 4, 55);
            append (issue (1242), "attachments", mock);

            note (1240, 5, 2900, t ("Reproduced on iOS 18.2 and 18.3. Steps are in the description.", "Воспроизвёл на iOS 18.2 и 18.3, шаги — в описании."), { "status_id", "1", "2" });
            note (1240, me, 1500, t ("Looks like the deep link handler runs before the scene is ready. The offline cache from #1238 makes it more likely.",
                "Похоже, обработчик ссылки срабатывает раньше, чем готова сцена. Офлайн-кэш из #1238 делает это вероятнее."));
            note (1240, 3, 180, t ("%s the crash log from TestFlight is attached, the stack points to @NotificationRouter.open(_:)@.",
                "%s приложил крэш-лог из TestFlight, стек указывает на @NotificationRouter.open(_:)@.").printf (at (me)), { "done_ratio", "30", "60" }, { shot, log });
            note (1240, 2, 12, t ("Let’s ship the fix in 1.5. Please add a regression test — %s will verify it on devices.",
                "Выпускаем исправление в 1.5. Добавь, пожалуйста, регрессионный тест — %s проверит на устройствах.").printf (at (5)), { "priority_id", "3", "4" });
            note (1238, 8, 2000, t ("Agreed on the scope with the team, see the table in the description.", "Согласовали объём с командой, таблица — в описании."));
            note (1238, me, 900, t ("Split into #1239 and #1241.", "Разбил на #1239 и #1241."));
            note (1238, 8, 45, t ("Moved the due date — design review takes one more day.", "Сдвинула срок: дизайн-ревью займёт ещё день."), { "due_date", day (4), day (5) });
            note (1230, 6, 25, t ("Two more customers reported this today. %s could you take a look first?",
                "Сегодня ещё два клиента написали. %s, посмотришь в первую очередь?").printf (at (me)));
            note (1243, 3, 30, t ("%s please check the iOS build job after the move — it uses the macOS runners.",
                "%s, проверь, пожалуйста, сборку iOS после переезда — она на macOS-раннерах.").printf (at (me)));
            note (1242, 4, 55, t ("New mockups are attached. Feedback welcome!", "Приложила новые макеты. Жду замечаний!"), {}, { mock });

            var pf = new GenericArray<Json.Object> ();
            pf.add (attach (601, new DemoUpload ("app-icon.png", "image/png", demo_picture ("★", 0x007AFF)), 4, 20000));
            pf.add (attach (602, new DemoUpload (t ("release-checklist.txt", "чеклист-выпуска.txt"), "text/plain",
                new Bytes (t ("1. Bump the version\n2. TestFlight\n3. Submit for review\n", "1. Поднять версию\n2. TestFlight\n3. Отправить на проверку\n").data)), 8, 9000));
            pf.add (attach (604, new DemoUpload (t ("roadmap.odt", "план-развития.odt"), "application/vnd.oasis.opendocument.text", demo_odt (demo_picture ("◆", 0xFF9500))), 2, 15000));
            project_files[1] = pf;
            var pf3 = new GenericArray<Json.Object> ();
            pf3.add (attach (603, new DemoUpload ("network-diagram.png", "image/png", demo_picture ("⌘", 0x30B0C7)), 7, 30000));
            project_files[3] = pf3;

            var release = t ("Release_process", "Выпуск_версии");
            var style = t ("Code_style", "Стиль_кода");
            var r15 = t ("Release_1.5", "Выпуск_1.5");
            var w1 = new GenericArray<DemoWiki> ();
            w1.add (new DemoWiki ("Wiki", null, t (
                "h1. Mobile App\n\nStart here. The team works in two-week iterations, see [[%s|how we ship]] and [[%s]].\n\n* Current version: [[%s]]\n* Open bugs: #1240, #1236",
                "h1. Мобильное приложение\n\nНачните отсюда. Команда работает двухнедельными итерациями: [[%s|как мы выпускаем]] и [[%s]].\n\n* Текущая версия: [[%s]]\n* Открытые ошибки: #1240, #1236"
            ).printf (release, style, r15)));
            w1.add (new DemoWiki (release, "Wiki", t (
                "h2. Release process\n\n# Freeze the branch on Monday\n# QA pass — %s\n# Submit to App Review\n\nbq. Never ship on Friday.",
                "h2. Выпуск версии\n\n# Заморозка ветки в понедельник\n# Проверка — %s\n# Отправка в App Review\n\nbq. В пятницу не выпускаем."
            ).printf (at (5))));
            w1.add (new DemoWiki (r15, release, t ("Offline mode and crash fixes. Back to [[Wiki]].", "Офлайн-режим и исправления падений. Назад — [[Wiki]].")));
            w1.add (new DemoWiki (style, "Wiki", t ("Swift 6, strict concurrency, *small diffs*.", "Swift 6, строгая конкурентность, *маленькие диффы*.")));
            wiki[1] = w1;
            var w2 = new GenericArray<DemoWiki> ();
            w2.add (new DemoWiki ("Wiki", null, t ("h1. Website\n\nSee also the [[mobile:Wiki|Mobile App wiki]].", "h1. Сайт\n\nСм. также [[mobile:Wiki|вики мобильного приложения]].")));
            wiki[2] = w2;
            note (1236, 6, 400, t ("The customer confirmed it on iPhone 15 Pro, iOS 18.3.", "Клиент подтвердил на iPhone 15 Pro, iOS 18.3."));
            note (1236, me, 125, t ("Fixed in build 1.5 (512), please check.", "Исправлено в сборке 1.5 (512), проверьте, пожалуйста."), { "status_id", "2", "3", "done_ratio", "50", "80" });
            note (1225, 7, 1440, t ("Staging is done, production is scheduled for Monday.", "Стенд готов, прод — в понедельник."));
            note (1222, 6, 170, t ("The reset link opens Safari instead of the app.", "Ссылка сброса открывает Safari вместо приложения."));
            note (1235, 3, 400, t ("Disk on the backup host is full, cleaning up.", "Закончилось место на хосте бэкапов, чищу."));

            relations.add (relation (801, 1240, 1236, "relates"));
            relations.add (relation (802, 1235, 1224, "blocks"));

            work (1240, me, 1.5, 8, "Investigating crash logs", "Разбор крэш-логов", -1, 1500);
            work (1240, 3, 0.5, 10, "Reproduced on devices", "Воспроизведение на устройствах", -1, 1400);
            work (1240, me, 2.0, 8, "Fix and regression test", "Исправление и регрессионный тест", 0, 60);
            work (1238, me, 3.0, 8, "Snapshot cache prototype", "Прототип кэша снимков", -2, 2900);
            work (1238, 4, 1.0, 9, "Offline state mockups", "Макеты офлайн-состояния", -1, 1300);
            work (1236, me, 1.25, 8, "Contrast fix", "Исправление контраста", 0, 130);
        }

        void work (int issue_id, int user, double h, int act, string en, string ru_, int d, double ago) {
            var i = issue (issue_id);
            if (i == null) return;
            time.add (entry (new_id (), i, user, h, act, t (en, ru_), day (d), ago));
            recount_time (issue_id);
        }

        void add (int id, int project, int tracker_id, int status_id, int priority_id, int author, int assignee, string subject,
                  int? due, int done, int upd, int cre, int parent = 0, int[] watch = {}, int ver = 0, double est = 0) {
            var st = status (status_id);
            var updated = iso (upd);
            var i = ref_id (id);
            i.set_object_member ("project", project_ref (project));
            i.set_object_member ("tracker", tracker (tracker_id));
            i.set_object_member ("status", st);
            i.set_object_member ("priority", priority (priority_id));
            i.set_object_member ("author", named (author));
            if (assignee > 0) i.set_object_member ("assigned_to", named (assignee));
            var vr = ver > 0 ? version_ref (ver) : null;
            if (vr != null) i.set_object_member ("fixed_version", vr);
            if (parent > 0) i.set_object_member ("parent", ref_id (parent));
            i.set_string_member ("subject", subject);
            i.set_string_member ("start_date", day (-cre));
            if (due != null) i.set_string_member ("due_date", day (due));
            i.set_int_member ("done_ratio", done);
            if (est > 0) i.set_double_member ("estimated_hours", est);
            i.set_string_member ("created_on", iso (cre * 1440.0));
            i.set_string_member ("updated_on", updated);
            if (jbool (st, "is_closed")) i.set_string_member ("closed_on", updated);
            var w = new Json.Array ();
            foreach (var x in watch) w.add_object_element (named (x));
            i.set_array_member ("watchers", w);
            i.set_array_member ("journals", new Json.Array ());
            i.set_array_member ("attachments", new Json.Array ());
            issues.add (i);
        }

        /** details — тройки «поле, было, стало» подряд. */
        void note (int id, int user, double ago, string text, string[] details = {}, Json.Object[] attached = {}) {
            var j = ref_id (new_id ());
            j.set_object_member ("user", named (user));
            j.set_string_member ("notes", text);
            j.set_string_member ("created_on", iso (ago));
            var d = new Json.Array ();
            for (int k = 0; k + 2 < details.length; k += 3) d.add_object_element (detail ("attr", details[k], details[k + 1], details[k + 2]));
            foreach (var a in attached) d.add_object_element (detail ("attachment", jint (a, "id").to_string (), null, jstr (a, "filename")));
            j.set_array_member ("details", d);
            var i = issue (id);
            if (i == null) return;
            var js = jarr (i, "journals");
            js.add (j);
            js.sort ((a, b) => strcmp (jstr (a, "created_on"), jstr (b, "created_on")));
            i.set_array_member ("journals", arr (js));
        }

        string crash_description () {
            return t ("""h2. Steps to reproduce

# Put the app in the background
# Receive a push about a new comment
# Tap the notification

h2. Expected

The issue opens scrolled to the new comment.

h2. Actual

The app crashes on *iOS 18.2+*, roughly *1 in 5* attempts. Related: #1238, #1236. Reported by @%s.

|_. Device |_. iOS |_. Reproduced |
| iPhone 15 Pro | 18.3 | yes |
| iPhone 13 | 18.2 | yes |
| iPad Air | 18.3 | no |

bq. Users mostly hit it after the phone has been locked for a while.

<pre>
Thread 0 Crashed:
0  RedTask  NotificationRouter.open(_:) + 132
1  RedTask  AppDelegate.userNotificationCenter(_:didReceive:) + 88
</pre>

!crash-screenshot.png!""", """h2. Как воспроизвести

# Свернуть приложение
# Получить пуш о новом комментарии
# Нажать на уведомление

h2. Ожидается

Открывается задача на новом комментарии.

h2. На деле

Приложение падает на *iOS 18.2+*, примерно *в одном случае из пяти*. Связано: #1238, #1236. Сообщила @%s.

|_. Устройство |_. iOS |_. Воспроизводится |
| iPhone 15 Pro | 18.3 | да |
| iPhone 13 | 18.2 | да |
| iPad Air | 18.3 | нет |

bq. Чаще всего — после того, как телефон какое-то время был заблокирован.

<pre>
Thread 0 Crashed:
0  RedTask  NotificationRouter.open(_:) + 132
1  RedTask  AppDelegate.userNotificationCenter(_:didReceive:) + 88
</pre>

!crash-screenshot.png!""").printf (login_of (6));
        }

        string offline_description () {
            return t ("""The list and the last opened issues should work without a network.

h3. Scope

* Cached lists: *My*, *Watching*, *Favorites*
* Issue snapshots — #1239
* Edits queue and sync — #1241
** comments
** status and assignee

|_. Screen |_. Offline |_. Notes |
| Issue list | read | stale badge |
| Issue | read | last snapshot |
| Comment | write | queued |

Design: @%s, review by @%s.""", """Список и последние открытые задачи должны работать без сети.

h3. Объём

* Кэш списков: *Мои*, *Отслеживаемые*, *Избранное*
* Снимки задач — #1239
* Очередь правок и синхронизация — #1241
** комментарии
** статус и исполнитель

|_. Экран |_. Офлайн |_. Примечание |
| Список задач | чтение | плашка «устарело» |
| Задача | чтение | последний снимок |
| Комментарий | запись | в очередь |

Дизайн — @%s, ревью — @%s.""").printf (login_of (4), login_of (2));
        }
    }

    /** Документ ODF со встроенной миниатюрой (без текста): строка вложения покажет её после первого открытия. */
    private Bytes demo_odt (Bytes thumbnail) {
        var content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" office:version=\"1.2\"><office:body><office:text/></office:body></office:document-content>";
        return stored_zip ({ "mimetype", "content.xml", "Thumbnails/thumbnail.png" },
            { new Bytes ("application/vnd.oasis.opendocument.text".data), new Bytes (content.data), thumbnail });
    }

    /** Zip без сжатия: локальные заголовки, центральный каталог, конец каталога. */
    private Bytes stored_zip (string[] names, Bytes[] datas) {
        var zip = new ByteArray ();
        var dir = new ByteArray ();
        for (int k = 0; k < names.length; k++) {
            unowned uint8[] d = datas[k].get_data ();
            uint32 c = (uint32) 0xFFFFFFFF;
            foreach (var b in d) { c ^= b; for (int j = 0; j < 8; j++) c = (c & 1) != 0 ? (c >> 1) ^ (uint32) 0xEDB88320 : c >> 1; }
            var common = new ByteArray ();
            put_le (common, 0, 2); put_le (common, 0, 2); put_le (common, 0, 4); put_le (common, ~c, 4);
            put_le (common, d.length, 4); put_le (common, d.length, 4); put_le (common, names[k].length, 2); put_le (common, 0, 2);
            put_le (dir, 0x02014b50, 4); put_le (dir, 20, 2); put_le (dir, 20, 2); dir.append (common.data);
            put_le (dir, 0, 6); put_le (dir, 0, 4); put_le (dir, zip.len, 4); dir.append (names[k].data);
            put_le (zip, 0x04034b50, 4); put_le (zip, 20, 2); zip.append (common.data); zip.append (names[k].data); zip.append (d);
        }
        var cd = zip.len;
        zip.append (dir.data);
        put_le (zip, 0x06054b50, 4); put_le (zip, 0, 4); put_le (zip, names.length, 2); put_le (zip, names.length, 2);
        put_le (zip, dir.len, 4); put_le (zip, cd, 4); put_le (zip, 0, 2);
        return ByteArray.free_to_bytes ((owned) zip);
    }

    private void put_le (ByteArray a, uint64 v, int n) {
        for (int i = 0; i < n; i++) a.append ({ (uint8) ((v >> (8 * i)) & 0xFF) });
    }

    /** Картинка-заглушка вложения: «окно приложения» со знаком (как символ шрифта на Android). */
    private Bytes demo_picture (string symbol, uint32 tint) {
        int w = 900, h = 560;
        double r = ((tint >> 16) & 0xFF) / 255.0, g = ((tint >> 8) & 0xFF) / 255.0, b = (tint & 0xFF) / 255.0;
        var s = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
        var cr = new Cairo.Context (s);
        var grad = new Cairo.Pattern.linear (0, 0, w, h);
        grad.add_color_stop_rgba (0, r, g, b, 0.85);
        grad.add_color_stop_rgba (1, r, g, b, 0.35);
        cr.set_source (grad);
        cr.paint ();
        double cl = 90, ct = 70, cw = 720, ch = 420;
        rounded (cr, cl, ct, cw, ch, 28);
        cr.set_source_rgb (1, 1, 1);
        cr.fill ();
        cr.save ();
        cr.rectangle (cl, ct, cw, 56);
        cr.clip ();
        rounded (cr, cl, ct, cw, ch, 28);
        cr.set_source_rgb (0xE5 / 255.0, 0xE5 / 255.0, 0xEA / 255.0);
        cr.fill ();
        cr.restore ();
        uint32[] dots = { 0xFF3B30, 0xFFCC00, 0x34C759 };
        for (int k = 0; k < 3; k++) {
            cr.set_source_rgb (((dots[k] >> 16) & 0xFF) / 255.0, ((dots[k] >> 8) & 0xFF) / 255.0, (dots[k] & 0xFF) / 255.0);
            cr.arc (cl + 35 + k * 30, ct + 28, 9, 0, 2 * Math.PI);
            cr.fill ();
        }
        cr.set_source_rgb (0xD1 / 255.0, 0xD1 / 255.0, 0xD6 / 255.0);
        double[] lens = { 420, 520, 360, 470 };
        for (int k = 0; k < 4; k++) {
            rounded (cr, cl + 260, ct + 120 + k * 56, lens[k] - 120, 22, 11);
            cr.fill ();
        }
        var layout = Pango.cairo_create_layout (cr);
        var fd = Pango.FontDescription.from_string ("Sans Bold");
        fd.set_absolute_size (150 * Pango.SCALE);
        layout.set_font_description (fd);
        layout.set_text (symbol, -1);
        int lw, lh;
        layout.get_pixel_size (out lw, out lh);
        cr.set_source_rgb (r, g, b);
        cr.move_to (cl + 130 - lw / 2.0, ct + 260 - layout.get_baseline () / (double) Pango.SCALE);
        Pango.cairo_show_layout (cr, layout);
        var buf = new ByteArray ();
        s.write_to_png_stream ((data) => { buf.append ((uint8[]) data); return Cairo.Status.SUCCESS; });
        return ByteArray.free_to_bytes ((owned) buf);
    }

    private void rounded (Cairo.Context cr, double x, double y, double w, double h, double rad) {
        cr.new_sub_path ();
        cr.arc (x + w - rad, y + rad, rad, -Math.PI / 2, 0);
        cr.arc (x + w - rad, y + h - rad, rad, 0, Math.PI / 2);
        cr.arc (x + rad, y + h - rad, rad, Math.PI / 2, Math.PI);
        cr.arc (x + rad, y + rad, rad, Math.PI, 3 * Math.PI / 2);
        cr.close_path ();
    }
}
