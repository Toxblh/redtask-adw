/*
 * Кэши: диск (~/.cache/redmine-adw/<учётка>/) + память. Справочники — с TTL, списки и задачи —
 * stale-while-revalidate: показываем сохранённое сразу, сеть обновляет фоном.
 */
namespace Redmine {


    public class DiskCache : Object {
        public string dir { get; private set; }
        private HashTable<string, Json.Node> mem = new HashTable<string, Json.Node> (str_hash, str_equal);
        private HashTable<string, int64?> mem_at = new HashTable<string, int64?> (str_hash, str_equal);

        /** Каталог привязан к учётке (сервер + пользователь): номера задач чужого сервера не смешиваются. */
        public DiskCache (string account) {
            var h = Checksum.compute_for_string (ChecksumType.SHA1, account).substring (0, 12);
            dir = Path.build_filename (Environment.get_user_cache_dir (), "redmine-adw", h);
            DirUtils.create_with_parents (dir, 0700);
        }

        private string path (string key) {
            return Path.build_filename (dir, key.replace ("/", "_") + ".json");
        }

        /** null — нет или старше ttl (0 — без срока). */
        public Json.Node? load (string key, int64 ttl = 0) {
            var at = mem_at[key];
            if (at != null && (ttl == 0 || now_ms () - at < ttl)) return mem[key];
            var p = path (key);
            string text;
            try {
                if (!FileUtils.get_contents (p, out text)) return null;
            } catch (Error e) {
                return null;
            }
            var f = File.new_for_path (p);
            int64 mtime = 0;
            try {
                var info = f.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                mtime = info.get_modification_date_time ().to_unix () * 1000;
            } catch (Error e) {}
            if (ttl > 0 && now_ms () - mtime >= ttl) return null;
            var n = json_parse (text);
            if (n == null) return null;
            mem[key] = n;
            mem_at[key] = mtime;
            return n;
        }

        public void save (string key, Json.Node n) {
            mem[key] = n;
            mem_at[key] = now_ms ();
            // не записалось (место на диске) — потеряем только мгновенный показ при следующем запуске
            try {
                FileUtils.set_contents (path (key), json_to_string (n));
            } catch (Error e) {
                warning ("cache save %s: %s", key, e.message);
            }
        }

        public void drop (string key) {
            mem.remove (key);
            mem_at.remove (key);
            FileUtils.unlink (path (key));
        }

        public Bytes? load_bytes (string key) {
            uint8[] data;
            try {
                if (FileUtils.get_data (Path.build_filename (dir, key), out data)) return new Bytes (data);
            } catch (Error e) {}
            return null;
        }

        public void save_bytes (string key, Bytes b) {
            try {
                FileUtils.set_data (Path.build_filename (dir, key), b.get_data ());
            } catch (Error e) {}
        }

        /** Выход: всё, что лежит под этой учёткой. */
        public void clear () {
            mem.remove_all ();
            mem_at.remove_all ();
            try {
                var d = Dir.open (dir);
                string? name;
                while ((name = d.read_name ()) != null) FileUtils.unlink (Path.build_filename (dir, name));
            } catch (Error e) {}
        }
    }

    public Json.Node arr_node (GenericArray<Json.Object> a) {
        var arr = new Json.Array ();
        foreach (var o in a) arr.add_object_element (o);
        var n = new Json.Node (Json.NodeType.ARRAY);
        n.set_array (arr);
        return n;
    }

    public GenericArray<Json.Object> node_arr (Json.Node? n) {
        var res = new GenericArray<Json.Object> ();
        if (n == null || n.get_node_type () != Json.NodeType.ARRAY) return res;
        n.get_array ().foreach_element ((a, i, e) => {
            if (e.get_node_type () == Json.NodeType.OBJECT) res.add (e.get_object ());
        });
        return res;
    }

    public Json.Node issues_node (GenericArray<Issue> a) {
        var arr = new Json.Array ();
        foreach (var i in a) arr.add_object_element (i.o);
        var n = new Json.Node (Json.NodeType.ARRAY);
        n.set_array (arr);
        return n;
    }

    public GenericArray<Issue> node_issues (Json.Node? n) {
        var res = new GenericArray<Issue> ();
        foreach (var o in node_arr (n)) res.add (new Issue (o));
        return res;
    }

    /**
     * Справочники: память → диск (TTL) → сеть. TTL: справочники и права 24 ч, проекты 7 дней, люди 24 ч.
     * ponytail: параллельные одинаковые запросы не склеиваются — бывает лишний запрос при первом открытии.
     */
    public class RefData : Object {
        private Client api;
        private DiskCache cache;

        public RefData (Client api, DiskCache cache) { this.api = api; this.cache = cache; }

