namespace Redmine {

    /** Всё, что живёт ровно столько, сколько вход в учётку: клиент, кэши, справочники, история уведомлений. */
    public class Session : Object {
        public Client api;
        public DiskCache cache;
        public RefData refs;
        public NotifStore notifs;
        public int user_id;
        public string server;

        public Session (string server, string key, int user_id) throws Error {
            this.server = server;
            this.user_id = user_id;
            api = new Client (server, key);
            cache = new DiskCache (server + "|" + user_id.to_string ());
            refs = new RefData (api, cache);
            // история уведомлений — данные, а не кэш: в ~/.local/share, рядом по имени каталога учётки
            notifs = new NotifStore (Path.build_filename (Environment.get_user_data_dir (), "redtask", Path.get_basename (cache.dir)));
        }
    }

    public class App : Adw.Application {
        public Session? session { get; private set; default = null; }
        public Poller poller;
        private bool background_hold = false;

        public static App get () { return (App) GLib.Application.get_default (); }

        public App () {
            // снимок (REDTASK_SHOT) — отдельным процессом, даже когда приложение уже запущено
            Object (application_id: Config.APP_ID, flags: ApplicationFlags.HANDLES_OPEN
                | (Environment.get_variable ("REDTASK_SHOT") != null ? ApplicationFlags.NON_UNIQUE : 0));
        }

        construct {
            ActionEntry[] actions = {
                { "quit", () => { release_background (); quit (); } },
                { "about", on_about },
                { "preferences", () => main_window ().show_preferences () },
                { "shortcuts", () => main_window ().show_shortcuts () },
                // из уведомления: (номер задачи, номер журнала; 0 — без комментария)
                { "open-issue", on_open_issue, "(ii)" },
                { "mute-issue", on_mute_issue, "(is)" },
            };
            add_action_entries (actions, this);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.preferences", { "<Control>comma" });
            set_accels_for_action ("app.shortcuts", { "<Control>question" });
            set_accels_for_action ("win.search", { "<Control>f" });
            set_accels_for_action ("win.refresh", { "<Control>r", "F5" });
            set_accels_for_action ("win.new-issue", { "<Control>n" });
            set_accels_for_action ("win.back", { "<Alt>Left" });
            set_accels_for_action ("window.close", { "<Control>w" });
            poller = new Poller ();
        }

        public override void startup () {
            base.startup ();
            Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/ru/toxblh/RedTask/icons");
            // style.css грузит сам Adw.Application (по resource base path) — с @media (prefers-color-scheme: dark) по теме;
            // свой провайдер тёмную тему не знал и перекрывал тёмные правила светлыми
            Prefs.get_default ().s.changed["run-in-background"].connect (sync_background);
            // фоновый запуск при входе в сеанс (--gapplication-service): activate не придёт, окна нет
            if ((get_flags () & ApplicationFlags.IS_SERVICE) != 0) start_session.begin (false);
        }

        public override void activate () {
            var w = main_window ();
            w.present ();
            if (session == null) start_session.begin (true);
            else w.show_main ();
        }

        /**
         * Ссылки снаружи (маршрутизатор ссылок — Switchyard, Junction — отдаёт нам http/https): свой сервер —
         * в приложении, остальное и при выключенном тумблере — браузеру по умолчанию.
         */
        public override void open (File[] files, string hint) {
            foreach (var f in files) open_uri (f.get_uri ());
        }

        private string? pending_uri = null;
        private string? last_forward = null;
        private int64 last_forward_at = 0;

        public void open_uri (string uri) {
            var p = Prefs.get_default ();
            if (!p.s.get_boolean ("open-server-links") || ServerLink.parse (session?.server ?? p.server_url, uri) == null) {
                // та же ссылка вернулась сразу — браузер по умолчанию мы сами: не гоняем её по кругу
                if (uri == last_forward && get_monotonic_time () - last_forward_at < 5 * 1000000) {
                    activate ();
                    main_window ().toast (_("No web browser to open the link: RedTask itself is set as the default browser"), 5);
                    return;
                }
                last_forward = uri;
                last_forward_at = get_monotonic_time ();
                hold ();
                new Gtk.UriLauncher (uri).launch.begin (get_active_window (), null, (o, r) => {
                    try {
                        ((Gtk.UriLauncher) o).launch.end (r);
                    } catch (Error e) {
                        warning ("open %s: %s", uri, e.message);
                    }
                    release ();
                });
                return;
            }
            if (session == null) pending_uri = uri; // после восстановления входа или входа заново
            activate ();
            if (session != null) main_window ().open_link (ServerLink.parse (session.server, uri));
        }

