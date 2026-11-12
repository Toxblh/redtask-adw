namespace Redmine {

    [GtkTemplate (ui = "/ru/toxblh/RedTask/ui/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ToastOverlay toasts;
        [GtkChild] private unowned Gtk.Stack root_stack;
        [GtkChild] private unowned Adw.OverlaySplitView outer;
        [GtkChild] private unowned Adw.NavigationSplitView inner;
        [GtkChild] private unowned Adw.NavigationView list_nav;
        [GtkChild] private unowned Adw.NavigationView issue_nav;
        [GtkChild] private unowned Adw.ViewStack sections;
        [GtkChild] private unowned Adw.WindowTitle section_title;
        [GtkChild] private unowned Adw.NavigationPage sections_page;
        [GtkChild] private unowned Adw.HeaderBar list_header;
        [GtkChild] private unowned Adw.StatusPage empty_status;
        private Gtk.Button search_button;
        private RefreshButton list_refresh;
        private Binding? list_busy = null;

        private LoginView? login_view = null;
        private bool built = false;

        public Window (App app) {
            Object (application: app);
        }

        construct {
            var p = Prefs.get_default ().s;
            set_default_size (p.get_int ("window-width"), p.get_int ("window-height"));
            if (p.get_boolean ("window-maximized")) maximize ();
            close_request.connect (() => {
                if (!maximized) {
                    int w, h;
                    get_default_size (out w, out h);
                    p.set_int ("window-width", w);
                    p.set_int ("window-height", h);
                }
                p.set_boolean ("window-maximized", maximized);
                return false;
            });

            // узко: в нижней панели не больше пяти разделов (HIG) — поиск открывается кнопкой в шапке
            search_button = new Gtk.Button.from_icon_name ("system-search-symbolic") { tooltip_text = _("Search Issues"), visible = false };
            search_button.clicked.connect (push_search);
            list_header.pack_end (search_button);
            list_refresh = new RefreshButton (() => current_section ()?.refresh ());
            list_header.pack_start (list_refresh);
            inner.notify["collapsed"].connect (sync_narrow);

            ActionEntry[] actions = {
                { "search", on_search },
                { "refresh", on_refresh },
                { "new-issue", () => new_issue (0, 0) },
                { "back", on_back },
                { "queries", () => push_list (new QueriesPage (0)) },
            };
            add_action_entries (actions, this);

            sections.notify["visible-child"].connect (() => {
                var page = sections.get_page (sections.visible_child);
                section_title.title = page != null ? page.title : "";
                sections_page.title = section_title.title;
                current_section ()?.shown ();
                // спиннер «Обновить» — по показанному разделу
                list_busy?.unbind ();
                list_busy = null;
                var sec = current_section ();
                if (sec != null) list_busy = sec.bind_property ("refreshing", list_refresh, "busy", BindingFlags.SYNC_CREATE);
                else list_refresh.busy = false;
            });
            sections.notify["visible-child"].connect (sync_empty);
            list_nav.notify["visible-page"].connect (sync_empty);
            Queries.get_default ().changed.connect (sync_fav_queries);
            if (Environment.get_variable ("REDTASK_SHOT") != null) Shots.schedule (this);
        }

        /** Пустая колонка задачи: в «Проектах», пока проект не открыт, — «Выберите проект». */
        private void sync_empty () {
            bool pick = sections.visible_child_name == "projects" && list_nav.visible_page?.tag == "sections";
            empty_status.icon_name = pick ? "folder-symbolic" : "ru.toxblh.RedTask-symbolic";
            empty_status.title = pick ? _("Select a project") : _("No Issue Selected");
            empty_status.description = pick ? null : _("Choose an issue from the list");
        }

        private void sync_narrow () {
            search_button.visible = inner.collapsed;
            // избранные запросы — секция боковой панели; в нижней панели телефона им места нет (они на экране «Запросы»)
            foreach (var q in fav_sections) {
                if (q.page == null) continue;
                if (inner.collapsed && sections.visible_child == q) sections.visible_child_name = "mine";
                q.page.visible = !inner.collapsed;
            }
            var child = sections.get_child_by_name ("search");
            if (child == null) return;
            var page = sections.get_page (child);
            if (inner.collapsed && sections.visible_child_name == "search") sections.visible_child_name = "mine";
            page.visible = !inner.collapsed;
        }

        private void push_search () {
            var sec = new SearchSection ();
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = sec;
            var page = new Adw.NavigationPage (tv, _("Search")) { tag = "search" };
            page.shown.connect (() => sec.shown ());
            list_nav.push (page);
        }

        /** Ctrl+F: в списке — поиск по загруженному, в разделе поиска — его поле. */
        private void on_search () {
            var sec = current_section ();
            if (sec is SearchSection || sec is IssueListSection || sec is ProjectsSection) sec.start_search ();
            else if (inner.collapsed) push_search ();
            else show_section ("search");
        }

        [GtkCallback]
        private void on_section_activated () {
            // раздел меняется под стеком колонки: открытый поверх проект закрывал бы выбранный раздел
            list_nav.pop_to_tag ("sections");
            if (outer.collapsed) outer.show_sidebar = false;
        }

        public IssuePage? visible_issue () { return issue_nav.visible_page as IssuePage; }

        public Section? current_section () {
            return sections.visible_child as Section;
        }

        public void toast (string text, int timeout = 3) {
            toasts.add_toast (new Adw.Toast (text) { timeout = timeout });
        }

        public void toast_error (Error e) {
            toast (e.message.length > 0 ? e.message : _("Something went wrong"), 5);
        }

        /** Звезда не записалась (откат уже сделан): без веб-сессии — вход через сайт и повтор. */
        public void favorite_failed (Error e, int id, bool on) {
            if (error_code (e) != 401) { toast_error (e); return; }
            web_login_toast (e.message, () => {
                var f = Favorites.get_default ();
                f.set_favorite.begin (id, on, (o, r) => {
                    try { f.set_favorite.end (r); } catch (Error e2) { toast_error (e2); }
                });
            });
        }

        /** Запрос остался только на устройстве (spec 17.3): без веб-сессии — вход через сайт, затем повтор всех таких. */
        public void query_not_saved (Error e) {
            var text = _("Saved only on this device: %s").printf (Queries.reason_of (e));
            if (error_code (e) != 401) { toast (text, 6); return; }
            web_login_toast (text, () => {});
        }

        /** Тост с «Войти на сайте»: после входа — retry и повтор своих запросов, не дошедших до сервера. */
        private void web_login_toast (string text, owned Callback retry) {
            var s = App.get ().session;
            if (s == null) return;
            var t = new Adw.Toast (text) { timeout = 0, button_label = _("Sign In on Website") };
            t.button_clicked.connect (() => {
                var d = new WebLoginDialog (s.server, true);
                d.web_ready.connect (() => {
                    retry ();
                    Queries.get_default ().retry_pending (true);
                });
                d.present (this);
            });
            toasts.add_toast (t);
        }

        public void show_login () {
            if (login_view == null) {
                login_view = new LoginView ();
                root_stack.add_named (login_view, "login");
            }
            root_stack.visible_child_name = "login";
        }

        public void show_main () {
            if (App.get ().session == null) return;
            build_sections ();
            root_stack.visible_child_name = "main";
            if (login_view != null) {
                root_stack.remove (login_view);
                login_view = null;
            }
            current_section ()?.shown ();
        }

        private void add_section (Section s, string name, string title, string icon) {
            var page = sections.add_titled_with_icon (s, name, title, icon);
            s.page = page;
        }

        private GenericArray<QuerySection> fav_sections = new GenericArray<QuerySection> ();
        private string fav_sig = "";
        private int unread = 0;

        /** Избранные запросы — секция «Запросы» под «Мои задачи» (spec 17.5); у ViewStack нет вставки — хвост снимаем и возвращаем. */
        private void sync_fav_queries () {
            if (!built) return;
            var qs = Queries.get_default ();
            var sb = new StringBuilder ();
            foreach (var f in qs.favs) sb.append ("%s\t%s\n".printf (jstr (f, "key"), qs.title_of (f)));
            if (sb.str == fav_sig) return;
            fav_sig = sb.str;
            var visible = sections.visible_child_name;
            var tail = new GenericArray<Section> ();
            string[] names = {}, titles = {}, icons = {};
            bool after = false;
            var pages = sections.pages;
            var drop = new GenericArray<Gtk.Widget> ();
            for (uint i = 0; i < pages.get_n_items (); i++) {
                var p = (Adw.ViewStackPage) pages.get_item (i);
                if (p.name == "mine") { after = true; continue; }
                if (!after) continue;
                drop.add (p.child);
                if (p.child is QuerySection) continue;
                tail.add ((Section) p.child);
                names += p.name;
                titles += p.title;
                icons += p.icon_name;
            }
            foreach (var w in drop) sections.remove (w);
            fav_sections.remove_range (0, fav_sections.length);
            for (int i = 0; i < qs.favs.length; i++) {
                var f = qs.favs[i];
                var iq = qs.issue_query (f, 0);
                var title = qs.title_of (f);
                if (iq == null || title == "") continue;
                var sec = new QuerySection (iq);
                add_section (sec, "query-%d".printf (i), title, "view-list-bullet-symbolic");
                if (fav_sections.length == 0) {
                    sec.page.starts_section = true;
                    sec.page.section_title = _("Saved Queries");
                }
                fav_sections.add (sec);
            }
            for (int i = 0; i < tail.length; i++) {
                add_section (tail[i], names[i], titles[i], icons[i]);
                if (i == 0) tail[i].page.starts_section = fav_sections.length > 0;
            }
            set_unread (unread);
            sections.visible_child_name = sections.get_child_by_name (visible) != null ? visible : "mine";
            sync_narrow ();
        }

        private void build_sections () {
            if (built) {
                // новая учётка: разделы держат данные прежней — пересоздаём
                Gtk.Widget? c;
                while ((c = sections.get_first_child ()) != null) sections.remove (c);
            }
            built = true;
            fav_sig = "";
            fav_sections.remove_range (0, fav_sections.length);
            add_section (new IssueListSection (ListKind.MINE), "mine", _("My Issues"), "avatar-default-symbolic");
            add_section (new IssueListSection (ListKind.WATCHED), "watched", _("Watching"), "view-reveal-symbolic");
            add_section (new IssueListSection (ListKind.FAVORITES), "favorites", _("Favorites"), "starred-symbolic");
            add_section (new ProjectsSection (), "projects", _("Projects"), "folder-symbolic");
            add_section (new SearchSection (), "search", _("Search"), "system-search-symbolic");
            add_section (new NotificationsSection (), "notifications", _("Notifications"), "preferences-system-notifications-symbolic");
            sections.visible_child_name = "mine";
            sync_fav_queries ();
            sync_narrow ();
            issue_nav.replace_with_tags ({ "empty" });
            list_nav.replace_with_tags ({ "sections" });
        }

        public void show_section (string name) {
            sections.visible_child_name = name;
            list_nav.pop_to_tag ("sections");
            inner.show_content = false;
        }

        /** Список задач проекта и пр. — поверх разделов в колонке списка. */
        public void push_list (Adw.NavigationPage page) {
            list_nav.push (page);
        }

        /**
         * Открыть задачу: из списка — новая история колонки задачи; по ссылке изнутри задачи (from_issue) —
         * вперёд по стеку, «назад» вернёт к прежней.
         */
        public void open_issue (int id, int note = 0, bool from_issue = false) {
            if (App.get ().session == null) return;
            var visible = issue_nav.visible_page as IssuePage;
            if (visible != null && visible.issue_id == id) {
                visible.reveal_note (note);
                inner.show_content = true;
                return;
            }
            var page = new IssuePage (id, note);
            if (from_issue) issue_nav.push (page);
            else issue_nav.replace ({ page });
            inner.show_content = true;
        }

        /** Веха, страница вики — в колонке задачи, «назад» вернёт к прежнему. */
        public void open_content (Adw.NavigationPage page) {
            if (App.get ().session == null) return;
            issue_nav.push (page);
            inner.show_content = true;
        }

        /** Ссылка своего сервера: пришедшая снаружи (App.open_uri) или из текста задачи (from_issue). */
        public void open_link (ServerLink l, bool from_issue = false) {
            switch (l.kind) {
                case LinkKind.ISSUE:
                    open_issue (l.id, l.journal_id, from_issue);
                    if (l.note_index > 0) (issue_nav.visible_page as IssuePage)?.reveal_note_index (l.note_index);
                    break;
                case LinkKind.USER:
                    new PersonCard (l.id).present (this);
                    break;
                case LinkKind.PROJECT:
                    open_project.begin (l.project, l.tab);
                    break;
                case LinkKind.VERSION:
                    open_content (new VersionPage (l.id));
                    break;
                case LinkKind.WIKI:
                    open_content (new WikiPage (l.project, l.title));
                    break;
            }
        }

        /** Проект по идентификатору из адреса (или номеру): из кэша списка проектов, иначе — с сервера. */
        private async void open_project (string ident, string tab) {
            var s = App.get ().session;
            if (s == null) return;
            Json.Object? found = null;
            var all = s.refs.projects_cached ();
            if (all != null) foreach (var p in all) if (jstr (p, "identifier") == ident || jint (p, "id").to_string () == ident) found = p;
            if (found == null) {
                try {
                    found = jobj (yield s.api.get_obj ("projects/%s.json".printf (Uri.escape_string (ident))), "project");
                } catch (Error e) {
                    toast_error (e);
                    return;
                }
            }
            if (found == null) return;
            show_section ("projects");
            push_list (new ProjectPage (jint (found, "id"), jstr (found, "name"), tab));
        }

        public void new_issue (int project_id, int parent_id) {
            if (App.get ().session == null) return;
            var d = new IssueEditDialog.create (project_id, parent_id);
            d.created.connect ((issue) => {
                toast (_("Issue #%d created").printf (issue.id));
                open_issue (issue.id);
                current_section ()?.refresh ();
            });
            d.present (this);
        }

        private void on_refresh () {
            current_section ()?.refresh ();
            var visible = list_nav.visible_page as Refreshable;
            if (visible != null) visible.refresh ();
            var ip = issue_nav.visible_page as IssuePage;
            if (ip != null) ip.refresh ();
        }

        private void on_back () {
            if (issue_nav.visible_page != null && issue_nav.navigation_stack.get_n_items () > 1 && inner.show_content) {
                issue_nav.pop ();
            } else if (inner.collapsed && inner.show_content) {
                inner.show_content = false;
            } else {
                list_nav.pop ();
            }
        }

        public void show_preferences () {
            if (App.get ().session == null) return;
            new PreferencesDialog ().present (this);
        }

        public void show_shortcuts () {
            var d = new Adw.ShortcutsDialog ();
            var g = new Adw.ShortcutsSection (_("General"));
            g.add (new Adw.ShortcutsItem (_("Search"), "<Control>f"));
            g.add (new Adw.ShortcutsItem (_("Refresh"), "<Control>r"));
            g.add (new Adw.ShortcutsItem (_("New issue"), "<Control>n"));
            g.add (new Adw.ShortcutsItem (_("Preferences"), "<Control>comma"));
            g.add (new Adw.ShortcutsItem (_("Keyboard shortcuts"), "<Control>question"));
            g.add (new Adw.ShortcutsItem (_("Close window"), "<Control>w"));
            g.add (new Adw.ShortcutsItem (_("Quit"), "<Control>q"));
            d.add (g);
            var n = new Adw.ShortcutsSection (_("Navigation"));
            n.add (new Adw.ShortcutsItem (_("Go back"), "<Alt>Left"));
            n.add (new Adw.ShortcutsItem (_("Go back"), "Escape"));
            d.add (n);
            var e = new Adw.ShortcutsSection (_("Editor"));
            e.add (new Adw.ShortcutsItem (_("Bold"), "<Control>b"));
            e.add (new Adw.ShortcutsItem (_("Italic"), "<Control>i"));
            e.add (new Adw.ShortcutsItem (_("Send"), "<Control>Return"));
            d.add (e);
            d.present (this);
        }

        public void set_unread (int n) {
            unread = n;
            var page = sections.get_page (sections.get_child_by_name ("notifications"));
            if (page == null) return;
            page.badge_number = n;
            page.needs_attention = n > 0;
        }

        // для скриншотов: ширины задаются извне, а здесь — какой экран показать
        public Adw.NavigationSplitView inner_split { get { return inner; } }
        public Adw.OverlaySplitView outer_split { get { return outer; } }
    }

    /** Раздел сайдбара: список задач, проекты, поиск, уведомления. */
    public interface Section : Gtk.Widget {
        public abstract Adw.ViewStackPage page { get; set; }
        public abstract void shown ();
        public abstract void refresh ();
        public abstract void start_search ();
        /** Идёт обновление уже показанного (spec 12): «Обновить» в шапке — спиннером. */
        public abstract bool refreshing { get; set; }
    }

    public interface Refreshable : Object {
        public abstract void refresh ();
        public abstract bool refreshing { get; set; }
    }

    public Window? win_of (Gtk.Widget w) {
        return w.get_root () as Window;
    }
}
