namespace Redmine {

    /**
     * Прочитано и непрочитано учётки (spec 19.1): ReadMarks в DiskCache под ключом «read-state» — очистка кэша
     * его не трогает, выход стирает. Нет записи (новый вход, первая версия с этим пунктом) — рубеж «сейчас».
     */
    public class ReadState : Object {
        private static ReadState? _inst;
        public static ReadState get_default () {
            if (_inst == null) _inst = new ReadState ();
            return _inst;
        }

        /** Задача стала прочитанной (id) или «Пометить всё прочитанным» (0) — точки и счётчики пересчитываются сразу. */
        public signal void changed (int issue_id);

        private ReadMarks marks = new ReadMarks ();
        private Session? owner = null;

        public int64 baseline { get { return marks.baseline; } }

        public void attach (Session? s) {
            owner = s;
            marks = new ReadMarks ();
            if (s != null) {
                var n = s.cache.load ("read-state");
                if (n != null && n.get_node_type () == Json.NodeType.OBJECT) marks = ReadMarks.from_json (n.get_object ());
                else {
                    marks.mark_all (now_ms ());
                    save ();
                }
            }
            changed (0);
        }

        private void save () {
            owner?.cache.save ("read-state", obj_node (marks.to_json ()));
        }

        public bool unread_at (int id, int64 ms) { return owner != null && marks.unread (id, ms); }

        public bool unread (Issue i) { return unread_at (i.id, parse_iso_ms (i.updated_on)); }

        /** Просмотр: свежая версия задачи пришла с сервера (из кэша — не считается). */
        public void viewed (Issue i) {
            if (owner == null) return;
            var was = unread (i);
            marks.view (i.id, parse_iso_ms (i.updated_on));
            save ();
            if (was) changed (i.id);
        }

        /** Только для снимков (REDTASK_SHOT_UNREAD): рубеж в прошлое — свежие задачи демо непрочитаны. */
        public void rewind (int64 ms) {
            marks.mark_all (ms);
            changed (0);
        }

        public void mark_all () {
            if (owner == null) return;
            marks.mark_all (now_ms ());
            save ();
            changed (0);
        }
    }
}
