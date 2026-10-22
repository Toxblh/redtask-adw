/*
 * Фоновый опрос (пока процесс жив: окно открыто или включено «работать в фоне»). Источники событий: журналы
 * «моих» задач (назначенных, отслеживаемых, авторских), выпавшие из «моих», списания времени, приближающийся
 * срок и (если категория включена) новые задачи в моих проектах и упоминания меня в любых доступных задачах.
 * Окно (last-check) сдвигается, только если удались все запросы; повтор не дублирует уведомления — NotifStore
 * отсекает известные события по ключу. В историю идёт всё собранное, системное уведомление — по NotifFilter.
 */
namespace Redmine {

    public class Poller : Object {
        private uint timer = 0;
        private bool running = false;
        /** Показанные этим процессом уведомления: задача → id GNotification. */
        public HashTable<int, string> posted = new HashTable<int, string> (direct_hash, direct_equal);
        private HashTable<int, string> posted_text = new HashTable<int, string> (direct_hash, direct_equal);
        private const int PAGE = 100;
        // ponytail: потолок 1000 задач на источник за окно; упёрлись — набор неполный
        private const int MAX_PAGES = 10;
        // до 300 задач с упоминаниями за опрос; остальное дочитывают следующие опросы (PollState.mention_since)
        private const int MENTION_PAGES = 3;
        public signal void finished (bool ok);

        public void start () {
            var s = Prefs.get_default ().s;
            s.changed["poll-interval"].connect (reschedule);
            s.changed["notifications-enabled"].connect (reschedule);
            reschedule ();
            // первый опрос — вскоре после запуска, не мешая первой загрузке списков
            Timeout.add_seconds (20, () => { run.begin (); return Source.REMOVE; });
        }

        public void stop () {
            if (timer != 0) Source.remove (timer);
            timer = 0;
        }

        private void reschedule () {
            stop ();
            var s = Prefs.get_default ().s;
            if (!s.get_boolean ("notifications-enabled")) return;
            var minutes = int.max (1, s.get_int ("poll-interval"));
            timer = Timeout.add_seconds (minutes * 60, () => { run.begin (); return Source.CONTINUE; });
        }

        public NotifFilter filter () {
            var p = Prefs.get_default ();
            var f = new NotifFilter ();
            foreach (var m in p.s.get_strv ("notif-muted")) f.muted.add (m);
            foreach (var k in p.muted ("muted-issues").get_keys ()) f.muted_issues.add (k);
            foreach (var k in p.muted ("muted-projects").get_keys ()) f.muted_projects.add (k);
            f.status_closed_only = p.s.get_boolean ("notif-status-closed-only");
            f.priority_raised_only = p.s.get_boolean ("notif-priority-raised-only");
            return f;
        }

        /** Начало окна: 90 с запаса на стык поллов; первый запуск — за последний час. */
        public static int64 window_start (int64 last_check, int64 now) {
            return (last_check == 0 ? now - HOUR_MS : last_check) - 90000;
        }

        public async bool run () {
            var session = App.get ().session;
            var p = Prefs.get_default ();
            if (session == null || running || !p.s.get_boolean ("notifications-enabled")) return false;
            running = true;
            var now = now_ms ();
            var since = window_start (p.s.get_int64 ("last-check"), now);
            bool ok = false;
            try {
                PollState state;
                var entries = yield collect (session, since, now, out state);
                if (App.get ().session != session) { running = false; return false; } // вышли во время опроса
                var fresh = session.notifs.append_all (entries);
                var f = filter ();
                var show = new GenericArray<NotifEntry> ();
                foreach (var e in fresh) if (f.notifies (e)) show.add (e);
                post (show, f);
                session.notifs.save_state (state);
                p.s.set_int64 ("last-check", now);
                debug ("poll ok: events=%u new=%u", entries.length, fresh.length);
                ok = true;
            } catch (Error e) {
                debug ("poll failed: %s", e.message);
            }
            running = false;
            finished (ok);
            return ok;
        }

