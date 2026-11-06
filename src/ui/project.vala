/* Экран проекта (Задачи / Обзор / Вехи / Вики / Файлы по включённым модулям), экран вехи (список и доска), страница вики. */
namespace Redmine {

    /** Задачи вехи загружаются один раз: и для прогресса в списке вех, и для экрана вехи. */
    private HashTable<int, GenericArray<Issue>>? version_issues_cache = null;

    /** Все задачи по запросу (любой статус), страницами по 100, не больше 500. */
    private async GenericArray<Issue> all_issues (IssueQuery q) throws Error {
        var s = App.get ().session;
        var res = new GenericArray<Issue> ();
        q.status = "*";
        q.limit = 100;
        while (res.length < 500) {
            var page = yield s.api.issues (q);
            foreach (var i in page.issues) res.add (i);
            q.offset += page.issues.length;
            if (page.issues.length == 0 || q.offset >= page.total) break;
        }
        return res;
    }

    /** Все задачи вехи — один раз на прогресс в списке и экран вехи. */
    public async GenericArray<Issue> version_issues (int vid, bool fresh = false) throws Error {
        if (version_issues_cache == null) version_issues_cache = new HashTable<int, GenericArray<Issue>> (direct_hash, direct_equal);
        if (!fresh && version_issues_cache.contains (vid)) return version_issues_cache[vid];
        var res = yield all_issues (new IssueQuery () { fixed_version_id = vid });
        version_issues_cache[vid] = res;
        return res;
    }

    /** «N из M закрыто» и доля для полосы. */
    private string progress_text (GenericArray<Issue> issues, out double fraction) {
        bool[] closed = {};
        foreach (var i in issues) closed += i.status_closed;
        int done, total;
        fraction = version_progress (closed, out done, out total) / 100.0;
        return ngettext ("%d of %d closed", "%d of %d closed", total).printf (done, total);
    }

    /** Прокручиваемая колонка по центру — содержимое вкладок и страниц. */
    private Gtk.ScrolledWindow scroll_column (Gtk.Widget child) {
        var clamp = new Adw.Clamp () { child = child, maximum_size = 860, tightening_threshold = 600 };
        return new Gtk.ScrolledWindow () { child = clamp, hscrollbar_policy = Gtk.PolicyType.NEVER, vexpand = true };
    }

