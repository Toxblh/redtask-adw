/* Разделы со списками: Мои, Слежу, Избранное, задачи проекта; Проекты; Поиск. */
namespace Redmine {

    public enum ListKind { MINE, WATCHED, FAVORITES, PROJECT }

    /**
     * Список задач с фильтром Открытые/Закрытые/Все, поиском по загруженному и подгрузкой при прокрутке.
     * Кэш stale-while-revalidate по ключу «список-фильтр»: смена фильтра мгновенно подставляет его кэш.
     */
    public class IssueList : Gtk.Box {
        public ListKind kind;
        public int project_id;
        private Adw.ToggleGroup filter;
        private Gtk.SearchBar search_bar;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox list;
        private StateView state;
        private Adw.Banner banner;
        private Gtk.Spinner? more_spinner;
        private GenericArray<Issue> items = new GenericArray<Issue> ();
        private int total = 0;
        private bool loading = false;
        private int gen = 0;
        private bool loaded_once = false;
        private int64 loaded_at = 0;

        public IssueList (ListKind kind, int project_id = 0) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.kind = kind;
            this.project_id = project_id;

            filter = new Adw.ToggleGroup () { margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6, homogeneous = true };
            filter.add (new Adw.Toggle () { name = "open", label = _("Open") });
            filter.add (new Adw.Toggle () { name = "closed", label = _("Closed") });
            filter.add (new Adw.Toggle () { name = "*", label = _("All") });
            filter.active_name = "open";
            filter.notify["active-name"].connect (() => reload (true));
            append (filter);

            search_entry = new Gtk.SearchEntry () { placeholder_text = _("Search in this list"), hexpand = true };
            search_entry.search_changed.connect (() => list.invalidate_filter ());
            search_entry.stop_search.connect (() => search_bar.search_mode_enabled = false);
            search_bar = new Gtk.SearchBar () { child = new Adw.Clamp () { child = search_entry, maximum_size = 400 } };
            search_bar.connect_entry (search_entry);
            append (search_bar);

            banner = new Adw.Banner (_("Could not refresh — showing the saved list")) { button_label = _("_Retry") };
            banner.button_clicked.connect (() => reload (false));
            append (banner);

