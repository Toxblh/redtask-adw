/*
 * Уведомления: модель записи истории, категории, разбор журнала на категории, фильтр «уведомлять ли».
 * Без GTK и GSettings — покрыто tests/. Порт NotifStore.kt / PollWorker.kt (PollCollector) / Settings.kt.
 */
namespace Redmine {

    /** Типы событий истории (строки, а не enum — файл старой версии читается новой и наоборот). */
    namespace NotifType {
        public const string ASSIGNED = "assigned";
        public const string COMMENT = "comment";
        public const string STATUS = "status";
        public const string PRIORITY = "priority";
        public const string DUE = "due";
        public const string ATTACHMENT = "attachment";
        public const string PRIVATE_NOTE = "private_note";
        public const string OTHER = "other";
        public const string REASSIGNED_AWAY = "reassigned_away";
        public const string TIME_LOGGED = "time_logged";
        public const string DUE_SOON = "due_soon";
        public const string NEW_ISSUE = "new_issue";
        public const string MENTION = "mention";
    }

    /** Группа категорий (фильтр колокольчика и приоритет системного уведомления). */
    public enum NotifGroup { ME, DISCUSSION, PROGRESS, DEADLINES, PROJECTS;
        public string label () {
            switch (this) {
                case ME: return _("For me");
                case DISCUSSION: return _("Discussion");
                case PROGRESS: return _("Progress");
                case DEADLINES: return _("Deadlines");
                default: return _("Projects");
            }
        }
        public GLib.NotificationPriority priority () {
            switch (this) {
                case ME: return GLib.NotificationPriority.HIGH;
                case PROJECTS: return GLib.NotificationPriority.LOW;
                default: return GLib.NotificationPriority.NORMAL;
            }
        }
    }

    public struct NotifCategory {
        public string type;
        public NotifGroup group;
        public bool default_on;
    }

    public const NotifCategory[] CATEGORIES = {
        { NotifType.ASSIGNED, NotifGroup.ME, true },
        { NotifType.REASSIGNED_AWAY, NotifGroup.ME, true },
        { NotifType.MENTION, NotifGroup.ME, true },
        { NotifType.COMMENT, NotifGroup.DISCUSSION, true },
        { NotifType.PRIVATE_NOTE, NotifGroup.DISCUSSION, true },
        { NotifType.STATUS, NotifGroup.PROGRESS, true },
        { NotifType.PRIORITY, NotifGroup.PROGRESS, true },
        { NotifType.DUE, NotifGroup.PROGRESS, true },
        { NotifType.ATTACHMENT, NotifGroup.PROGRESS, true },
        { NotifType.TIME_LOGGED, NotifGroup.PROGRESS, true },
        { NotifType.OTHER, NotifGroup.PROGRESS, false },
        { NotifType.DUE_SOON, NotifGroup.DEADLINES, true },
        { NotifType.NEW_ISSUE, NotifGroup.PROJECTS, false },
    };

    /** Неизвестный тип (запись другой версии) — «прочее», а не падение. */
    public NotifGroup group_of (string type) {
        foreach (var c in CATEGORIES) if (c.type == type) return c.group;
        return NotifGroup.PROGRESS;
    }

    public string category_label (string type) {
        switch (type) {
            case NotifType.ASSIGNED: return _("Assigned to me");
            case NotifType.REASSIGNED_AWAY: return _("Left me: reassigned or deleted");
            case NotifType.MENTION: return _("Mentions");
            case NotifType.COMMENT: return _("New comment");
            case NotifType.PRIVATE_NOTE: return _("Private note");
            case NotifType.STATUS: return _("Status change");
            case NotifType.PRIORITY: return _("Priority change");
            case NotifType.DUE: return _("Due date changed");
            case NotifType.ATTACHMENT: return _("Attachments");
            case NotifType.TIME_LOGGED: return _("Time logged");
            case NotifType.DUE_SOON: return _("Due tomorrow, today or overdue");
            case NotifType.NEW_ISSUE: return _("New issue in my projects");
            default: return _("Other field changes");
        }
    }

    public string category_icon (string type) {
        switch (type) {
            case NotifType.ASSIGNED: return "avatar-default-symbolic";
            case NotifType.REASSIGNED_AWAY: return "go-jump-symbolic";
            case NotifType.MENTION: return "user-available-symbolic";
            case NotifType.COMMENT: return "chat-message-new-symbolic";
            case NotifType.PRIVATE_NOTE: return "dialog-password-symbolic";
            case NotifType.STATUS: return "emblem-system-symbolic";
            case NotifType.PRIORITY: return "mail-mark-important-symbolic";
            case NotifType.DUE: case NotifType.DUE_SOON: return "alarm-symbolic";
            case NotifType.ATTACHMENT: return "mail-attachment-symbolic";
            case NotifType.TIME_LOGGED: return "alarm-symbolic";
            case NotifType.NEW_ISSUE: return "list-add-symbolic";
            default: return "document-edit-symbolic";
        }
    }

