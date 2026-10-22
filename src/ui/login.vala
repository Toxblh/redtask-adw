namespace Redmine {

    /**
     * Экран входа: первичен «Войти через сайт» (ключ забирается из веб-сессии), ручной ключ — запасная дверь.
     */
    public class LoginView : Adw.Bin {
        private Adw.EntryRow server_row;
        private Adw.PasswordEntryRow key_row;
        private Gtk.Button key_button;
        private Gtk.Button web_button;
        private Gtk.Label error_label;

        construct {
            var page = new Adw.StatusPage () {
                icon_name = Config.APP_ID,
                title = _("Connect to Redmine"),
                description = _("Sign in on the website — the app picks up your API key automatically"),
            };
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 24);

            var group = new Adw.PreferencesGroup ();
            server_row = new Adw.EntryRow () { title = _("Server Address"), input_purpose = Gtk.InputPurpose.URL };
            server_row.text = Prefs.get_default ().server_url != "" ? Prefs.get_default ().server_url : "https://my.basealt.space";
            group.add (server_row);
            box.append (group);

            web_button = new Gtk.Button.with_mnemonic (_("_Sign In on Website…")) { halign = Gtk.Align.CENTER };
            web_button.add_css_class ("pill");
            web_button.add_css_class ("suggested-action");
            web_button.clicked.connect (on_web);
            box.append (web_button);

            var manual = new Adw.PreferencesGroup () {
                title = _("API Key"),
                description = _("My account → API access key → Show"),
            };
            key_row = new Adw.PasswordEntryRow () { title = _("API Key") };
            key_row.entry_activated.connect (on_key);
            manual.add (key_row);
            key_button = new Gtk.Button.with_mnemonic (_("Sign _In")) { halign = Gtk.Align.CENTER, margin_top = 12 };
            key_button.add_css_class ("pill");
            key_button.clicked.connect (on_key);
            var expander = new Gtk.Expander (_("Enter API key manually"));
            var inner = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_top = 12 };
            inner.append (manual);
            inner.append (key_button);
            expander.child = inner;
            box.append (expander);

            error_label = new Gtk.Label ("") { wrap = true, visible = false, justify = Gtk.Justification.CENTER };
            error_label.add_css_class ("error");
            box.append (error_label);

            page.child = new Adw.Clamp () { maximum_size = 420, child = box };
            var tv = new Adw.ToolbarView ();
            var hb = new Adw.HeaderBar () { show_title = false };
            var about = new Gtk.MenuButton () { icon_name = "open-menu-symbolic", tooltip_text = _("Main Menu"), primary = true };
            var m = new Menu ();
            m.append (_("_Keyboard Shortcuts"), "app.shortcuts");
            m.append (_("_About Redmine"), "app.about");
            about.menu_model = m;
            hb.pack_end (about);
            tv.add_top_bar (hb);
            tv.content = new Gtk.ScrolledWindow () { child = page, hscrollbar_policy = Gtk.PolicyType.NEVER };
            child = tv;
        }

        private void show_error (string? msg) {
            error_label.label = msg ?? "";
            error_label.visible = msg != null;
        }

        private void on_key () {
            if (key_row.text.strip () == "") return;
            key_button.sensitive = false;
            show_error (null);
            App.get ().login.begin (server_row.text, key_row.text, (o, r) => {
                try {
                    App.get ().login.end (r);
                    key_row.text = "";
                } catch (Error e) {
                    show_error (e.message);
                }
                key_button.sensitive = true;
            });
        }

        private void on_web () {
            show_error (null);
            var d = new WebLoginDialog (server_row.text.strip ());
            d.failed.connect ((msg) => show_error (msg));
            d.present (this);
        }
    }

    /** Общий для входа и капчи браузер: постоянное хранилище кук, чтобы веб-сессия переживала перезапуск. */
    private WebKit.NetworkSession? _web_session = null;

    public WebKit.NetworkSession web_session () {
        var s = _web_session;
        if (s == null) {
            var base_dir = Path.build_filename (Environment.get_user_data_dir (), "redmine-adw", "web");
            var cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "redmine-adw", "web");
            s = new WebKit.NetworkSession (base_dir, cache_dir);
            s.get_cookie_manager ().set_persistent_storage (Path.build_filename (base_dir, "cookies.sqlite"), WebKit.CookiePersistentStorage.SQLITE);
            s.get_cookie_manager ().set_accept_policy (WebKit.CookieAcceptPolicy.NO_THIRD_PARTY);
            _web_session = s;
        }
        return s;
    }

    /**
     * Вход через сайт: WebKit с формой логина Redmine. Сервер за WAF («Security check»): веб-запросы от не-браузера
     * он встречает капчей, поэтому ключ забираем fetch'ем ИЗ контекста страницы, где куки и репутация браузера уже есть.
     * current.json в веб-контексте api_key не отдаёт — работает /my/api_key (ключ открытым текстом).
     */
    public class WebLoginDialog : Adw.Dialog {
        public signal void failed (string message);
        private WebKit.WebView web;
        private string server;
        private uint timer = 0;
        private bool busy = false;
        private Gtk.Label hint;

        public WebLoginDialog (string server_raw) {
            var s = server_raw;
            while (s.has_suffix ("/")) s = s.substring (0, s.length - 1);
            if (!s.has_prefix ("http")) s = "https://" + s;
            server = s;
            title = _("Sign In");
            content_width = 900;
            content_height = 720;
            web = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", web_session ());
            web.vexpand = true;
            web.load_uri (server + "/login");
            hint = new Gtk.Label (_("Sign in to your Redmine account — the app picks up the key automatically")) {
                wrap = true, margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6, xalign = 0,
            };
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (hint);
            box.append (web);
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = box;
            child = tv;
            timer = Timeout.add (1500, () => { probe.begin (); return Source.CONTINUE; });
            closed.connect (() => { if (timer != 0) Source.remove (timer); timer = 0; });
        }

        /** Каждые 1,5 с — fetch из контекста страницы; await в call_async_javascript_function ждёт Promise. */
        private async void probe () {
            if (busy) return;
            var uri = web.uri ?? "";
            if (!uri.has_prefix (server) || uri.contains ("/login")) return;
            busy = true;
            try {
                var v = yield web.call_async_javascript_function (
                    "let k='';try{const r=await fetch('/users/current.json',{credentials:'same-origin'});k=(JSON.parse(await r.text()).user||{}).api_key||''}catch(e){}" +
                    "if(!k){try{const r2=await fetch('/my/api_key',{credentials:'same-origin'});const m=String(await r2.text()).match(/[a-f0-9]{40}/i);if(m)k=m[0]}catch(e){}}" +
                    "return k;", -1, null, null, null, null);
                var key = v.is_string () ? v.to_string () : "";
                if (key.length >= 40 && key.length <= 64) {
                    if (timer != 0) Source.remove (timer);
                    timer = 0;
                    try {
                        yield App.get ().login (server, key);
                        close ();
                    } catch (Error e) {
                        hint.label = e.message;
                        failed (e.message);
                        // повтор не чаще раза в 5 с
                        timer = Timeout.add (5000, () => { probe.begin (); return Source.CONTINUE; });
                    }
                }
            } catch (Error e) {
                debug ("web login probe: %s", e.message);
            }
            busy = false;
        }
    }

    /**
     * «Решить капчу»: сайт во весь экран; после «Готово» запросы идут с куками и UA этого WebKit,
     * и on_solved повторяет загрузку.
     */
    public class CaptchaDialog : Adw.Dialog {
        public signal void solved ();
        private WebKit.WebView web;

        public CaptchaDialog (string server) {
            title = _("Pass the Check and Press Done");
            content_width = 900;
            content_height = 720;
            web = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", web_session ());
            web.vexpand = true;
            web.load_uri (server + "/");
            var tv = new Adw.ToolbarView ();
            var hb = new Adw.HeaderBar () { show_end_title_buttons = false, show_start_title_buttons = false };
            var done = new Gtk.Button.with_mnemonic (_("_Done"));
            done.add_css_class ("suggested-action");
            done.clicked.connect (() => close ());
            hb.pack_end (done);
            tv.add_top_bar (hb);
            tv.content = web;
            child = tv;
            closed.connect (() => finish.begin (server));
        }

        private async void finish (string server) {
            var waf = WafGate.get_default ();
            if (waf.jar == null) waf.jar = new Soup.CookieJar ();
            try {
                var cookies = yield web_session ().get_cookie_manager ().get_cookies (server + "/", null);
                foreach (unowned Soup.Cookie c in cookies) waf.jar.add_cookie (c.copy ());
            } catch (Error e) {
                warning ("captcha cookies: %s", e.message);
            }
            waf.browser_agent = web.get_settings ().user_agent;
            solved ();
        }
    }

    /** Кнопка «Решить капчу» — видна, только пока сервер отвечает капчей WAF, а автоповтор её не прошёл. */
    public Gtk.Button captcha_button (owned Callback on_solved) {
        var b = new Gtk.Button.with_mnemonic (_("_Solve Captcha")) { halign = Gtk.Align.CENTER };
        b.add_css_class ("pill");
        var waf = WafGate.get_default ();
        waf.bind_property ("blocked", b, "visible", BindingFlags.SYNC_CREATE);
        b.clicked.connect (() => {
            var s = App.get ().session;
            if (s == null) return;
            var d = new CaptchaDialog (s.server);
            d.solved.connect (() => on_solved ());
            d.present (b);
        });
        return b;
    }

    public delegate void Callback ();
}
