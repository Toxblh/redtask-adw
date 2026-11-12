namespace Redmine {

    /**
     * Память поллера между запусками: «мои» открытые задачи прошлого опроса (id → тема; по разнице видно
     * переназначение и удаление) и показанные напоминания о сроке («id:дата»). scope — охват, при котором
     * набор собран. mention_since/offset — недочитанный хвост поиска упоминаний; 0 — хвоста нет.
     */
    public class PollState : Object {
        public HashTable<int, string> mine = new HashTable<int, string> (direct_hash, direct_equal);
        public GenericSet<string> due = new GenericSet<string> (str_hash, str_equal);
        public string scope = "";
        public int64 mention_since = 0;
        public int mention_offset = 0;

        public Json.Object to_json () {
            var o = new Json.Object ();
            var m = new Json.Object ();
            foreach (var k in mine.get_keys ()) m.set_string_member (k.to_string (), mine[k]);
            o.set_object_member ("mine", m);
            var d = new Json.Array ();
            foreach (var k in due.get_values ()) d.add_string_element (k);
            o.set_array_member ("due", d);
            o.set_string_member ("scope", scope);
            o.set_int_member ("mentionSince", mention_since);
            o.set_int_member ("mentionOffset", mention_offset);
            return o;
        }

        public static PollState from_json (Json.Object o) {
            var s = new PollState ();
            var m = jobj (o, "mine");
            if (m != null) foreach (var k in m.get_members ()) s.mine[int.parse (k)] = m.get_string_member (k);
            if (o.has_member ("due")) o.get_array_member ("due").foreach_element ((a, i, n) => s.due.add (n.get_string ()));
            s.scope = jstr (o, "scope");
            s.mention_since = o.has_member ("mentionSince") ? o.get_int_member ("mentionSince") : 0;
            s.mention_offset = jint (o, "mentionOffset");
            return s;
        }
    }

    /**
     * История уведомлений: файл notifications.json (кап 500) в данных учётки. Живые события дописывает опрос,
     * однократный бэкфилл за 7 дней — колокольчик при первом открытии.
     */
    public class NotifStore : Object {
        private const int CAP = 500;
        private string dir;
        public signal void changed ();

        public NotifStore (string dir) {
            this.dir = dir;
            DirUtils.create_with_parents (dir, 0700);
        }

        private string p (string name) { return Path.build_filename (dir, name); }

        private static void replace (string path, string text) throws Error {
            // set_contents пишет во временный файл и переименовывает: оборванная запись не оставляет обрубок
            FileUtils.set_contents (path, text);
        }

        public PollState? load_state () {
            string text;
            try {
                if (!FileUtils.get_contents (p ("poll-state.json"), out text)) return null;
            } catch (Error e) { return null; }
            var n = json_parse (text);
            return n != null && n.get_node_type () == Json.NodeType.OBJECT ? PollState.from_json (n.get_object ()) : null;
        }

        /** Сбой записи пробрасывается: опрос, не сохранивший память, не вправе сдвигать окно. */
        public void save_state (PollState s) throws Error {
            replace (p ("poll-state.json"), json_to_string (obj_node (s.to_json ())));
        }

        public GenericArray<NotifEntry> load () {
            var res = new GenericArray<NotifEntry> ();
            string text;
            try {
                if (!FileUtils.get_contents (p ("notifications.json"), out text)) return res;
            } catch (Error e) { return res; }
            foreach (var o in node_arr (json_parse (text))) res.add (NotifEntry.from_json (o));
            return res;
        }

        /**
         * Дописывает записи и возвращает только действительно новые: повтор опроса и бэкфилл не дублируют
         * ни историю, ни системные уведомления. Непрочитанность — по ReadState (spec 19). Сбой записи пробрасывается.
         */
        public GenericArray<NotifEntry> append_all (GenericArray<NotifEntry> entries) throws Error {
            var old = load ();
            var known = new GenericSet<string> (str_hash, str_equal);
            foreach (var e in old) known.add (e.key);
            var fresh = new GenericArray<NotifEntry> ();
            foreach (var e in entries) if (!known.contains (e.key)) { known.add (e.key); fresh.add (e); }
            if (fresh.length == 0) return fresh;
            var all = new GenericArray<NotifEntry> ();
            foreach (var e in old) all.add (e);
            foreach (var e in fresh) all.add (e);
            all.sort ((a, b) => a.at > b.at ? -1 : (a.at < b.at ? 1 : 0));
            if (all.length > CAP) all.remove_range (CAP, all.length - CAP);
            var arr = new Json.Array ();
            foreach (var e in all) arr.add_object_element (e.to_json ());
            var n = new Json.Node (Json.NodeType.ARRAY);
            n.set_array (arr);
            replace (p ("notifications.json"), json_to_string (n));
            changed ();
            return fresh;
        }

        public bool needs_backfill () { return !FileUtils.test (p ("notifications.backfilled"), FileTest.EXISTS); }

        public void mark_backfilled () {
            try { FileUtils.set_contents (p ("notifications.backfilled"), "1"); } catch (Error e) {}
        }

        /** Выход: история, флаг бэкфилла, непрочитанное и память поллера. */
        public void clear () {
            foreach (var n in new string[] { "notifications.json", "notifications.unread", "notifications.backfilled", "poll-state.json" })
                FileUtils.unlink (p (n));
            changed ();
        }
    }
}
