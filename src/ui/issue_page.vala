/* Экран задачи: поля, описание, подзадачи, связи, файлы, наблюдатели, лента Комментарии/Действия/Время/Все. */
namespace Redmine {

    /** Мои права в проекте задачи. known = false — ещё не спрашивали; set == null — сервер не сообщил. */
    public class Perms : Object {
        public bool known = false;
        public GenericSet<string>? set = null;

        public bool has (string p) { return known && (set == null || set.contains ("*") || set.contains (p)); }
        /** Для решений, где «неизвестно» нельзя приравнять ни к «да», ни к «нет»: -1 неизвестно, 0 нет, 1 да. */
        public int state (string p) { return (!known || set == null) ? -1 : ((set.contains ("*") || set.contains (p)) ? 1 : 0); }
        /** Право «на любое» или «на своё»; когда права неизвестны — решает unknown (прежнее поведение). */
        public bool has_own (string any, string own, bool mine, bool unknown) {
            if (!known) return false;
            if (set == null) return unknown;
            return has (any) || (mine && has (own));
        }
    }

    public string relation_label (string t) {
        switch (t) {
            case "relates": return _("Related to");
            case "duplicates": return _("Duplicates");
            case "duplicated": return _("Duplicated by");
            case "blocks": return _("Blocks");
            case "blocked": return _("Blocked by");
            case "precedes": return _("Precedes");
            case "follows": return _("Follows");
            case "copied_to": return _("Copied to");
            case "copied_from": return _("Copied from");
            default: return t;
        }
    }

    public string field_label (string name) {
        switch (name) {
            case "status_id": return _("Status");
            case "priority_id": return _("Priority");
            case "tracker_id": return _("Tracker");
            case "assigned_to_id": return _("Assignee");
            case "fixed_version_id": return _("Version");
            case "category_id": return _("Category");
            case "project_id": return _("Project");
            case "parent_id": return _("Parent issue");
            case "done_ratio": return _("Progress");
            case "due_date": return _("Due date");
            case "start_date": return _("Start date");
            case "estimated_hours": return _("Estimate");
            case "subject": return _("Subject");
            case "description": return _("Description");
            case "is_private": return _("Private");
            default: return name;
        }
    }

    public class IssuePage : Adw.NavigationPage, Refreshable {
        public bool refreshing { get; set; }
        public int issue_id;
        private int pending_note;
        private int pending_index;
        private Issue? issue = null;
        private GenericArray<Json.Object> times = new GenericArray<Json.Object> ();
        private Perms can = new Perms ();
        /** Имена значений журналов: поле (status_id…) → id → имя. */
        private HashTable<string, HashTable<string, string>> names = new HashTable<string, HashTable<string, string>> (str_hash, str_equal);
        private GenericSet<string> closed_statuses = new GenericSet<string> (str_hash, str_equal);
        private HashTable<int, Gtk.Widget> note_widgets = new HashTable<int, Gtk.Widget> (direct_hash, direct_equal);
        private HashTable<int, Issue> linked = new HashTable<int, Issue> (direct_hash, direct_equal);
        private int[] jids = {};

        private Adw.WindowTitle wt;
        private StateView state;
        private Gtk.ScrolledWindow sw;
        private Gtk.Box body;
        private Gtk.Box? activity = null;
        private Gtk.ToggleButton star;
        private Gtk.MenuButton menu_btn;
        private Gtk.Box bottom;
        private Gtk.MenuButton status_btn;
        private Gtk.Label status_label;
        private Gtk.Button comment_btn;
        private Gtk.Button time_btn;
        private SimpleActionGroup group;
        private int gen = 0;
        private bool busy = false;

        public IssuePage (int id, int note = 0) {
            Object (title: "#%d".printf (id), tag: "issue-%d".printf (id));
            issue_id = id;
            pending_note = note;

            wt = new Adw.WindowTitle ("#%d".printf (id), "");
            var hb = new Adw.HeaderBar () { title_widget = wt };
            menu_btn = new Gtk.MenuButton () { icon_name = "view-more-symbolic", tooltip_text = _("Issue Menu") };
            hb.pack_start (refresh_button (this, () => refresh ()));
            hb.pack_end (menu_btn);
            star = new Gtk.ToggleButton () { icon_name = "non-starred-symbolic" };
            var favs = Favorites.get_default ();
            star.active = favs.has (id);
            sync_star ();
            star.toggled.connect (() => {
                sync_star ();
                var on = star.active;
                if (on == favs.has (issue_id)) return; // отражение набора, а не нажатие
                favs.set_favorite.begin (issue_id, on, (o, r) => {
                    try {
                        favs.set_favorite.end (r);
                    } catch (Error e) {
                        win_of (this)?.favorite_failed (e, issue_id, on);
                    }
                });
            });
            hb.pack_end (star);

            body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 72 }; // снизу — место под кнопку «Обновить»
            // без прокрутки к фокусу: перерисовка (права, имена) не должна уводить экран к кнопке внизу
            var vp = new Gtk.Viewport (null, null) { scroll_to_focus = false, child = new Adw.Clamp () { child = body, maximum_size = 860, tightening_threshold = 600 } };
            sw = new Gtk.ScrolledWindow () { child = vp, hscrollbar_policy = Gtk.PolicyType.NEVER, vexpand = true };
            state = new StateView (sw);
            state.retry_clicked.connect (() => load.begin ());

            bottom = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { halign = Gtk.Align.CENTER, margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
            comment_btn = new Gtk.Button () { child = new Adw.ButtonContent () { icon_name = "chat-message-new-symbolic", label = _("Comment"), can_shrink = true }, tooltip_text = _("Add Comment") };
            comment_btn.add_css_class ("suggested-action");
            comment_btn.action_name = "issue.comment";
            // длинное название статуса не должно распирать окно на телефоне
            status_label = new Gtk.Label (_("Status")) { ellipsize = Pango.EllipsizeMode.END, max_width_chars = 18 };
            status_btn = new Gtk.MenuButton () { child = status_label, tooltip_text = _("Change Status"), always_show_arrow = true };
            time_btn = new Gtk.Button () { icon_name = "alarm-symbolic", tooltip_text = _("Log Time"), action_name = "issue.log-time", valign = Gtk.Align.CENTER };
            time_btn.add_css_class ("circular");
            bottom.append (comment_btn);
            bottom.append (status_btn);
            bottom.append (time_btn);
            bottom.visible = false;

            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = state;
            tv.add_bottom_bar (bottom);
            child = tv;

            setup_actions ();
            favs.changed.connect (() => star.active = favs.has (issue_id));
            state.loading ();
            load.begin ();
            App.get ().poller.withdraw_issue (id);
        }

        private void sync_star () {
            star.icon_name = star.active ? "starred-symbolic" : "non-starred-symbolic";
            star.tooltip_text = star.active ? _("Remove from Favorites") : _("Add to Favorites");
        }

        public void refresh () { load.begin (); }

        /** #note-K из адреса на сайте: K — порядковый номер записи журнала, а не её id. */
        public void reveal_note_index (int k) {
            pending_index = k;
            if (issue != null) scroll_to_note ();
        }

        public void reveal_note (int note) {
            pending_note = note;
            if (issue != null) scroll_to_note ();
        }

        private Window? win () { return win_of (this); }

        // ---------- загрузка ----------

