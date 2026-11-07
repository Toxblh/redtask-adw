/*
 * Кэши: диск (~/.cache/redtask/<учётка>/) + память. Справочники — с TTL, списки и задачи —
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
            dir = Path.build_filename (Environment.get_user_cache_dir (), "redtask", h);
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

        /**
         * Как load без срока, но чтение и разбор — в потоке: мегабайтный список проектов не замирает главный поток
         * (замер: 6 МБ — 140 мс). Уже в памяти — сразу.
         */
        public async Json.Node? load_async (string key) {
            if (mem_at[key] != null) return mem[key];
            var p = path (key);
            Json.Node? n = null;
            int64 mtime = 0;
            new Thread<void> ("cache", () => {
                string text;
                try {
                    if (FileUtils.get_contents (p, out text)) {
                        n = json_parse (text);
                        mtime = File.new_for_path (p).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE).get_modification_date_time ().to_unix () * 1000;
                    }
                } catch (Error e) {}
                Idle.add (load_async.callback);
            });
            yield;
            // пока читали, могли сохранить свежее — оно главнее
            if (mem_at[key] != null) return mem[key];
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

        // ---- кэш в настройках (spec 15): аватары, миниатюры, скачанные вложения, задачи и списки, справочники ----

        public const int KINDS = 5;
        private const int ANY = 99;

        /** Категория файла (или ключа) кэша; −1 — не кэш: избранное и недавние в поиске не считаем и не стираем. */
        private static int kind_of (string name) {
            if (name.has_prefix ("favorite-ids") || name.has_prefix ("recent-search")) return -1;
            if (name.has_prefix ("avatar-")) return 0;
            if (name.has_prefix ("thumb-") || name.has_prefix ("nothumb-") || name.has_prefix ("notif-thumb-")) return 1;
            if (name.has_prefix ("att-")) return 2;
            if (name.has_prefix ("issue-") || name.has_prefix ("list-") || name.has_prefix ("brief-")) return 3;
            return 4; // справочники, люди, права, словарь подписей (spec 14)
        }

        /** Документы, скачанные для открытия (open_attachment), — общий каталог учёток. */
        private static string open_dir () { return Path.build_filename (Environment.get_user_cache_dir (), "redtask", "open"); }

        /** Сумма размеров файлов категории kind под path (подкаталоги — целиком); del — заодно стереть. */
        private static int64 walk (string path, int kind, bool del) {
            int64 sum = 0;
            try {
                var d = Dir.open (path);
                string? name;
                while ((name = d.read_name ()) != null) {
                    var p = Path.build_filename (path, name);
                    if (FileUtils.test (p, FileTest.IS_DIR)) {
                        sum += walk (p, ANY, del);
                        if (del) DirUtils.remove (p);
                        continue;
                    }
                    if (kind != ANY && kind_of (name) != kind) continue;
                    try {
                        sum += File.new_for_path (p).query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size ();
                    } catch (Error e) {}
                    if (del) FileUtils.unlink (p);
                }
            } catch (Error e) {}
            return sum;
        }

        /** Размеры категорий на диске — в потоке. */
        public async int64[] sizes () {
            var res = new int64[KINDS];
            SourceFunc cb = sizes.callback;
            new Thread<void> ("cache-size", () => {
                for (int k = 0; k < KINDS; k++) res[k] = walk (dir, k, false);
                res[2] += walk (open_dir (), ANY, false);
                Idle.add ((owned) cb);
            });
            yield;
            return res;
        }

        /** Стереть категорию с диска (в потоке) и из памяти. */
        public async void clear_kind (int kind) {
            SourceFunc cb = clear_kind.callback;
            new Thread<void> ("cache-clear", () => {
                walk (dir, kind, true);
                if (kind == 2) walk (open_dir (), ANY, true);
                Idle.add ((owned) cb);
            });
            yield;
            mem.foreach_remove ((k, v) => kind_of (k) == kind);
            mem_at.foreach_remove ((k, v) => kind_of (k) == kind);
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
            // десятки страниц: второй вызывающий (прогрев при запуске и открытие раздела) ждёт первый, а не качает заново
            if (projects_busy) {
                var id = projects_done.connect (() => Idle.add (projects.callback));
                yield;
                disconnect (id);
                if (projects_error != null) throw projects_error;
                return node_arr (cache.load ("projects"));
            }
            projects_busy = true;
            projects_error = null;
            try {
                var a = yield api.projects ();
                cache.save ("projects", arr_node (a));
                return a;
            } catch (Error e) {
                projects_error = e;
                throw e;
            } finally {
                projects_busy = false;
                projects_done ();
            }
        }
        private bool projects_busy = false;
        private Error? projects_error = null;
        private signal void projects_done ();

        public async GenericArray<Json.Object>? projects_cached_async () {
            var h = yield cache.load_async ("projects");
            return h != null ? node_arr (h) : null;
        }

        /** Кэш проектов старше 7 дней (или его нет) — пора в сеть. */
        public bool projects_stale () { return cache.load ("projects", 7 * DAY_MS) == null; }

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

        /** Сохранённое любого возраста (показать сразу); fresh — моложе суток, сеть не нужна. */
        public Json.Object? cached (string key, out bool fresh) {
            var h = cache.load (key);
            fresh = h != null && cache.load (key, DAY_MS) != null;
            return h != null && h.get_node_type () == Json.NodeType.OBJECT ? h.get_object () : null;
        }

        /** Телефоны со страницы /people/:id (spec 11) — в кэш человека; страницу уже скачали ради аватара. */
        public void learn_phones (int id, string html) {
            var n = new Json.Node (Json.NodeType.ARRAY);
            n.set_array (people_phones (html));
            cache.save ("phones-%d".printf (id), n);
        }

        /** Сохранённые телефоны: null — страницу ещё не разбирали; fresh — моложе суток. */
        public Json.Array? phones_cached (int id, out bool fresh) {
            var h = cache.load ("phones-%d".printf (id));
            fresh = h != null && cache.load ("phones-%d".printf (id), DAY_MS) != null;
            return h != null && h.get_node_type () == Json.NodeType.ARRAY ? h.get_array () : null;
        }

        /** Телефоны с сервера: своя загрузка страницы, если аватар её не принёс. */
        public async Json.Array phones (int id) throws Error {
            var html = yield api.people_page (id);
            learn_phones (id, html ?? "");
            bool f;
            return phones_cached (id, out f) ?? new Json.Array ();
        }

        /**
         * Словарь подписей значений истории (spec 14): «attr:project_id:5539» → «Продукты». Без срока, до 5000 записей;
         * порядок членов объекта — порядок обновления, лишние снимаются с начала (самые давно обновлённые).
         */
        public string? label (string prop, string name, string value) {
            var h = cache.load ("labels");
            var k = "%s:%s:%s".printf (prop, name, value);
            return h != null && h.get_node_type () == Json.NodeType.OBJECT && h.get_object ().has_member (k) ? jstr (h.get_object (), k) : null;
        }

        /** Подписи из HTML задачи (journal_detail_labels) — в словарь; пишутся только attr с именем на _id и cf. */
        public void learn_labels (GenericArray<Json.Object> journals, Json.Object labels) {
            var h = cache.load ("labels");
            var o = h != null && h.get_node_type () == Json.NodeType.OBJECT ? h.get_object () : new Json.Object ();
            foreach (var j in journals) {
                var id = jint (j, "id").to_string ();
                if (!labels.has_member (id)) continue;
                var pairs = labels.get_array_member (id);
                var details = jarr (j, "details");
                for (int k = 0; k < details.length && k < pairs.get_length (); k++) {
                    var prop = jstr (details[k], "property");
                    var name = jstr (details[k], "name");
                    if (prop != "cf" && !(prop == "attr" && name.has_suffix ("_id"))) continue;
                    foreach (var side in new string[] { "old", "new" }) {
                        var l = jstr (pairs.get_object_element (k), side);
                        if (l == "") continue;
                        var key = "%s:%s:%s".printf (prop, name, jstr (details[k], side + "_value"));
                        o.remove_member (key); // заново — в конец
                        o.set_string_member (key, l);
                    }
                }
            }
            while (o.get_size () > 5000) o.remove_member (o.get_members ().data);
            cache.save ("labels", obj_node (o));
        }

        /** /users/:id (логин, регистрация, последний вход): кэш сутки, net — мимо кэша. */
        public async Json.Object user (int id, bool net = false) throws Error {
            var key = "user-%d".printf (id);
            var h = net ? null : cache.load (key, DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) return h.get_object ();
            var u = yield api.user (id);
            cache.save (key, obj_node (u));
            return u;
        }

        public async Json.Object person (int id, bool net = false) throws Error {
            var key = "person-%d".printf (id);
            var h = net ? null : cache.load (key, DAY_MS);
            if (h != null && h.get_node_type () == Json.NodeType.OBJECT) return h.get_object ();
            var p = yield api.person (id);
            cache.save (key, obj_node (p));
            return p;
        }

        /**
         * Сводка задач для ссылок #N: номер → «C|Трекер: тема (Статус)» у закрытой, «O|…» у открытой. По задаче — в
         * кэше на час, остальные одним запросом; закрытость — по статусу и справочнику статусов. Недоступных нет в ответе.
         */
        public async HashTable<int, string> issue_briefs (int[] ids) {
            var res = new HashTable<int, string> (direct_hash, direct_equal);
            int[] ask = {};
            foreach (var id in ids) {
                var h = cache.load ("brief-%d".printf (id), HOUR_MS);
                if (h != null && h.get_node_type () == Json.NodeType.OBJECT && jstr (h.get_object (), "b") != "") res[id] = jstr (h.get_object (), "b");
                else ask += id;
            }
            if (ask.length == 0) return res;
            try {
                var closed_st = new GenericSet<string> (str_hash, str_equal);
                foreach (var st in yield statuses ()) if (jbool (st, "is_closed")) closed_st.add (jint (st, "id").to_string ());
                int[] miss;
                foreach (var i in yield api.issues_by_ids (ask, out miss)) {
                    bool c = i.status_closed || closed_st.contains (i.status.id.to_string ());
                    var b = "%s|%s: %s (%s)".printf (c ? "C" : "O", i.tracker.name, i.subject, i.status.name);
                    var o = new Json.Object ();
                    o.set_string_member ("b", b);
                    cache.save ("brief-%d".printf (i.id), obj_node (o));
                    res[i.id] = b;
                }
            } catch (Error e) {}
            return res;
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
