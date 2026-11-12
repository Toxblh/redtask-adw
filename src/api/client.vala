/*
 * Клиент REST API Redmine (https://www.redmine.org/projects/redmine/wiki/Rest_api).
 * Авторизация — заголовок X-Redmine-API-Key. Причуды my.basealt.space — в комментариях у мест, где они лечатся.
 */
namespace Redmine {

    public Quark http_error_quark () { return Quark.from_string ("redmine-http-error"); }

    /** Код ошибки — HTTP-статус; 0 — сеть/адрес, 200 — 200 с не тем содержимым (капча WAF, страница логина). */
    public Error http_error (int code, string message) {
        return new Error (http_error_quark (), code, "%s", message);
    }

    public int error_code (Error e) {
        return e.domain == http_error_quark () ? e.code : 0;
    }

    /**
     * Капча WAF, которую автоповтор не прошёл: решается руками в WebKit (CaptchaWindow). После решения
     * запросы к серверу идут с куками и UA этого WebKit — WAF привязывает пропуск к браузеру.
     */
    public class WafGate : Object {
        private static WafGate? _inst;
        public static WafGate get_default () {
            if (_inst == null) _inst = new WafGate ();
            return _inst;
        }
        /** Последний ответ сервера — капча; сбрасывается первым нормальным ответом. */
        public bool blocked { get; set; default = false; }
        /** UA WebKit, в котором решили капчу; null — ходим как обычно, без кук браузера. */
        public string? browser_agent { get; set; default = null; }
        /** Куки браузера после капчи; пока null — сессия без кук. */
        public Soup.CookieJar? jar = null;
    }

    public async void sleep_ms (uint ms) {
        Timeout.add (ms, sleep_ms.callback);
        yield;
    }

    public class IssueQuery {
        public int project_id = 0;
        public bool assigned_to_me = false;
        public bool watched_by_me = false;
        public bool authored_by_me = false;
        /** Серверное избранное (плагин favourites). */
        public bool favourite = false;
        public string status = "open"; // open | closed | *
        public int parent_id = 0;
        public int fixed_version_id = 0;
        public string? subject = null;
        public string? updated_since = null; // ISO, целые секунды, Z
        public string sort = "updated_on:desc";
        public int limit = 50;
        public int offset = 0;
        /** Свой фильтр (spec 17.2): готовые параметры filter_params — вместо полей выше, кроме project_id. */
        public Query? params = null;
        /** Серверный запрос (spec 17.4): issues.json?query_id=N. */
        public int query_id = 0;
        public IssueQuery copy () {
            var q = new IssueQuery ();
            q.project_id = project_id; q.assigned_to_me = assigned_to_me; q.watched_by_me = watched_by_me;
            q.authored_by_me = authored_by_me; q.favourite = favourite; q.status = status; q.parent_id = parent_id; q.fixed_version_id = fixed_version_id; q.subject = subject;
            q.updated_since = updated_since; q.sort = sort; q.limit = limit; q.offset = offset;
            q.params = params; q.query_id = query_id;
            return q;
        }
    }

    public class IssueChunk {
        public GenericArray<Issue> issues = new GenericArray<Issue> ();
        public int total = 0;
    }

    internal const int WAF_RETRIES = 3;

    public class Resp {
        public Bytes body;
        public uint code;
        public Soup.MessageHeaders headers;
        public string text () {
            if (body.get_size () == 0) return "";
            // данные Bytes не оканчиваются нулём — копируем ровно size байт
            var copy = new uint8[body.get_size () + 1];
            Memory.copy (copy, body.get_data (), body.get_size ());
            copy[body.get_size ()] = 0;
            return (string) copy;
        }
    }

    public class Client : Object {
        public string base_url { get; private set; }
        private string api_key;
        private Uri base_uri;
        private Soup.Session session;

        // Отказы сервера помним в самом клиенте: он один на пару «сервер + ключ», то есть на учётку.
        private GenericSet<int> watchers_forbidden_in = new GenericSet<int> (direct_hash, direct_equal);
        private bool custom_fields_forbidden = false;
        /** Сервер отверг фильтр по комментариям (старый Redmine): до пересоздания клиента его больше не спрашиваем. */
        public bool mention_filter_unsupported = false;
        /** Демо-режим (spec 6): ответы — из DemoServer, в сеть не уходит ни один запрос. */
        public bool demo { get; private set; }

        public Client (string base_url, string api_key) throws Error {
            this.base_url = base_url.has_suffix ("/") ? base_url.substring (0, base_url.length - 1) : base_url;
            this.api_key = api_key.strip ();
            base_uri = Uri.parse (this.base_url, UriFlags.NONE);
            if (base_uri.get_host () == null || base_uri.get_host () == "") throw http_error (0, _("Bad server address"));
            demo = DemoServer.is_demo (this.base_url);
            // 6 соединений, как у браузера (по умолчанию 2): страницы проектов качаются параллельно
            session = (Soup.Session) Object.new (typeof (Soup.Session), "max-conns-per-host", 6);
            session.timeout = 40;
            session.user_agent = "RedTask/" + Config.VERSION + " (GNOME)";
            var waf = WafGate.get_default ();
            apply_browser (waf);
            waf.notify["browser-agent"].connect (() => apply_browser (waf));
        }