    /** Одно уведомление в истории колокольчика. */
    public class NotifEntry : Object {
        public int issue_id;
        public string subject = "";
        public string project = "";
        public int project_id = 0;       // 0 — неизвестен (записи «задача удалена»)
        public string[] lines = {};
        public int64 at;
        public int avatar_user_id = 0;   // 0 — автора нет (срок)
        public string type = NotifType.OTHER;
        /** Ключ события внутри задачи («j123» — журнал, «t45» — списание, «due:2026-01-31»…): по нему дедуп. */
        public string event_id = "";
        /** Значимое внутри типа: статус — закрыли/решили, приоритет — повысили. Не удалось определить — значимое. */
        public bool strong = true;
        /** Остальные категории того же события: тип → значимость. */
        public HashTable<string, bool> also = new HashTable<string, bool> (str_hash, str_equal);
        public string author = "";
        /** Вложение-картинка события (notification_image), 0 — нет. */
        public int image_id = 0;

        public string key { owned get { return "%d-%s".printf (issue_id, event_id != "" ? event_id : at.to_string ()); } }

        /** id журнала, если событие — журнал («j123»): к нему ведёт клик. */
        public int journal_id {
            get {
                int v = 0;
                if (event_id.has_prefix ("j") && int.try_parse (event_id.substring (1), out v)) return v;
                return 0;
            }
        }

        public string[] types () {
            string[] t = { type };
            foreach (var k in also.get_keys ()) t += k;
            return t;
        }

        public Json.Object to_json () {
            var o = new Json.Object ();
            o.set_int_member ("issueId", issue_id);
            o.set_string_member ("subject", subject);
            o.set_string_member ("project", project);
            if (project_id != 0) o.set_int_member ("projectId", project_id);
            var a = new Json.Array ();
            foreach (var l in lines) a.add_string_element (l);
            o.set_array_member ("lines", a);
            o.set_int_member ("at", at);
            if (avatar_user_id != 0) o.set_int_member ("avatarUserId", avatar_user_id);
            o.set_string_member ("type", type);
            o.set_string_member ("eventId", event_id);
            o.set_boolean_member ("strong", strong);
            var al = new Json.Object ();
            foreach (var k in also.get_keys ()) al.set_boolean_member (k, also[k]);
            o.set_object_member ("alsoTypes", al);
            o.set_string_member ("author", author);
            if (image_id != 0) o.set_int_member ("imageId", image_id);
            return o;
        }

        public static NotifEntry from_json (Json.Object o) {
            var e = new NotifEntry ();
            e.issue_id = jint (o, "issueId");
            e.subject = jstr (o, "subject");
            e.project = jstr (o, "project");
            e.project_id = jint (o, "projectId");
            string[] ls = {};
            if (o.has_member ("lines")) o.get_array_member ("lines").foreach_element ((a, i, n) => ls += n.get_string ());
            e.lines = ls;
            e.at = o.has_member ("at") ? o.get_int_member ("at") : 0;
            e.avatar_user_id = jint (o, "avatarUserId");
            e.type = jstr (o, "type", NotifType.OTHER);
            e.event_id = jstr (o, "eventId");
            e.strong = jbool (o, "strong", true);
            var al = jobj (o, "alsoTypes");
            if (al != null) foreach (var k in al.get_members ()) e.also[k] = al.get_boolean_member (k);
            e.author = jstr (o, "author");
            e.image_id = jint (o, "imageId");
            return e;
        }
    }

    /** Что уведомляет системным уведомлением; на историю колокольчика не влияет. */
    public class NotifFilter : Object {
        public GenericSet<string> muted = new GenericSet<string> (str_hash, str_equal);
        public GenericSet<int> muted_issues = new GenericSet<int> (direct_hash, direct_equal);
        public GenericSet<int> muted_projects = new GenericSet<int> (direct_hash, direct_equal);
        public bool status_closed_only = false;
        public bool priority_raised_only = false;

        /**
         * Категории события, по которым оно уведомляет: включённые и не отсечённые подопцией «только…».
         * Пусто — уведомления нет (в том числе по отключённой задаче или проекту).
         */
        public string[] notify_types (NotifEntry e) {
            string[] res = {};
            if (muted_issues.contains (e.issue_id) || (e.project_id != 0 && muted_projects.contains (e.project_id))) return res;
            foreach (var t in e.types ()) {
                var strong = t == e.type ? e.strong : (e.also.contains (t) ? e.also[t] : true);
                var weak = !strong && ((t == NotifType.STATUS && status_closed_only) || (t == NotifType.PRIORITY && priority_raised_only));
                var known = false;
                foreach (var c in CATEGORIES) if (c.type == t) known = true;
                var cat = known ? t : NotifType.OTHER;
                if (!muted.contains (cat) && !weak) res += t;
            }
            return res;
        }

        public bool notifies (NotifEntry e) { return notify_types (e).length > 0; }
    }

