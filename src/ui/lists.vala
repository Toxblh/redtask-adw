/* Разделы со списками: Мои, Слежу, Избранное, задачи проекта; Проекты; Поиск. */
namespace Redmine {

    public enum ListKind { MINE, WATCHED, FAVORITES, PROJECT, QUERY }

    /**
     * Список задач с фильтром Открытые/Закрытые/Все, поиском по загруженному и подгрузкой при прокрутке.
     * Кэш stale-while-revalidate по ключу «список-фильтр»: смена фильтра мгновенно подставляет его кэш.
     * Горизонтальный свайп (палец, тачпад) листает фильтр по кругу, как на Android: список один,
     * сдвиг показывает Gtk.Stack — старое содержимое уезжает снимком, новое въезжает с нужной стороны.
     */
    public class IssueList : Gtk.Box {
        /** Обновляется уже показанный список (spec 12). */
        public bool refreshing { get; set; }
        public ListKind kind;
        public int project_id;
        private Adw.ToggleGroup filter;
        private Gtk.SearchBar search_bar;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox list;
        private StateView state;
        private Adw.Banner banner;
        private Gtk.Stack slide;
        private Gtk.Picture old_snap;
        private int cur = 0;
        private int swipe_dir = 0;
        private double swipe_dx = 0;
        private const string[] FILTERS = { "open", "closed", "*" };
        private Gtk.Spinner? more_spinner;
        private GenericArray<Issue> items = new GenericArray<Issue> ();
        private int total = 0;
        private bool loading = false;
        private int gen = 0;
        private bool loaded_once = false;
        private int64 loaded_at = 0;

        /** Свой фильтр или запрос (spec 17): статус — в его условиях, переключателя нет. */
        private IssueQuery? base_query = null;

        public IssueList (ListKind kind, int project_id = 0, IssueQuery? base_query = null) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.kind = kind;
            this.project_id = project_id;
            this.base_query = base_query;

            filter = new Adw.ToggleGroup () { homogeneous = true, margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            filter.add (new Adw.Toggle () { name = "open", label = _("Open") });
            filter.add (new Adw.Toggle () { name = "closed", label = _("Closed") });
            filter.add (new Adw.Toggle () { name = "*", label = _("All") });
            filter.active_name = "open";
            filter.notify["active-name"].connect (() => { animate_switch (); reload (true); });
            filter.visible = base_query == null;
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
            // капча WAF, которую автоповтор не прошёл: кнопка видна, пока сервер отвечает проверкой
            append (captcha_button (() => reload (false)));

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
            // снизу — место под кнопку «Обновить», последняя строка не прячется под ней
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            sw.edge_reached.connect ((pos) => { if (pos == Gtk.PositionType.BOTTOM) load_more.begin (); });
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => reload (false));
            old_snap = new Gtk.Picture () { content_fit = Gtk.ContentFit.FILL, can_shrink = true };
            slide = new Gtk.Stack () { vexpand = true, transition_duration = 200 };
            slide.add_child (state);
            slide.add_child (old_snap);
            append (slide);
            setup_swipe ();
            Favorites.get_default ().changed.connect (() => {
                if (kind == ListKind.FAVORITES && loaded_once) reload (false);
                for (var r = list.get_first_child (); r != null; r = r.get_next_sibling ()) (r as IssueRow)?.sync_star ();
            });
        }

        /** Следующий/предыдущий фильтр по кругу. */
        private void step_filter (int dir) {
            if (!filter.visible) return;
            swipe_dir = dir; // по кругу: с «Все» вперёд на «Открытые» — всё равно влево
            filter.active_name = FILTERS[(cur + dir + FILTERS.length) % FILTERS.length];
            swipe_dir = 0;
        }