        private void apply_browser (WafGate waf) {
            if (waf.jar != null && !session.has_feature (typeof (Soup.CookieJar))) session.add_feature (waf.jar);
            if (waf.browser_agent != null) session.user_agent = waf.browser_agent;
        }

        public string url (string path, Query? q = null) {
            var p = path.has_prefix ("/") ? path.substring (1) : path;
            var s = base_url + "/" + p;
            if (q != null && q.keys.length > 0) s += "?" + q.encode ();
            return s;
        }

        /** Свой хост с пониженной схемой (http content_url за TLS-прокси) → схема и порт сервера. */
        public string own (string u) {
            try {
                var t = Uri.parse (u, UriFlags.NONE);
                if (t.get_host () == base_uri.get_host () && base_uri.get_scheme () == "https" && t.get_scheme () != "https")
                    return Uri.join (UriFlags.NONE, "https", null, t.get_host (), base_uri.get_port (), t.get_path (), t.get_query (), null);
            } catch (Error e) {}
            return u;
        }

        public string issue_web_url (int id) { return base_url + "/issues/%d".printf (id); }

        /**
         * Один HTTP-обмен с автоповтором капчи WAF. Ключ — только своему хосту (и при ручном переходе по редиректу).
         * WAF перед сервером случайно (замерено: каждый 4–5-й запрос) отвечает страницей «Security check»:
         * 200 + HTML, до Redmine запрос не доходит (нет X-Request-Id) — значит, повтор безопасен и для записи.
         */
        public async Resp raw (string method, string u, string accept, Bytes? body, string? body_type,
                               bool html_auth = false, Cancellable? c = null) throws Error {
            if (demo) {
                var d = DemoServer.handle (method, u, body);
                var hd = new Soup.MessageHeaders (Soup.MessageHeadersType.RESPONSE);
                hd.replace ("Content-Type", d.type);
                hd.replace ("X-Request-Id", "demo");
                if (d.location != null) hd.replace ("Location", d.location);
                return new Resp () { body = d.body, code = d.code, headers = hd };
            }
            string target = u;
            for (int hop = 0; hop < 4; hop++) {
                for (int attempt = 0; ; attempt++) {
                    var msg = new Soup.Message (method, target);
                    if (msg == null) throw http_error (0, _("Bad address: %s").printf (target));
                    msg.flags |= Soup.MessageFlags.NO_REDIRECT;
                    var h = msg.request_headers;
                    h.replace ("Accept", accept);
                    bool mine = key_allowed (base_uri, msg.get_uri ());
                    if (mine) {
                        // HTML-страницы People не принимают ключ в заголовке — только Basic «ключ:x»
                        if (html_auth) h.replace ("Authorization", "Basic " + Base64.encode ((api_key + ":x").data));
                        else h.replace ("X-Redmine-API-Key", api_key);
                    }
                    if (body != null) msg.set_request_body_from_bytes (body_type ?? "application/json", body);
                    Bytes resp;
                    try {
                        resp = yield session.send_and_read_async (msg, Priority.DEFAULT, c);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        throw http_error (0, e.message);
                    }
                    var code = msg.status_code;
                    var ct = msg.response_headers.get_content_type (null);
                    if (attempt < WAF_RETRIES && waf_challenge (accept, code, ct, msg.response_headers.get_one ("X-Request-Id"))) {
                        yield sleep_ms (300 * (attempt + 1));
                        continue;
                    }
                    if (code >= 300 && code < 400 && msg.response_headers.get_one ("Location") != null) {
                        try {
                            target = Uri.resolve_relative (msg.get_uri ().to_string (), msg.response_headers.get_one ("Location"), UriFlags.NONE);
                        } catch (Error e) { throw http_error ((int) code, "Bad redirect"); }
                        break; // следующий hop
                    }
                    return new Resp () { body = resp, code = msg.status_code, headers = msg.response_headers };
                }
            }
            throw http_error (0, "Too many redirects");
        }

        private async string exec (string method, string u, Json.Node? payload, Cancellable? c = null) throws Error {
            Bytes? body = payload != null ? new Bytes (json_to_string (payload).data) : null;
            var r = yield raw (method, u, "application/json", body, "application/json", false, c);
            var text = r.text ();
            var ct = r.headers.get_content_type (null);
            var code = r.code;
            var waf = WafGate.get_default ();
            bool captcha = waf_challenge ("application/json", code, ct, r.headers.get_one ("X-Request-Id"));
            if (waf.blocked != captcha) waf.blocked = captcha;
            if (captcha) throw http_error (200, _("Server asks for a captcha (Security check)"));
            // страница логина вместо JSON: для записи это НЕ успех — иначе комментарий молча пропадёт
            if (code >= 200 && code < 300 && ct != null && ct.contains ("html"))
                throw http_error (200, _("Unexpected response from server"));
            if (code < 200 || code >= 300) {
                string detail = "";
                var n = json_parse (text);
                if (n != null && n.get_node_type () == Json.NodeType.OBJECT && n.get_object ().has_member ("errors")) {
                    var parts = new GenericArray<string> ();
                    n.get_object ().get_array_member ("errors").foreach_element ((a, i, e) => {
                        if (e.get_node_type () == Json.NodeType.VALUE) parts.add (e.get_string ());
                    });
                    detail = string.joinv (", ", parts.data);
                }
                string m;
                switch (code) {
                    case 401: m = _("Unauthorized: check the API key"); break;
                    case 403: m = _("Forbidden") + (detail != "" ? ": " + detail : ""); break;
                    case 404: m = _("Not found"); break;
                    case 422: m = detail != "" ? detail : _("Validation failed"); break;
                    default: m = "HTTP %u".printf (code) + (detail != "" ? ": " + detail : ""); break;
                }
                throw http_error ((int) code, m);
            }
            return text;
        }