            list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.SINGLE };
            list.add_css_class ("navigation-sidebar");
            list.set_filter_func ((row) => {
                var r = row as IssueRow;
                var q = search_entry.text.strip ().casefold ();
                if (r == null || q == "") return true;
                return r.issue.subject.casefold ().contains (q) || ("#%d".printf (r.issue.id)).contains (q)
                    || r.issue.project.name.casefold ().contains (q);
            });
            list.row_activated.connect ((row) => {
                var r = row as IssueRow;
                if (r != null) win_of (this)?.open_issue (r.issue.id);
            });
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            sw.edge_reached.connect ((pos) => { if (pos == Gtk.PositionType.BOTTOM) load_more.begin (); });
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => reload (false));
            append (state);
            Prefs.get_default ().s.changed["favorites"].connect (() => {
                if (kind == ListKind.FAVORITES) reload (false);
            });
        }

        public void start_search () {
            search_bar.search_mode_enabled = true;
            search_entry.grab_focus ();
        }

        private string cache_key () {
            var k = kind == ListKind.MINE ? "mine" : (kind == ListKind.WATCHED ? "watched" : (kind == ListKind.FAVORITES ? "favorites" : "project-%d".printf (project_id)));
            return "list-%s-%s".printf (k, filter.active_name == "*" ? "all" : filter.active_name);
        }

        /** Показ раздела: первый раз — загрузка, потом — тихое обновление, если список старше минуты. */
        public void shown () {
            if (!loaded_once) reload (true);
            else if (now_ms () - loaded_at > 60000) reload (false);
        }

        private void fill (GenericArray<Issue> issues) {
            list.remove_all ();
            more_spinner = null;
            foreach (var i in issues) list.append (new IssueRow (i, kind != ListKind.PROJECT));
            if (issues.length == 0) {
                state.empty (_("Nothing Here Yet"), "checkbox-checked-symbolic");
            } else state.content ();
        }

        /** use_cache — подставить сохранённое мгновенно (смена фильтра, первый показ). */
        public void reload (bool use_cache) {
            var s = App.get ().session;
            if (s == null) return;
            loaded_once = true;
            var my_gen = ++gen;
            if (use_cache) {
                var cached = node_issues (s.cache.load (cache_key ()));
                if (cached.length > 0) { items = cached; total = cached.length; fill (cached); }
                else state.loading ();
            }
            fetch.begin (s, my_gen);
        }

        public void refresh () { reload (false); }

        private IssueQuery query () {
            var q = new IssueQuery ();
            q.status = filter.active_name;
            q.assigned_to_me = kind == ListKind.MINE;
            q.watched_by_me = kind == ListKind.WATCHED;
            q.project_id = project_id;
            q.limit = 50;
            return q;
        }

        private async void fetch (Session s, int my_gen) {
            loading = true;
            try {
                GenericArray<Issue> got;
                if (kind == ListKind.FAVORITES) {
                    int[] missing;
                    var all = yield s.api.issues_by_ids (Prefs.get_default ().favorites (), out missing);
                    got = new GenericArray<Issue> ();
                    var f = filter.active_name;
                    foreach (var i in all) if (f == "*" || (f == "open") != i.status_closed) got.add (i);
                    total = got.length;
                    if (my_gen == gen && missing.length > 0) {
                        var parts = new GenericArray<string> ();
                        foreach (var id in missing) parts.add ("#%d".printf (id));
                        parts.add (null);
                        win_of (this)?.toast (_("Unavailable (deleted or no access): %s").printf (string.joinv (", ", parts.data)));
                    }
                } else {
                    var page = yield s.api.issues (query ());
                    got = page.issues;
                    total = page.total;
                }
                if (my_gen != gen) return;
                items = got;
                fill (got);
                banner.revealed = false;
                loaded_at = now_ms ();
                s.cache.save (cache_key (), issues_node (got));
            } catch (Error e) {
                if (my_gen != gen) return;
                if (items.length > 0 && list.get_row_at_index (0) != null) {
                    banner.title = _("Could not refresh — showing the saved list") + (WafGate.get_default ().blocked ? " (" + _("captcha") + ")" : "");
                    banner.revealed = true;
                } else state.error (e);
            } finally {
                if (my_gen == gen) loading = false;
            }
        }

        private async void load_more () {
            var s = App.get ().session;
            if (s == null || loading || kind == ListKind.FAVORITES || items.length >= total) return;
            loading = true;
            var my_gen = gen;
            var spinner_row = new Gtk.ListBoxRow () { selectable = false, activatable = false };
            spinner_row.child = new Adw.Spinner () { height_request = 24, margin_top = 6, margin_bottom = 6 };
            list.append (spinner_row);
            try {
                var q = query ();
                q.offset = items.length;
                var page = yield s.api.issues (q);
                if (my_gen != gen) return;
                list.remove (spinner_row);
                var seen = new GenericSet<int> (direct_hash, direct_equal);
                foreach (var i in items) seen.add (i.id);
                foreach (var i in page.issues) {
                    if (seen.contains (i.id)) continue;
                    items.add (i);
                    list.append (new IssueRow (i, kind != ListKind.PROJECT));
                }
                total = page.total;
                if (page.issues.length == 0) total = items.length;
            } catch (Error e) {
                if (my_gen == gen) {
                    list.remove (spinner_row);
                    win_of (this)?.toast (_("Could not load more"));
                }
            } finally {
                if (my_gen == gen) loading = false;
            }
        }
    }

    public class IssueListSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        private IssueList list;

        public IssueListSection (ListKind kind) {
            list = new IssueList (kind);
            child = list;
        }

        public void shown () { list.shown (); }
        public void refresh () { list.refresh (); }
        public void start_search () { list.start_search (); }
    }

    /** Задачи проекта — страница поверх разделов в колонке списка. */
    public class ProjectIssuesPage : Adw.NavigationPage, Refreshable {
        private IssueList list;

        public ProjectIssuesPage (int project_id, string name) {
            Object (title: name, tag: "project-%d".printf (project_id));
            list = new IssueList (ListKind.PROJECT, project_id);
            var tv = new Adw.ToolbarView ();
            var hb = new Adw.HeaderBar ();
            var add = new Gtk.Button.from_icon_name ("list-add-symbolic") { tooltip_text = _("New Issue in Project") };
            add.clicked.connect (() => win_of (this)?.new_issue (project_id, 0));
            hb.pack_end (add);
            var search = new Gtk.Button.from_icon_name ("system-search-symbolic") { tooltip_text = _("Search") };
            search.clicked.connect (() => list.start_search ());
            hb.pack_end (search);
            tv.add_top_bar (hb);
            tv.content = list;
            child = tv;
            shown.connect (() => list.shown ());
        }

        public void refresh () { list.refresh (); }
    }

    /** Проекты: все видимые (их тысячи — поиск по названию обязателен), кэш 7 дней. */
    public class ProjectsSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        private Gtk.SearchEntry entry;
        private Gtk.ListBox list;
        private StateView state;
        private bool loaded = false;

        construct {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            entry = new Gtk.SearchEntry () { placeholder_text = _("Find a project"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            entry.search_changed.connect (() => list.invalidate_filter ());
            box.append (entry);
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.set_filter_func ((row) => {
                var q = entry.text.strip ().casefold ();
                return q == "" || ((string) row.get_data<string> ("key")).contains (q);
            });
            list.row_activated.connect ((row) => {
                var id = row.get_data<int> ("id");
                var name = (string) row.get_data<string> ("name");
                win_of (this)?.push_list (new ProjectIssuesPage (id, name));
            });
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => load.begin (true));
            box.append (state);
            child = box;
        }

        public void shown () { if (!loaded) load.begin (false); }
        public void refresh () { load.begin (true); }
        public void start_search () { entry.grab_focus (); }

        private async void load (bool fresh) {
            var s = App.get ().session;
            if (s == null) return;
            loaded = true;
            var cached = s.refs.projects_cached ();
            if (cached != null && list.get_row_at_index (0) == null) fill (cached);
            else if (list.get_row_at_index (0) == null) state.loading ();
            try {
                fill (yield s.refs.projects (fresh));
            } catch (Error e) {
                if (list.get_row_at_index (0) == null) state.error (e);
                else win_of (this)?.toast_error (e);
            }
        }

        private void fill (GenericArray<Json.Object> projects) {
            list.remove_all ();
            var names = new HashTable<int, string> (direct_hash, direct_equal);
            foreach (var p in projects) names[jint (p, "id")] = jstr (p, "name");
            var sorted = new GenericArray<Json.Object> ();
            foreach (var p in projects) if (jint (p, "status", 1) == 1) sorted.add (p);
            sorted.sort ((a, b) => strcmp (jstr (a, "name").casefold (), jstr (b, "name").casefold ()));
            foreach (var p in sorted) {
                var row = new Gtk.ListBoxRow ();
                var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
                var t = new Gtk.Label (jstr (p, "name")) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR };
                b.append (t);
                var parent = Named.from (jobj (p, "parent"));
                var sub_text = parent != null ? (names[parent.id] ?? parent.name) : jstr (p, "identifier");
                var sub = new Gtk.Label (sub_text) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
                sub.add_css_class ("dim-label");
                sub.add_css_class ("caption");
                b.append (sub);
                row.child = b;
                row.set_data<int> ("id", jint (p, "id"));
                row.set_data<string> ("name", jstr (p, "name"));
                row.set_data<string> ("key", (jstr (p, "name") + " " + jstr (p, "identifier") + " " + sub_text).casefold ());
                list.append (row);
            }
            if (sorted.length == 0) state.empty (_("No Projects"), "folder-symbolic");
            else state.content ();
        }
    }

    /** Поиск по серверу: текст (search.json) или номер «#123» / «123» — задача первой. */
    public class SearchSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        private Gtk.SearchEntry entry;
        private Gtk.ListBox list;
        private StateView state;
        private int offset = 0;
        private int total = 0;
        private string query = "";
        private int gen = 0;
        private bool loading = false;

        construct {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            entry = new Gtk.SearchEntry () { placeholder_text = _("Text or issue number"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            entry.activate.connect (() => run.begin (entry.text.strip ()));
            entry.search_changed.connect (() => { if (entry.text.strip ().length >= 3) run.begin (entry.text.strip ()); });
            box.append (entry);
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => {
                var id = row.get_data<int> ("id");
                if (id > 0) win_of (this)?.open_issue (id);
            });
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            sw.edge_reached.connect ((pos) => { if (pos == Gtk.PositionType.BOTTOM) more.begin (); });
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => run.begin (query));
            state.empty (_("Search Issues"), "system-search-symbolic", _("Enter text or an issue number"));
            box.append (state);
            child = box;
        }

        public void shown () { entry.grab_focus (); }
        public void refresh () { if (query != "") run.begin (query); }
        public void start_search () { entry.grab_focus (); }

        private void add_row (int id, string title, string subtitle) {
            var row = new Gtk.ListBoxRow ();
            var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
            b.append (new Gtk.Label (title) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 2, ellipsize = Pango.EllipsizeMode.END });
            if (subtitle != "") {
                var sub = new Gtk.Label (subtitle) { xalign = 0, lines = 2, wrap = true, ellipsize = Pango.EllipsizeMode.END };
                sub.add_css_class ("dim-label");
                sub.add_css_class ("caption");
                b.append (sub);
            }
            row.child = b;
            row.set_data<int> ("id", id);
            list.append (row);
        }

        private async void run (string q) {
            var s = App.get ().session;
            if (s == null || q == "") return;
            var my = ++gen;
            query = q;
            offset = 0;
            list.remove_all ();
            state.loading ();
            var seen = new GenericSet<int> (direct_hash, direct_equal);
            try {
                var bare = q.has_prefix ("#") ? q.substring (1) : q;
                int id;
                if (int.try_parse (bare, out id) && id > 0) {
                    foreach (var i in yield s.api.find_issues (q, 30)) {
                        if (my != gen) return;
                        seen.add (i.id);
                        add_row (i.id, "#%d %s".printf (i.id, i.subject), "%s · %s".printf (i.status.name, i.project.name));
                    }
                    total = 0;
                } else {
                    var r = yield s.api.search_page (q, 0);
                    if (my != gen) return;
                    append_results (r);
                }
                if (my != gen) return;
                if (list.get_row_at_index (0) == null) state.empty (_("Nothing Found"), "system-search-symbolic");
                else state.content ();
            } catch (Error e) {
                if (my == gen) state.error (e);
            }
        }

        private void append_results (Json.Object r) {
            total = jint (r, "total_count");
            var results = jarr (r, "results");
            offset += results.length;
            foreach (var x in results) {
                if (!jstr (x, "type").has_prefix ("issue")) continue;
                add_row (jint (x, "id"), jstr (x, "title"), Textile.preview (jstr (x, "description")));
            }
        }

        private async void more () {
            var s = App.get ().session;
            if (s == null || loading || query == "" || offset >= total) return;
            loading = true;
            var my = gen;
            try {
                var r = yield s.api.search_page (query, offset);
                if (my == gen) append_results (r);
            } catch (Error e) {
                win_of (this)?.toast (_("Could not load more"));
            }
            loading = false;
        }
    }
}