        public Window main_window () {
            var w = get_active_window () as Window;
            if (w == null) {
                foreach (var x in get_windows ()) if (x is Window) return (Window) x;
                w = new Window (this);
            }
            return w;
        }

        /** Восстановление входа: адрес — из настроек, ключ — из связки ключей. */
        public async void start_session (bool ui) {
            if (Environment.get_variable ("REDTASK_SHOT_DEMO") != null) {
                DemoServer.reset (DemoServer.ui_ru ());
                try {
                    apply_session (new Session (DemoServer.BASE, DemoServer.KEY, DemoServer.ME));
                } catch (Error e) { warning ("demo: %s", e.message); }
                return;
            }
            var p = Prefs.get_default ();
            var server = p.server_url;
            string? key = null;
            if (server != "") {
                try {
                    key = yield Secrets.lookup (server);
                } catch (Error e) {
                    warning ("secret lookup: %s", e.message);
                }
            }
            // разработческий вход без UI (скриншоты, проверка на живом сервере)
            var dev_key = Environment.get_variable ("REDTASK_DEV_KEY");
            var dev_server = Environment.get_variable ("REDTASK_DEV_SERVER");
            if ((key == null || server == "") && dev_key != null && dev_server != null) {
                try {
                    yield login (dev_server, dev_key);
                } catch (Error e) {
                    warning ("dev login: %s", e.message);
                    if (ui) main_window ().show_login ();
                }
                return;
            }
            if (key == null || server == "" || p.user_id == 0) {
                if (ui) main_window ().show_login ();
                return;
            }
            try {
                apply_session (new Session (server, key, p.user_id));
            } catch (Error e) {
                if (ui) main_window ().show_login ();
            }
        }

        /** Вход: users/current — проверка ключа и личность; сохраняем только после успеха. */
        public async void login (string server_raw, string key) throws Error {
            var server = server_raw.strip ();
            while (server.has_suffix ("/")) server = server.substring (0, server.length - 1);
            if (!server.has_prefix ("http://") && !server.has_prefix ("https://")) server = "https://" + server;
            var api = new Client (server, key);
            var me = yield api.current_user ();
            // связка ключей заблокирована или нет её (телефон без пароля входа) — входим всё равно, ключ просто не запомнится
            try {
                yield Secrets.store (server, key.strip ());
            } catch (Error e) {
                warning ("secret store: %s", e.message);
            }
            var p = Prefs.get_default ();
            // другая учётка — отключённые задачи и проекты прежней к ней не относятся
            if (p.server_url != server || p.user_id != me.id) {
                p.s.reset ("muted-issues");
                p.s.reset ("muted-projects");
            }
            p.save_login (server, me);
            apply_session (new Session (server, key.strip (), me.id));
        }

        public async void logout () {
            var p = Prefs.get_default ();
            var s = session;
            if (s != null) {
                poller.stop ();
                s.cache.clear ();
                s.notifs.clear ();
                try {
                    yield Secrets.clear (s.server);
                } catch (Error e) {}
            }
            p.logout ();
            session = null;
            Favorites.get_default ().attach (null);
            Queries.get_default ().attach (null);
            withdraw_all ();
            main_window ().show_login ();
        }

        private void apply_session (Session s) {
            session = s;
            Favorites.get_default ().attach (s);
            Queries.get_default ().attach (s);
            // в фоновом режиме окна нет — его покажет activate, когда человек откроет приложение
            foreach (var x in get_windows ()) if (x is Window) ((Window) x).show_main ();
            poller.start ();
            sync_background ();
            warm.begin (s);
            if (pending_uri != null) {
                var u = pending_uri;
                pending_uri = null;
                open_uri (u);
            }
        }

