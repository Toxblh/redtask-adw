/* Настройки (GSettings) и ключ API (Secret Service через libsecret). */
namespace Redmine {

    public class Prefs : Object {
        private static Prefs? _inst;
        public static Prefs get_default () {
            if (_inst == null) _inst = new Prefs ();
            return _inst;
        }

        public GLib.Settings s;
        private Prefs () { s = new GLib.Settings (Config.APP_ID); }

        public string server_url { owned get { return s.get_string ("server-url"); } }
        public int user_id { get { return s.get_int ("user-id"); } }
        public string user_name { owned get { return s.get_string ("user-name"); } }
        public string user_login { owned get { return s.get_string ("user-login"); } }

        /** Прежнее локальное избранное — только для переноса на сервер (Favorites.migrate). */
        public int[] favorites () {
            var v = s.get_value ("favorites");
            int[] res = {};
            for (size_t i = 0; i < v.n_children (); i++) res += v.get_child_value (i).get_int32 ();
            return res;
        }
        // ---- избранные проекты: «сервер|пользователь|id» — у каждой учётки свои ----
        private string pin_prefix () { return "%s|%d|".printf (server_url, user_id); }
        public int[] project_pins () {
            int[] res = {};
            foreach (var v in s.get_strv ("pinned-projects")) if (v.has_prefix (pin_prefix ())) res += int.parse (v.substring (pin_prefix ().length));
            return res;
        }
        public void set_project_pin (int id, bool on) {
            string[] res = {};
            var key = pin_prefix () + id.to_string ();
            foreach (var v in s.get_strv ("pinned-projects")) if (v != key) res += v;
            if (on) res += key;
            s.set_strv ("pinned-projects", res);
        }

        // ---- отключённые задачи/проекты: «id|название» ----
        public HashTable<int, string> muted (string key) {
            var res = new HashTable<int, string> (direct_hash, direct_equal);
            foreach (var v in s.get_strv (key)) {
                var bar = v.index_of ("|");
                int id = 0;
                if (int.try_parse (bar < 0 ? v : v.substring (0, bar), out id)) res[id] = bar < 0 ? "" : v.substring (bar + 1);
            }
            return res;
        }
        public void set_muted (string key, int id, string name, bool on) {
            string[] res = {};
            foreach (var v in s.get_strv (key)) if (!v.has_prefix ("%d|".printf (id)) && v != id.to_string ()) res += v;
            if (on) res += "%d|%s".printf (id, name);
            s.set_strv (key, res);
        }

        public bool category_on (string type) {
            foreach (var m in s.get_strv ("notif-muted")) if (m == type) return false;
            return true;
        }
        public void set_category (string type, bool on) {
            string[] res = {};
            foreach (var m in s.get_strv ("notif-muted")) if (m != type) res += m;
            if (!on) res += type;
            s.set_strv ("notif-muted", res);
        }

        /** Отпечаток охвата: сменился — прошлый набор «моих» задач с новым сравнивать нельзя. */
        public string scope_key () {
            var k = (s.get_boolean ("notif-scope-assigned") ? "1" : "0") + (s.get_boolean ("notif-scope-authored") ? "1" : "0")
                + (s.get_boolean ("notif-scope-watched") ? "1" : "0") + (s.get_boolean ("notif-favorites-only") ? "1" : "0");
            if (s.get_boolean ("notif-favorites-only")) {
                var f = Favorites.get_default ().all ();
                qsort_with_data<int> (f, sizeof (int), (a, b) => a - b);
                var parts = new GenericArray<string> ();
                foreach (var x in f) parts.add (x.to_string ());
                k += ":" + string.joinv (",", parts.data);
            }
            return k;
        }

        public void save_login (string server, User u) {
            s.set_string ("server-url", server);
            s.set_int ("user-id", u.id);
            s.set_string ("user-name", u.display_name);
            s.set_string ("user-login", u.login);
            s.set_int64 ("last-check", now_ms ());
        }

        /**
         * Избранное — номера задач этой учётки, уходит вместе с ней. Настройки уведомлений остаются:
         * тот же человек после повторного входа не настраивает их заново.
         */
        public void logout () {
            s.reset ("server-url"); s.reset ("user-id"); s.reset ("user-name"); s.reset ("user-login");
            s.reset ("last-check"); s.reset ("favorites");
        }
    }

    /** Ключ API — в Secret Service (связке ключей), по адресу сервера. */
    namespace Secrets {
        private Secret.Schema schema () {
            return new Secret.Schema (Config.APP_ID, Secret.SchemaFlags.NONE, "server", Secret.SchemaAttributeType.STRING);
        }
        private HashTable<string, string> attrs (string server) {
            var a = new HashTable<string, string> (str_hash, str_equal);
            a["server"] = server;
            return a;
        }
        public async void store (string server, string key) throws Error {
            yield Secret.password_storev (schema (), attrs (server), Secret.COLLECTION_DEFAULT, "Redmine API key (%s)".printf (server), key, null);
        }
        public async string? lookup (string server) throws Error {
            return yield Secret.password_lookupv (schema (), attrs (server), null);
        }
        public async void clear (string server) throws Error {
            yield Secret.password_clearv (schema (), attrs (server), null);
        }
    }
}