        /** «Мои» задачи по включённым источникам, все страницы; complete = false — упёрлись в потолок. */
        private async HashTable<int, Issue> my_issues (Session s, string status, string? updated_since, out bool complete) throws Error {
            var p = Prefs.get_default ();
            var res = new HashTable<int, Issue> (direct_hash, direct_equal);
            complete = true;
            var fav_only = p.s.get_boolean ("notif-favorites-only");
            var favs = new GenericSet<int> (direct_hash, direct_equal);
            foreach (var x in p.favorites ()) favs.add (x);
            if (fav_only && favs.length == 0) return res;
            for (int src = 0; src < 3; src++) {
                var q = new IssueQuery ();
                if (src == 0) { if (!p.s.get_boolean ("notif-scope-assigned")) continue; q.assigned_to_me = true; }
                if (src == 1) { if (!p.s.get_boolean ("notif-scope-watched")) continue; q.watched_by_me = true; }
                if (src == 2) { if (!p.s.get_boolean ("notif-scope-authored")) continue; q.authored_by_me = true; }
                q.status = status;
                q.updated_since = updated_since;
                q.limit = PAGE;
                // по id порядок страниц не плывёт от правок во время обхода; свежие правки — сначала новые
                q.sort = updated_since != null ? "updated_on:desc" : "id:desc";
                bool done = false;
                for (int n = 0; n < MAX_PAGES; n++) {
                    var page = yield s.api.issues (q);
                    foreach (var i in page.issues) {
                        // сервер не знает author_id и вернул всё подряд — отсекаем чужое на клиенте
                        if (!q.authored_by_me || i.author.id == s.user_id) res[i.id] = i;
                    }
                    q.offset += page.issues.length;
                    if (page.issues.length == 0 || q.offset >= page.total) { done = true; break; }
                }
                if (!done) complete = false;
            }
            if (fav_only) {
                foreach (var k in res.get_keys ()) if (!favs.contains (k)) res.remove (k);
            }
            return res;
        }

        /** Логин для упоминаний: у разработческих/старых входов его может не быть — спрашиваем сервер один раз. */
        private async string login (Session s) throws Error {
            var p = Prefs.get_default ();
            if (p.user_login != "") return p.user_login;
            var me = yield s.api.current_user ();
            if (me.login != "") p.s.set_string ("user-login", me.login);
            return me.login;
        }

        /**
         * Задачи, изменённые после since_ms, в комментариях которых есть «@login». next_offset ≥ 0 — упёрлись в
         * потолок страниц, дочитывать с этого смещения. 400/403/404/422 — фильтр сервер не знает: выключаем до конца сессии.
         */
        private async int[] mention_ids (Session s, string login, int64 since_ms, int offset, out int next_offset) throws Error {
            int[] res = {};
            next_offset = -1;
            if (login == "" || s.api.mention_filter_unsupported) return res;
            int next = offset;
            bool done = false;
            try {
                for (int n = 0; n < MENTION_PAGES; n++) {
                    var page = yield s.api.issues_mentioning (login, iso_seconds (since_ms), next);
                    foreach (var i in page.issues) res += i.id;
                    next += page.issues.length;
                    if (page.issues.length == 0 || next >= page.total) { done = true; break; }
                }
            } catch (Error e) {
                var c = error_code (e);
                if (c != 400 && c != 403 && c != 404 && c != 422) throw e;
                s.api.mention_filter_unsupported = true;
                return {};
            }
            if (!done) next_offset = next;
            return res;
        }

        // ponytail: «решена» — не признак в API, а название статуса; угадываем по слову
        private static Regex? resolved_re = null;

        private async bool strong (Session s, Json.Object j, string type) {
            Json.Object? d = null;
            var want = type == NotifType.STATUS ? "status_id" : "priority_id";
            foreach (var x in jarr (j, "details")) if (jstr (x, "property") == "attr" && jstr (x, "name") == want) d = x;
            if (d == null) return true;
            try {
                if (type == NotifType.STATUS) {
                    if (resolved_re == null) resolved_re = new Regex ("решен|решён|выполнен|resolv|done|fixed", RegexCompileFlags.CASELESS);
                    foreach (var st in yield s.refs.statuses ())
                        if (jstr (st, "id") == jstr (d, "new_value")) return jbool (st, "is_closed") || resolved_re.match (jstr (st, "name"));
                    return true;
                }
                if (type == NotifType.PRIORITY) {
                    // справочник приоритетов сервер отдаёт по возрастанию важности
                    int old = -1, nw = -1, k = 0;
                    foreach (var pr in yield s.refs.priorities ()) {
                        if (jstr (pr, "id") == jstr (d, "old_value")) old = k;
                        if (jstr (pr, "id") == jstr (d, "new_value")) nw = k;
                        k++;
                    }
                    return old < 0 || nw < 0 || nw > old;
                }
            } catch (Error e) {}
            return true;
        }

