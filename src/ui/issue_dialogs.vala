/* Диалоги действий над задачей: комментарий, списание времени, связь, правка и создание задачи. */
namespace Redmine {

    private const int64 FILE_LIMIT = 25 * 1024 * 1024;

    /** Загрузка файлов на сервер: токены для вложения. Слишком большие и нечитаемые — пропускаются с тостом. */
    public async GenericArray<UploadRef>? upload_files (Gtk.Widget from, GenericArray<File> files) {
        var s = App.get ().session;
        if (s == null) return null;
        var res = new GenericArray<UploadRef> ();
        var w = win_of (from);
        foreach (var f in files) {
            var name = f.get_basename ();
            try {
                var info = yield f.query_info_async (FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE);
                if (info.get_size () > FILE_LIMIT) { w?.toast (_("File %s is larger than 25 MB").printf (name)); continue; }
                uint8[] data;
                yield f.load_contents_async (null, out data, null);
                var ct = ContentType.get_mime_type (info.get_content_type () ?? "") ?? "application/octet-stream";
                res.add (yield s.api.upload (new Bytes (data), name, ct));
            } catch (Error e) {
                w?.toast (_("Could not upload %s: %s").printf (name, e.message));
                return null;
            }
        }
        return res;
    }

    /** Диалог с кнопками «Отмена» / действие в шапке (HIG: подтверждающее действие справа). */
    public abstract class FormDialog : Adw.Dialog {
        protected Gtk.Button ok_btn;
        protected Adw.ToastOverlay toasts;
        protected Gtk.Box content_box;
        protected bool busy = false;

        protected void setup (string title, string ok_label, int width = 560, int height = 640) {
            this.title = title;
            content_width = width;
            content_height = height;
            var hb = new Adw.HeaderBar () { show_end_title_buttons = false, show_start_title_buttons = false };
            var cancel = new Gtk.Button.with_mnemonic (_("_Cancel"));
            cancel.clicked.connect (() => close ());
            hb.pack_start (cancel);
            ok_btn = new Gtk.Button.with_mnemonic (ok_label);
            ok_btn.add_css_class ("suggested-action");
            ok_btn.clicked.connect (() => { if (!busy) submit.begin (); });
            hb.pack_end (ok_btn);
            content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 12 };
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            toasts = new Adw.ToastOverlay () { child = new Gtk.ScrolledWindow () { child = new Adw.Clamp () { child = content_box, maximum_size = 760 }, hscrollbar_policy = Gtk.PolicyType.NEVER } };
            tv.content = toasts;
            child = tv;
            default_widget = ok_btn;
        }

        protected void set_busy (bool b) {
            busy = b;
            ok_btn.sensitive = !b;
            if (b) ok_btn.child = new Adw.Spinner ();
        }

        protected void fail (Error e, string label) {
            set_busy (false);
            ok_btn.child = null;
            ok_btn.use_underline = true;
            ok_btn.label = label;
            toasts.add_toast (new Adw.Toast (e.message) { timeout = 6, use_markup = false });
        }

