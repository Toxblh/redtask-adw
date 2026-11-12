namespace Redmine {

    /**
     * Свои запросы, недавние фильтры и избранные запросы (spec 17) — данные учётки на устройстве: ключи «queries-*»
     * в DiskCache (очистка кэша их не трогает, выход стирает). Серверные запросы — queries.json, кэш «server-queries».
     *
     * Свой запрос: {local_id, name, description, project_id (или null — для всех проектов), origin (проект, где создан),
     * filters, sort, visibility, role_ids, server_id (0 — нет), state: local|sending|server, reason, no_auto, pushed_at}.
     * Условие: {field, op, values[], name, op_label, text} — последние три только для показа.
     * Избранное: {key, kind: local|server|recent, name, project_id, local_id | server_id | filters+sort}.
     */
    public class Queries : Object {
        private static Queries? _inst;
        public static Queries get_default () {
            if (_inst == null) _inst = new Queries ();
            return _inst;
        }

        public signal void changed ();

        public GenericArray<Json.Object> local = new GenericArray<Json.Object> ();
        public GenericArray<Json.Object> recent = new GenericArray<Json.Object> ();
        public GenericArray<Json.Object> favs = new GenericArray<Json.Object> ();
        public GenericArray<Json.Object> server = new GenericArray<Json.Object> ();
        private Session? owner = null;
        /** Свои, которые в этой сессии уже сами пробовали отправить (повтор без кнопки — раз на запрос). */
        private GenericSet<int> tried = new GenericSet<int> (direct_hash, direct_equal);

        public void attach (Session? s) {
            owner = s;
            tried.remove_all ();
            local = s != null ? node_arr (s.cache.load ("queries-local")) : new GenericArray<Json.Object> ();
            recent = s != null ? node_arr (s.cache.load ("queries-recent")) : new GenericArray<Json.Object> ();
            favs = s != null ? node_arr (s.cache.load ("queries-favs")) : new GenericArray<Json.Object> ();
            server = s != null ? node_arr (s.cache.load ("server-queries")) : new GenericArray<Json.Object> ();
            // отправка, прерванная выходом из приложения, — снова «только на устройстве»
            foreach (var q in local) if (jstr (q, "state") == "sending") q.set_string_member ("state", "local");
            changed ();
        }

        private void store () {
            var s = owner;
            if (s == null) return;
            s.cache.save ("queries-local", arr_node (local));
            s.cache.save ("queries-recent", arr_node (recent));
            s.cache.save ("queries-favs", arr_node (favs));
            changed ();
        }

        public static string summary (Json.Array filters) {
            var parts = new GenericArray<string> ();
            foreach (var n in filters.get_elements ()) {
                var f = n.get_object ();
                var t = "%s %s".printf (jstr (f, "name", jstr (f, "field")), jstr (f, "op_label", jstr (f, "op")));
                if (jstr (f, "text") != "") t += " " + jstr (f, "text");
                parts.add (t);
            }
            return parts.length > 0 ? string.joinv ("; ", parts.data) : _("All issues");
        }

        private static Json.Array copy_arr (Json.Array a) { return json_parse (json_to_string (arr_of (a))).get_array (); }
        private static Json.Node arr_of (Json.Array a) { var n = new Json.Node (Json.NodeType.ARRAY); n.set_array (a); return n; }

        // ---- недавние фильтры (17.2) ----

        public static string recent_key (int pid, Json.Array filters, Json.Array sort) {
            return "r:%d:%s".printf (pid, filter_params (filters, sort).encode ());
        }

        /** Применённый фильтр — первым; одинаковые по параметрам схлопываются, не больше 10. */
        public void remember (int pid, Json.Array filters, Json.Array sort) {
            var key = recent_key (pid, filters, sort);
            var o = new Json.Object ();
            o.set_string_member ("key", key);
            o.set_int_member ("project_id", pid);
            o.set_array_member ("filters", copy_arr (filters));
            o.set_array_member ("sort", copy_arr (sort));
            var res = new GenericArray<Json.Object> ();
            res.add (o);
            foreach (var r in recent) if (jstr (r, "key") != key && res.length < 10) res.add (r);
            recent = res;
            store ();
        }

        // ---- избранные (17.5) ----

        public bool is_fav (string key) {
            foreach (var f in favs) if (jstr (f, "key") == key) return true;
            return false;
        }

        public static string key_of (Json.Object q) {
            if (q.has_member ("key")) return jstr (q, "key"); // избранное и недавний
            if (q.has_member ("local_id")) return "l:%d".printf (jint (q, "local_id"));
            return "s:%d".printf (jint (q, "id"));
        }

        /** Звезда у своего, серверного или недавнего. */
        public void set_fav (Json.Object q, bool on) {
            var key = key_of (q);
            for (int k = (int) favs.length - 1; k >= 0; k--) if (jstr (favs[k], "key") == key) favs.remove_index (k);
            if (on) {
                var f = new Json.Object ();
                f.set_string_member ("key", key);
                if (q.has_member ("local_id")) {
                    f.set_string_member ("kind", "local");
                    f.set_int_member ("local_id", jint (q, "local_id"));
                } else if (q.has_member ("filters")) {
                    f.set_string_member ("kind", "recent");
                    f.set_int_member ("project_id", jint (q, "project_id"));
                    f.set_array_member ("filters", copy_arr (q.get_array_member ("filters")));
                    f.set_array_member ("sort", copy_arr (q.get_array_member ("sort")));
                } else {
                    f.set_string_member ("kind", "server");
                    f.set_int_member ("server_id", jint (q, "id"));
                    f.set_string_member ("name", jstr (q, "name"));
                    f.set_int_member ("project_id", jint (q, "project_id"));
                }
                favs.add (f);
            }
            store ();
        }

        /** Перетаскивание: избранное from встаёт на место to. */
        public void move_fav (int from, int to) {
            if (from == to || from < 0 || to < 0 || from >= favs.length || to >= favs.length) return;
            var f = favs[from];
            favs.remove_index (from);
            favs.insert (to, f);
            store ();
        }

        public Json.Object? local_by_id (int id) {
            foreach (var q in local) if (jint (q, "local_id") == id) return q;
            return null;
        }

        /** Имя для показа: свой — его имя (с сервера, если там есть), серверный — имя, недавний — условия кратко. */
        public string title_of (Json.Object q) {
            var kind = jstr (q, "kind");
            if (q.has_member ("local_id") || kind == "local") {
                var l = local_by_id (jint (q, "local_id"));
                if (l == null) return "";
                foreach (var x in server) if (jint (l, "server_id") > 0 && jint (x, "id") == jint (l, "server_id")) return jstr (x, "name");
                return jstr (l, "name");
            }
            if (q.has_member ("filters")) return summary (q.get_array_member ("filters"));
            return jstr (q, "name");
        }

        /** Что запускать: параметры своего/недавнего или query_id серверного; ctx — проект, где открыли (0 — нигде). */
        public IssueQuery? issue_query (Json.Object q, int ctx) {
            var iq = new IssueQuery ();
            var kind = jstr (q, "kind");
            if (q.has_member ("local_id") || kind == "local") {
                var l = local_by_id (jint (q, "local_id"));
                if (l == null) return null;
                iq.params = filter_params (l.get_array_member ("filters"), l.get_array_member ("sort"));
                iq.project_id = jint (l, "project_id") > 0 ? jint (l, "project_id") : ctx;
            } else if (q.has_member ("filters")) {
                iq.params = filter_params (q.get_array_member ("filters"), q.get_array_member ("sort"));
                iq.project_id = jint (q, "project_id");
            } else {
                iq.query_id = jint (q, kind == "server" ? "server_id" : "id");
                iq.project_id = jint (q, "project_id") > 0 ? jint (q, "project_id") : ctx;
            }
            return iq;
        }

        // ---- свои и серверные (17.3, 17.4) ----

        private static bool visible_in (int query_pid, int pid) { return pid == 0 || query_pid == 0 || query_pid == pid; }

        /** Группы экрана запросов проекта pid (0 — все): «Мои» — свои и личные серверные, «Общие» — остальные серверные. */
        public void groups (int pid, out GenericArray<Json.Object> mine, out GenericArray<Json.Object> shared) {
            mine = new GenericArray<Json.Object> ();
            shared = new GenericArray<Json.Object> ();
            var copies = new GenericSet<int> (direct_hash, direct_equal);
            foreach (var l in local) {
                if (jint (l, "server_id") > 0) copies.add (jint (l, "server_id"));
                if (visible_in (jint (l, "project_id"), pid)) mine.add (l);
            }
            foreach (var x in server) {
                if (copies.contains (jint (x, "id")) || !visible_in (jint (x, "project_id"), pid)) continue;
                if (jbool (x, "is_public")) shared.add (x); else mine.add (x);
            }
        }

        /** queries.json: свои, удалённые на сайте, теряют server_id («только на устройстве», сами не пересоздаются). */
        public async void refresh_server () throws Error {
            var s = owner;
            if (s == null) return;
            var started = now_ms ();
            var got = yield s.api.server_queries ();
            if (s != owner) return;
            server = got;
            s.cache.save ("server-queries", arr_node (got));
            var ids = new GenericSet<int> (direct_hash, direct_equal);
            foreach (var x in got) ids.add (jint (x, "id"));
            foreach (var l in local) {
                var sid = jint (l, "server_id");
                if (sid == 0 || ids.contains (sid) || l.get_int_member_with_default ("pushed_at", 0) >= started) continue;
                l.set_int_member ("server_id", 0);
                l.set_string_member ("state", "local");
                l.set_string_member ("reason", _("Deleted on the website"));
                l.set_boolean_member ("no_auto", true);
            }
            for (int k = (int) favs.length - 1; k >= 0; k--)
                if (jstr (favs[k], "kind") == "server" && !ids.contains (jint (favs[k], "server_id"))) favs.remove_index (k);
            store ();
        }

        /** Шаг 1 — у себя (новый или правка existing), шаг 2 — на сервер (push, вызывает сам). */
        public Json.Object save (Json.Object? existing, int pid, string name, string description, int visibility, int[] role_ids,
                                 bool for_all, Json.Array filters, Json.Array sort) {
            var q = existing;
            if (q == null) {
                int next = 1;
                foreach (var l in local) next = int.max (next, jint (l, "local_id") + 1);
                q = new Json.Object ();
                q.set_int_member ("local_id", next);
                q.set_int_member ("server_id", 0);
                q.set_int_member ("origin", pid);
                local.insert (0, q);
            }
            q.set_string_member ("name", name);
            q.set_string_member ("description", description);
            q.set_int_member ("project_id", for_all ? 0 : jint (q, "origin"));
            q.set_int_member ("visibility", visibility);
            var roles = new Json.Array ();
            foreach (var r in role_ids) roles.add_int_element (r);
            q.set_array_member ("role_ids", roles);
            q.set_array_member ("filters", copy_arr (filters));
            q.set_array_member ("sort", copy_arr (sort));
            q.set_string_member ("state", "local");
            q.set_string_member ("reason", "");
            q.set_boolean_member ("no_auto", false);
            store ();
            return q;
        }

        /** Почему не на сервере — для пометки «Только на устройстве». */
        public static string reason_of (Error e) {
            var c = error_code (e);
            if (c == 401) return _("Sign in through the website");
            if (c == 0 || (c == 200 && WafGate.get_default ().blocked) || e.message.contains ("captcha")) return _("No connection");
            return e.message;
        }

        /** Шаг 2: веб-формой сайта. null — на сервере; иначе ошибка (пометка и причина уже записаны). */
        public async Error? push (Json.Object q) {
            var s = owner;
            if (s == null || jstr (q, "state") == "sending") return null;
            q.set_string_member ("state", "sending");
            changed ();
            var roles = new GenericArray<int> ();
            foreach (var n in q.get_array_member ("role_ids").get_elements ()) roles.add ((int) n.get_int ());
            var fields = query_form (jstr (q, "name"), jstr (q, "description"), jint (q, "visibility"), roles.data,
                jint (q, "project_id") == 0, q.get_array_member ("filters"), q.get_array_member ("sort"));
            var origin = jint (q, "origin");
            Error? err = null;
            try {
                var id = yield web_save_query (s.server, origin > 0 ? origin.to_string () : null, jint (q, "server_id"), fields);
                q.set_int_member ("server_id", id);
                q.set_int_member ("pushed_at", now_ms ());
                q.set_string_member ("state", "server");
                q.set_string_member ("reason", "");
            } catch (Error e) {
                err = e;
                q.set_string_member ("state", "local");
                q.set_string_member ("reason", reason_of (e));
            }
            if (s != owner) return err;
            store ();
            if (err == null) {
                try { yield refresh_server (); } catch (Error e) { debug ("queries: %s", e.message); }
            }
            return err;
        }

        /** Сам, без кнопки: при открытии списка (раз в сессию на запрос) и после входа через сайт (force). */
        public void retry_pending (bool force) {
            foreach (var q in local) {
                var id = jint (q, "local_id");
                if (jint (q, "server_id") > 0 || jbool (q, "no_auto") || jstr (q, "state") == "sending" || (!force && tried.contains (id))) continue;
                tried.add (id);
                push.begin (q);
            }
        }

        /** Удаление: есть server_id — сначала на сайте (там уже нет — тоже успех); не вышло — бросает, у себя остаётся. */
        public async void remove (Json.Object q, bool device_only) throws Error {
            var s = owner;
            if (s == null) return;
            var sid = jint (q, "server_id");
            if (sid > 0 && !device_only) {
                try {
                    yield web_delete_query (s.server, sid);
                } catch (Error e) {
                    if (error_code (e) != 404) throw e;
                }
            }
            local.remove (q);
            var key = key_of (q);
            for (int k = (int) favs.length - 1; k >= 0; k--) if (jstr (favs[k], "key") == key) favs.remove_index (k);
            store ();
            if (sid > 0 && !device_only) {
                try { yield refresh_server (); } catch (Error e) { debug ("queries: %s", e.message); }
            }
        }
    }
}
