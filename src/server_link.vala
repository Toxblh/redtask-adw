/* Разбор ссылки на свой сервер Redmine: задача (с комментарием), проект, человек. Чужое — null. */
namespace Redmine {

    public enum LinkKind { ISSUE, PROJECT, USER }

    public class ServerLink : Object {
        public LinkKind kind;
        public int id;            // задача или человек
        public string project = ""; // идентификатор или номер проекта
        public int note_index;    // #note-K — порядковый номер записи журнала (с 1)
        public int journal_id;    // #change-ID

        /** server — адрес учётки (может быть с подпутём: https://host/redmine). http и https — один сервер. */
        public static ServerLink? parse (string server, string uri) {
            if (server == "") return null;
            Uri s, u;
            try {
                s = Uri.parse (server, UriFlags.NONE);
                u = Uri.parse (uri, UriFlags.NONE);
            } catch (Error e) {
                return null;
            }
            if (!is_web (u.get_scheme ()) || !is_web (s.get_scheme ())) return null;
            if (s.get_host () == null || u.get_host () == null || s.get_host ().down () != u.get_host ().down ()) return null;
            if (eff_port (s) != eff_port (u)) return null;
            var base_path = s.get_path ();
            while (base_path.has_suffix ("/")) base_path = base_path.substring (0, base_path.length - 1);
            var path = u.get_path ();
            if (!path.has_prefix (base_path + "/")) return null;
            path = path.substring (base_path.length);

            var l = new ServerLink ();
            MatchInfo mi;
            if (/^\/issues\/(\d+)\/?$/.match (path, 0, out mi)) {
                l.kind = LinkKind.ISSUE;
                l.id = int.parse (mi.fetch (1));
                var frag = u.get_fragment () ?? "";
                if (/^note-(\d+)$/.match (frag, 0, out mi)) l.note_index = int.parse (mi.fetch (1));
                else if (/^change-(\d+)$/.match (frag, 0, out mi)) l.journal_id = int.parse (mi.fetch (1));
            } else if (/^\/projects\/([^\/]+)(\/.*)?$/.match (path, 0, out mi)) {
                l.kind = LinkKind.PROJECT;
                l.project = Uri.unescape_string (mi.fetch (1)) ?? mi.fetch (1);
            } else if (/^\/(users|people)\/(\d+)\/?$/.match (path, 0, out mi)) {
                l.kind = LinkKind.USER;
                l.id = int.parse (mi.fetch (2));
            } else {
                return null;
            }
            return l.id > 0 || l.project != "" ? l : null;
        }

        private static bool is_web (string? scheme) {
            return scheme != null && (scheme.down () == "http" || scheme.down () == "https");
        }

        /** Порт по умолчанию считаем одним: https://host и http://host — тот же сервер. */
        private static int eff_port (Uri u) {
            var p = u.get_port ();
            if (p == -1 || (p == 443 && u.get_scheme ().down () == "https") || (p == 80 && u.get_scheme ().down () == "http")) return 0;
            return p;
        }
    }
}