        private NotifEntry entry (Issue issue, int64 at, Named? who, string text, string type, string event_id) {
            var name = who != null && who.name != "" ? who.name : _("Someone");
            var e = new NotifEntry ();
            e.issue_id = issue.id;
            e.subject = issue.subject;
            e.project = issue.project.name;
            e.project_id = issue.project.id;
            e.lines = { type == NotifType.MENTION ? _("%s mentioned you: %s").printf (name, text) : "%s: %s".printf (name, text) };
            e.at = at;
            e.avatar_user_id = who != null ? who.id : 0;
            e.type = type;
            e.event_id = event_id;
            e.author = name;
            return e;
        }

        /** Чужая задача, созданная после since: «назначена мне» либо «новая задача». */
        private NotifEntry? created_entry (Issue issue, int user_id, int64 since) {
            var at = parse_iso_ms (issue.created_on);
            if (at <= since || issue.author.id == user_id) return null;
            var a = issue.assigned_to;
            return entry (issue, at, issue.author, _("new issue (%s)").printf (issue.tracker.name),
                a != null && a.id == user_id ? NotifType.ASSIGNED : NotifType.NEW_ISSUE, "created");
        }

        /** Записи по задаче: её создание и каждый чужой журнал после since. null — задача недоступна (404/403). */
        private async GenericArray<NotifEntry>? issue_entries (Session s, int64 since, int issue_id, string login, bool mentions_only) throws Error {
            Issue issue;
            try {
                issue = yield s.api.issue_journals (issue_id);
            } catch (Error e) {
                if (error_code (e) == 404 || error_code (e) == 403) return null;
                throw e;
            }
            var res = new GenericArray<NotifEntry> ();
            if (!mentions_only) {
                var c = created_entry (issue, s.user_id, since);
                if (c != null) res.add (c);
            }
            foreach (var j in issue.journals) {
                // по дате создания, а не правки: отредактированный старый журнал повторно не уведомляет
                var at = parse_iso_ms (jstr (j, "created_on"));
                var who = Named.from (jobj (j, "user"));
                if (at <= since || (who != null && who.id == s.user_id)) continue;
                if (mentions_only && !mentions (jstr (j, "notes"), login)) continue;
                var text = yield journal_text (s, issue, j);
                if (text == "") continue;
                var cats = journal_types (j, s.user_id, login);
                var e = entry (issue, at, who, text, cats[0], "j%d".printf (jint (j, "id")));
                e.strong = yield strong (s, j, cats[0]);
                for (int k = 1; k < cats.length; k++) e.also[cats[k]] = yield strong (s, j, cats[k]);
                res.add (e);
            }
            return res;
        }

        private async string? named (string? v, GenericArray<Json.Object>? refs, Named? current) {
            int id = 0;
            if (v == null || !int.try_parse (v, out id)) return v;
            if (refs != null) foreach (var r in refs) if (jint (r, "id") == id) return jstr (r, "name");
            if (current != null && current.id == id) return current.name;
            return "#" + v;
        }

        private async string? user_name (Session s, Issue issue, string? v) {
            int id = 0;
            if (v == null || !int.try_parse (v, out id)) return v;
            var a = issue.assigned_to;
            if (a != null && a.id == id && a.name != "") return a.name;
            if (issue.author.id == id) return issue.author.name;
            foreach (var j in issue.journals) {
                var u = Named.from (jobj (j, "user"));
                if (u != null && u.id == id && u.name != "") return u.name;
            }
            try {
                var n = person_short_name (yield s.refs.person (id));
                if (n != "") return n;
            } catch (Error e) {}
            return "#" + v;
        }

        private async string journal_text (Session s, Issue issue, Json.Object j) {
            var parts = new GenericArray<string> ();
            foreach (var d in jarr (j, "details")) parts.add (yield detail_text (s, issue, d));
            parts.add (null);
            var details = string.joinv (", ", parts.data);
            var note = Textile.preview (jstr (j, "notes"));
            if (details != "" && note != "") return details + " — " + note;
            return details != "" ? details : note;
        }

        private string line (string label, string? value) {
            var v = value ?? "—";
            if (v.char_count () > 80) v = v.substring (0, v.index_of_nth_char (80));
            return "%s → %s".printf (label, v);
        }

        private GenericArray<Json.Object>? soft_arr (GenericArray<Json.Object>? a) { return a; }