    /**
     * Упомянут ли login в тексте: «@логин» целиком и без учёта регистра; «@loginX» и почта — не упоминания,
     * в цитате — упоминание (Redmine шлёт письмо и по ней).
     */
    public bool mentions (string? notes, string login) {
        if (login == "" || notes == null || notes == "") return false;
        MatchInfo mi;
        if (Textile.mention_re ().match (notes, 0, out mi)) {
            do {
                if (mi.fetch (1).down () == login.down ()) return true;
                try { if (!mi.next ()) break; } catch (RegexError e) { break; }
            } while (true);
        }
        return false;
    }

    /**
     * Категории журнала — все, а не одна: комментарий со сменой статуса относится к обеим. Порядок — что главное
     * для получателя: первая становится типом записи истории, остальные идут в also. Упоминание меня — всегда первое.
     */
    public string[] journal_types (Json.Object j, int user_id, string login = "") {
        var me = user_id.to_string ();
        Json.Object? status = null, priority = null, due = null, assignee = null;
        bool attachment = false, other = false;
        foreach (var d in jarr (j, "details")) {
            var prop = jstr (d, "property");
            var name = jstr (d, "name");
            if (prop == "attachment") { attachment = true; continue; }
            if (prop != "attr") { other = true; continue; }
            switch (name) {
                case "status_id": status = d; break;
                case "priority_id": priority = d; break;
                case "due_date": due = d; break;
                case "assigned_to_id": assignee = d; break;
                default: other = true; break;
            }
        }
        var to_me = assignee != null && jstr (assignee, "new_value") == me;
        var from_me = !to_me && assignee != null && jstr (assignee, "old_value") == me;
        if (assignee != null && !to_me && !from_me) other = true;
        var notes = jstr (j, "notes");
        string[] res = {};
        if (mentions (notes, login)) res += NotifType.MENTION;
        if (to_me) res += NotifType.ASSIGNED;
        if (from_me) res += NotifType.REASSIGNED_AWAY;
        if (status != null) res += NotifType.STATUS;
        if (notes.strip () != "") res += jbool (j, "private_notes") ? NotifType.PRIVATE_NOTE : NotifType.COMMENT;
        if (priority != null) res += NotifType.PRIORITY;
        if (due != null) res += NotifType.DUE;
        if (attachment) res += NotifType.ATTACHMENT;
        if (other) res += NotifType.OTHER;
        if (res.length == 0) res += NotifType.OTHER;
        return res;
    }

    /** Задача внутри дня в виде «По задачам»: её события за этот день, новые сначала. */
    public class NotifIssueGroup : Object {
        public int issue_id;
        public GenericArray<NotifEntry> entries = new GenericArray<NotifEntry> ();
        public NotifEntry latest { get { return entries[0]; } }
        public int journal_id {
            get {
                foreach (var e in entries) if (e.journal_id != 0) return e.journal_id;
                return 0;
            }
        }
    }

    public class NotifDay : Object {
        public string date; // YYYY-MM-DD по местному времени
        public GenericArray<NotifIssueGroup> groups = new GenericArray<NotifIssueGroup> ();
    }

    public string local_day (int64 ms, TimeZone tz) {
        return new DateTime.from_unix_utc (ms / 1000).to_timezone (tz).format ("%Y-%m-%d");
    }

    /**
     * «По задачам»: дни от нового к старому, в дне — карточка на задачу в порядке её последнего события.
     * Задача с событиями по обе стороны полуночи есть в обоих днях. entries — уже отсортированы от новых.
     */
    public GenericArray<NotifDay> group_by_issue (GenericArray<NotifEntry> entries, TimeZone tz) {
        var res = new GenericArray<NotifDay> ();
        NotifDay? day = null;
        HashTable<int, NotifIssueGroup>? idx = null;
        foreach (var e in entries) {
            var d = local_day (e.at, tz);
            if (day == null || day.date != d) {
                day = new NotifDay () { date = d };
                idx = new HashTable<int, NotifIssueGroup> (direct_hash, direct_equal);
                res.add (day);
            }
            var g = idx[e.issue_id];
            if (g == null) {
                g = new NotifIssueGroup () { issue_id = e.issue_id };
                idx[e.issue_id] = g;
                day.groups.add (g);
            }
            g.entries.add (e);
        }
        return res;
    }

    /**
     * Картинка уведомления (набор notif_image): первая !имя! из текста, если это вложение-картинка задачи
     * (имя без учёта регистра), иначе первое вложение-картинка из details журнала. 0 — картинки нет.
     */
    public int notification_image (string notes, GenericArray<Json.Object> details, GenericArray<Json.Object> attachments) {
        MatchInfo mi;
        try {
            if (Textile.image_re ().match (notes, 0, out mi)) do {
                var name = mi.fetch (1).down ();
                foreach (var a in attachments)
                    if (jstr (a, "filename").down () == name && jstr (a, "content_type").has_prefix ("image/")) return jint (a, "id");
            } while (mi.next ());
        } catch (RegexError e) {}
        foreach (var d in details) {
            if (jstr (d, "property") != "attachment") continue;
            foreach (var a in attachments)
                if (jstr (a, "id") == jstr (d, "name") && jstr (a, "content_type").has_prefix ("image/")) return jint (a, "id");
        }
        return 0;
    }
}