        private async void load () {
            var s = App.get ().session;
            if (s == null) return;
            Favorites.get_default ().refresh.begin (); // звезда — по серверу: могли поменять на сайте
            var my = ++gen;
            // мгновенно — из кэша (stale-while-revalidate), потом — свежая с сервера
            if (issue == null) {
                var c = s.cache.load ("issue-%d".printf (issue_id));
                if (c != null && c.get_node_type () == Json.NodeType.OBJECT) {
                    issue = new Issue (c.get_object ());
                    render ();
                }
            }
            refreshing = issue != null;
            fresh_tables = null;
            load_tables.begin (s, my); // HTML страницы — параллельно, показ задачи не ждёт
            try {
                var fresh = yield s.api.issue (issue_id);
                if (my != gen) return;
                refreshing = false;
                // листы согласования: свежие, если HTML уже пришёл, иначе прежние из кэша
                if (fresh_tables != null) fresh.o.set_array_member ("_custom_tables", fresh_tables);
                else if (issue != null && issue.o.has_member ("_custom_tables")) fresh.o.set_member ("_custom_tables", issue.o.get_member ("_custom_tables").copy ());
                // подписи полей лежат в кэше вместе с задачей — годны, пока задачу не меняли
                if (issue != null && issue.o.has_member ("_cf_labels") && jstr (issue.o, "updated_on") == jstr (fresh.o, "updated_on"))
                    fresh.o.set_member ("_cf_labels", issue.o.get_member ("_cf_labels").copy ());
                issue = fresh;
                s.cache.save ("issue-%d".printf (issue_id), obj_node (fresh.o));
                render ();
            } catch (Error e) {
                if (my != gen) return;
                refreshing = false;
                if (issue == null) { state.error (e); return; }
                win ()?.toast (_("Could not refresh the issue: %s").printf (e.message));
                return;
            }
            // остальное — не обязательно для показа: права, время, имена в журналах, связанные задачи
            load_perms.begin (s, my);
            load_times.begin (s, my);
            load_names.begin (s, my);
            load_linked.begin (s, my);
            if (!issue.o.has_member ("_cf_labels")) load_labels.begin (s, my);
        }

        private Json.Array? fresh_tables = null;

        /** Листы согласования (spec 10) из HTML страницы задачи; не пришло — остаётся кэш. */
        private async void load_tables (Session s, int my) {
            Json.Array t;
            try {
                t = custom_tables (yield s.api.issue_html (issue_id));
            } catch (Error e) {
                debug ("custom tables %d: %s", issue_id, e.message);
                return;
            }
            if (my != gen) return;
            fresh_tables = t;
            if (issue == null) return;
            issue.o.set_array_member ("_custom_tables", t);
            s.cache.save ("issue-%d".printf (issue_id), obj_node (issue.o));
            render ();
        }

        /** Подписи полей-списков («88» → название) из CSV-экспорта; пустой ответ не запоминаем — мог быть сбоем. */
        private async void load_labels (Session s, int my) {
            var labels = yield s.api.custom_field_labels (issue_id, issue.custom_fields);
            if (my != gen || labels.get_size () == 0) return;
            issue.o.set_object_member ("_cf_labels", labels);
            s.cache.save ("issue-%d".printf (issue_id), obj_node (issue.o));
            render ();
        }

        private async void load_perms (Session s, int my) {
            try {
                var p = yield s.refs.permissions (issue.project.id);
                if (my != gen) return;
                can = new Perms () { known = true, set = p };
            } catch (Error e) {
                can = new Perms () { known = true, set = null };
            }
            render ();
        }

        private async void load_times (Session s, int my) {
            try {
                var t = yield s.api.time_entries (issue_id);
                if (my != gen) return;
                times = t;
                render_activity ();
            } catch (Error e) {
                debug ("time entries: %s", e.message);
            }
        }

        private void put_name (string field, int id, string name) {
            var t = names[field];
            if (t == null) { t = new HashTable<string, string> (str_hash, str_equal); names[field] = t; }
            t[id.to_string ()] = name;
        }

        private async void load_names (Session s, int my) {
            try {
                foreach (var x in yield s.refs.statuses ()) {
                    put_name ("status_id", jint (x, "id"), jstr (x, "name"));
                    if (jbool (x, "is_closed")) closed_statuses.add (jint (x, "id").to_string ());
                }
                foreach (var x in yield s.refs.priorities ()) put_name ("priority_id", jint (x, "id"), jstr (x, "name"));
                foreach (var x in yield s.refs.trackers ()) put_name ("tracker_id", jint (x, "id"), jstr (x, "name"));
                foreach (var x in yield s.refs.versions (issue.project.id)) put_name ("fixed_version_id", jint (x, "id"), jstr (x, "name"));
                foreach (var x in yield s.refs.categories (issue.project.id)) put_name ("category_id", jint (x, "id"), jstr (x, "name"));
                foreach (var x in yield s.refs.members (issue.project.id)) put_name ("assigned_to_id", x.id, x.name);
            } catch (Error e) {
                debug ("names: %s", e.message);
            }
            if (my == gen) { render_activity (); build_menu (); }
        }

        /** Статусы и темы подзадач и связанных — одним пакетным запросом. */
        private async void load_linked (Session s, int my) {
            int[] ids = {};
            foreach (var c in issue.children) ids += jint (c, "id");
            foreach (var r in issue.relations) ids += relation_other (r, issue_id);
            if (issue.parent_id > 0) ids += issue.parent_id;
            if (ids.length == 0) return;
            try {
                int[] missing;
                foreach (var i in yield s.api.issues_by_ids (ids, out missing)) linked[i.id] = i;
                if (my == gen) render ();
            } catch (Error e) {
                debug ("linked issues: %s", e.message);
            }
        }

        // ---------- действия ----------

        private SimpleAction act (string name, VariantType? param = null) {
            var a = new SimpleAction (name, param);
            group.add_action (a);
            return a;
        }

        private void setup_actions () {
            group = new SimpleActionGroup ();
            act ("copy-number").activate.connect (() => { copy_text (this, "#%d".printf (issue_id)); win ()?.toast (_("Issue number copied")); });
            act ("copy-link").activate.connect (() => { copy_text (this, link ()); win ()?.toast (_("Link copied")); });
            act ("share").activate.connect (() => {
                copy_text (this, "#%d %s\n%s".printf (issue_id, issue != null ? issue.subject : "", link ()));
                win ()?.toast (_("Issue number, subject and link copied"));
            });
            act ("open-browser").activate.connect (() => new Gtk.UriLauncher (link ()).launch.begin (win (), null));
            act ("comment").activate.connect (() => open_comment (null));
            act ("log-time").activate.connect (() => open_time (null));
            act ("assign-me").activate.connect (confirm_assign);
            act ("edit").activate.connect (() => {
                if (issue == null) return;
                var d = new IssueEditDialog.edit (issue);
                d.saved.connect (() => { win ()?.toast (_("Saved")); refresh (); ListsStale.mark (); });
                d.present (this);
            });
            act ("add-subtask").activate.connect (() => { if (issue != null) win ()?.new_issue (issue.project.id, issue_id); });
            act ("add-relation").activate.connect (() => {
                var d = new RelationDialog (issue_id);
                d.done.connect (() => refresh ());
                d.present (this);
            });
            act ("attach").activate.connect (() => pick_files.begin ());
            act ("mute").activate.connect (() => {
                var p = Prefs.get_default ();
                var on = !p.muted ("muted-issues").contains (issue_id);
                p.set_muted ("muted-issues", issue_id, issue != null ? issue.subject : "", on);
                win ()?.toast (on ? _("Notifications for this issue are off") : _("Notifications for this issue are on"));
                build_menu ();
            });
            act ("watch").activate.connect (() => toggle_watch.begin ());
            act ("set-status", VariantType.INT32).activate.connect ((a, v) => set_field ("status_id", v.get_int32 ()));
            act ("set-priority", VariantType.INT32).activate.connect ((a, v) => set_field ("priority_id", v.get_int32 ()));
            act ("set-progress", VariantType.INT32).activate.connect ((a, v) => set_field ("done_ratio", v.get_int32 ()));
            insert_action_group ("issue", group);
        }