        /** Одна правка журнала → текст. Значение — из new_value самого журнала, а не из текущего состояния задачи. */
        private async string detail_text (Session s, Issue issue, Json.Object d) {
            var nv = jstr (d, "new_value");
            string? v = nv.strip () != "" ? nv : null;
            var prop = jstr (d, "property");
            var name = jstr (d, "name");
            GenericArray<Json.Object>? refs = null;
            if (prop == "attr") {
                switch (name) {
                    case "status_id":
                        try { refs = yield s.refs.statuses (); } catch (Error e) {}
                        return line (_("status"), yield named (v, refs, issue.status));
                    case "priority_id":
                        try { refs = yield s.refs.priorities (); } catch (Error e) {}
                        return line (_("priority"), yield named (v, refs, issue.priority));
                    case "tracker_id":
                        try { refs = yield s.refs.trackers (); } catch (Error e) {}
                        return line (_("tracker"), yield named (v, refs, issue.tracker));
                    case "fixed_version_id":
                        try { refs = yield s.refs.versions (issue.project.id); } catch (Error e) {}
                        return line (_("version"), yield named (v, refs, issue.fixed_version));
                    case "assigned_to_id": return line (_("assignee"), yield user_name (s, issue, v));
                    case "category_id": return line (_("category"), yield named (v, null, issue.category));
                    case "project_id": return line (_("project"), yield named (v, null, issue.project));
                    case "parent_id": return line (_("parent issue"), v != null ? "#" + v : null);
                    case "done_ratio": return line (_("progress"), v != null ? v + "%" : null);
                    case "due_date": return line (_("due date"), v);
                    case "start_date": return line (_("start date"), v);
                    case "estimated_hours": return line (_("estimate"), v);
                    case "subject": return line (_("subject"), v);
                    case "description": return _("description changed");
                    case "is_private": return v == "1" || v == "true" ? _("issue made private") : _("issue made public");
                    default: return line (name, v);
                }
            }
            if (prop == "cf") {
                var label = _("field");
                foreach (var cf in issue.custom_fields) if (jstr (cf, "id") == name && jstr (cf, "name") != "") label = jstr (cf, "name");
                return line (label, v);
            }
            // у удалённого вложения/связи new_value пуст, имя/номер — в old_value
            if (prop == "attachment") return v != null ? _("file: %s").printf (v) : _("file removed: %s").printf (jstr (d, "old_value"));
            if (prop == "relation") return v != null ? _("relation with #%s").printf (v) : _("relation with #%s removed").printf (jstr (d, "old_value"));
            return line (name != "" ? name : prop, v);
        }