        /** Прогрев после входа: проекты с диска (разбор в потоке), справочники, устаревший список проектов — фоном. */
        private async void warm (Session s) {
            yield s.refs.projects_cached_async ();
            try {
                yield s.refs.statuses ();
                yield s.refs.trackers ();
                yield s.refs.priorities ();
                if (s.refs.projects_stale ()) yield s.refs.projects ();
            } catch (Error e) {
                debug ("warm: %s", e.message);
            }
        }

        private void withdraw_all () {
            // ponytail: GNotification не перечисляет показанные — снимаем те, что этот процесс поставил
            foreach (var id in poller.posted.get_values ()) withdraw_notification (id);
            poller.posted.remove_all ();
        }

        /**
         * «Работать в фоне»: держим процесс после закрытия окна (hold) и просим автозапуск у портала Background
         * (во flatpak) или кладём .desktop в ~/.config/autostart (без песочницы).
         */
        public void sync_background () {
            var on = Prefs.get_default ().s.get_boolean ("run-in-background") && session != null;
            if (on && !background_hold) { hold (); background_hold = true; }
            if (!on && background_hold) { release (); background_hold = false; }
            Background.request.begin (on);
        }

        private void release_background () {
            if (background_hold) { release (); background_hold = false; }
        }

        private void on_open_issue (SimpleAction a, Variant? v) {
            int id, note;
            v.get ("(ii)", out id, out note);
            var w = main_window ();
            w.present ();
            w.open_issue (id, note);
        }

        private void on_mute_issue (SimpleAction a, Variant? v) {
            int id;
            string subject;
            v.get ("(is)", out id, out subject);
            Prefs.get_default ().set_muted ("muted-issues", id, subject, true);
            withdraw_notification ("issue-%d".printf (id));
        }

        private void on_about () {
            var d = new Adw.AboutDialog () {
                application_name = "RedTask",
                application_icon = Config.APP_ID,
                developer_name = "Anton Palgunov",
                version = Config.VERSION,
                website = "https://altlinux.space/toxblh/redmine-adw",
                license_type = Gtk.License.GPL_3_0,
                copyright = "© 2026 Anton Palgunov",
                comments = _("Native GNOME client for Redmine"),
            };
            d.developers = { "Anton Palgunov" };
            d.translator_credits = _("translator-credits");
            d.present (get_active_window ());
        }
    }

    /** Портал Background: разрешение работать без окна и автозапуск при входе. Без песочницы — autostart-файл. */
    namespace Background {
        public async void request (bool on) {
            if (FileUtils.test ("/.flatpak-info", FileTest.EXISTS)) {
                try {
                    var bus = yield Bus.get (BusType.SESSION);
                    var opts = new VariantBuilder (new VariantType ("a{sv}"));
                    opts.add ("{sv}", "reason", new Variant.string (_("Check Redmine for new notifications")));
                    opts.add ("{sv}", "autostart", new Variant.boolean (on));
                    string[] cmd = { "redtask", "--gapplication-service" };
                    opts.add ("{sv}", "commandline", new Variant.strv (cmd));
                    opts.add ("{sv}", "dbus-activatable", new Variant.boolean (false));
                    yield bus.call ("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                        "org.freedesktop.portal.Background", "RequestBackground",
                        new Variant ("(sa{sv})", "", opts), null, DBusCallFlags.NONE, -1);
                } catch (Error e) {
                    warning ("background portal: %s", e.message);
                }
                return;
            }
            var dir = Path.build_filename (Environment.get_user_config_dir (), "autostart");
            var path = Path.build_filename (dir, Config.APP_ID + ".desktop");
            if (!on) { FileUtils.unlink (path); return; }
            DirUtils.create_with_parents (dir, 0755);
            string exe = "redtask";
            try { exe = FileUtils.read_link ("/proc/self/exe"); } catch (Error e) {}
            try {
                FileUtils.set_contents (path, "[Desktop Entry]\nType=Application\nName=RedTask\nExec=%s --gapplication-service\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n".printf (exe));
            } catch (Error e) {
                warning ("autostart: %s", e.message);
            }
        }
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    // запуск из каталога сборки: переводы лежат в build/po (tools/dev.sh)
    Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Environment.get_variable ("REDTASK_LOCALEDIR") ?? Config.LOCALEDIR);
    Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain (Config.GETTEXT_PACKAGE);
    return new Redmine.App ().run (args);
}