        /** Палец — перетаскивание, тачпад — горизонтальная прокрутка; фаза capture, события не забираем. */
        private void setup_swipe () {
            var drag = new Gtk.GestureDrag () { touch_only = true, propagation_phase = Gtk.PropagationPhase.CAPTURE };
            drag.drag_end.connect ((x, y) => {
                if (Math.fabs (x) > 80 && Math.fabs (x) > 2 * Math.fabs (y)) step_filter (x < 0 ? 1 : -1);
            });
            slide.add_controller (drag);
            var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.BOTH_AXES) { propagation_phase = Gtk.PropagationPhase.CAPTURE };
            scroll.scroll_begin.connect (() => swipe_dx = 0);
            scroll.scroll.connect ((dx, dy) => {
                // только тачпад: колесо мыши (в т. ч. наклон) фильтр не листает
                if (scroll.get_unit () == Gdk.ScrollUnit.SURFACE && Math.fabs (dx) > Math.fabs (dy)) swipe_dx += dx;
                return false;
            });
            scroll.scroll_end.connect (() => {
                if (Math.fabs (swipe_dx) > 60) step_filter (swipe_dx > 0 ? 1 : -1);
                swipe_dx = 0;
            });
            slide.add_controller (scroll);
        }

        /** Снимок текущего содержимого встаёт на место списка и уезжает, список въезжает с другой стороны. */
        private void animate_switch () {
            int i = 0;
            while (i < FILTERS.length && FILTERS[i] != filter.active_name) i++;
            var forward = swipe_dir != 0 ? swipe_dir > 0 : i > cur;
            cur = i;
            if (!slide.get_mapped () || state.get_width () == 0) return;
            old_snap.paintable = new Gtk.WidgetPaintable (state).get_current_image ();
            slide.transition_type = Gtk.StackTransitionType.NONE;
            slide.visible_child = old_snap;
            slide.transition_type = forward ? Gtk.StackTransitionType.SLIDE_LEFT : Gtk.StackTransitionType.SLIDE_RIGHT;
            slide.visible_child = state;
        }

        public void start_search () {
            search_bar.search_mode_enabled = true;
            search_entry.grab_focus ();
        }

        private string cache_key () {
            if (base_query != null) {
                var b = base_query;
                var sig = "%d|%d|%s".printf (b.project_id, b.query_id, b.params != null ? b.params.encode () : "");
                return "list-q-" + Checksum.compute_for_string (ChecksumType.SHA1, sig).substring (0, 16);
            }
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
            list.unselect_all ();
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
            if (base_query != null) {
                var bq = base_query.copy ();
                bq.limit = 50;
                bq.offset = 0;
                return bq;
            }
            var q = new IssueQuery ();
            q.status = filter.active_name;
            q.assigned_to_me = kind == ListKind.MINE;
            q.watched_by_me = kind == ListKind.WATCHED;
            q.favourite = kind == ListKind.FAVORITES;
            q.project_id = project_id;
            q.limit = 50;
            return q;
        }

        private async void fetch (Session s, int my_gen) {
            loading = true;
            refreshing = items.length > 0;
            try {
                var page = yield s.api.issues (query ());
                var got = page.issues;
                total = page.total;
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
                if (my_gen == gen) { loading = false; refreshing = false; }
            }
        }

        private async void load_more () {
            var s = App.get ().session;
            if (s == null || loading || items.length >= total) return;
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

        public bool refreshing { get; set; }

        public IssueListSection (ListKind kind) {
            list = new IssueList (kind);
            list.bind_property ("refreshing", this, "refreshing", BindingFlags.SYNC_CREATE);
            child = list;
        }

        public void shown () { list.shown (); }
        public void refresh () { list.refresh (); }
        public void start_search () { list.start_search (); }
    }

    /**
     * Проекты: все видимые (их тысячи — поиск по названию обязателен), кэш 7 дней. Список виртуальный (ListView):
     * строки строятся только для видимого, показ из кэша мгновенный, сеть — фоном, если кэш устарел.
     */
    public class ProjectsSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        public bool refreshing { get; set; }
        private Gtk.SearchEntry entry;
        private GLib.ListStore store = new GLib.ListStore (typeof (LazyRow));
        private Gtk.CustomFilter filter;
        private Gtk.ScrolledWindow sw;
        private StateView state;
        private bool loaded = false;

        construct {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            entry = new Gtk.SearchEntry () { placeholder_text = _("Find a project"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            // поиск: заголовки разделов прячутся, остаются совпавшие строки
            filter = new Gtk.CustomFilter ((o) => {
                var r = (LazyRow) o;
                var q = entry.text.strip ().casefold ();
                return q == "" || (r.act != null && r.key.contains (q));
            });
            entry.search_changed.connect (() => filter.changed (Gtk.FilterChange.DIFFERENT));
            box.append (entry);
            var list = lazy_list (new Gtk.FilterListModel (store, filter));
            sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
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
            // кэш (разбор — в потоке): показать сразу; сеть — только если устарел или «обновить»
            var cached = yield s.refs.projects_cached_async ();
            if (cached != null && store.get_n_items () == 0) fill (cached);
            else if (store.get_n_items () == 0) state.loading ();
            if (!fresh && cached != null && !s.refs.projects_stale ()) return;
            refreshing = store.get_n_items () > 0;
            try {
                fill (yield s.refs.projects (fresh));
            } catch (Error e) {
                if (store.get_n_items () == 0) state.error (e);
                else win_of (this)?.toast_error (e);
            }
            refreshing = false;
        }

        private GenericArray<Json.Object> all = new GenericArray<Json.Object> ();

        private void fill (GenericArray<Json.Object> projects) {
            all = projects;
            var names = new HashTable<int, string> (direct_hash, direct_equal);
            foreach (var p in projects) names[jint (p, "id")] = jstr (p, "name");
            var sorted = new GenericArray<Json.Object> ();
            foreach (var p in projects) if (jint (p, "status", 1) == 1) sorted.add (p);
            var keys = new HashTable<Json.Object, string> (direct_hash, direct_equal);
            foreach (var p in sorted) keys[p] = jstr (p, "name").casefold ();
            sorted.sort_with_data ((a, b) => strcmp (keys[a], keys[b]));
            // «Избранные» — сверху, общий список не меняется (закреплённые есть и в нём)
            var pins = Prefs.get_default ().project_pins ();
            var pinned = pinned_projects (sorted, pins);
            var rows = new Object[0];
            if (pinned.length > 0) rows += new LazyRow (() => list_heading (_("Favorite Projects")));
            foreach (var p in pinned) rows += project_row (p, names, pins);
            if (pinned.length > 0) rows += new LazyRow (() => list_heading (_("All Projects")));
            foreach (var p in sorted) rows += project_row (p, names, pins);
            lazy_fill (store, rows);
            if (sorted.length == 0) state.empty (_("No Projects"), "folder-symbolic");
            else state.content ();
        }

        private void toggle_pin (int id, bool on) {
            Prefs.get_default ().set_project_pin (id, on);
            var keep = sw.vadjustment.value;
            fill (all);
            Idle.add (() => { sw.vadjustment.value = keep; return Source.REMOVE; });
        }

        private LazyRow project_row (Json.Object p, HashTable<int, string> names, int[] pins) {
            var id = jint (p, "id");
            var name = jstr (p, "name");
            var parent = Named.from (jobj (p, "parent"));
            var sub_text = parent != null ? (names[parent.id] ?? parent.name) : jstr (p, "identifier");
            var r = new LazyRow (() => project_widget (id, name, sub_text, id in pins), () => win_of (this)?.push_list (new ProjectPage (id, name)));
            r.key = (name + " " + jstr (p, "identifier") + " " + sub_text).casefold ();
            return r;
        }

        private Gtk.Widget project_widget (int id, string name, string sub_text, bool on) {
            var h = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 2 };
            var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
            b.append (new Gtk.Label (name) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR });
            var sub = new Gtk.Label (sub_text) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            sub.add_css_class ("dim-label");
            sub.add_css_class ("caption");
            b.append (sub);
            h.append (b);
            var star = new Gtk.Button.from_icon_name (on ? "starred-symbolic" : "non-starred-symbolic") {
                valign = Gtk.Align.CENTER, tooltip_text = on ? _("Remove from Favorites") : _("Add to Favorites"),
            };
            star.add_css_class ("flat");
            star.clicked.connect (() => toggle_pin (id, !on));
            h.append (star);
            // контекстное меню: правый клик и долгое нажатие
            var m = new Menu ();
            m.append (on ? _("Remove from Favorites") : _("Add to Favorites"), "row.pin");
            var g = new SimpleActionGroup ();
            var a = new SimpleAction ("pin", null);
            a.activate.connect (() => toggle_pin (id, !on));
            g.add_action (a);
            h.insert_action_group ("row", g);
            var click = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
            click.pressed.connect ((n, x, y) => popup_menu (h, m, x, y));
            h.add_controller (click);
            var lp = new Gtk.GestureLongPress () { touch_only = true };
            lp.pressed.connect ((x, y) => popup_menu (h, m, x, y));
            h.add_controller (lp);
            return h;
        }
    }

    /** Поиск по серверу: текст (search.json) или номер «#123» / «123» — задача первой. */
    public class SearchSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        public bool refreshing { get; set; }
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
            entry.search_changed.connect (() => {
                var t = entry.text.strip ();
                if (t.length >= 3) run.begin (t);
                else if (t == "") show_recent ();
            });
            box.append (entry);
            list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => {
                var id = row.get_data<int> ("id");
                if (id <= 0) return;
                remember (row);
                win_of (this)?.open_issue (id);
            });
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            sw.edge_reached.connect ((pos) => { if (pos == Gtk.PositionType.BOTTOM) more.begin (); });
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => run.begin (query));
            box.append (state);
            child = box;
            show_recent ();
        }

        public void shown () {
            if (entry.text.strip () == "") show_recent ();
            entry.grab_focus ();
        }

        // ---- недавние (spec 9): до 10 задач, открытых из результатов; кэш учётки — стирается при выходе ----

        private GenericArray<Json.Object> recent () {
            var s = App.get ().session;
            return s != null ? node_arr (s.cache.load ("recent-search")) : new GenericArray<Json.Object> ();
        }

        /** Открыли из результатов: первой в «Недавних» (набор recent_opened), с темой и статусом для показа. */
        private void remember (Gtk.ListBoxRow row) {
            var s = App.get ().session;
            if (s == null) return;
            var id = row.get_data<int> ("id");
            var old = recent ();
            int[] ids = {};
            foreach (var o in old) ids += jint (o, "id");
            var res = new GenericArray<Json.Object> ();
            foreach (var x in recent_opened (ids, id)) {
                if (x == id) {
                    var o = new Json.Object ();
                    o.set_int_member ("id", id);
                    o.set_string_member ("subject", row.get_data<string> ("subject") ?? "");
                    o.set_string_member ("status", row.get_data<string> ("status") ?? "");
                    o.set_boolean_member ("closed", row.get_data<bool> ("closed"));
                    res.add (o);
                } else foreach (var o in old) if (jint (o, "id") == x) res.add (o);
            }
            s.cache.save ("recent-search", arr_node (res));
        }

        private void show_recent () {
            gen++;
            query = "";
            list.remove_all ();
            var items = recent ();
            if (items.length == 0) {
                state.empty (_("Search Issues"), "system-search-symbolic", _("Enter text or an issue number"));
                return;
            }
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_start = 6, margin_top = 6 };
            var l = new Gtk.Label (_("Recent")) { xalign = 0, hexpand = true };
            l.add_css_class ("heading");
            head.append (l);
            var clear = new Gtk.Button.with_label (_("Clear"));
            clear.add_css_class ("flat");
            clear.clicked.connect (() => {
                App.get ().session?.cache.drop ("recent-search");
                show_recent ();
            });
            head.append (clear);
            list.append (new Gtk.ListBoxRow () { child = head, activatable = false, selectable = false });
            foreach (var o in items) {
                var st = jstr (o, "status");
                add_row (jint (o, "id"), "#%d %s".printf (jint (o, "id"), jstr (o, "subject")), "", st != "" ? st : null, jbool (o, "closed"));
            }
            state.content ();
        }
        public void refresh () {
            if (query == "" || refreshing) return;
            refreshing = true;
            run.begin (query, (o, r) => { run.end (r); refreshing = false; });
        }
        public void start_search () { entry.grab_focus (); }

        /** status — пилюлей над подписью (null — без статуса). */
        private void add_row (int id, string title, string subtitle, string? status = null, bool closed = false) {
            var row = new Gtk.ListBoxRow ();
            var b = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { margin_top = 6, margin_bottom = 6, margin_start = 6, margin_end = 6 };
            b.append (new Gtk.Label (title) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 2, ellipsize = Pango.EllipsizeMode.END });
            if (status != null) b.append (status_line (status, closed, ""));
            if (subtitle != "") {
                var sub = new Gtk.Label (subtitle) { xalign = 0, lines = 2, wrap = true, ellipsize = Pango.EllipsizeMode.END };
                sub.add_css_class ("dim-label");
                sub.add_css_class ("caption");
                b.append (sub);
            }
            row.child = b;
            row.set_data<int> ("id", id);
            // для «Недавних»: тема без «Трекер #N: », статус
            MatchInfo mi;
            row.set_data<string> ("subject", /^.*?#\d+:? (.*)$/s.match (title, 0, out mi) ? mi.fetch (1) : title);
            row.set_data<string> ("status", status ?? "");
            row.set_data<bool> ("closed", closed);
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
                        add_row (i.id, "#%d %s".printf (i.id, i.subject), i.project.name, i.status.name, i.status_closed);
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
                // заголовок search.json — «Трекер #N (Статус): тема»; статус — пилюлей, «issue-closed» — закрытая
                string? st = null;
                var title = split_search_status (jstr (x, "title"), out st);
                add_row (jint (x, "id"), title, Textile.preview (jstr (x, "description")), st, jstr (x, "type") == "issue-closed");
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