        // ponytail: JSON разбирается на главном потоке — задача с сотнями журналов это десятки мс; мегабайтный
        // ответ ролей зовётся раз в сутки (кэш RefData). Начнёт тормозить — разбор в GLib.Thread.
        public async Json.Object get_obj (string path, Query? q = null, Cancellable? c = null) throws Error {
            var text = yield exec ("GET", url (path, q), null, c);
            var n = json_parse (text);
            // 200 с HTML (проверка WAF, страница логина) — это сбой, а не «нет данных»
            if (n == null || n.get_node_type () != Json.NodeType.OBJECT) throw http_error (200, _("Unexpected response from server"));
            return n.get_object ();
        }

        public async string send (string method, string path, Json.Object? payload) throws Error {
            return yield exec (method, url (path), payload != null ? obj_node (payload) : null);
        }

        public async void delete (string path) throws Error {
            yield exec ("DELETE", url (path), null);
        }

        // ---------- users ----------
        public async User current_user () throws Error {
            var o = yield get_obj ("users/current.json");
            return new User.from (jobj (o, "user"));
        }

        /** Мои роли по проектам: проект → id ролей. Ответ — больше мегабайта: результат кэширует RefData. */
        public async Json.Object my_roles () throws Error {
            var o = jobj (yield get_obj ("users/current.json", new Query ().add ("include", "memberships")), "user");
            var roles = new Json.Object ();
            foreach (var m in jarr (o, "memberships")) {
                var p = jobj (m, "project");
                if (p == null) continue;
                var key = jint (p, "id").to_string ();
                var arr = roles.has_member (key) ? roles.get_array_member (key) : new Json.Array ();
                foreach (var r in jarr (m, "roles")) arr.add_int_element (jint (r, "id"));
                roles.set_array_member (key, arr);
            }
            var res = new Json.Object ();
            res.set_boolean_member ("admin", jbool (o, "admin"));
            res.set_object_member ("roles", roles);
            return res;
        }

        /** Права роли: edit_issues, add_issue_notes, log_time, … */
        public async Json.Array role_permissions (int role_id) throws Error {
            var o = jobj (yield get_obj ("roles/%d.json".printf (role_id)), "role");
            return o != null && o.has_member ("permissions") ? o.get_array_member ("permissions") : new Json.Array ();
        }

        // ---------- справочники ----------
        public async GenericArray<Json.Object> statuses () throws Error {
            return jarr (yield get_obj ("issue_statuses.json"), "issue_statuses");
        }
        public async GenericArray<Json.Object> priorities () throws Error {
            var res = new GenericArray<Json.Object> ();
            foreach (var p in jarr (yield get_obj ("enumerations/issue_priorities.json"), "issue_priorities"))
                if (jbool (p, "active", true)) res.add (p);
            return res;
        }
        public async GenericArray<Json.Object> trackers () throws Error {
            return jarr (yield get_obj ("trackers.json"), "trackers");
        }
        public async GenericArray<Json.Object> activities () throws Error {
            var res = new GenericArray<Json.Object> ();
            foreach (var p in jarr (yield get_obj ("enumerations/time_entry_activities.json"), "time_entry_activities"))
                if (jbool (p, "active", true)) res.add (p);
            return res;
        }

        // ---------- проекты ----------
        /**
         * Все проекты: сервер отдаёт не больше 100 за раз, страница — ~3 с (замер: 27 страниц подряд — 85 с).
         * Первая страница называет total_count, остальные — в 5 потоков (≈ 20 с).
         */
        public async GenericArray<Json.Object> projects () throws Error {
            var first = yield get_obj ("projects.json", new Query ().add ("limit", "100").add ("offset", "0"));
            // ponytail: потолок 5000 проектов (50 запросов) — у пользователя их ~3200
            var total = int.min (jint (first, "total_count"), 5000);
            var n = (total + 99) / 100;
            var pages = new HashTable<int, Json.Object> (direct_hash, direct_equal);
            pages[0] = first;
            int next = 1, running = 0;
            Error? failed = null;
            SourceFunc resume = projects.callback;
            for (int w = 0; w < 5; w++) {
                running++;
                projects_worker.begin (pages, n, () => next++, (o, r) => {
                    try { projects_worker.end (r); } catch (Error e) { failed = e; }
                    if (--running == 0) resume ();
                });
            }
            yield;
            if (failed != null) throw failed;
            var all = new GenericArray<Json.Object> ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            // страницы могут перекрыться, если список сдвинулся между запросами
            for (int i = 0; i < int.max (n, 1); i++) if (pages[i] != null)
                foreach (var p in jarr (pages[i], "projects")) if (!seen.contains (jint (p, "id"))) { seen.add (jint (p, "id")); all.add (p); }
            return all;
        }

        private delegate int NextPage ();

        private async void projects_worker (HashTable<int, Json.Object> pages, int n, NextPage take) throws Error {
            for (var i = take (); i < n; i = take ()) {
                pages[i] = yield get_obj ("projects.json", new Query ().add ("limit", "100").add ("offset", (i * 100).to_string ()));
            }
        }