        private string link () {
            var s = App.get ().session;
            return s != null ? s.api.issue_web_url (issue_id) : "";
        }

        private bool watching () {
            if (issue == null) return false;
            foreach (var w in issue.watchers) if (jint (w, "id") == App.get ().session.user_id) return true;
            return false;
        }

        private bool can_edit () {
            return issue != null && can.has_own ("edit_issues", "edit_own_issues", issue.author.id == App.get ().session.user_id, true);
        }

        private void enable (string name, bool on) {
            var a = group.lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private void update_actions () {
            if (issue == null) return;
            var edit = can_edit ();
            foreach (var n in new string[] { "edit", "set-status", "set-priority", "set-progress", "attach", "assign-me" }) enable (n, edit);
            enable ("comment", can.has ("add_issue_notes"));
            enable ("log-time", can.has ("log_time"));
            enable ("add-subtask", can.has ("manage_subtasks") || can.has ("add_issues"));
            enable ("add-relation", can.has ("manage_issue_relations"));
            bottom.visible = can.known;
            time_btn.visible = can.has ("log_time");
            status_btn.visible = edit;
            build_menu ();
        }

        private void build_menu () {
            if (issue == null) return;
            var m = new Menu ();
            var top = new Menu ();
            if (can_edit ()) top.append (_("_Edit Issue…"), "issue.edit");
            top.append (_("Add _Subtask…"), "issue.add-subtask");
            top.append (_("Add _Relation…"), "issue.add-relation");
            top.append (_("_Attach Files…"), "issue.attach");
            m.append_section (null, top);
            if (can_edit ()) {
                var fields = new Menu ();
                var pr = names["priority_id"];
                if (pr != null) {
                    var prio = new Menu ();
                    var keys = new GenericArray<string> ();
                    foreach (var k in pr.get_keys ()) keys.add (k);
                    keys.sort ((a, b) => int.parse (a) - int.parse (b));
                    foreach (var k in keys) prio.append (pr[k], "issue.set-priority(%s)".printf (k));
                    fields.append_submenu (_("_Priority"), prio);
                }
                var prog = new Menu ();
                for (int p = 0; p <= 100; p += 10) prog.append ("%d %%".printf (p), "issue.set-progress(%d)".printf (p));
                fields.append_submenu (_("Pro_gress"), prog);
                fields.append (_("Assign to _Me"), "issue.assign-me");
                m.append_section (null, fields);
            }
            var share = new Menu ();
            share.append (_("Copy Issue _Number"), "issue.copy-number");
            share.append (_("Copy _Link"), "issue.copy-link");
            share.append (_("S_hare"), "issue.share");
            share.append (_("Open in _Browser"), "issue.open-browser");
            m.append_section (null, share);
            var other = new Menu ();
            other.append (watching () ? _("_Stop Watching") : _("_Watch"), "issue.watch");
            other.append (Prefs.get_default ().muted ("muted-issues").contains (issue_id) ? _("_Notify About This Issue") : _("_Mute Notifications"), "issue.mute");
            m.append_section (null, other);
            menu_btn.menu_model = m;

            // статусы — по allowed_statuses задачи (что разрешает рабочий процесс)
            // пункты — цветными пилюлями (PARITY 0): свой поповер вместо GMenu, тот красит только текст
            var sm = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var allowed = issue.allowed_statuses;
            int n = 0;
            if (allowed != null) foreach (var st in allowed) {
                if (jint (st, "id") == issue.status.id) continue;
                var pill = status_pill (jstr (st, "name"), jbool (st, "is_closed") || closed_statuses.contains (jint (st, "id").to_string ()));
                pill.halign = Gtk.Align.START;
                var item = new Gtk.Button () { child = pill, action_name = "issue.set-status", action_target = new Variant.int32 (jint (st, "id")) };
                item.add_css_class ("flat");
                item.clicked.connect (() => status_btn.popdown ());
                sm.append (item);
                n++;
            }
            status_btn.popover = new Gtk.Popover () { child = sm };
            status_btn.sensitive = n > 0;
            status_label.label = issue.status.name;
            status_label.css_classes = { "status-pill", status_class (issue.status.name, issue.status_closed) };
        }

        /** PUT одного поля и обновление экрана. */
        private void set_field (string field, int value) {
            var f = new Json.Object ();
            f.set_int_member (field, value);
            mutate.begin (f, _("Saved"));
        }

        public async bool mutate (Json.Object fields, string ok) {
            var s = App.get ().session;
            if (s == null || busy) return false;
            busy = true;
            try {
                yield s.api.update_issue (issue_id, fields);
                win ()?.toast (ok);
                busy = false;
                yield load ();
                ListsStale.mark ();
                return true;
            } catch (Error e) {
                win ()?.toast_error (e);
            }
            busy = false;
            return false;
        }

        private void confirm_assign () {
            if (issue == null) return;
            var d = new Adw.AlertDialog (_("Take the Issue?"), _("You will become the assignee of “%s”.").printf (issue.subject));
            d.add_response ("cancel", _("_Cancel"));
            d.add_response ("take", _("_Take"));
            d.set_response_appearance ("take", Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "take";
            d.response.connect ((r) => { if (r == "take") set_field ("assigned_to_id", App.get ().session.user_id); });
            d.present (this);
        }

        private async void toggle_watch () {
            var s = App.get ().session;
            if (s == null || issue == null) return;
            var on = !watching ();
            if (s.api.watchers_forbidden (issue_id)) { watch_on_web (); return; }
            try {
                yield s.api.set_watcher (issue_id, s.user_id, on);
                win ()?.toast (on ? _("You are watching this issue") : _("You stopped watching this issue"));
                yield load ();
            } catch (Error e) {
                if (error_code (e) == 403 || error_code (e) == 401) watch_on_web ();
                else win ()?.toast_error (e);
            }
        }

        /** Сервер не даёт менять наблюдателей через REST — открываем задачу на сайте. */
        private void watch_on_web () {
            win ()?.toast (_("The server does not allow changing watchers from the app — opening the website"));
            new Gtk.UriLauncher (link ()).launch.begin (win (), null);
        }

        private async void pick_files () {
            var fd = new Gtk.FileDialog () { title = _("Attach Files") };
            try {
                var files = yield fd.open_multiple (win (), null);
                var list = new GenericArray<File> ();
                for (uint i = 0; i < files.get_n_items (); i++) list.add ((File) files.get_item (i));
                var ups = yield upload_files (this, list);
                if (ups == null || ups.length == 0) return;
                var f = new Json.Object ();
                f.set_array_member ("uploads", Client.uploads_json (ups));
                yield mutate (f, ngettext ("File attached", "%u files attached", ups.length).printf (ups.length));
            } catch (Error e) {
                if (!(e is Gtk.DialogError)) win ()?.toast_error (e);
            }
        }

        private void open_comment (Json.Object? editing, Json.Object? reply_to = null, string? quote = null) {
            if (issue == null) return;
            var d = new CommentDialog (issue, can, editing, reply_to, quote);
            d.sent.connect (() => { refresh (); ListsStale.mark (); });
            d.present (this);
        }

        private void open_time (Json.Object? entry) {
            if (issue == null) return;
            var d = new TimeDialog (issue_id, entry);
            d.saved.connect (() => refresh ());
            d.present (this);
        }

        private void confirm (string heading, string text, string action, owned Callback cb) {
            var d = new Adw.AlertDialog (heading, text);
            d.add_response ("cancel", _("_Cancel"));
            d.add_response ("ok", action);
            d.set_response_appearance ("ok", Adw.ResponseAppearance.DESTRUCTIVE);
            d.response.connect ((r) => { if (r == "ok") cb (); });
            d.present (this);
        }

        // ---------- отрисовка ----------

        private Gtk.ListBox boxed () {
            var l = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            l.add_css_class ("boxed-list");
            return l;
        }

        private Adw.ActionRow prop (Gtk.ListBox list, string title, string value) {
            var r = new Adw.ActionRow () { title = Markup.escape_text (title), subtitle = Markup.escape_text (value), subtitle_selectable = true };
            r.add_css_class ("property");
            list.append (r);
            return r;
        }

        private void render () {
            if (issue == null) return;
            var keep = sw.vadjustment.value;
            Idle.add (() => { if (pending_note == 0 && pending_index == 0) sw.vadjustment.value = keep; return Source.REMOVE; });
            clear_box (body);
            note_widgets.remove_all ();
            var i = issue;
            jids = i.journal_ids ();
            RichText.learn (i);
            wt.title = "#%d".printf (i.id);
            wt.subtitle = i.project.name;
            title = "#%d %s".printf (i.id, i.subject);

            var meta = new Gtk.Label ("%s · %s".printf (i.tracker.name, i.project.name)) { xalign = 0, wrap = true };
            meta.add_css_class ("dim-label");
            meta.add_css_class ("caption");
            var meta_line = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            meta_line.append (status_pill (i.status.name, i.status_closed));
            meta_line.append (meta);
            body.append (meta_line);
            var subj = new Gtk.Label (i.subject) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, selectable = true, margin_top = 4 };
            subj.add_css_class ("title-2");
            body.append (subj);
            // автор — ссылкой на карточку (курсор-указатель и Tab по ссылке даёт сам GtkLabel)
            var by = new Gtk.Label (Markup.escape_text (_("Created by %s · %s")).printf ("<a href=\"user:%d\">%s</a>".printf (i.author.id, Markup.escape_text (i.author.name)),
                Markup.escape_text (format_datetime (i.created_on))) + (i.is_private ? " · " + Markup.escape_text (_("private")) : "")) { xalign = 0, wrap = true, margin_top = 4, use_markup = true };
            by.add_css_class ("dim-label");
            var author = i.author;
            by.activate_link.connect ((uri) => { new PersonCard (author.id, author.name).present (this); return true; });
            body.append (by);

            // поля
            var props = boxed ();
            props.margin_top = 18;
            var st = prop (props, _("Status"), "");
            st.add_suffix (status_pill (i.status.name, i.status_closed));
            prop (props, _("Priority"), i.priority.name);
            var a = i.assigned_to;
            var asg = prop (props, _("Assignee"), a != null ? a.name : _("Not assigned"));
            if (a != null) {
                asg.add_prefix (Avatars.make (a.id, a.name, 32));
                asg.activatable = true;
                asg.tooltip_text = _("Profile of %s").printf (a.name);
                asg.activated.connect (() => new PersonCard (a.id, a.name).present (this));
                asg.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            }
            var me = App.get ().session.user_id;
            if ((a == null || a.id != me) && can_edit ()) {
                var take = new Gtk.Button.with_label (_("Take")) { valign = Gtk.Align.CENTER, tooltip_text = _("Assign to Me"), action_name = "issue.assign-me" };
                asg.add_suffix (take);
            }
            var prog = prop (props, _("Progress"), "%d %%".printf (i.done_ratio));
            prog.add_suffix (new Gtk.LevelBar.for_interval (0, 100) { value = i.done_ratio, valign = Gtk.Align.CENTER, width_request = 100 });
            if (i.start_date != "") prop (props, _("Start date"), format_date (i.start_date));
            if (i.due_date != "") {
                var overdue = is_overdue (i.due_date) && !i.status_closed;
                var due = prop (props, _("Due date"), format_date (i.due_date) + (overdue ? " · " + _("overdue") : ""));
                if (overdue) due.add_css_class ("error");
            }
            if (i.has_estimate) prop (props, _("Estimate"), _("%s h").printf (format_hours (i.estimated_hours))
                + (i.total_estimated_hours != i.estimated_hours && i.total_estimated_hours > 0 ? " " + _("(total %s)").printf (format_hours (i.total_estimated_hours)) : ""));
            if (i.spent_hours > 0 || i.total_spent_hours > 0) prop (props, _("Spent time"), _("%s h").printf (format_hours (i.spent_hours))
                + (i.total_spent_hours != i.spent_hours ? " " + _("(total %s)").printf (format_hours (i.total_spent_hours)) : ""));
            var v = i.fixed_version;
            if (v != null) prop (props, _("Version"), v.name);
            var cat = i.category;
            if (cat != null) prop (props, _("Category"), cat.name);
            if (i.parent_id > 0) {
                var parent = linked[i.parent_id];
                var pr_row = prop (props, _("Parent issue"), "#%d%s".printf (i.parent_id, parent != null ? " " + parent.subject : ""));
                pr_row.activatable = true;
                pr_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                var pid = i.parent_id;
                pr_row.activated.connect (() => win ()?.open_issue (pid, 0, true));
            }
            prop (props, _("Updated"), format_datetime (i.updated_on));
            if (i.status_closed && i.closed_on != "") prop (props, _("Closed on"), format_datetime (i.closed_on));
            var blocks = new GenericArray<Json.Object> ();
            var labels = jobj (i.o, "_cf_labels");
            foreach (var cf in i.custom_fields) {
                var val = cf_display (labels, cf);
                if (val.strip () == "") continue;
                // длинное, многострочное или с блочной разметкой — Textile-блоком ниже, как на Android/сайте
                if (cf.get_member ("value").get_node_type () != Json.NodeType.ARRAY && is_block_value (val)) blocks.add (cf);
                else prop (props, jstr (cf, "name"), /^\d{4}-\d{2}-\d{2}$/.match (val) ? format_date (val) : val);
            }
            if (can_edit ()) {
                st.activatable = true;
                st.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                st.activated.connect (() => status_btn.popup ());
            }
            body.append (props);

            foreach (var cf in blocks) {
                body.append (heading (jstr (cf, "name")));
                body.append (card (rich (cf_display (labels, cf).replace ("\r\n", "\n").strip ())));
            }
            render_custom_tables ();

            // описание
            body.append (heading (_("Description")));
            if (i.description.strip () != "") {
                var rt = rich (i.description, true);
                rt.quote_selected.connect ((sel) => {
                    var q = quote_reply (issue.author.name, 0, sel, ui_lang ());
                    if (q != null) open_comment (null, null, q);
                });
                body.append (card (rt));
            } else {
                var none = new Gtk.Label (_("No description")) { xalign = 0 };
                none.add_css_class ("dim-label");
                body.append (none);
            }

            render_children ();
            render_relations ();
            render_files ();
            render_watchers ();

            // лента
            var tabs_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_top = 24 };
            var tabs = new Adw.ToggleGroup () { hexpand = true, homogeneous = true };
            tabs.add (new Adw.Toggle () { name = "comments", label = _("Comments") });
            tabs.add (new Adw.Toggle () { name = "actions", label = _("Changes") });
            tabs.add (new Adw.Toggle () { name = "time", label = _("Time") });
            tabs.add (new Adw.Toggle () { name = "all", label = _("All") });
            tabs.active_name = Prefs.get_default ().s.get_string ("issue-tab");
            tabs.notify["active-name"].connect (() => {
                Prefs.get_default ().s.set_string ("issue-tab", tabs.active_name);
                render_activity ();
            });
            tabs_row.append (tabs);
            var order = new Gtk.ToggleButton () { valign = Gtk.Align.CENTER };
            order.add_css_class ("flat");
            Prefs.get_default ().s.bind ("comments-newest-first", order, "active", SettingsBindFlags.DEFAULT);
            sync_order (order);
            order.toggled.connect (() => { sync_order (order); render_activity (); });
            tabs_row.append (order);
            body.append (tabs_row);
            activity = new Gtk.Box (Gtk.Orientation.VERTICAL, 16) { margin_top = 12 };
            body.append (activity);
            render_activity ();
            state.content ();
            update_actions ();
            if (pending_note > 0 || pending_index > 0) Idle.add (() => { scroll_to_note (); return Source.REMOVE; });
        }