        public async GenericArray<Json.Object> statuses () throws Error {
            var h = cache.load ("statuses", DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.statuses ();
            cache.save ("statuses", arr_node (a));
            return a;
        }

        public async GenericArray<Json.Object> priorities () throws Error {
            var h = cache.load ("priorities", DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.priorities ();
            cache.save ("priorities", arr_node (a));
            return a;
        }

        public async GenericArray<Json.Object> trackers () throws Error {
            var h = cache.load ("trackers", DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.trackers ();
            cache.save ("trackers", arr_node (a));
            return a;
        }

        public async GenericArray<Json.Object> activities () throws Error {
            var h = cache.load ("activities", DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.activities ();
            cache.save ("activities", arr_node (a));
            return a;
        }

        /** fresh — мимо кэша (кнопка «обновить» на экране проектов). */
        public async GenericArray<Json.Object> projects (bool fresh = false) throws Error {
            var h = fresh ? null : cache.load ("projects", 7 * DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.projects ();
            cache.save ("projects", arr_node (a));
            return a;
        }

        public GenericArray<Json.Object>? projects_cached () {
            var h = cache.load ("projects");
            return h != null ? node_arr (h) : null;
        }

        public async Json.Object project (int id) throws Error {
            var key = "project-%d".printf (id);
            var h = cache.load (key, DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) return h.get_object ();
            var p = yield api.project (id);
            cache.save (key, obj_node (p));
            return p;
        }

        public async GenericArray<Json.Object> versions (int pid) throws Error {
            var key = "versions-%d".printf (pid);
            var h = cache.load (key, DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.versions (pid);
            cache.save (key, arr_node (a));
            return a;
        }

        public async GenericArray<Json.Object> categories (int pid) throws Error {
            var key = "categories-%d".printf (pid);
            var h = cache.load (key, DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.issue_categories (pid);
            cache.save (key, arr_node (a));
            return a;
        }

        public async GenericArray<Named> members (int pid) throws Error {
            var key = "members-%d".printf (pid);
            var h = cache.load (key, DAY_MS);
            var res = new GenericArray<Named> ();
            if (h != null) {
                foreach (var o in node_arr (h)) res.add (Named.from (o));
                return res;
            }
            res = yield api.members (pid);
            var a = new GenericArray<Json.Object> ();
            foreach (var m in res) {
                var o = new Json.Object ();
                o.set_int_member ("id", m.id);
                o.set_string_member ("name", m.name);
                a.add (o);
            }
            cache.save (key, arr_node (a));
            return res;
        }

        public async GenericArray<Json.Object> custom_field_defs () throws Error {
            var h = cache.load ("custom-fields", DAY_MS);
            if (h != null) return node_arr (h);
            var a = yield api.custom_field_defs ();
            cache.save ("custom-fields", arr_node (a));
            return a;
        }

        /**
         * Мои права в проекте — объединение прав моих ролей; «*» — администратор.
         * null — сервер их не сообщил (роли закрыты): действия тогда судятся по прежнему поведению.
         */
        public async GenericSet<string>? permissions (int project_id) throws Error {
            Json.Object roles;
            var h = cache.load ("my-roles", DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) roles = h.get_object ();
            else {
                roles = yield api.my_roles ();
                cache.save ("my-roles", obj_node (roles));
            }
            var res = new GenericSet<string> (str_hash, str_equal);
            if (jbool (roles, "admin")) { res.add ("*"); return res; }
            var rm = jobj (roles, "roles");
            var key = project_id.to_string ();
            // не участник (права «не участника» и публичных проектов REST не отдаёт): неизвестно — вызывающий остаётся оптимистом
            if (rm == null || !rm.has_member (key)) return null;
            var ids = rm.get_array_member (key);
            for (uint i = 0; i < ids.get_length (); i++) {
                var rid = (int) ids.get_int_element (i);
                var rk = "role-%d".printf (rid);
                var rh = cache.load (rk, DAY_MS);
                Json.Array perms;
                if (rh != null && rh.get_node_type () == Json.NodeType.ARRAY) perms = rh.get_array ();
                else {
                    try {
                        perms = yield api.role_permissions (rid);
                    } catch (Error e) {
                        if (error_code (e) == 403 || error_code (e) == 404) return null;
                        throw e;
                    }
                    var n = new Json.Node (Json.NodeType.ARRAY);
                    n.set_array (perms);
                    cache.save (rk, n);
                }
                perms.foreach_element ((a, j, e) => res.add (e.get_string ()));
            }
            return res;
        }

        public async Json.Object person (int id) throws Error {
            var key = "person-%d".printf (id);
            var h = cache.load (key, DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) return h.get_object ();
            var p = yield api.person (id);
            cache.save (key, obj_node (p));
            return p;
        }

        /** login → человек (id, имя); null — такого нет или поиск людей закрыт. Отказы помним 10 минут. */
        public async Json.Object? person_by_login (string login) {
            var l = login.strip ().down ();
            if (l == "") return null;
            var key = "login-" + l;
            var h = cache.load (key, DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) {
                var o = h.get_object ();
                if (jint (o, "id") > 0) return o;
                if (now_ms () - jint (o, "at") * (int64) 1000 < 10 * 60 * 1000) return null;
            }
            try {
                // с запасом: по началу «iv» сервер вернёт и Ивановых — нужный логин не должен выпасть за лимит
                foreach (var p in yield api.search_people (l, 100)) {
                    if (jstr (p, "login").down () == l) {
                        cache.save (key, obj_node (p));
                        return p;
                    }
                }
                var miss = new Json.Object ();
                miss.set_int_member ("id", 0);
                miss.set_int_member ("at", now_ms () / 1000);
                cache.save (key, obj_node (miss));
            } catch (Error e) {}
            return null;
        }
    }
}