        public async Json.Object project (int id) throws Error {
            return jobj (yield get_obj ("projects/%d.json".printf (id), new Query ().add ("include", "trackers,enabled_modules,issue_custom_fields")), "project");
        }
        public async GenericArray<Json.Object> versions (int project_id) throws Error {
            return jarr (yield get_obj ("projects/%d/versions.json".printf (project_id)), "versions");
        }
        public async GenericArray<Json.Object> issue_categories (int project_id) throws Error {
            return jarr (yield get_obj ("projects/%d/issue_categories.json".printf (project_id)), "issue_categories");
        }

        /**
         * Описания настраиваемых полей задач. /custom_fields.json на многих серверах только для админа:
         * на 403 отдаём пусто и помним это — форма показывает такие поля свободным текстом.
         */
        public async GenericArray<Json.Object> custom_field_defs () throws Error {
            var res = new GenericArray<Json.Object> ();
            if (custom_fields_forbidden) return res;
            try {
                foreach (var f in jarr (yield get_obj ("custom_fields.json"), "custom_fields"))
                    if (jstr (f, "customized_type") == "issue") res.add (f);
            } catch (Error e) {
                if (error_code (e) != 403) throw e;
                custom_fields_forbidden = true;
            }
            return res;
        }

        /** Участники проекта (и группы: задачу можно назначить на группу), по имени. */
        public async GenericArray<Named> members (int project_id) throws Error {
            var res = new GenericArray<Named> ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            int offset = 0;
            while (true) {
                var page = yield get_obj ("projects/%d/memberships.json".printf (project_id),
                    new Query ().add ("limit", "100").add ("offset", offset.to_string ()));
                var items = jarr (page, "memberships");
                foreach (var m in items) {
                    var who = Named.from (jobj (m, "user") ?? jobj (m, "group"));
                    if (who != null && !seen.contains (who.id)) { seen.add (who.id); res.add (who); }
                }
                offset += 100;
                if (offset >= jint (page, "total_count") || items.length == 0 || offset >= 1000) break;
            }
            res.sort ((a, b) => strcmp (a.name.casefold (), b.name.casefold ()));
            return res;
        }

        // ---------- задачи ----------
        public async IssueChunk issues (IssueQuery q, Cancellable? c = null) throws Error {
            if (q.params != null || q.query_id > 0) {
                var p = new Query ();
                if (q.params != null) for (int i = 0; i < q.params.keys.length; i++) p.add (q.params.keys[i], q.params.vals[i]);
                p.add ("query_id", q.query_id > 0 ? q.query_id.to_string () : null)
                    .add ("project_id", q.project_id > 0 ? q.project_id.to_string () : null)
                    .add ("limit", q.limit.to_string ()).add ("offset", q.offset.to_string ());
                return page_of (yield get_obj ("issues.json", p, c));
            }
            // фильтр плагина — только полной формой f[]/op/v, и тогда статус тоже в ней: простые параметры сервер не смешивает
            if (q.favourite) return page_of (yield get_obj ("issues.json", new Query ()
                .add ("set_filter", "1")
                .add ("f[]", "favourite_state").add ("op[favourite_state]", "=").add ("v[favourite_state][]", "Избранные задачи")
                .add ("f[]", "status_id").add ("op[status_id]", q.status == "open" ? "o" : (q.status == "closed" ? "c" : "*"))
                .add ("sort", q.sort).add ("limit", q.limit.to_string ()).add ("offset", q.offset.to_string ()), c));
            var query = new Query ()
                .add ("limit", q.limit.to_string ())
                .add ("offset", q.offset.to_string ())
                .add ("sort", q.sort)
                .add ("status_id", q.status)
                .add ("project_id", q.project_id > 0 ? q.project_id.to_string () : null)
                .add ("parent_id", q.parent_id > 0 ? q.parent_id.to_string () : null)
                .add ("fixed_version_id", q.fixed_version_id > 0 ? q.fixed_version_id.to_string () : null)
                .add ("assigned_to_id", q.assigned_to_me ? "me" : null)
                .add ("watcher_id", q.watched_by_me ? "me" : null)
                .add ("author_id", q.authored_by_me ? "me" : null)
                .add ("subject", q.subject != null ? "~" + q.subject : null)
                .add ("updated_on", q.updated_since != null ? ">=" + q.updated_since : null);
            return page_of (yield get_obj ("issues.json", query, c));
        }

        private IssueChunk page_of (Json.Object o) {
            var p = new IssueChunk ();
            foreach (var i in jarr (o, "issues")) p.issues.add (new Issue (i));
            p.total = jint (o, "total_count");
            return p;
        }

        /**
         * Подписи значений настраиваемых полей, которые REST отдаёт идентификаторами: «88» → «Альт Сервер».
         * Описания полей не-админу недоступны (/custom_fields.json — 403), зато CSV-экспорт принимает ключ
         * и печатает значения, как сайт. id поля → текст; сбой — пустой объект (не бросает).
         */
        public async Json.Object custom_field_labels (int issue_id, GenericArray<Json.Object> fields) {
            var ids = new GenericArray<Json.Object> ();
            foreach (var f in fields) if (cf_id_like (f)) ids.add (f);
            if (ids.length == 0) return new Json.Object ();
            var q = new Query ().add ("issue_id", issue_id.to_string ()).add ("status_id", "*").add ("encoding", "UTF-8");
            foreach (var f in ids) q.add ("c[]", "cf_%d".printf (jint (f, "id")));
            try {
                return cf_labels_from_csv (parse_csv (yield exec ("GET", url ("issues.csv", q), null)), ids);
            } catch (Error e) {
                debug ("cf labels: %s", e.message);
                return new Json.Object ();
            }
        }

