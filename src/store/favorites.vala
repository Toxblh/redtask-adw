namespace Redmine {

    /**
     * Избранное — серверное (плагин favourites): чтение — фильтром issues.json ключом API, запись — веб-сессией
     * (web_favourite). Набор кэшируется по учётке; запись оптимистична, при сбое — откат.
     * Один раз переносит прежнее локальное избранное (Prefs «favorites») на сервер.
     */
    public class Favorites : Object {
        private static Favorites? _inst;
        public static Favorites get_default () {
            if (_inst == null) _inst = new Favorites ();
            return _inst;
        }

        /** Набор поменялся или запись дошла до сервера — списки перечитывают раздел. */
        public signal void changed ();

        private GenericSet<int> ids = new GenericSet<int> (direct_hash, direct_equal);
        private Session? owner = null;
        private int pending = 0;
        private bool migrating = false;

        public bool has (int id) { return ids.contains (id); }

        public int[] all () {
            int[] res = {};
            foreach (var id in ids.get_values ()) res += id;
            return res;
        }

        /** Новая учётка (null — выход): набор из её кэша сразу, свежий — с сервера. */
        public void attach (Session? s) {
            owner = s;
            ids.remove_all ();
            if (s != null) {
                var n = s.cache.load ("favorite-ids");
                if (n != null && n.get_node_type () == Json.NodeType.ARRAY)
                    n.get_array ().foreach_element ((a, i, e) => ids.add ((int) e.get_int ()));
                refresh.begin ();
            }
            changed ();
        }

        private void save (Session s) {
            var a = new Json.Array ();
            foreach (var id in ids.get_values ()) a.add_int_element (id);
            var n = new Json.Node (Json.NodeType.ARRAY);
            n.set_array (a);
            s.cache.save ("favorite-ids", n);
        }

        /** Перечитать набор с сервера; сбой сети — остаётся кэш. */
        public async void refresh () {
            var s = owner;
            if (s == null) return;
            try {
                var got = yield s.api.favourite_ids ();
                // пока идёт запись, оптимистичное состояние не перетираем
                if (s != owner || pending > 0) return;
                bool same = got.length == ids.length;
                if (same) foreach (var id in got.get_values ()) if (!ids.contains (id)) { same = false; break; }
                if (!same) {
                    ids = got;
                    save (s);
                    changed ();
                }
            } catch (Error e) {
                debug ("favourites refresh: %s", e.message);
                return;
            }
            yield migrate (s);
        }

        /** Поставить/снять звезду. Ошибка с кодом 401 — нужна веб-сессия (вход через сайт). */
        public async void set_favorite (int id, bool on) throws Error {
            var s = owner;
            if (s == null) return;
            pending++;
            if (on) ids.add (id); else ids.remove (id);
            changed ();
            try {
                yield web_favourite (s.server, id, on);
            } catch (Error e) {
                if (s == owner) {
                    if (on) ids.remove (id); else ids.add (id);
                    changed ();
                }
                throw e;
            } finally {
                pending--;
            }
            if (s != owner) return;
            save (s);
            changed ();
            yield migrate (s);
        }

        /**
         * Один раз: локальные избранные, которых нет на сервере, — на сервер, затем локальные стираем.
         * Нет веб-сессии или сбой — попробуем при следующем обновлении; задачи без доступа (403/404) пропускаем.
         */
        private async void migrate (Session s) {
            var p = Prefs.get_default ();
            // демо — не учётка: прежнее локальное избранное ждёт настоящий вход
            if (migrating || s.api.demo || p.s.get_boolean ("favorites-migrated")) return;
            migrating = true;
            bool done = true;
            foreach (var id in fav_to_migrate (p.favorites (), ids)) {
                try {
                    yield web_favourite (s.server, id, true);
                    if (s == owner) ids.add (id);
                } catch (Error e) {
                    var c = error_code (e);
                    if (c == 403 || c == 404) continue;
                    debug ("favourites migration: %s", e.message);
                    done = false;
                    break;
                }
            }
            migrating = false;
            if (s != owner) return;
            if (done) {
                p.s.set_boolean ("favorites-migrated", true);
                p.s.reset ("favorites");
            }
            save (s);
            changed ();
        }
    }
}