    private Gtk.Box page_box () {
        return new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 72 };
    }

    public class ProjectPage : Adw.NavigationPage, Refreshable {
        private int project_id;
        private Adw.ViewStack stack;
        private IssueList issues;
        private Gtk.Button search;
        private HashTable<string, StateView> states = new HashTable<string, StateView> (str_hash, str_equal);
        private HashTable<string, Gtk.Box> boxes = new HashTable<string, Gtk.Box> (str_hash, str_equal);
        private GenericSet<string> loaded = new GenericSet<string> (str_hash, str_equal);
        private string want_tab;

        public ProjectPage (int id, string name, string tab = "") {
            Object (title: name, tag: "project-%d".printf (id));
            project_id = id;
            want_tab = tab;
            stack = new Adw.ViewStack ();
            issues = new IssueList (ListKind.PROJECT, id);
            stack.add_titled_with_icon (issues, "issues", _("Issues"), "checkbox-checked-symbolic");
            add_tab ("overview", _("Overview"), "help-about-symbolic");
            add_tab ("versions", _("Versions"), "emoji-flags-symbolic");
            add_tab ("wiki", _("Wiki"), "accessories-dictionary-symbolic");
            add_tab ("files", _("Files"), "folder-documents-symbolic");
            // до ответа сервера о модулях — только задачи и обзор
            foreach (var t in new string[] { "versions", "wiki", "files" }) show_tab (t, false);

            var hb = new Adw.HeaderBar ();
            hb.pack_start (refresh_button (() => refresh ()));
            var add = new Gtk.Button.from_icon_name ("list-add-symbolic") { tooltip_text = _("New Issue in Project") };
            add.clicked.connect (() => win_of (this)?.new_issue (project_id, 0));
            hb.pack_end (add);
            search = new Gtk.Button.from_icon_name ("system-search-symbolic") { tooltip_text = _("Search") };
            search.clicked.connect (() => issues.start_search ());
            hb.pack_end (search);
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = stack;
            tv.add_bottom_bar (new Adw.ViewSwitcherBar () { stack = stack, reveal = true });
            child = tv;
            stack.notify["visible-child-name"].connect (on_tab);
            shown.connect (on_tab);
            load_project.begin ();
        }

        private void add_tab (string name, string title, string icon) {
            var box = page_box ();
            var st = new StateView (scroll_column (box));
            st.retry_clicked.connect (() => load_tab.begin (name));
            states[name] = st;
            boxes[name] = box;
            stack.add_titled_with_icon (st, name, title, icon);
        }

        private void show_tab (string name, bool on) {
            stack.get_page (stack.get_child_by_name (name)).visible = on;
        }

        private void on_tab () {
            var name = stack.visible_child_name;
            search.visible = name == "issues";
            if (name == "issues") issues.shown ();
            else if (name != null && !loaded.contains (name)) load_tab.begin (name);
        }

        public void refresh () {
            var name = stack.visible_child_name;
            if (name == "issues") issues.refresh ();
            else load_tab.begin (name);
        }

        /** Модули проекта: выключенный — раздела нет, а не пустой. */
        private async void load_project () {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var p = yield s.refs.project (project_id);
                var mods = new GenericSet<string> (str_hash, str_equal);
                foreach (var m in jarr (p, "enabled_modules")) mods.add (jstr (m, "name"));
                var tracking = mods.contains ("issue_tracking");
                show_tab ("issues", tracking);
                show_tab ("versions", tracking);
                show_tab ("wiki", mods.contains ("wiki"));
                show_tab ("files", mods.contains ("files"));
                if (!tracking && stack.visible_child_name == "issues") stack.visible_child_name = "overview";
            } catch (Error e) {
                debug ("project %d: %s", project_id, e.message);
            }
            if (want_tab != "" && stack.get_page (stack.get_child_by_name (want_tab)).visible) stack.visible_child_name = want_tab;
            want_tab = "";
        }

        private async void load_tab (string name) {
            var s = App.get ().session;
            if (s == null) return;
            loaded.add (name);
            var st = states[name];
            var box = boxes[name];
            if (box.get_first_child () == null) st.loading ();
            try {
                switch (name) {
                    case "overview": yield fill_overview (s, box); break;
                    case "versions": yield fill_versions (s, box); break;
                    case "wiki": yield fill_wiki (s, box); break;
                    case "files": yield fill_files (s, box); break;
                }
                st.content ();
            } catch (Error e) {
                loaded.remove (name);
                // нет доступа к разделу — раздела нет
                if (error_code (e) == 403 || error_code (e) == 404) {
                    show_tab (name, false);
                    stack.visible_child_name = "overview";
                } else st.error (e);
            }
        }

        private async void fill_overview (Session s, Gtk.Box box) throws Error {
            var p = jobj (yield s.api.get_obj ("projects/%d.json".printf (project_id)), "project");
            clear_box (box);
            var name = new Gtk.Label (jstr (p, "name")) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, selectable = true };
            name.add_css_class ("title-2");
            box.append (name);
            var desc = jstr (p, "description").strip ();
            if (desc != "") {
                var rt = new RichText (desc) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 12 };
                rt.wiki_project = project_id.to_string ();
                var c = card (rt);
                c.margin_top = 12;
                box.append (c);
            }
            var props = boxed_list ();
            props.margin_top = 18;
            var home = jstr (p, "homepage");
            if (home != "") {
                var r = new Adw.ActionRow () { title = _("Homepage"), subtitle = Markup.escape_text (home), activatable = true };
                r.add_css_class ("property");
                r.add_suffix (new Gtk.Image.from_icon_name ("web-browser-symbolic"));
                r.activated.connect (() => new Gtk.UriLauncher (home).launch.begin (win_of (this), null));
                props.append (r);
            }
            var parent = Named.from (jobj (p, "parent"));
            if (parent != null) {
                var r = new Adw.ActionRow () { title = _("Parent project"), subtitle = Markup.escape_text (parent.name), activatable = true };
                r.add_css_class ("property");
                r.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                r.activated.connect (() => win_of (this)?.push_list (new ProjectPage (parent.id, parent.name)));
                props.append (r);
            }
            var ident = new Adw.ActionRow () { title = _("Identifier"), subtitle = Markup.escape_text (jstr (p, "identifier")), subtitle_selectable = true };
            ident.add_css_class ("property");
            props.append (ident);
            box.append (props);

            // участники по ролям; закрыто — без раздела
            Json.Object m;
            try {
                m = yield s.api.get_obj ("projects/%d/memberships.json".printf (project_id), new Query ().add ("limit", "100"));
            } catch (Error e) {
                if (error_code (e) == 403) return;
                throw e;
            }
            var by_role = new HashTable<string, Gtk.ListBox> (str_hash, str_equal);
            string[] roles = {};
            foreach (var x in jarr (m, "memberships")) {
                var who = Named.from (jobj (x, "user"));
                var group = Named.from (jobj (x, "group"));
                foreach (var r in jarr (x, "roles")) {
                    var rn = jstr (r, "name");
                    if (!by_role.contains (rn)) { by_role[rn] = boxed_list (); roles += rn; }
                    var n = who ?? group;
                    if (n == null) continue;
                    var row = new Adw.ActionRow () { title = Markup.escape_text (n.name) };
                    row.add_prefix (Avatars.make (who != null ? n.id : 0, n.name, 32));
                    if (who != null) {
                        row.activatable = true;
                        row.tooltip_text = _("Profile of %s").printf (n.name);
                        row.activated.connect (() => new PersonCard (n.id, n.name).present (this));
                        row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                    }
                    by_role[rn].append (row);
                }
            }
            foreach (var rn in roles) {
                box.append (heading (rn));
                box.append (by_role[rn]);
            }
        }

        private static int version_rank (Json.Object v) {
            var st = jstr (v, "status");
            return st == "open" ? 0 : (st == "locked" ? 1 : 2);
        }

        private static string version_due (Json.Object v) {
            var d = jstr (v, "due_date");
            return d != "" ? d : jstr (v, "effective_date");
        }

        private static string version_status (string st) {
            switch (st) {
                case "open": return _("open");
                case "locked": return _("locked");
                case "closed": return _("closed");
                default: return st;
            }
        }

        private async void fill_versions (Session s, Gtk.Box box) throws Error {
            var vs = yield s.api.versions (project_id);
            // открытые, затем заблокированные — по сроку, без срока в конце; закрытые — свёрнутой группой
            vs.sort ((a, b) => {
                if (version_rank (a) != version_rank (b)) return version_rank (a) - version_rank (b);
                var da = version_due (a), db = version_due (b);
                if (da == "" || db == "") return (da == "" ? 1 : 0) - (db == "" ? 1 : 0);
                return strcmp (da, db);
            });
            clear_box (box);
            if (vs.length == 0) {
                var l = new Gtk.Label (_("No versions")) { margin_top = 24 };
                l.add_css_class ("dim-label");
                box.append (l);
                return;
            }
            var open = boxed_list ();
            Adw.ExpanderRow? closed = null;
            var pending = new GenericArray<Adw.ActionRow> ();
            var closed_rows = new GenericArray<Adw.ActionRow> ();
            foreach (var v in vs) {
                var row = version_row (v);
                if (version_rank (v) < 2) { open.append (row); pending.add (row); continue; }
                if (closed == null) {
                    closed = new Adw.ExpanderRow () { title = _("Closed") };
                    var cl = boxed_list ();
                    cl.margin_top = 12;
                    cl.append (closed);
                    box.append (open);
                    box.append (cl);
                    // прогресс закрытых — когда группу раскрыли
                    closed.notify["expanded"].connect (() => { if (closed.expanded) progress_all.begin (closed_rows); });
                }
                closed.add_row (row);
                closed_rows.add (row);
            }
            if (open.parent == null) box.append (open);
            open.visible = pending.length > 0;
            progress_all.begin (pending); // по одной вехе за раз, экран уже показан
        }

        private async void progress_all (GenericArray<Adw.ActionRow> rows) {
            foreach (var r in rows) yield load_progress (r);
        }

        private Adw.ActionRow version_row (Json.Object v) {
            var due = version_due (v);
            var meta = (due != "" ? format_date (due) + " · " : "") + version_status (jstr (v, "status"));
            var row = new Adw.ActionRow () { title = Markup.escape_text (jstr (v, "name")), subtitle = Markup.escape_text (meta), activatable = true, title_lines = 2 };
            var bar = new Gtk.LevelBar.for_interval (0, 1) { valign = Gtk.Align.CENTER, width_request = 64, visible = false };
            row.add_suffix (bar);
            row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            row.set_data<string> ("meta", meta);
            row.set_data<Gtk.LevelBar> ("bar", bar);
            row.set_data<int> ("id", jint (v, "id"));
            row.activated.connect (() => win_of (this)?.open_content (new VersionPage (jint (v, "id"), v)));
            return row;
        }

        private async void load_progress (Adw.ActionRow row) {
            if (row.get_data<bool> ("done")) return;
            row.set_data<bool> ("done", true);
            try {
                double f;
                var text = progress_text (yield version_issues (row.get_data<int> ("id")), out f);
                row.subtitle = Markup.escape_text (row.get_data<string> ("meta") + " · " + text);
                var bar = row.get_data<Gtk.LevelBar> ("bar");
                bar.value = f;
                bar.visible = true;
            } catch (Error e) {
                row.set_data<bool> ("done", false);
            }
        }

        /** Страницы вики деревом по parent; нажатие — страница в приложении. */
        private async void fill_wiki (Session s, Gtk.Box box) throws Error {
            var pages = jarr (yield s.api.get_obj ("projects/%d/wiki/index.json".printf (project_id)), "wiki_pages");
            var titles = new GenericSet<string> (str_hash, str_equal);
            foreach (var p in pages) titles.add (jstr (p, "title"));
            var kids = new HashTable<string, GenericArray<Json.Object>> (str_hash, str_equal);
            foreach (var p in pages) {
                var parent = jstr (jobj (p, "parent"), "title");
                if (!titles.contains (parent)) parent = "";
                if (!kids.contains (parent)) kids[parent] = new GenericArray<Json.Object> ();
                kids[parent].add (p);
            }
            clear_box (box);
            var list = boxed_list ();
            add_wiki_rows (list, kids, "", 0);
            if (pages.length == 0) {
                var l = new Gtk.Label (_("No wiki pages")) { margin_top = 24 };
                l.add_css_class ("dim-label");
                box.append (l);
            } else box.append (list);
        }

        private void add_wiki_rows (Gtk.ListBox list, HashTable<string, GenericArray<Json.Object>> kids, string parent, int depth) {
            var ch = kids[parent];
            if (ch == null || depth > 10) return;
            foreach (var p in ch) {
                var t = jstr (p, "title");
                var row = new Adw.ActionRow () { title = Markup.escape_text (t.replace ("_", " ")), activatable = true };
                // add_prefix ставит левее прежних: отступ — после значка
                row.add_prefix (new Gtk.Image.from_icon_name ("text-x-generic-symbolic"));
                if (depth > 0) row.add_prefix (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { width_request = 16 * depth });
                row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                row.activated.connect (() => win_of (this)?.open_content (new WikiPage (project_id.to_string (), t)));
                list.append (row);
                add_wiki_rows (list, kids, t, depth + 1);
            }
        }

        private async void fill_files (Session s, Gtk.Box box) throws Error {
            var files = jarr (yield s.api.get_obj ("projects/%d/files.json".printf (project_id)), "files");
            clear_box (box);
            if (files.length == 0) {
                var l = new Gtk.Label (_("No files")) { margin_top = 24 };
                l.add_css_class ("dim-label");
                box.append (l);
                return;
            }
            var list = boxed_list ();
            foreach (var f in files) list.append (attachment_row (f));
            box.append (list);
        }
    }

    /** Веха: шапка, фильтры по статусу и исполнителю (локально), вид «Список / Доска». */
    /**
     * Экран вехи (spec 3.2) и он же — подзадачи доской (3.3, parent_id > 0): шапка, статус, поиск по доске,
     * аватары исполнителей (несколько сразу, лишние — «+N»), Список / Доска.
     */
    public class VersionPage : Adw.NavigationPage, Refreshable {
        private int version_id;
        private int parent_id = 0;
        private string parent_subject = "";
        private Json.Object? version;
        private GenericArray<Issue> all = new GenericArray<Issue> ();
        private int[] status_order = {};
        private StateView state;
        private Gtk.Box info;
        private Adw.ToggleGroup status_filter;
        private Gtk.SearchEntry search;
        private Gtk.Box avatars;
        private GenericSet<string> picked = new GenericSet<string> (str_hash, str_equal);
        private const int MAX_AVATARS = 7;
        private const double AVATAR_STEP = 22; // 32 px со смещением 10 — заход на треть, как в Jira
        private Gtk.Fixed? stack = null;
        private Gtk.Stack results;
        private Gtk.ListBox list;
        private Gtk.Box board;
        public VersionPage (int id, Json.Object? v = null) {
            Object (title: v != null ? jstr (v, "name") : _("Version"), tag: "version-%d".printf (id));
            version_id = id;
            version = v;
            build ();
        }

        /** Подзадачи задачи parent доской (spec 3.3). */
        public VersionPage.subtasks (int parent, string subject) {
            Object (title: "#%d".printf (parent), tag: "subtasks-%d".printf (parent));
            parent_id = parent;
            parent_subject = subject;
            build ();
        }

        private void build () {
            var view = new Adw.ToggleGroup ();
            view.add (new Adw.Toggle () { name = "list", icon_name = "view-list-symbolic", tooltip = _("List") });
            view.add (new Adw.Toggle () { name = "board", icon_name = "view-grid-symbolic", tooltip = _("Board") });
            view.add_css_class ("flat");
            Prefs.get_default ().s.bind ("version-view", view, "active-name", SettingsBindFlags.DEFAULT);
            var hb = new Adw.HeaderBar ();
            hb.pack_start (refresh_button (() => refresh ()));
            hb.pack_end (view);

            info = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            status_filter = new Adw.ToggleGroup ();
            status_filter.add (new Adw.Toggle () { name = "open", label = _("Open") });
            status_filter.add (new Adw.Toggle () { name = "closed", label = _("Closed") });
            status_filter.add (new Adw.Toggle () { name = "*", label = _("All") });
            status_filter.active_name = "open";
            status_filter.notify["active-name"].connect (() => { if (all.length > 0) fill_assignees (); apply (); });
            search = new Gtk.SearchEntry () { placeholder_text = _("Search the board"), width_chars = 18 };
            search.search_changed.connect (apply);
            // аватары внахлёст, как в Jira: каждый следующий заходит на предыдущий на треть (margin_start -10 у 32 px)
            avatars = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { valign = Gtk.Align.CENTER, margin_start = 4 };
            avatars.add_css_class ("avatar-stack");
            var filters = new Adw.WrapBox () { child_spacing = 6, line_spacing = 6, margin_top = 12 };
            filters.append (status_filter);
            filters.append (search);
            filters.append (avatars);
            var top = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 6 };
            top.append (info);
            top.append (filters);

            list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, margin_bottom = 66 };
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => open ((row as IssueRow).issue.id));
            board = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 12 };
            results = new Gtk.Stack () { vexpand = true };
            results.add_named (scroll_column (list), "list");
            results.add_named (new Gtk.ScrolledWindow () { child = board, vscrollbar_policy = Gtk.PolicyType.NEVER }, "board");
            view.bind_property ("active-name", results, "visible-child-name", BindingFlags.SYNC_CREATE);

            var main = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            main.append (new Adw.Clamp () { child = top, maximum_size = 860, tightening_threshold = 600 });
            main.append (results);
            state = new StateView (main);
            state.retry_clicked.connect (() => load.begin (true));
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = state;
            child = tv;
            state.loading ();
            load.begin (false);
        }

        public void refresh () { load.begin (true); }

        private void open (int id) { win_of (this)?.open_issue (id, 0, true); }

        private async void load (bool fresh) {
            var s = App.get ().session;
            if (s == null) return;
            try {
                if (parent_id == 0) {
                    if (version == null || fresh) version = jobj (yield s.api.get_obj ("versions/%d.json".printf (version_id)), "version");
                    title = jstr (version, "name");
                }
                int[] order = {};
                foreach (var st in yield s.refs.statuses ()) order += jint (st, "id");
                status_order = order;
                all = parent_id > 0 ? yield all_issues (new IssueQuery () { parent_id = parent_id }) : yield version_issues (version_id, fresh);
                render_info ();
                fill_assignees ();
                apply ();
                state.content ();
            } catch (Error e) {
                state.error (e);
            }
        }

        private void render_info () {
            clear_box (info);
            var name = new Gtk.Label (parent_id > 0 ? "#%d %s".printf (parent_id, parent_subject) : jstr (version, "name")) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR };
            name.add_css_class ("title-2");
            info.append (name);
            var due = parent_id > 0 ? "" : jstr (version, "due_date");
            var proj = parent_id > 0 ? null : Named.from (jobj (version, "project"));
            var meta = new Gtk.Label (parent_id > 0 ? _("Subtasks") : (due != "" ? _("Due %s").printf (format_date (due)) + " · " : "") + (proj != null ? proj.name : "")) { xalign = 0, wrap = true };
            meta.add_css_class ("dim-label");
            info.append (meta);
            var d = parent_id > 0 ? "" : jstr (version, "description").strip ();
            if (d != "") info.append (new Gtk.Label (d) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, selectable = true, lines = 4, ellipsize = Pango.EllipsizeMode.END });
            double f;
            var text = progress_text (all, out f);
            var prog = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) { margin_top = 4 };
            prog.append (new Gtk.LevelBar.for_interval (0, 1) { value = f, hexpand = true, valign = Gtk.Align.CENTER });
            var pl = new Gtk.Label (text);
            pl.add_css_class ("caption");
            prog.append (pl);
            info.append (prog);
        }

        /**
         * Исполнители рядом аватаров (как в Jira, варианты assignee_filter без «все»): нажатие включает и выключает,
         * выбранных несколько — объединение; не поместились — «+N» со списком с галочками и аватарами. Выбор переживает обновление.
         */
        private void fill_assignees () {
            clear_box (avatars);
            // Gtk.Fixed: отрицательный margin в GTK растягивает кнопку, а не сдвигает её — шаг задаём координатами
            stack = new Gtk.Fixed () { overflow = Gtk.Overflow.VISIBLE, margin_top = 3, margin_bottom = 3, margin_start = 3, margin_end = 3 };
            avatars.append (stack);
            double x = 0;
            var me = App.get ().session.user_id;
            string my_name = "";
            foreach (var i in all) if (i.assigned_to != null && i.assigned_to.id == me) my_name = i.assigned_to.name;
            // порядок и числа — по задачам на доске при текущем фильтре статуса (набор assignee_avatars)
            var st = status_filter.active_name;
            var opts = assignee_avatars (all, me, st == "*" ? "all" : st);
            var known = new GenericSet<string> (str_hash, str_equal);
            foreach (var o in opts) known.add (o.key);
            foreach (var k in picked.get_values ()) if (!known.contains (k)) picked.remove (k);
            Gtk.Box? more = null;
            for (int n = 0; n < opts.length; n++) {
                var o = opts[n];
                var label = o.key == "me" ? (my_name != "" ? my_name : _("Me")) : (o.key == "none" ? _("Not assigned") : o.name);
                var tip = "%s · %d".printf (label, o.count);
                var key = o.key;
                if (n < MAX_AVATARS || opts.length == MAX_AVATARS + 1) {
                    var av = assignee_avatar (key, me, label, 32);
                    var t = new Gtk.ToggleButton () { child = av, tooltip_text = tip, active = picked.contains (key) };
                    t.add_css_class ("avatar-toggle");
                    t.update_property (Gtk.AccessibleProperty.LABEL, tip, -1);
                    t.toggled.connect (() => pick (key, t.active));
                    stack.put (t, x, 0);
                    x += AVATAR_STEP;
                    continue;
                }
                if (more == null) more = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
                var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
                row.append (assignee_avatar (key, me, label, 24));
                row.append (new Gtk.Label (tip) { xalign = 0 });
                var c = new Gtk.CheckButton () { child = row, active = picked.contains (key) };
                c.update_property (Gtk.AccessibleProperty.LABEL, tip, -1);
                c.toggled.connect (() => pick (key, c.active));
                more.append (c);
            }
            if (more != null) {
                var extra = opts.length - MAX_AVATARS;
                // «+N» — такой же кружок внахлёст; подпись своим ярлыком: у label MenuButton рисует стрелку
                var mb = new Gtk.MenuButton () { child = new Gtk.Label ("+%d".printf (extra)), tooltip_text = _("More assignees"), popover = new Gtk.Popover () { child = more } };
                mb.add_css_class ("avatar-more");
                stack.put (mb, x, 0);
            }
        }

        private static Adw.Avatar assignee_avatar (string key, int me, string label, int size) {
            if (key != "none") return Avatars.make (key == "me" ? me : int.parse (key.substring (5)), label, size);
            var av = new Adw.Avatar (size, null, false);
            av.add_css_class ("avatar-none");
            return av;
        }

        private void pick (string key, bool on) {
            if (on) picked.add (key); else picked.remove (key);
            apply ();
        }

        private void apply () {
            var st = status_filter.active_name;
            var by_status = new GenericArray<Issue> ();
            foreach (var i in all) if (st == "*" || (st == "closed") == i.status_closed) by_status.add (i);
            string[] keys = {};
            foreach (var k in picked.get_values ()) keys += k;
            var shown = board_filter (by_status, App.get ().session.user_id, keys, search.text);
            list.remove_all ();
            foreach (var i in shown) list.append (new IssueRow (i, false));
            clear_box (board);
            foreach (var c in board_columns (shown, status_order)) board.append (column (c));
            if (shown.length == 0) {
                var l = new Gtk.Label (_("Nothing Here Yet")) { margin_top = 24, hexpand = true };
                l.add_css_class ("dim-label");
                board.append (l);
            }
        }

        /** Колонка доски: пилюля статуса с числом задач, компактные карточки с вертикальной прокруткой. */
        private Gtk.Widget column (BoardColumn c) {
            var i0 = c.issues[0];
            var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) { width_request = 260 };
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_start = 6 };
            head.append (status_pill (i0.status.name, i0.status_closed));
            var n = new Gtk.Label ("%u".printf (c.issues.length));
            n.add_css_class ("dim-label");
            n.add_css_class ("numeric");
            head.append (n);
            col.append (head);
            var cards = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, valign = Gtk.Align.START };
            cards.add_css_class ("boxed-list");
            foreach (var i in c.issues) {
                var row = new Gtk.ListBoxRow ();
                var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 8, margin_bottom = 8, margin_start = 10, margin_end = 10 };
                var num = new Gtk.Label ("%s #%d".printf (i.tracker.name, i.id)) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
                num.add_css_class ("caption");
                num.add_css_class ("dim-label");
                b.append (num);
                var subj = new Gtk.Label (i.subject) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 3, ellipsize = Pango.EllipsizeMode.END };
                if (i.status_closed) subj.add_css_class ("closed-issue");
                b.append (subj);
                var a = i.assigned_to;
                if (a != null) {
                    var who = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_top = 2 };
                    who.append (Avatars.make (a.id, a.name, 20));
                    var al = new Gtk.Label (a.name) { ellipsize = Pango.EllipsizeMode.END };
                    al.add_css_class ("caption");
                    who.append (al);
                    b.append (who);
                }
                row.child = b;
                row.set_data<int> ("id", i.id);
                row.update_property (Gtk.AccessibleProperty.LABEL, "#%d %s, %s".printf (i.id, i.subject, i.status.name), -1);
                cards.append (row);
            }
            cards.row_activated.connect ((r) => open (r.get_data<int> ("id")));
            col.append (new Gtk.ScrolledWindow () { child = cards, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER, propagate_natural_height = false });
            return col;
        }
    }

    /** Страница вики: текст тем же Textile-рендером, [[ссылки]] — в приложении; автор, дата, версия, «Открыть в браузере». */
    public class WikiPage : Adw.NavigationPage, Refreshable {
        private string project;
        private string page_title;
        private StateView state;
        private Gtk.Box box;

        public WikiPage (string project, string title) {
            Object (title: title.replace ("_", " "), tag: "wiki-%s-%s".printf (project, title));
            this.project = project;
            page_title = title;
            var hb = new Adw.HeaderBar ();
            hb.pack_start (refresh_button (() => refresh ()));
            var web = new Gtk.Button.from_icon_name ("web-browser-symbolic") { tooltip_text = _("Open in Browser") };
            web.clicked.connect (() => new Gtk.UriLauncher (web_url ()).launch.begin (win_of (this), null));
            hb.pack_end (web);
            box = page_box ();
            state = new StateView (scroll_column (box));
            state.retry_clicked.connect (() => load.begin ());
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = state;
            child = tv;
            state.loading ();
            load.begin ();
        }

        public void refresh () { load.begin (); }

        private string path () {
            return "projects/%s/wiki/%s".printf (Uri.escape_string (project, null, false), Uri.escape_string (page_title, null, false));
        }

        private string web_url () {
            var s = App.get ().session;
            return s != null ? s.api.url (path ()) : "";
        }

        private async void load () {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var p = jobj (yield s.api.get_obj (path () + ".json", new Query ().add ("include", "attachments")), "wiki_page");
                clear_box (box);
                var t = new Gtk.Label (jstr (p, "title").replace ("_", " ")) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, selectable = true };
                t.add_css_class ("title-2");
                box.append (t);
                var meta = new Gtk.Label ("%s · %s · %s".printf (jstr (jobj (p, "author"), "name"), format_datetime (jstr (p, "updated_on")),
                    _("version %d").printf (jint (p, "version")))) { xalign = 0, wrap = true, margin_top = 4 };
                meta.add_css_class ("dim-label");
                box.append (meta);
                var rt = new RichText (jstr (p, "text"), jarr (p, "attachments")) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 12 };
                rt.wiki_project = project;
                var c = card (rt);
                c.margin_top = 12;
                box.append (c);
                state.content ();
            } catch (Error e) {
                state.error (e);
            }
        }
    }
}