        /** Номера всех задач серверного избранного (любой статус), все страницы. */
        public async GenericSet<int> favourite_ids () throws Error {
            var res = new GenericSet<int> (direct_hash, direct_equal);
            var q = new IssueQuery () { favourite = true, status = "*", sort = "id:desc", limit = 100 };
            // ponytail: потолок 2000 задач (20 запросов)
            for (int n = 0; n < 20; n++) {
                var page = yield issues (q);
                foreach (var i in page.issues) res.add (i.id);
                q.offset += page.issues.length;
                if (page.issues.length == 0 || q.offset >= page.total) break;
            }
            return res;
        }

        /** Задачи по id пачками по 100, в порядке запроса; недоступные/удалённые — в missing. */
        public async GenericArray<Issue> issues_by_ids (int[] ids, out int[] missing) throws Error {
            var found = new HashTable<int, Issue> (direct_hash, direct_equal);
            for (int i = 0; i < ids.length; i += 100) {
                var parts = new GenericArray<string> ();
                for (int j = i; j < int.min (i + 100, ids.length); j++) parts.add (ids[j].to_string ());
                var o = yield get_obj ("issues.json", new Query ()
                    .add ("issue_id", string.joinv (",", parts.data)).add ("status_id", "*").add ("limit", "100"));
                foreach (var x in jarr (o, "issues")) found[jint (x, "id")] = new Issue (x);
            }
            var res = new GenericArray<Issue> ();
            int[] miss = {};
            foreach (var id in ids) {
                if (found.contains (id)) res.add (found[id]); else miss += id;
            }
            missing = miss;
            return res;
        }

        public async Issue issue (int id, Cancellable? c = null) throws Error {
            var o = yield get_obj ("issues/%d.json".printf (id),
                new Query ().add ("include", "children,relations,journals,attachments,allowed_statuses,watchers"), c);
            return new Issue (jobj (o, "issue"));
        }

        /** Журналы и вложения (картинка уведомления — по ним). */
        public async Issue issue_journals (int id) throws Error {
            var o = yield get_obj ("issues/%d.json".printf (id), new Query ().add ("include", "journals,attachments"));
            return new Issue (jobj (o, "issue"));
        }

        /**
         * Задачи, созданные не раньше created_since в проектах, где я участник.
         * Полная форма фильтра: короткое project_id=mine сервер принял бы за идентификатор проекта (404).
         */
        public async IssueChunk new_issues_in_my_projects (string created_since, int offset) throws Error {
            return page_of (yield get_obj ("issues.json", new Query ()
                .add ("set_filter", "1")
                .add ("f[]", "project_id").add ("op[project_id]", "=").add ("v[project_id][]", "mine")
                .add ("f[]", "created_on").add ("op[created_on]", ">=").add ("v[created_on][]", created_since)
                .add ("sort", "id:desc").add ("limit", "100").add ("offset", offset.to_string ())));
        }

        /**
         * Задачи любого статуса, изменённые не раньше updated_since (ISO, целые секунды, Z — иначе 422),
         * в комментариях которых есть «@login»: search.json комментарии не индексирует, а этот фильтр их читает.
         */
        public async IssueChunk issues_mentioning (string login, string updated_since, int offset = 0) throws Error {
            return page_of (yield get_obj ("issues.json", new Query ()
                .add ("set_filter", "1")
                .add ("f[]", "notes").add ("op[notes]", "~").add ("v[notes][]", "@" + login)
                .add ("f[]", "updated_on").add ("op[updated_on]", ">=").add ("v[updated_on][]", updated_since)
                .add ("status_id", "*")
                .add ("sort", "updated_on:desc").add ("limit", "100").add ("offset", offset.to_string ())));
        }

        /** PUT задачи готовым объектом полей (status_id, notes, private_notes, uploads, custom_fields…). */
        public async void update_issue (int id, Json.Object fields) throws Error {
            var p = new Json.Object ();
            p.set_object_member ("issue", fields);
            yield send ("PUT", "issues/%d.json".printf (id), p);
        }

        public static Json.Array uploads_json (GenericArray<UploadRef> uploads) {
            var a = new Json.Array ();
            foreach (var u in uploads) {
                var o = new Json.Object ();
                o.set_string_member ("token", u.token);
                o.set_string_member ("filename", u.filename);
                if (u.content_type != null) o.set_string_member ("content_type", u.content_type);
                if (u.description != null && u.description.strip () != "") o.set_string_member ("description", u.description);
                a.add_object_element (o);
            }
            return a;
        }

        public async Issue create_issue (Json.Object fields) throws Error {
            var p = new Json.Object ();
            p.set_object_member ("issue", fields);
            var n = json_parse (yield send ("POST", "issues.json", p));
            if (n == null || n.get_node_type () != Json.NodeType.OBJECT) throw http_error (200, _("Unexpected response from server"));
            return new Issue (jobj (n.get_object (), "issue"));
        }