        /** Все события окна и новое состояние поллера. Ничего не сохраняет и не показывает. */
        public async GenericArray<NotifEntry> collect (Session s, int64 since, int64 now, out PollState state) throws Error {
            var p = Prefs.get_default ();
            var saved = s.notifs.load_state ();
            // набор прошлого опроса собран при другом охвате — «выпавшие» из него были бы ложными
            var prev = saved != null && saved.scope == p.scope_key () ? saved : null;
            var res = new GenericArray<NotifEntry> ();
            bool changed_complete, complete;
            var changed = yield my_issues (s, "*", iso_seconds (since), out changed_complete);
            var open = yield my_issues (s, "open", null, out complete);

            // журналы изменившихся и выпавших из «моих» задач: переназначенные найдутся по журналу,
            // удалённые/закрытые от меня ответят 404/403
            var left = new GenericSet<int> (direct_hash, direct_equal);
            if (prev != null && complete)
                foreach (var k in prev.mine.get_keys ()) if (!open.contains (k) && !changed.contains (k)) left.add (k);
            var mentions_on = p.category_on (NotifType.MENTION);
            var my_login = mentions_on ? yield login (s) : p.user_login;
            var mine = new GenericSet<int> (direct_hash, direct_equal);
            foreach (var k in changed.get_keys ()) mine.add (k);
            foreach (var k in left.get_values ()) mine.add (k);
            foreach (var id in mine.get_values ()) {
                var es = yield issue_entries (s, since, id, my_login, false);
                if (es != null) foreach (var e in es) res.add (e);
                else if (left.contains (id)) {
                    var e = new NotifEntry ();
                    e.issue_id = id;
                    e.subject = prev.mine[id] ?? "";
                    e.lines = { _("The issue was deleted or is no longer available") };
                    e.at = now;
                    e.type = NotifType.REASSIGNED_AWAY;
                    e.event_id = "gone";
                    res.add (e);
                }
            }

            // упоминания в задачах вне «моих»; хвост, не влезший в потолок страниц, дочитывают следующие опросы
            int64 mention_since = 0;
            int mention_offset = 0;
            if (mentions_on) {
                var tail = saved != null && saved.mention_since > 0 ? saved : null;
                int more, more_old = -1;
                var ids = yield mention_ids (s, my_login, since, 0, out more);
                var all = new GenericSet<int> (direct_hash, direct_equal);
                foreach (var x in ids) all.add (x);
                if (tail != null) foreach (var x in yield mention_ids (s, my_login, tail.mention_since, tail.mention_offset, out more_old)) all.add (x);
                var from = tail != null ? tail.mention_since : since;
                foreach (var id in all.get_values ()) {
                    if (tail == null && mine.contains (id)) continue;
                    var es = yield issue_entries (s, from, id, my_login, true);
                    if (es != null) foreach (var e in es) res.add (e);
                }
                var m = more >= 0 ? more : more_old;
                if (m >= 0) { mention_since = from; mention_offset = m; }
            }

            // новые задачи в проектах, где я участник; категория выключена — запроса нет вовсе
            if (p.category_on (NotifType.NEW_ISSUE)) {
                try {
                    int offset = 0;
                    for (int n = 0; n < MAX_PAGES; n++) {
                        var page = yield s.api.new_issues_in_my_projects (iso_seconds (since), offset);
                        foreach (var i in page.issues) {
                            var c = created_entry (i, s.user_id, since);
                            if (c != null) res.add (c);
                        }
                        offset += page.issues.length;
                        if (page.issues.length == 0 || offset >= page.total) break;
                    }
                } catch (Error e) {
                    // сервер не принял фильтр «мои проекты» — определённое «нет», а не сбой опроса
                    if (error_code (e) != 404 && error_code (e) != 422) throw e;
                }
            }

            // списания времени в моих задачах — это не журналы, в запросах выше их нет.
            // ponytail: from — дата spent_on, списание задним числом (раньше вчера) не увидим
            var subjects = new HashTable<int, string> (direct_hash, direct_equal);
            if (prev != null) foreach (var k in prev.mine.get_keys ()) subjects[k] = prev.mine[k];
            foreach (var i in open.get_values ()) subjects[i.id] = i.subject;
            foreach (var i in changed.get_values ()) subjects[i.id] = i.subject;
            if (subjects.length > 0) {
                GenericArray<Json.Object> time;
                try {
                    var from = new DateTime.from_unix_local (since / 1000).add_days (-1).format ("%Y-%m-%d");
                    time = yield s.api.time_entries_from (from, since);
                } catch (Error e) {
                    // нет права смотреть время / модуль выключен — определённое «нет»
                    if (error_code (e) != 403 && error_code (e) != 404) throw e;
                    time = new GenericArray<Json.Object> ();
                }
                foreach (var t in time) {
                    var id = jint (jobj (t, "issue"), "id");
                    if (id == 0 || !subjects.contains (id)) continue;
                    var at = parse_iso_ms (jstr (t, "created_on"));
                    var who = Named.from (jobj (t, "user"));
                    if (at <= since || (who != null && who.id == s.user_id)) continue;
                    var name = who != null && who.name != "" ? who.name : _("Someone");
                    var e = new NotifEntry ();
                    e.issue_id = id;
                    e.subject = subjects[id];
                    var pr = Named.from (jobj (t, "project"));
                    e.project = pr != null ? pr.name : "";
                    e.project_id = pr != null ? pr.id : 0;
                    var cm = jstr (t, "comments");
                    e.lines = { "%s: %s".printf (name, _("time logged: %s h").printf (format_hours (jdouble (t, "hours")))) + (cm != "" ? " — " + cm : "") };
                    e.at = at;
                    e.avatar_user_id = who != null ? who.id : 0;
                    e.type = NotifType.TIME_LOGGED;
                    e.event_id = "t%d".printf (jint (t, "id"));
                    e.author = name;
                    res.add (e);
                }
            }

            // срок — локально: одно напоминание на задачу и дату срока (завтра / сегодня / просрочена)
            var today = today_str ();
            var tomorrow = new DateTime.now_local ().add_days (1).format ("%Y-%m-%d");
            var due = new GenericSet<string> (str_hash, str_equal);
            foreach (var i in open.get_values ()) {
                var a = i.assigned_to;
                if (a == null || a.id != s.user_id) continue;
                var date = i.due_date;
                if (date.length < 10 || date > tomorrow) continue;
                var key = "%d:%s".printf (i.id, date);
                due.add (key);
                // первый опрос после входа: давно просроченное пачкой не вываливаем, только запоминаем
                var known = prev == null ? date < today : prev.due.contains (key);
                if (known) continue;
                var e = new NotifEntry ();
                e.issue_id = i.id;
                e.subject = i.subject;
                e.project = i.project.name;
                e.project_id = i.project.id;
                e.lines = { date < today ? _("Overdue since %s").printf (format_date (date)) : (date == today ? _("Due today") : _("Due tomorrow")) };
                e.at = now;
                e.type = NotifType.DUE_SOON;
                e.event_id = "due:" + date;
                res.add (e);
            }

            // неполный набор «моих» не запоминаем: по нему следующий опрос увидел бы ложные «выпавшие»
            state = new PollState ();
            state.scope = p.scope_key ();
            if (complete) foreach (var i in open.get_values ()) state.mine[i.id] = i.subject;
            else if (prev != null) state.mine = prev.mine;
            if (!complete && prev != null) foreach (var k in prev.due.get_values ()) state.due.add (k);
            foreach (var k in due.get_values ()) state.due.add (k);
            state.mention_since = mention_since;
            state.mention_offset = mention_offset;
            return res;
        }