        private void sync_order (Gtk.ToggleButton b) {
            b.icon_name = b.active ? "view-sort-descending-symbolic" : "view-sort-ascending-symbolic";
            b.tooltip_text = b.active ? _("Newest First") : _("Oldest First");
        }

        private Gtk.Box section_header (string text, string? action_label, string? action) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_top = 18, margin_bottom = 6 };
            var l = new Gtk.Label (text) { xalign = 0, hexpand = true };
            l.add_css_class ("heading");
            row.append (l);
            if (action != null) {
                var b = new Gtk.Button.from_icon_name ("list-add-symbolic") { tooltip_text = action_label, action_name = action };
                b.add_css_class ("flat");
                row.append (b);
            }
            body.append (row);
            return row;
        }

        /** Пилюля статуса справа в строке подзадачи/связи: тема переносится, пилюля — нет. */
        private static Gtk.Widget suffix_pill (Issue i) {
            var p = status_pill (i.status.name, i.status_closed);
            p.ellipsize = Pango.EllipsizeMode.NONE;
            return p;
        }

        private void render_children () {
            var ch = issue.children;
            if (ch.length == 0) return;
            var head = section_header (_("Subtasks"), _("Add Subtask"), "issue.add-subtask");
            // как экран вехи (spec 3.3): список или доска, аватары, поиск
            var as_board = new Gtk.Button.with_label (_("As Board")) { tooltip_text = _("Subtasks as a board"), valign = Gtk.Align.CENTER };
            as_board.add_css_class ("flat");
            var pid = issue.id;
            var subj = issue.subject;
            as_board.clicked.connect (() => win ()?.open_content (new VersionPage.subtasks (pid, subj)));
            head.insert_child_after (as_board, head.get_first_child ());
            var list = boxed ();
            foreach (var c in ch) {
                var id = jint (c, "id");
                var full = linked[id];
                var assignee = full != null ? full.assigned_to : null;
                var r = new Adw.ActionRow () {
                    title = Markup.escape_text ("#%d %s".printf (id, jstr (c, "subject"))),
                    subtitle = assignee != null ? Markup.escape_text (assignee.name) : "",
                    activatable = true,
                };
                if (full != null && full.status_closed) { r.add_css_class ("dim-label"); r.add_css_class ("closed-issue"); }
                if (full != null) r.add_suffix (suffix_pill (full));
                r.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                r.activated.connect (() => win ()?.open_issue (id, 0, true));
                list.append (r);
            }
            body.append (list);
        }

        private void render_relations () {
            var rels = issue.relations;
            var manage = can.has ("manage_issue_relations");
            if (rels.length == 0 && !manage) return;
            section_header (_("Relations"), _("Add Relation"), manage ? "issue.add-relation" : null);
            if (rels.length == 0) return;
            var list = boxed ();
            foreach (var r in rels) {
                var other = relation_other (r, issue_id);
                var full = linked[other];
                var type = relation_type_for (r, issue_id);
                var delay = jint (r, "delay");
                var row = new Adw.ActionRow () {
                    title = Markup.escape_text ("#%d %s".printf (other, full != null ? full.subject : "")),
                    subtitle = Markup.escape_text (relation_label (type) + (delay > 0 ? " · " + _("+%d d").printf (delay) : "")),
                    activatable = true,
                };
                if (full != null && full.status_closed) { row.add_css_class ("dim-label"); row.add_css_class ("closed-issue"); }
                if (full != null) row.add_suffix (suffix_pill (full));
                row.activated.connect (() => win ()?.open_issue (other, 0, true));
                if (manage) {
                    var del = new Gtk.Button.from_icon_name ("user-trash-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Remove Relation") };
                    del.add_css_class ("flat");
                    var rid = jint (r, "id");
                    del.clicked.connect (() => confirm (_("Remove Relation?"), _("The relation with #%d will be removed.").printf (other), _("_Remove"), () => {
                        App.get ().session.api.delete_relation.begin (rid, (o, res) => {
                            try { App.get ().session.api.delete_relation.end (res); refresh (); } catch (Error e) { win ()?.toast_error (e); }
                        });
                    }));
                    row.add_suffix (del);
                }
                list.append (row);
            }
            body.append (list);
        }

        private void render_files () {
            var atts = issue.attachments;
            var edit = can_edit ();
            if (atts.length == 0 && !edit) return;
            section_header (_("Files") + (atts.length > 0 ? " %u".printf (atts.length) : ""), _("Attach Files"), edit ? "issue.attach" : null);
            if (atts.length == 0) return;
            var list = boxed ();
            var me = App.get ().session.user_id;
            foreach (var att in atts) {
                var name = jstr (att, "filename");
                var row = attachment_row (att);
                var author = jint (jobj (att, "author"), "id");
                if (edit || author == me) {
                    var del = new Gtk.Button.from_icon_name ("user-trash-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Delete %s").printf (name) };
                    del.add_css_class ("flat");
                    var aid = jint (att, "id");
                    del.clicked.connect (() => confirm (_("Delete File?"), _("“%s” will be deleted from the issue.").printf (name), _("_Delete"), () => {
                        App.get ().session.api.delete_attachment.begin (aid, (o, res) => {
                            try { App.get ().session.api.delete_attachment.end (res); refresh (); } catch (Error e) { win ()?.toast_error (e); }
                        });
                    }));
                    row.add_suffix (del);
                }
                list.append (row);
            }
            body.append (list);
        }

        /** Листы согласования (spec 10): строка — человек аватаром и «Колонка: значение»; «Согласовано» — зелёной пилюлей. */
        private void render_custom_tables () {
            var ts = issue.o.has_member ("_custom_tables") ? issue.o.get_array_member ("_custom_tables") : null;
            if (ts == null) return;
            foreach (var tn in ts.get_elements ()) {
                var t = tn.get_object ();
                var cols = t.get_array_member ("columns");
                var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                var hl = heading (jstr (t, "title"));
                hl.hexpand = true;
                head.append (hl);
                // «Добавить» — на сайте: правки через API плагина пока нет (spec 10)
                var tid = jint (t, "table_id");
                if (tid > 0) {
                    var add = new Gtk.Button.from_icon_name ("list-add-symbolic") { tooltip_text = _("Add on Website"), valign = Gtk.Align.CENTER };
                    add.add_css_class ("flat");
                    var iid = issue.id;
                    add.clicked.connect (() => open_site ("/custom_entities/new?custom_table_id=%d&issue_id=%d".printf (tid, iid)));
                    head.append (add);
                }
                body.append (head);
                var list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
                list.add_css_class ("boxed-list");
                var row_ids = t.has_member ("row_ids") ? t.get_array_member ("row_ids") : null;
                uint ri = 0;
                foreach (var rn in t.get_array_member ("rows").get_elements ()) {
                    var rid = row_ids != null && ri < row_ids.get_length () && !row_ids.get_element (ri).is_null () ? (int) row_ids.get_int_element (ri) : 0;
                    ri++;
                    var line = new Adw.WrapBox () { child_spacing = 12, line_spacing = 4, margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 12 };
                    var cells = rn.get_array ();
                    for (uint k = 0; k < cells.get_length (); k++) {
                        var c = cells.get_object_element (k);
                        var text = jstr (c, "text");
                        if (text == "") continue;
                        if (jint (c, "user_id") > 0) {
                            var who = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                            who.append (Avatars.make (jint (c, "user_id"), text, 24));
                            who.append (new Gtk.Label (text));
                            var b = person_button (jint (c, "user_id"), text, who);
                            b.remove_css_class ("person-link");
                            line.append (b);
                            continue;
                        }
                        var col = k < cols.get_length () ? cols.get_string_element (k) : "";
                        if (text == "Согласовано") { line.append (status_pill (text, true)); continue; }
                        var l = new Gtk.Label (col != "" ? "%s: %s".printf (col, text) : text) { wrap = true, xalign = 0, valign = Gtk.Align.CENTER, selectable = true };
                        line.append (l);
                    }
                    var lr = new Gtk.ListBoxRow () { child = line };
                    lr.set_data<int> ("rid", rid);
                    lr.set_data<Json.Array> ("cells", cells);
                    list.append (lr);
                }
                list.row_activated.connect ((r) => {
                    var cs = r.get_data<Json.Array> ("cells");
                    if (cs != null) new SheetRowDialog (jstr (t, "title"), cols, cs, r.get_data<int> ("rid")).present (this);
                });
                if (t.get_array_member ("rows").get_length () == 0) {
                    var l = new Gtk.Label (_("No entries")) { margin_top = 10, margin_bottom = 10 };
                    l.add_css_class ("dim-label");
                    list.append (new Gtk.ListBoxRow () { child = l, activatable = false });
                }
                body.append (list);
            }
        }

        private void open_site (string path) {
            var s = App.get ().session;
            if (s != null) new Gtk.UriLauncher (s.server + path).launch.begin (win (), null);
        }

        private void render_watchers () {
            var ws = issue.watchers;
            if (ws.length == 0) return;
            section_header (_("Watchers") + " %u".printf (ws.length), null, null);
            var wrap = new Adw.WrapBox () { child_spacing = 6, line_spacing = 6 };
            foreach (var w in ws) {
                var c = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                c.append (Avatars.make (jint (w, "id"), jstr (w, "name"), 24));
                c.append (new Gtk.Label (jstr (w, "name")));
                var b = person_button (jint (w, "id"), jstr (w, "name"), c);
                b.remove_css_class ("person-link"); // в обёртке — обычная плоская кнопка с отступами
                wrap.append (b);
            }
            body.append (wrap);
        }

        // ---------- лента ----------

        private string detail_value (string field, string v) {
            if (v == "") return "—";
            var t = names[field];
            if (t != null && t.contains (v)) return t[v];
            if (field == "assigned_to_id") {
                var a = issue.assigned_to;
                if (a != null && a.id.to_string () == v) return a.name;
            }
            if (field == "done_ratio") return v + " %";
            if (field == "parent_id") return "#" + v;
            // даты (start_date, due_date, поля-даты) — как в карточке, а не «2026-09-03»
            if (/^\d{4}-\d{2}-\d{2}$/.match (v)) return format_date (v);
            return v.char_count () > 120 ? v.substring (0, v.index_of_nth_char (120)) + "…" : v;
        }

        /** «Статус: было → стало» — оба значения пилюлями (PARITY 0). */
        private Gtk.Widget status_detail (Json.Object d) {
            var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var l = new Gtk.Label (_("Status") + ":");
            l.add_css_class ("dim-label");
            b.append (l);
            var ov = jstr (d, "old_value");
            if (ov != "") {
                b.append (status_pill (detail_value ("status_id", ov), closed_statuses.contains (ov)));
                var arrow = new Gtk.Label ("→");
                arrow.add_css_class ("dim-label");
                b.append (arrow);
            }
            var nv = jstr (d, "new_value");
            b.append (status_pill (detail_value ("status_id", nv), closed_statuses.contains (nv)));
            return b;
        }

        private string detail_text (Json.Object d) {
            var prop = jstr (d, "property");
            var name = jstr (d, "name");
            var ov = jstr (d, "old_value");
            var nv = jstr (d, "new_value");
            if (prop == "attachment") return nv != "" ? _("File added: %s").printf (nv) : _("File deleted: %s").printf (ov);
            if (prop == "relation") return nv != "" ? _("Relation added: %s #%s").printf (relation_label (name), nv) : _("Relation removed: %s #%s").printf (relation_label (name), ov);
            string label = name;
            if (prop == "attr") label = field_label (name);
            else if (prop == "cf") {
                foreach (var cf in issue.custom_fields) if (jstr (cf, "id") == name) label = jstr (cf, "name");
            }
            if (name == "description") return _("Description changed");
            if (ov == "") return "%s: %s".printf (label, detail_value (name, nv));
            return "%s: %s → %s".printf (label, detail_value (name, ov), detail_value (name, nv));
        }

        /** Textile описания и длинных настраиваемых полей; quotable — с «Ответить с цитатой» в меню выделения. */
        private RichText rich (string text, bool quotable = false) {
            var rt = new RichText (text, issue.attachments, quotable && can.has ("add_issue_notes")) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 12 };
            rt.note_activated.connect ((n) => reveal_note_index (n));
            rt.wiki_project = issue.project.id.to_string ();
            return rt;
        }

        private Gtk.Widget header_line (int user_id, string user, string when, string? extra, Gtk.Widget? menu) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var who = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            who.append (Avatars.make (user_id, user, 32));
            var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { valign = Gtk.Align.CENTER };
            var n = new Gtk.Label (user) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            n.add_css_class ("heading");
            col.append (n);
            var w = new Gtk.Label (when + (extra != null ? " · " + extra : "")) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            w.add_css_class ("dim-label");
            w.add_css_class ("caption");
            col.append (w);
            who.append (col);
            // аватар, имя и дата — одна кнопка на карточку; до меню справа — пусто, мимо не промахнуться
            var b = person_button (user_id, user, who);
            b.halign = Gtk.Align.START;
            row.append (b);
            row.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
            if (menu != null) row.append (menu);
            return row;
        }

        private Gtk.Widget journal_widget (Json.Object j, bool notes, bool details) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
            var user = Named.from (jobj (j, "user")) ?? new Named (0, _("Someone"));
            var jid = jint (j, "id");
            var is_private = jbool (j, "private_notes");
            var text = jstr (j, "notes");
            string? extra = is_private ? _("private note") : null;
            var upd = jstr (j, "updated_on");
            if (upd != "" && upd != jstr (j, "created_on") && notes && text != "") extra = (extra != null ? extra + " · " : "") + _("edited");
            // #N — позиция в issue.journals, как #note-N на сайте
            int n = 0;
            while (n < jids.length && jids[n] != jid) n++;
            var when = format_datetime (jstr (j, "created_on")) + (n < jids.length ? " · #%d".printf (n + 1) : "");
            Gtk.MenuButton? mb = null;
            if (notes && text != "") {
                mb = new Gtk.MenuButton () { icon_name = "view-more-symbolic", valign = Gtk.Align.CENTER, tooltip_text = _("Comment Menu") };
                mb.add_css_class ("flat");
                var m = new Menu ();
                var g = new SimpleActionGroup ();
                var me = App.get ().session.user_id;
                var reply = new SimpleAction ("reply", null);
                reply.activate.connect (() => quote_note (j, text));
                reply.set_enabled (can.has ("add_issue_notes"));
                g.add_action (reply);
                m.append (_("_Reply with Quote"), "j.reply");
                var copy_raw = new SimpleAction ("copy-text", null);
                copy_raw.activate.connect (() => { copy_text (this, text); win ()?.toast (_("Text copied")); });
                g.add_action (copy_raw);
                m.append (_("Copy _Text"), "j.copy-text");
                var copy = new SimpleAction ("copy", null);
                copy.activate.connect (() => {
                    copy_text (this, note_url (App.get ().session.server, issue_id, jids, jid));
                    win ()?.toast (_("Link copied"));
                });
                g.add_action (copy);
                m.append (_("Copy Comment _Link"), "j.copy");
                if (can.has_own ("edit_issue_notes", "edit_own_issue_notes", user.id == me, user.id == me)) {
                    var edit = new SimpleAction ("edit", null);
                    edit.activate.connect (() => open_comment (j));
                    g.add_action (edit);
                    m.append (_("_Edit"), "j.edit");
                    var del = new SimpleAction ("delete", null);
                    del.activate.connect (() => confirm (_("Delete This Comment?"), "", _("_Delete"), () => {
                        App.get ().session.api.update_journal.begin (jid, "", null, (o, r) => {
                            try { App.get ().session.api.update_journal.end (r); refresh (); } catch (Error e) { win ()?.toast_error (e); }
                        });
                    }));
                    g.add_action (del);
                    m.append (_("_Delete"), "j.delete");
                }
                mb.menu_model = m;
                mb.insert_action_group ("j", g);
            }
            var head = header_line (user.id, user.name, when, extra, mb);
            if (mb != null) {
                // правый клик и долгое нажатие на шапку — то же меню «⋮»
                var rc = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
                rc.pressed.connect (() => mb.popup ());
                head.add_controller (rc);
                var lp = new Gtk.GestureLongPress () { touch_only = true, propagation_phase = Gtk.PropagationPhase.CAPTURE };
                lp.pressed.connect (() => { lp.set_state (Gtk.EventSequenceState.CLAIMED); mb.popup (); });
                head.add_controller (lp);
            }
            box.append (head);
            var inner = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) { margin_start = 40 };
            if (details) foreach (var d in jarr (j, "details")) {
                if (jstr (d, "property") == "attr" && jstr (d, "name") == "status_id") { inner.append (status_detail (d)); continue; }
                var l = new Gtk.Label (detail_text (d)) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR };
                l.add_css_class ("dim-label");
                inner.append (l);
            }
            if (notes && text != "") {
                var rt = new RichText (text, issue.attachments, can.has ("add_issue_notes"));
                rt.note_activated.connect ((k) => reveal_note_index (k));
                rt.quote_selected.connect ((sel) => quote_note (j, sel));
                rt.wiki_project = issue.project.id.to_string ();
                inner.append (rt);
                // файлы, пришедшие с этим комментарием (details property=attachment, name — id вложения), —
                // строками под текстом; удалённые потом из задачи не показываем: открывать там нечего
                Gtk.ListBox? files = null;
                foreach (var d in jarr (j, "details")) {
                    if (jstr (d, "property") != "attachment" || jstr (d, "new_value") == "") continue;
                    foreach (var att in issue.attachments) if (jstr (att, "id") == jstr (d, "name")) {
                        if (files == null) { files = boxed (); files.margin_top = 4; inner.append (files); }
                        files.append (attachment_row (att));
                    }
                }
            }
            if (is_private) inner.add_css_class ("journal-private");
            box.append (inner);
            note_widgets[jid] = box;
            return box;
        }

        /** Ответ с цитатой комментария: весь текст или выделение; шапка — со ссылкой #note-N. */
        private void quote_note (Json.Object j, string text) {
            var jid = jint (j, "id");
            int n = 0;
            while (n < jids.length && jids[n] != jid) n++;
            var q = quote_reply ((Named.from (jobj (j, "user")) ?? new Named (0, _("Someone"))).name, n < jids.length ? n + 1 : 0, text, ui_lang ());
            if (q != null) open_comment (null, j, q);
        }

        private Gtk.Widget time_widget (Json.Object t) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            var user = Named.from (jobj (t, "user")) ?? new Named (0, "");
            var me = App.get ().session.user_id;
            Gtk.MenuButton? mb = null;
            if (can.has_own ("edit_time_entries", "edit_own_time_entries", user.id == me, user.id == me)) {
                mb = new Gtk.MenuButton () { icon_name = "view-more-symbolic", valign = Gtk.Align.CENTER, tooltip_text = _("Time Entry Menu") };
                mb.add_css_class ("flat");
                var g = new SimpleActionGroup ();
                var edit = new SimpleAction ("edit", null);
                edit.activate.connect (() => open_time (t));
                g.add_action (edit);
                var del = new SimpleAction ("delete", null);
                var hours = format_hours (jdouble (t, "hours"));
                del.activate.connect (() => confirm (_("Delete Time Entry?"), _("%s h will be removed from the issue.").printf (hours), _("_Delete"), () => {
                    App.get ().session.api.delete_time.begin (jint (t, "id"), (o, r) => {
                        try { App.get ().session.api.delete_time.end (r); refresh (); } catch (Error e) { win ()?.toast_error (e); }
                    });
                }));
                g.add_action (del);
                var m = new Menu ();
                m.append (_("_Edit"), "t.edit");
                m.append (_("_Delete"), "t.delete");
                mb.menu_model = m;
                mb.insert_action_group ("t", g);
            }
            box.append (header_line (user.id, user.name, format_date (jstr (t, "spent_on")), null, mb));
            var text = _("%s h").printf (format_hours (jdouble (t, "hours"))) + " · " + jstr (jobj (t, "activity"), "name");
            var c = jstr (t, "comments");
            box.append (new Gtk.Label (c != "" ? text + " — " + c : text) { xalign = 0, wrap = true, margin_start = 40 });
            return box;
        }

        private class Event {
            public int64 at;
            public int seq;
            public Json.Object? journal;
            public Json.Object? time;
            public bool created;
        }

        private void render_activity () {
            if (activity == null || issue == null) return;
            clear_box (activity);
            note_widgets.remove_all ();
            var tab = Prefs.get_default ().s.get_string ("issue-tab");
            var newest = Prefs.get_default ().s.get_boolean ("comments-newest-first");
            var evs = new GenericArray<Event> ();
            int seq = 0;
            if (tab == "all") evs.add (new Event () { at = parse_iso_ms (issue.created_on), seq = seq++, created = true });
            foreach (var j in issue.journals) {
                var has_notes = jstr (j, "notes").strip () != "";
                var has_details = jarr (j, "details").length > 0;
                if ((tab == "comments" && has_notes) || (tab == "actions" && has_details) || (tab == "all" && (has_notes || has_details)))
                    evs.add (new Event () { at = parse_iso_ms (jstr (j, "created_on")), seq = seq++, journal = j });
            }
            if (tab == "time" || tab == "all") foreach (var t in times)
                evs.add (new Event () { at = parse_iso_ms (jstr (t, "spent_on")), seq = seq++, time = t });
            evs.sort ((a, b) => a.at != b.at ? (a.at < b.at ? -1 : 1) : a.seq - b.seq);
            if (newest) {
                var rev = new GenericArray<Event> ();
                for (int k = (int) evs.length - 1; k >= 0; k--) rev.add (evs[k]);
                evs = rev;
            }
            if (tab == "time" && times.length > 0) {
                double total = 0;
                foreach (var t in times) total += jdouble (t, "hours");
                var tl = new Gtk.Label (_("Total: %s h").printf (format_hours (total))) { xalign = 0 };
                tl.add_css_class ("heading");
                activity.append (tl);
            }
            foreach (var e in evs) {
                if (e.created) activity.append (header_line (issue.author.id, issue.author.name, format_datetime (issue.created_on), _("created the issue"), null));
                else if (e.journal != null) activity.append (journal_widget (e.journal, tab != "actions", tab != "comments"));
                else activity.append (time_widget (e.time));
            }
            if (evs.length == 0) {
                var msg = tab == "comments" ? _("No comments yet") : (tab == "actions" ? _("No changes") : (tab == "time" ? _("No time logged") : _("Nothing yet")));
                var l = new Gtk.Label (msg) { margin_top = 12 };
                l.add_css_class ("dim-label");
                activity.append (l);
            }
        }

        /** Переход к комментарию (из уведомления, #note-N): прокрутка и подсветка; нет на вкладке — «Все». */
        private void scroll_to_note () {
            // ponytail: номер считаем по видимому нам журналу — чужие приватные записи сдвигают его на сайте
            if (pending_index > 0 && issue != null && issue.full) {
                var jid = journal_for_fragment (issue.journal_ids (), "note-%d".printf (pending_index));
                if (jid != 0) pending_note = jid;
                pending_index = 0;
            }
            var note = pending_note;
            if (note <= 0 || issue == null) return;
            var w = note_widgets[note];
            if (w == null && Prefs.get_default ().s.get_string ("issue-tab") != "all") {
                Prefs.get_default ().s.set_string ("issue-tab", "all");
                render ();
                return; // render снова позовёт scroll_to_note
            }
            if (w == null) return;
            pending_note = 0;
            w.add_css_class ("highlight-note");
            Timeout.add (150, () => {
                Graphene.Point p;
                if (w.compute_point (body, Graphene.Point () { x = 0, y = 0 }, out p))
                    sw.vadjustment.value = double.max (0, p.y - 24);
                return Source.REMOVE;
            });
            Timeout.add_seconds (4, () => { w.remove_css_class ("highlight-note"); return Source.REMOVE; });
        }
    }

    public string file_icon (string name, string ct) {
        var n = name.down ();
        if (ct.has_prefix ("image/") || is_image_name (n)) return "image-x-generic-symbolic";
        if (ct == "application/pdf" || n.has_suffix (".pdf")) return "x-office-document-symbolic";
        foreach (var ext in new string[] { ".zip", ".gz", ".xz", ".7z", ".tar", ".rpm", ".deb" }) if (n.has_suffix (ext)) return "package-x-generic-symbolic";
        foreach (var ext in new string[] { ".ods", ".xlsx", ".xls", ".csv" }) if (n.has_suffix (ext)) return "x-office-spreadsheet-symbolic";
        foreach (var ext in new string[] { ".odp", ".pptx", ".ppt" }) if (n.has_suffix (ext)) return "x-office-presentation-symbolic";
        if (ct.has_prefix ("audio/")) return "audio-x-generic-symbolic";
        if (ct.has_prefix ("video/")) return "video-x-generic-symbolic";
        return "text-x-generic-symbolic";
    }

    /** Списки могли устареть после правки задачи — текущий раздел тихо обновляется. */
    namespace ListsStale {
        public void mark () {
            // только списки задач: «обновить» колокольчика — это внеочередной опрос сервера
            var sec = App.get ().main_window ().current_section ();
            if (sec is IssueListSection) sec.refresh ();
        }
    }
}