        /**
         * Выбор задачи по тому, что помнит человек: номер (можно с #) — эта задача первой, если видна;
         * плюс задачи с этим текстом в теме, в любом статусе, свежие первыми.
         */
        public async GenericArray<Issue> find_issues (string query, int limit = 20) throws Error {
            var res = new GenericArray<Issue> ();
            var q = query.strip ();
            if (q == "") return res;
            var bare = q.has_prefix ("#") ? q.substring (1).strip () : q;
            int id = 0;
            if (int.try_parse (bare, out id) && id > 0) {
                try {
                    res.add (new Issue (jobj (yield get_obj ("issues/%d.json".printf (id)), "issue")));
                } catch (Error e) {
                    if (error_code (e) != 404 && error_code (e) != 403) throw e;
                }
            }
            var iq = new IssueQuery ();
            iq.subject = id > 0 ? bare : q;
            iq.status = "*";
            iq.limit = limit;
            foreach (var i in (yield issues (iq)).issues) {
                bool dup = false;
                foreach (var x in res) if (x.id == i.id) dup = true;
                if (!dup) res.add (i);
            }
            return res;
        }

        // ---------- наблюдатели ----------
        public bool watchers_forbidden (int issue_id) { return watchers_forbidden_in.contains (issue_id); }

        public async void set_watcher (int issue_id, int user_id, bool on) throws Error {
            try {
                if (on) {
                    var p = new Json.Object ();
                    p.set_int_member ("user_id", user_id);
                    yield send ("POST", "issues/%d/watchers.json".printf (issue_id), p);
                } else {
                    yield delete ("issues/%d/watchers/%d.json".printf (issue_id, user_id));
                }
            } catch (Error e) {
                if (error_code (e) == 403) watchers_forbidden_in.add (issue_id);
                throw e;
            }
        }

        // ---------- журналы ----------
        /** Правка своего комментария; пустой notes удаляет его (журнал без изменений полей исчезает целиком). */
        public async void update_journal (int id, string notes, bool? private_notes = null) throws Error {
            var j = new Json.Object ();
            j.set_string_member ("notes", notes);
            if (private_notes != null) j.set_boolean_member ("private_notes", private_notes);
            var p = new Json.Object ();
            p.set_object_member ("journal", j);
            yield send ("PUT", "journals/%d.json".printf (id), p);
        }

        // ---------- связи ----------
        /** type — с точки зрения issue_id (relates, blocks, blocked, precedes, follows, …); delay — дни, только precedes/follows. */
        public async void add_relation (int issue_id, string type, int issue_to_id, int delay = -1) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("relation_type", type);
            r.set_int_member ("issue_to_id", issue_to_id);
            if (delay >= 0) r.set_int_member ("delay", delay);
            var p = new Json.Object ();
            p.set_object_member ("relation", r);
            yield send ("POST", "issues/%d/relations.json".printf (issue_id), p);
        }

        public async void delete_relation (int id) throws Error { yield delete ("relations/%d.json".printf (id)); }

        // ---------- время ----------
        public async GenericArray<Json.Object> time_entries (int issue_id) throws Error {
            var all = new GenericArray<Json.Object> ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            int offset = 0;
            while (true) {
                var page = yield get_obj ("time_entries.json", new Query ()
                    .add ("issue_id", issue_id.to_string ()).add ("limit", "100").add ("offset", offset.to_string ()));
                var items = jarr (page, "time_entries");
                offset += items.length;
                // запись, съехавшая на соседнюю страницу, приходит дважды
                foreach (var t in items) if (!seen.contains (jint (t, "id"))) { seen.add (jint (t, "id")); all.add (t); }
                if (items.length == 0 || offset >= jint (page, "total_count")) break;
                // ponytail: потолок 5000 записей на задачу (50 запросов); дальше — обрезаем
                if (offset >= 5000) { warning ("issue time entries cut at %d", offset); break; }
            }
            return all;
        }

        /** Списания времени с даты (все видимые проекты), свежесозданные первыми — до границы окна. */
        public async GenericArray<Json.Object> time_entries_from (string from, int64 created_after_ms) throws Error {
            var all = new GenericArray<Json.Object> ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            int offset = 0;
            while (true) {
                var page = yield get_obj ("time_entries.json", new Query ()
                    .add ("from", from).add ("sort", "created_on:desc").add ("limit", "100").add ("offset", offset.to_string ()));
                var items = jarr (page, "time_entries");
                offset += items.length;
                foreach (var t in items) if (!seen.contains (jint (t, "id"))) { seen.add (jint (t, "id")); all.add (t); }
                int64 oldest = items.length > 0 ? parse_iso_ms (jstr (items[items.length - 1], "created_on")) : 0;
                if (items.length == 0 || offset >= jint (page, "total_count") || (oldest > 0 && oldest <= created_after_ms)) break;
                // ponytail: страховка от сервера, игнорирующего sort, — 3000 записей
                if (offset >= 3000) { warning ("time entries cut at %d", offset); break; }
            }
            return all;
        }

        public async void save_time (int entry_id, int issue_id, double hours, int activity_id, string comments, string? spent_on) throws Error {
            var t = new Json.Object ();
            if (entry_id == 0) t.set_int_member ("issue_id", issue_id);
            t.set_double_member ("hours", hours);
            t.set_string_member ("comments", comments);
            if (activity_id > 0) t.set_int_member ("activity_id", activity_id);
            if (spent_on != null) t.set_string_member ("spent_on", spent_on);
            var p = new Json.Object ();
            p.set_object_member ("time_entry", t);
            if (entry_id == 0) yield send ("POST", "time_entries.json", p);
            else yield send ("PUT", "time_entries/%d.json".printf (entry_id), p);
        }