        /**
         * Системные уведомления: одно на задачу (строки копятся, новые сверху), действие по умолчанию —
         * открыть задачу на самом новом комментарии пачки, кнопка «Не уведомлять по задаче».
         */
        public void post (GenericArray<NotifEntry> fresh, NotifFilter f) {
            if (fresh.length == 0) return;
            var app = App.get ();
            var by_issue = new HashTable<int, GenericArray<NotifEntry>> (direct_hash, direct_equal);
            int[] order = {};
            fresh.sort ((a, b) => a.at > b.at ? 1 : (a.at < b.at ? -1 : 0));
            foreach (var e in fresh) {
                if (!by_issue.contains (e.issue_id)) { by_issue[e.issue_id] = new GenericArray<NotifEntry> (); order += e.issue_id; }
                by_issue[e.issue_id].add (e);
            }
            foreach (var id in order) {
                var list = by_issue[id];
                var last = list[list.length - 1];
                var sb = new StringBuilder ();
                var group = NotifGroup.PROJECTS;
                int note = 0;
                for (int k = (int) list.length - 1; k >= 0; k--) {
                    foreach (var l in list[k].lines) sb.append (l + "\n");
                    if (note == 0) note = list[k].journal_id;
                    foreach (var t in f.notify_types (list[k])) if (group_of (t) < group) group = group_of (t);
                }
                // непрочитанное уведомление этой же задачи не затираем — дописываем его строки ниже новых
                var old = posted_text[id];
                var body = sb.str.strip ();
                if (old != null) body = body + "\n" + old;
                var lines = body.split ("\n");
                if (lines.length > 8) body = string.joinv ("\n", lines[0:8]);
                var n = new GLib.Notification ("#%d %s".printf (id, last.subject));
                n.set_body (body);
                n.set_priority (group.priority ());
                n.set_category ("im.received");
                n.set_default_action_and_target_value ("app.open-issue", new Variant ("(ii)", id, note));
                n.add_button_with_target_value (_("Mute Issue"), "app.mute-issue", new Variant ("(is)", id, last.subject));
                var nid = "issue-%d".printf (id);
                app.send_notification (nid, n);
                posted[id] = nid;
                posted_text[id] = body;
            }
        }

        /** Пользователь открыл задачу — её уведомление больше не нужно. */
        public void withdraw_issue (int id) {
            if (!posted.contains (id)) return;
            App.get ().withdraw_notification (posted[id]);
            posted.remove (id);
            posted_text.remove (id);
        }

        /**
         * Бэкфилл колокольчика: события «моих» задач за 7 дней, без системных уведомлений и непрочитанного.
         */
        public async void backfill (Session s) throws Error {
            if (!s.notifs.needs_backfill ()) return;
            PollState st;
            var now = now_ms ();
            var entries = yield collect (s, now - 7 * DAY_MS, now, out st);
            s.notifs.append_all (entries, false);
            s.notifs.mark_backfilled ();
        }
    }
}