namespace Redmine {
    /**
     * Карточка строки листа согласования (spec 10): все колонки «Колонка: значение» (пустые — «—»), согласующий — аватар
     * и имя (карточка человека); «Открыть на сайте» — /custom_entities/{id} во внешнем браузере (у GNOME нет веб-просмотра
     * с сессией сайта). Только чтение.
     */
    public class SheetRowDialog : Adw.Dialog {
        public SheetRowDialog (string table, Json.Array cols, Json.Array cells, int row_id) {
            title = table;
            content_width = 420;
            var pp = new Adw.PreferencesPage ();
            var g = new Adw.PreferencesGroup ();
            for (uint k = 0; k < cells.get_length (); k++) {
                var c = cells.get_object_element (k);
                var col = k < cols.get_length () ? cols.get_string_element (k) : "";
                var text = jstr (c, "text");
                var r = new Adw.ActionRow () { title = col, subtitle = text != "" ? text : "—", use_markup = false };
                r.add_css_class ("property");
                var uid = jint (c, "user_id");
                if (uid > 0) {
                    r.add_prefix (Avatars.make (uid, text, 32));
                    r.activatable = true;
                    r.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                    r.activated.connect (() => new PersonCard (uid, text).present (this));
                } else if (text == "Согласовано") {
                    r.add_suffix (status_pill (text, true));
                }
                g.add (r);
            }
            pp.add (g);
            if (row_id > 0) {
                var lg = new Adw.PreferencesGroup ();
                var open = new Adw.ButtonRow () { title = _("Open on Website"), end_icon_name = "adw-external-link-symbolic" };
                open.activated.connect (() => {
                    var s = App.get ().session;
                    if (s != null) new Gtk.UriLauncher (s.server + "/custom_entities/%d".printf (row_id)).launch.begin (get_root () as Gtk.Window, null);
                });
                lg.add (open);
                pp.add (lg);
            }
            var tv = new Adw.ToolbarView () { content = pp };
            tv.add_top_bar (new Adw.HeaderBar ());
            child = tv;
        }
    }
}