        public async void delete_time (int id) throws Error { yield delete ("time_entries/%d.json".printf (id)); }

        // ---------- поиск ----------
        /** Страница поиска по задачам; total — сколько всего нашлось (для «загрузить ещё»). */
        public async Json.Object search_page (string q, int offset = 0, int limit = 30) throws Error {
            return yield get_obj ("search.json", new Query ().add ("q", q).add ("issues", "1")
                .add ("limit", limit.to_string ()).add ("offset", offset.to_string ()));
        }

        // ---------- люди ----------
        /** Поиск по всем сотрудникам (плагин People): по НАЧАЛУ фамилии/имени/логина, без учёта регистра. */
        public async GenericArray<Json.Object> search_people (string q, int limit = 8) throws Error {
            return jarr (yield get_obj ("people.json", new Query ().add ("search", q).add ("limit", limit.to_string ())), "people");
        }

        /** Профиль: плагин People (должность/отдел) → /users/:id. */
        public async Json.Object person (int user_id) throws Error {
            try {
                return jobj (yield get_obj ("people/%d.json".printf (user_id)), "person");
            } catch (Error e) {
                if (error_code (e) != 404 && error_code (e) != 403) throw e;
                return jobj (yield get_obj ("users/%d.json".printf (user_id)), "user");
            }
        }

        /** /users/:id открыт и не-админу: логин, created_on, last_login_on. */
        public async Json.Object user (int user_id) throws Error {
            return jobj (yield get_obj ("users/%d.json".printf (user_id)), "user");
        }

        // ---------- файлы ----------
        /** Скачивает содержимое (вложения) с авторизацией ключом. */
        public async Bytes download (string u, Cancellable? c = null) throws Error {
            var r = yield raw ("GET", own (u), "*/*", null, null, false, c);
            var b = r.body;
            if (r.code < 200 || r.code >= 300) throw http_error ((int) r.code, "HTTP %u".printf (r.code));
            var ct = r.headers.get_content_type (null);
            // повторы WAF исчерпаны: страница проверки вместо файла — это сбой, а не файл
            if (ct != null && ct.contains ("html") && r.headers.get_one ("X-Request-Id") == null && !u.has_suffix (".html"))
                throw http_error (200, _("Unexpected response from server"));
            return b;
        }

        /**
         * GET с Range (spec 4.1): 206 — пришёл кусок; 200 (сервер Range не умеет) — всё тело, если оно не длиннее max,
         * иначе соединение рвётся сразу (отмена и закрытие потока — libsoup дальше не качает) и null; max = 0 — рвать любое 200.
         */
        public async Bytes? get_range (string u, string range, int64 max, out uint status) throws Error {
            status = 0;
            if (demo) {
                // демо Range не умеет — всё тело, как сервер без Range
                var d = DemoServer.handle ("GET", own (u), null);
                status = d.code;
                if (d.code != 200) throw http_error ((int) d.code, "range: HTTP %u".printf (d.code));
                return max > 0 && d.body.get_size () <= max ? d.body : null;
            }
            var c = new Cancellable ();
            var msg = new Soup.Message ("GET", own (u));
            if (msg == null) throw http_error (0, _("Bad address: %s").printf (u));
            msg.flags |= Soup.MessageFlags.NO_REDIRECT;
            var h = msg.request_headers;
            h.replace ("Accept", "*/*");
            h.replace ("Range", range);
            if (key_allowed (base_uri, msg.get_uri ())) h.replace ("X-Redmine-API-Key", api_key);
            InputStream body;
            try {
                body = yield session.send_async (msg, Priority.LOW, c);
            } catch (Error e) {
                throw http_error (0, e.message);
            }
            status = msg.status_code;
            var ct = msg.response_headers.get_content_type (null);
            bool waf = waf_challenge ("application/json", status, ct, msg.response_headers.get_one ("X-Request-Id"));
            bool whole = status == 200 && !waf;
            if ((status != 206 && !whole) || (whole && (max <= 0 || msg.response_headers.get_content_length () > max))) {
                c.cancel ();
                try { body.close (); } catch (Error e) {}
                if (waf || status < 200 || status >= 300) throw http_error ((int) status, "range: HTTP %u".printf (status));
                return null;
            }
            var out = new MemoryOutputStream.resizable ();
            var buf = new uint8[65536];
            int64 total = 0;
            while (true) {
                var n = yield body.read_async (buf, Priority.LOW, c);
                if (n <= 0) break;
                total += n;
                // длины в заголовке не было, а тело всё идёт — рвём так же
                if (whole && total > max) {
                    c.cancel ();
                    try { body.close (); } catch (Error e) {}
                    return null;
                }
                out.write_all (buf[0:n], null);
            }
            yield body.close_async ();
            out.close ();
            return out.steal_as_bytes ();
        }

        /** HTML-страница сайта с Basic «ключ:x» (ключ в заголовке такие страницы не принимают); страница WAF без заголовка Rails — повтор. */
        private async Resp html_page (string path, Cancellable? c = null) throws Error {
            for (int attempt = 0; ; attempt++) {
                var r = yield raw ("GET", url (path), "text/html", null, null, true, c);
                if (r.code == 200 && r.headers.get_one ("X-Request-Id") == null && attempt < WAF_RETRIES) {
                    yield sleep_ms (300 * (attempt + 1));
                    continue;
                }
                return r;
            }
        }