        protected abstract async void submit ();
    }

    public Gtk.ListBox boxed_list () {
        var l = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
        l.add_css_class ("boxed-list");
        return l;
    }

    /** Текущая правка/ответ: черновик комментария по задаче переживает закрытие диалога. */
    private HashTable<int, string>? drafts = null;

    /**
     * Комментарий: новый, ответ с цитатой (reply_to) или правка своего (editing). Охрана приватности как в
     * Android: цитата приватного комментария без права на приватные заметки не вставляется (ушла бы публично),
     * а «приватный» комментарий без этого права не отправляется.
     */
    public class CommentDialog : FormDialog {
        public signal void sent ();
        private Issue issue;
        private Perms can;
        private Json.Object? editing;
        private TextileEditor editor;
        private Adw.SwitchRow priv;
        private Gtk.Label warn;
        private GenericArray<File> files = new GenericArray<File> ();
        private Gtk.ListBox files_list;
        private bool sent_ok = false;

        public CommentDialog (Issue issue, Perms can, Json.Object? editing, Json.Object? reply_to) {
            this.issue = issue;
            this.can = can;
            this.editing = editing;
            setup (editing != null ? _("Edit Comment") : _("Add Comment"), editing != null ? _("_Save") : _("_Send"), 640, 620);
            if (drafts == null) drafts = new HashTable<int, string> (direct_hash, direct_equal);
            editor = new TextileEditor (220);
            editor.attachments = issue.attachments;
            editor.submit.connect (() => { if (!busy) submit.begin (); });
            content_box.append (editor);

            warn = new Gtk.Label ("") { wrap = true, xalign = 0, visible = false };
            warn.add_css_class ("warning");
            content_box.append (warn);

            var opts = boxed_list ();
            priv = new Adw.SwitchRow () { title = _("Private note") };
            opts.append (priv);
            content_box.append (opts);

            if (editing != null) {
                editor.text = jstr (editing, "notes");
                priv.active = jbool (editing, "private_notes");
                // менять пометку нельзя — сервер оставит прежнюю; так и показываем
                var st = can.state ("set_notes_private");
                if (st == 0) { priv.sensitive = false; if (priv.active) show_warn (_("Private comment. You may not change this flag: it will stay private.")); }
                else if (st < 0) show_warn (_("Could not find out whether you may change the private flag. If not, the server will keep it as it was."));
            } else {
                editor.text = drafts[issue.id] ?? "";
                if (reply_to != null) {
                    var reply_private = jbool (reply_to, "private_notes");
                    if (reply_private && can.state ("set_notes_private") == 0) {
                        show_warn (_("The private comment was not quoted: you may not write private notes, and a reply with its text would be visible to everyone. You can reply without the quote."));
                    } else {
                        if (reply_private) priv.active = true;
                        var q = quote_reply (jstr (jobj (reply_to, "user"), "name"), 0, jstr (reply_to, "notes"), ui_lang ()) ?? "";
                        var cur = editor.text.strip ();
                        editor.text = (cur != "" ? cur + "\n\n" : "") + q;
                    }
                }
                files_list = boxed_list ();
                var add = new Adw.ButtonRow () { title = _("Attach Files…"), start_icon_name = "mail-attachment-symbolic" };
                add.activated.connect (() => pick.begin ());
                files_list.append (add);
                content_box.append (files_list);
            }
            priv.notify["active"].connect (check_private);
            check_private ();
            closed.connect (() => {
                if (editing == null && !sent_ok) {
                    if (editor.text.strip () != "") drafts[issue.id] = editor.text; else drafts.remove (issue.id);
                }
            });
            Idle.add (() => { editor.focus_text (); return Source.REMOVE; });
        }

        private void show_warn (string t) {
            warn.label = t;
            warn.visible = true;
        }

        private void check_private () {
            if (editing != null) return;
            var st = can.state ("set_notes_private");
            if (priv.active && st == 0) show_warn (_("You may not write private notes: the server would publish this comment openly. Remove what must stay private and clear “Private note” to send."));
            else if (priv.active && st < 0) show_warn (_("Could not find out whether you may write private notes. If not, the server will publish this comment openly."));
            else if (!warn.label.has_prefix (_("The private comment was not quoted")))
                warn.visible = false;
            ok_btn.sensitive = !(priv.active && st == 0);
        }

        private async void pick () {
            try {
                var fs = yield new Gtk.FileDialog () { title = _("Attach Files") }.open_multiple (get_root () as Gtk.Window, null);
                for (uint i = 0; i < fs.get_n_items (); i++) {
                    var f = (File) fs.get_item (i);
                    files.add (f);
                    var r = new Adw.ActionRow () { title = Markup.escape_text (f.get_basename ()) };
                    var rm = new Gtk.Button.from_icon_name ("list-remove-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Remove %s").printf (f.get_basename ()) };
                    rm.add_css_class ("flat");
                    rm.clicked.connect (() => { files.remove (f); files_list.remove (r); });
                    r.add_suffix (rm);
                    files_list.append (r);
                }
            } catch (Error e) {}
        }

        protected override async void submit () {
            var s = App.get ().session;
            var text = editor.text.strip ();
            if (s == null || (text == "" && files.length == 0 && editing == null)) return;
            set_busy (true);
            try {
                if (editing != null) {
                    bool? p = can.state ("set_notes_private") == 0 ? null : (bool?) priv.active;
                    yield s.api.update_journal (jint (editing, "id"), text, p);
                } else {
                    var f = new Json.Object ();
                    f.set_string_member ("notes", text);
                    if (priv.active) f.set_boolean_member ("private_notes", true);
                    if (files.length > 0) {
                        var ups = yield upload_files (this, files);
                        if (ups == null) { set_busy (false); ok_btn.child = null; ok_btn.label = _("_Send"); return; }
                        f.set_array_member ("uploads", Client.uploads_json (ups));
                    }
                    yield s.api.update_issue (issue.id, f);
                    drafts.remove (issue.id);
                }
                sent_ok = true;
                sent ();
                close ();
            } catch (Error e) {
                fail (e, editing != null ? _("_Save") : _("_Send"));
            }
        }
    }

    /** Строка выбора из списка (ComboRow) с id значений; поиск — для длинных списков. */
    public class Choice : Adw.ComboRow {
        private int[] _ids = {};
        public int[] ids { get { return _ids; } }
        private Gtk.StringList strings = new Gtk.StringList (null);

        public Choice (string title, bool search = false) {
            this.title = title;
            model = strings;
            if (search) {
                enable_search = true;
                expression = new Gtk.PropertyExpression (typeof (Gtk.StringObject), null, "string");
            }
        }

        public void add (int id, string label) {
            _ids += id;
            strings.append (label);
        }

        public void clear () {
            _ids = {};
            strings.splice (0, strings.get_n_items (), null);
        }

        public int selected_id {
            get { return selected < _ids.length ? _ids[selected] : 0; }
            set {
                for (int i = 0; i < _ids.length; i++) if (_ids[i] == value) { selected = i; return; }
            }
        }
    }

    /** Дата YYYY-MM-DD: поле + календарь во всплывающем окне + очистка. */
    public class DateRow : Adw.EntryRow {
        public DateRow (string title, string value) {
            this.title = title;
            text = value;
            input_purpose = Gtk.InputPurpose.DIGITS;
            var cal = new Gtk.Calendar ();
            var pop = new Gtk.Popover () { child = cal };
            var btn = new Gtk.MenuButton () { icon_name = "x-office-calendar-symbolic", popover = pop, valign = Gtk.Align.CENTER, tooltip_text = _("Pick a Date") };
            btn.add_css_class ("flat");
            pop.show.connect (() => {
                var dt = new DateTime.from_iso8601 ((text.length == 10 ? text : today_str ()) + "T00:00:00", new TimeZone.local ());
                if (dt != null) cal.select_day (dt);
            });
            cal.day_selected.connect (() => { text = cal.get_date ().format ("%Y-%m-%d"); pop.popdown (); });
            add_suffix (btn);
            var clear = new Gtk.Button.from_icon_name ("edit-clear-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Clear") };
            clear.add_css_class ("flat");
            clear.clicked.connect (() => text = "");
            add_suffix (clear);
        }

        public bool valid () { return text == "" || /^\d{4}-\d{2}-\d{2}$/.match (text); }
    }

    /** Списание времени: новое или правка своего; дата — любая (не только сегодня). */
    public class TimeDialog : FormDialog {
        public signal void saved ();
        private int issue_id;
        private Json.Object? entry;
        private Adw.EntryRow hours;
        private Choice activity;
        private Adw.EntryRow comment;
        private DateRow date;

        public TimeDialog (int issue_id, Json.Object? entry) {
            this.issue_id = issue_id;
            this.entry = entry;
            setup (entry != null ? _("Edit Time Entry") : _("Log Time"), _("_Save"), 480, 420);
            var list = boxed_list ();
            hours = new Adw.EntryRow () { title = _("Hours"), input_purpose = Gtk.InputPurpose.NUMBER };
            activity = new Choice (_("Activity"));
            comment = new Adw.EntryRow () { title = _("Comment") };
            date = new DateRow (_("Date"), entry != null ? jstr (entry, "spent_on") : today_str ());
            list.append (hours);
            list.append (activity);
            list.append (comment);
            list.append (date);
            content_box.append (list);
            if (entry != null) {
                hours.text = format_hours (jdouble (entry, "hours"));
                comment.text = jstr (entry, "comments");
            }
            hours.entry_activated.connect (() => submit.begin ());
            focus_widget = hours;
            load.begin ();
        }

        private async void load () {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var def = 0;
                foreach (var a in yield s.refs.activities ()) {
                    activity.add (jint (a, "id"), jstr (a, "name"));
                    if (jbool (a, "is_default")) def = jint (a, "id");
                }
                activity.selected_id = entry != null ? jint (jobj (entry, "activity"), "id") : def;
            } catch (Error e) {
                activity.visible = false;
            }
        }

        protected override async void submit () {
            var s = App.get ().session;
            var h = parse_hours (hours.text);
            if (s == null) return;
            if (h <= 0) { toasts.add_toast (new Adw.Toast (_("Enter the hours, for example 1.5 or 1:30"))); return; }
            if (!date.valid ()) { toasts.add_toast (new Adw.Toast (_("Date format: YYYY-MM-DD"))); return; }
            set_busy (true);
            try {
                yield s.api.save_time (entry != null ? jint (entry, "id") : 0, issue_id, h, activity.visible ? activity.selected_id : 0,
                    comment.text.strip (), date.text != "" ? date.text : null);
                saved ();
                close ();
            } catch (Error e) {
                fail (e, _("_Save"));
            }
        }
    }

    /** Новая связь: тип, задача (поиск по номеру или теме), задержка для «предшествует/следует». */
    public class RelationDialog : FormDialog {
        public signal void done ();
        private int issue_id;
        private Choice type;
        private Adw.ActionRow target;
        private Adw.SpinRow delay;
        private Issue? picked = null;
        private const string[] TYPES = { "relates", "duplicates", "duplicated", "blocks", "blocked", "precedes", "follows", "copied_to", "copied_from" };

        public RelationDialog (int issue_id) {
            this.issue_id = issue_id;
            setup (_("Add Relation"), _("_Add"), 480, 420);
            var list = boxed_list ();
            type = new Choice (_("Type"));
            for (int i = 0; i < TYPES.length; i++) type.add (i, relation_label (TYPES[i]));
            list.append (type);
            target = new Adw.ActionRow () { title = _("Issue"), subtitle = _("Not selected"), activatable = true };
            target.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            target.activated.connect (() => {
                var d = new IssuePickerDialog (_("Find Issue")) { exclude = issue_id };
                d.picked.connect ((i) => { picked = i; target.subtitle = Markup.escape_text ("#%d %s".printf (i.id, i.subject)); });
                d.present (this);
            });
            list.append (target);
            delay = new Adw.SpinRow.with_range (0, 365, 1) { title = _("Delay, days"), visible = false };
            list.append (delay);
            type.notify["selected"].connect (() => {
                var t = TYPES[type.selected];
                delay.visible = t == "precedes" || t == "follows";
            });
            content_box.append (list);
        }

        protected override async void submit () {
            var s = App.get ().session;
            if (s == null) return;
            if (picked == null) { toasts.add_toast (new Adw.Toast (_("Choose an issue"))); return; }
            set_busy (true);
            try {
                var t = TYPES[type.selected];
                yield s.api.add_relation (issue_id, t, picked.id, delay.visible ? (int) delay.value : -1);
                done ();
                close ();
            } catch (Error e) {
                fail (e, _("_Add"));
            }
        }
    }

    /** Поле формы для настраиваемого поля: по формату — список, флажок или текст. */
    private class CfField : Object {
        public int id;
        public string name;
        public bool required;
        public bool multiple;
        public Gtk.Widget row;
        public string original = "";

        public string value () {
            if (row is Choice) {
                var c = (Choice) row;
                return c.selected > 0 ? ((Gtk.StringObject) c.model.get_item (c.selected)).get_string () : "";
            }
            if (row is Adw.SwitchRow) return ((Adw.SwitchRow) row).active ? "1" : "0";
            return ((Adw.EntryRow) row).text.strip ();
        }
    }

    /**
     * Правка всех полей задачи (edit) или создание задачи/подзадачи (create). В правке уходят только изменённые поля.
     * Сброс значения: id = "" и дата/оценка = "" — Redmine ждёт пустую строку.
     */
    public class IssueEditDialog : FormDialog {
        public signal void created (Issue issue);
        public signal void saved ();
        private Issue? issue;
        private int parent_id;
        private Choice project;
        private Choice tracker;
        private Adw.EntryRow subject;
        private TextileEditor description;
        private Choice status;
        private Choice priority;
        private Choice assignee;
        private Choice category;
        private Choice version;
        private Adw.ActionRow parent;
        private DateRow start;
        private DateRow due;
        private Adw.EntryRow estimate;
        private Adw.SpinRow done;
        private Adw.SwitchRow is_private;
        private Adw.PreferencesGroup cf_group;
        private GenericArray<CfField> cf_fields = new GenericArray<CfField> ();
        private GenericArray<File> files = new GenericArray<File> ();
        private Gtk.ListBox files_list;
        private int project_gen = 0;

        public IssueEditDialog.create (int project_id, int parent_id) {
            this.issue = null;
            this.parent_id = parent_id;
            setup (parent_id > 0 ? _("New Subtask") : _("New Issue"), _("C_reate"), 640, 760);
            build ();
            load_projects.begin (project_id);
        }

        public IssueEditDialog.edit (Issue issue) {
            this.issue = issue;
            this.parent_id = issue.parent_id;
            setup (_("Edit Issue"), _("_Save"), 640, 760);
            build ();
            project.add (issue.project.id, issue.project.name);
            project.sensitive = false;
            subject.text = issue.subject;
            description.text = issue.description;
            description.attachments = issue.attachments;
            start.text = issue.start_date;
            due.text = issue.due_date;
            estimate.text = issue.has_estimate ? format_hours (issue.estimated_hours) : "";
            done.value = issue.done_ratio;
            is_private.active = issue.is_private;
            load_project.begin (issue.project.id);
        }

        private void build () {
            var main = new Adw.PreferencesGroup ();
            project = new Choice (_("Project"), true);
            tracker = new Choice (_("Tracker"));
            subject = new Adw.EntryRow () { title = _("Subject") };
            main.add (project);
            main.add (tracker);
            main.add (subject);
            content_box.append (main);

            var dg = new Adw.PreferencesGroup () { title = _("Description") };
            description = new TextileEditor (180);
            dg.add (description);
            content_box.append (dg);

            var g = new Adw.PreferencesGroup () { title = _("Fields") };
            status = new Choice (_("Status"));
            priority = new Choice (_("Priority"));
            assignee = new Choice (_("Assignee"), true);
            category = new Choice (_("Category"));
            version = new Choice (_("Version"));
            g.add (status);
            g.add (priority);
            g.add (assignee);
            g.add (category);
            g.add (version);
            parent = new Adw.ActionRow () { title = _("Parent issue"), activatable = true };
            parent.subtitle = parent_id > 0 ? "#%d".printf (parent_id) : _("None");
            var clear_parent = new Gtk.Button.from_icon_name ("edit-clear-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Clear") };
            clear_parent.add_css_class ("flat");
            clear_parent.clicked.connect (() => { parent_id = 0; parent.subtitle = _("None"); });
            parent.add_suffix (clear_parent);
            parent.activated.connect (() => {
                var d = new IssuePickerDialog (_("Parent issue")) { exclude = issue != null ? issue.id : 0 };
                d.picked.connect ((i) => { parent_id = i.id; parent.subtitle = Markup.escape_text ("#%d %s".printf (i.id, i.subject)); });
                d.present (this);
            });
            g.add (parent);
            start = new DateRow (_("Start date"), "");
            due = new DateRow (_("Due date"), "");
            estimate = new Adw.EntryRow () { title = _("Estimate, hours"), input_purpose = Gtk.InputPurpose.NUMBER };
            done = new Adw.SpinRow.with_range (0, 100, 10) { title = _("Progress, %") };
            is_private = new Adw.SwitchRow () { title = _("Private issue") };
            g.add (start);
            g.add (due);
            g.add (estimate);
            g.add (done);
            g.add (is_private);
            content_box.append (g);
            status.visible = issue != null;
            done.visible = issue != null;

            cf_group = new Adw.PreferencesGroup () { title = _("Custom fields"), visible = false };
            content_box.append (cf_group);

            if (issue == null) {
                files_list = boxed_list ();
                var add = new Adw.ButtonRow () { title = _("Attach Files…"), start_icon_name = "mail-attachment-symbolic" };
                add.activated.connect (() => pick.begin ());
                files_list.append (add);
                var fg = new Adw.PreferencesGroup () { title = _("Files") };
                fg.add (files_list);
                content_box.append (fg);
            }
            project.notify["selected"].connect (() => {
                if (issue == null && project.selected_id > 0) load_project.begin (project.selected_id);
            });
            tracker.notify["selected"].connect (() => {
                if (project.selected_id > 0) load_custom_fields.begin (project.selected_id);
            });
            focus_widget = subject;
        }

        private async void pick () {
            try {
                var fs = yield new Gtk.FileDialog () { title = _("Attach Files") }.open_multiple (get_root () as Gtk.Window, null);
                for (uint i = 0; i < fs.get_n_items (); i++) {
                    var f = (File) fs.get_item (i);
                    files.add (f);
                    var r = new Adw.ActionRow () { title = Markup.escape_text (f.get_basename ()) };
                    var rm = new Gtk.Button.from_icon_name ("list-remove-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Remove %s").printf (f.get_basename ()) };
                    rm.add_css_class ("flat");
                    rm.clicked.connect (() => { files.remove (f); files_list.remove (r); });
                    r.add_suffix (rm);
                    files_list.append (r);
                }
            } catch (Error e) {}
        }

        private async void load_projects (int project_id) {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var ps = s.refs.projects_cached () ?? yield s.refs.projects ();
                var sorted = new GenericArray<Json.Object> ();
                foreach (var p in ps) if (jint (p, "status", 1) == 1) sorted.add (p);
                sorted.sort ((a, b) => strcmp (jstr (a, "name").casefold (), jstr (b, "name").casefold ()));
                foreach (var p in sorted) project.add (jint (p, "id"), jstr (p, "name"));
                if (project_id > 0) project.selected_id = project_id;
                if (project.selected_id > 0) yield load_project (project.selected_id);
            } catch (Error e) {
                toasts.add_toast (new Adw.Toast (e.message));
            }
        }

        /** Справочники проекта: трекеры, участники, категории, версии; статусы и приоритеты — общие. */
        private async void load_project (int pid) {
            var s = App.get ().session;
            if (s == null) return;
            var my = ++project_gen;
            try {
                var proj = yield s.refs.project (pid);
                var prios = yield s.refs.priorities ();
                var members = yield s.refs.members (pid);
                GenericArray<Json.Object> cats, vers;
                try { cats = yield s.refs.categories (pid); } catch (Error e) { cats = new GenericArray<Json.Object> (); }
                try { vers = yield s.refs.versions (pid); } catch (Error e) { vers = new GenericArray<Json.Object> (); }
                if (my != project_gen) return;
                tracker.clear ();
                foreach (var t in jarr (proj, "trackers")) tracker.add (jint (t, "id"), jstr (t, "name"));
                if (tracker.ids.length == 0) foreach (var t in yield s.refs.trackers ()) tracker.add (jint (t, "id"), jstr (t, "name"));
                priority.clear ();
                int def_prio = 0;
                foreach (var p in prios) { priority.add (jint (p, "id"), jstr (p, "name")); if (jbool (p, "is_default")) def_prio = jint (p, "id"); }
                assignee.clear ();
                assignee.add (0, _("Not assigned"));
                foreach (var m in members) assignee.add (m.id, m.name);
                category.clear ();
                category.add (0, _("None"));
                foreach (var c in cats) category.add (jint (c, "id"), jstr (c, "name"));
                category.visible = cats.length > 0;
                version.clear ();
                version.add (0, _("None"));
                foreach (var v in vers) if (jstr (v, "status", "open") == "open" || (issue != null && issue.fixed_version != null && issue.fixed_version.id == jint (v, "id")))
                    version.add (jint (v, "id"), jstr (v, "name"));
                version.visible = version.ids.length > 1;
                if (issue != null) {
                    tracker.selected_id = issue.tracker.id;
                    priority.selected_id = issue.priority.id;
                    var a = issue.assigned_to;
                    if (a != null) {
                        bool found = false;
                        foreach (var id in assignee.ids) if (id == a.id) found = true;
                        if (!found) assignee.add (a.id, a.name);
                        assignee.selected_id = a.id;
                    }
                    var c = issue.category;
                    if (c != null) category.selected_id = c.id;
                    var v = issue.fixed_version;
                    if (v != null) version.selected_id = v.id;
                    status.clear ();
                    status.add (issue.status.id, issue.status.name);
                    var allowed = issue.allowed_statuses;
                    if (allowed != null) foreach (var st in allowed) if (jint (st, "id") != issue.status.id) status.add (jint (st, "id"), jstr (st, "name"));
                    status.selected_id = issue.status.id;
                } else {
                    priority.selected_id = def_prio;
                }
                yield load_custom_fields (pid);
            } catch (Error e) {
                toasts.add_toast (new Adw.Toast (e.message));
            }
        }

        /**
         * Настраиваемые поля проекта и трекера. Описания (/custom_fields.json) у не-админа закрыты — тогда поля
         * идут текстом по именам из проекта; обязательность и списки значений известны только с описаниями.
         */
        private async void load_custom_fields (int pid) {
            var s = App.get ().session;
            if (s == null) return;
            var my = project_gen;
            GenericArray<Json.Object> defs;
            Json.Object proj;
            try {
                defs = yield s.refs.custom_field_defs ();
                proj = yield s.refs.project (pid);
            } catch (Error e) { return; }
            if (my != project_gen) return;
            foreach (var f in cf_fields) cf_group.remove (f.row);
            cf_fields = new GenericArray<CfField> ();
            var current = new HashTable<int, Json.Object> (direct_hash, direct_equal);
            if (issue != null) foreach (var cf in issue.custom_fields) current[jint (cf, "id")] = cf;
            var tid = tracker.selected_id;
            var ids = new GenericArray<Json.Object> ();
            foreach (var cf in jarr (proj, "issue_custom_fields")) ids.add (cf);
            // правка: поля задачи, даже если проект не сообщил список
            if (ids.length == 0 && issue != null) foreach (var cf in issue.custom_fields) ids.add (cf);
            foreach (var cf in ids) {
                var id = jint (cf, "id");
                Json.Object? def = null;
                foreach (var d in defs) if (jint (d, "id") == id) def = d;
                if (def != null) {
                    var trs = jarr (def, "trackers");
                    bool ok = trs.length == 0;
                    foreach (var t in trs) if (jint (t, "id") == tid) ok = true;
                    if (!ok) continue;
                }
                var f = new CfField () { id = id, name = jstr (cf, "name"), required = def != null && jbool (def, "is_required"), multiple = def != null && jbool (def, "multiple") };
                var cur = current[id];
                f.original = cur != null ? json_value_display (cur.get_member ("value")) : (def != null ? jstr (def, "default_value") : "");
                var fmt = def != null ? jstr (def, "field_format") : "";
                var title = Markup.escape_text (f.name) + (f.required ? " *" : "");
                var pv = def != null ? jarr (def, "possible_values") : new GenericArray<Json.Object> ();
                if ((fmt == "list" || fmt == "enumeration") && pv.length > 0 && !f.multiple) {
                    var c = new Choice (title);
                    c.add (0, "—");
                    int k = 1;
                    foreach (var v in pv) {
                        c.add (k, jstr (v, "value"));
                        if (jstr (v, "value") == f.original) c.selected = k;
                        k++;
                    }
                    f.row = c;
                } else if (fmt == "bool") {
                    f.row = new Adw.SwitchRow () { title = title, active = f.original == "1" };
                } else {
                    f.row = new Adw.EntryRow () { title = title, text = f.original };
                }
                cf_group.add (f.row);
                cf_fields.add (f);
            }
            cf_group.visible = cf_fields.length > 0;
        }

        private void put_id (Json.Object o, string key, int v, int old) {
            if (v == old) return;
            if (v == 0) o.set_string_member (key, ""); else o.set_int_member (key, v);
        }

        private void put_str (Json.Object o, string key, string v, string old) {
            if (v != old) o.set_string_member (key, v);
        }

        protected override async void submit () {
            var s = App.get ().session;
            if (s == null) return;
            if (subject.text.strip () == "") { toasts.add_toast (new Adw.Toast (_("Enter the subject"))); return; }
            if (project.selected_id == 0) { toasts.add_toast (new Adw.Toast (_("Choose a project"))); return; }
            if (!start.valid () || !due.valid ()) { toasts.add_toast (new Adw.Toast (_("Date format: YYYY-MM-DD"))); return; }
            var est = estimate.text.strip ();
            if (est != "" && parse_hours (est) <= 0) { toasts.add_toast (new Adw.Toast (_("Enter the estimate in hours"))); return; }
            string[] missing = {};
            foreach (var f in cf_fields) if (f.required && f.value () == "") missing += f.name;
            if (missing.length > 0) { toasts.add_toast (new Adw.Toast (_("Fill in the required fields: %s").printf (string.joinv (", ", missing)))); return; }

            var o = new Json.Object ();
            var est_val = est == "" ? "" : format_hours (parse_hours (est));
            if (issue == null) {
                o.set_int_member ("project_id", project.selected_id);
                if (tracker.selected_id > 0) o.set_int_member ("tracker_id", tracker.selected_id);
                o.set_string_member ("subject", subject.text.strip ());
                if (description.text.strip () != "") o.set_string_member ("description", description.text);
                if (priority.selected_id > 0) o.set_int_member ("priority_id", priority.selected_id);
                if (assignee.selected_id > 0) o.set_int_member ("assigned_to_id", assignee.selected_id);
                if (category.selected_id > 0) o.set_int_member ("category_id", category.selected_id);
                if (version.selected_id > 0) o.set_int_member ("fixed_version_id", version.selected_id);
                if (parent_id > 0) o.set_int_member ("parent_issue_id", parent_id);
                if (start.text != "") o.set_string_member ("start_date", start.text);
                if (due.text != "") o.set_string_member ("due_date", due.text);
                if (est_val != "") o.set_string_member ("estimated_hours", est_val);
                if (is_private.active) o.set_boolean_member ("is_private", true);
            } else {
                var i = issue;
                put_id (o, "tracker_id", tracker.selected_id, i.tracker.id);
                put_str (o, "subject", subject.text.strip (), i.subject);
                put_str (o, "description", description.text, i.description);
                put_id (o, "status_id", status.selected_id, i.status.id);
                put_id (o, "priority_id", priority.selected_id, i.priority.id);
                var a = i.assigned_to;
                put_id (o, "assigned_to_id", assignee.selected_id, a != null ? a.id : 0);
                var c = i.category;
                put_id (o, "category_id", category.selected_id, c != null ? c.id : 0);
                var v = i.fixed_version;
                put_id (o, "fixed_version_id", version.selected_id, v != null ? v.id : 0);
                put_id (o, "parent_issue_id", parent_id, i.parent_id);
                put_str (o, "start_date", start.text, i.start_date);
                put_str (o, "due_date", due.text, i.due_date);
                put_str (o, "estimated_hours", est_val, i.has_estimate ? format_hours (i.estimated_hours) : "");
                if ((int) done.value != i.done_ratio) o.set_int_member ("done_ratio", (int) done.value);
                if (is_private.active != i.is_private) o.set_boolean_member ("is_private", is_private.active);
            }
            var cfa = new Json.Array ();
            foreach (var f in cf_fields) {
                var v = f.value ();
                if (issue != null && v == f.original) continue;
                if (issue == null && v == "") continue;
                var co = new Json.Object ();
                co.set_int_member ("id", f.id);
                if (f.multiple) {
                    var arr = new Json.Array ();
                    foreach (var part in v.split (",")) if (part.strip () != "") arr.add_string_element (part.strip ());
                    co.set_array_member ("value", arr);
                } else co.set_string_member ("value", v);
                cfa.add_object_element (co);
            }
            if (cfa.get_length () > 0) o.set_array_member ("custom_fields", cfa);
            if (issue != null && o.get_size () == 0) { close (); return; }

            set_busy (true);
            try {
                if (files.length > 0) {
                    var ups = yield upload_files (this, files);
                    if (ups == null) { set_busy (false); ok_btn.child = null; ok_btn.label = issue == null ? _("C_reate") : _("_Save"); return; }
                    o.set_array_member ("uploads", Client.uploads_json (ups));
                }
                if (issue == null) {
                    var created_issue = yield s.api.create_issue (o);
                    created (created_issue);
                } else {
                    yield s.api.update_issue (issue.id, o);
                    saved ();
                }
                close ();
            } catch (Error e) {
                fail (e, issue == null ? _("C_reate") : _("_Save"));
            }
        }
    }
}