        /** HTML страницы задачи (листы согласования, spec 10). */
        public async string issue_html (int id, Cancellable? c = null) throws Error {
            var r = yield html_page ("issues/%d".printf (id), c);
            var code = r.code;
            if (code != 200) throw http_error ((int) code, "issue page: HTTP %u".printf (code));
            return r.text ();
        }

        /** HTML страницы задач проекта (0 — всех задач): каталог фильтров, spec 17.1. */
        public async string issues_page_html (int project_id) throws Error {
            var r = yield html_page (project_id > 0 ? "projects/%d/issues".printf (project_id) : "issues");
            if (r.code != 200) throw http_error ((int) r.code, "issues page: HTTP %u".printf (r.code));
            return r.text ();
        }

        /** Сохранённые запросы сервера, все страницы (spec 17.4). */
        public async GenericArray<Json.Object> server_queries () throws Error {
            var all = new GenericArray<Json.Object> ();
            // ponytail: потолок 1000 запросов (10 страниц)
            for (int offset = 0; offset < 1000; ) {
                var page = yield get_obj ("queries.json", new Query ().add ("limit", "100").add ("offset", offset.to_string ()));
                var items = jarr (page, "queries");
                foreach (var x in items) all.add (x);
                offset += items.length;
                if (items.length == 0 || offset >= jint (page, "total_count")) break;
            }
            return all;
        }

        /** Роли сервера {id, name} — видимость запроса «ролям». */
        public async GenericArray<Json.Object> roles () throws Error {
            return jarr (yield get_obj ("roles.json"), "roles");
        }

        /** Страница /people/:id (аватар, телефоны — spec 11); null — профиля нет или он закрыт. */
        public async string? people_page (int user_id, Cancellable? c = null) throws Error {
            var r = yield html_page ("people/%d".printf (user_id), c);
            var code = r.code;
            if (code == 404 || code == 401 || code == 403) return null;
            if (code < 200 || code >= 300) throw http_error ((int) code, "people: HTTP %u".printf (code));
            return r.text ();
        }

        /** Миниатюра вложения; null — определённое «нет» (не картинка, нет прав). */
        public async Bytes? thumbnail (int attachment_id, int size = 200, Cancellable? c = null) throws Error {
            var r = yield raw ("GET", url ("attachments/thumbnail/%d/%d".printf (attachment_id, size)), "image/*", null, null, false, c);
            var b = r.body;
            var ct = r.headers.get_content_type (null) ?? "";
            var code = r.code;
            if (code >= 200 && code < 300 && ct.has_prefix ("image/")) return b;
            if (code >= 200 && code < 300 && ct.contains ("html")) throw http_error (200, _("Unexpected response from server"));
            if ((code >= 200 && code < 300) || code == 404 || code == 403 || code == 406) return null;
            throw http_error ((int) code, "thumbnail: HTTP %u".printf (code));
        }

        public async void delete_attachment (int id) throws Error { yield delete ("attachments/%d.json".printf (id)); }

        /** Загрузка файла: POST /uploads.json → токен. Redmine принимает только octet-stream (иначе 406). */
        public async UploadRef upload (Bytes data, string filename, string? content_type) throws Error {
            var r = yield raw ("POST", url ("uploads.json", new Query ().add ("filename", filename)), "application/json",
                data, "application/octet-stream");
            var text = r.text ();
            if (r.code < 200 || r.code >= 300) throw http_error ((int) r.code, "upload: HTTP %u".printf (r.code));
            var n = json_parse (text);
            var token = n != null && n.get_node_type () == Json.NodeType.OBJECT ? jstr (jobj (n.get_object (), "upload"), "token") : "";
            if (token == "") throw http_error (200, _("Unexpected response from server"));
            return new UploadRef (token, filename, content_type);
        }

        /** Аватар: страница /people/:id (HTML, Basic «ключ:x») → id вложения → картинка. null — фото нет. */
        public async Bytes? avatar (int user_id, Cancellable? c = null) throws Error {
            var html = yield people_page (user_id, c);
            return html != null ? yield avatar_from_page (html, c) : null;
        }

        /** Фото со страницы человека: id вложения аватара → картинка; null — фото нет. */
        public async Bytes? avatar_from_page (string html, Cancellable? c = null) throws Error {
            MatchInfo mi;
            if (!/class="avatar"[\s\S]{0,500}?href="[^"]*?\/attachments\/(\d+)"/.match (html, 0, out mi)) return null;
            var att_id = int.parse (mi.fetch (1));
            string content_url;
            try {
                content_url = jstr (jobj (yield get_obj ("attachments/%d.json".printf (att_id), null, c), "attachment"), "content_url");
            } catch (Error e) {
                if (error_code (e) == 404 || error_code (e) == 403) return null;
                throw e;
            }
            if (content_url == "") return null;
            var img = yield raw ("GET", own (content_url), "image/*", null, null, false, c);
            var ct = img.headers.get_content_type (null) ?? "";
            if (img.code >= 200 && img.code < 300 && ct.has_prefix ("image/")) return img.body;
            return null;
        }
    }
}
