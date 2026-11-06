namespace Redmine {
    /**
     * Карточка человека (PersonSheet на Android): фото, имя, должность; отдел, руководитель (→ его карточка
     * в том же диалоге, «назад» — к прежней), почта и телефоны (открыть/копировать), логин, вход — из /users/:id.
     * Пустые поля не показываются. На узком окне Adw.Dialog сам становится bottom sheet.
     */
    public class PersonCard : Adw.Dialog {
        private Adw.NavigationView nav = new Adw.NavigationView ();
        private Adw.ToastOverlay toasts = new Adw.ToastOverlay ();

        public PersonCard (int user_id, string name = "") {
            title = _("Person");
            content_width = 420;
            content_height = 640;
            toasts.child = nav;
            child = toasts;
            nav.add (page (user_id, name));
        }

        private Adw.NavigationPage page (int id, string name) {
            var pp = new Adw.PreferencesPage ();
            var head = new Adw.PreferencesGroup ();
            var top = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) { halign = Gtk.Align.CENTER };
            var av = Avatars.make (id, name, 96);
            av.margin_bottom = 6;
            top.append (av);
            var name_l = new Gtk.Label (name) { wrap = true, justify = Gtk.Justification.CENTER };
            name_l.add_css_class ("title-2");
            top.append (name_l);
            var sub = new Gtk.Label ("") { wrap = true, justify = Gtk.Justification.CENTER, visible = false };
            sub.add_css_class ("dim-label");
            top.append (sub);
            var spinner = new Adw.Spinner () { height_request = 24, margin_top = 12 };
            top.append (spinner);
            head.add (top);
            pp.add (head);
            var hb = new Adw.HeaderBar () { show_title = false };
            var tv = new Adw.ToolbarView () { content = pp };
            tv.add_top_bar (hb);
            var np = new Adw.NavigationPage (tv, name != "" ? name : _("Person"));
            load.begin (id, np, pp, av, name_l, sub, spinner);
            return np;
        }

        /**
         * Как на Android: сохранённое (любого возраста) — сразу, без спиннера; старше суток или нет — фоном
         * с сервера, поля тихо перерисовываются. Сеть упала — остаётся сохранённое.
         */
        private async void load (int id, Adw.NavigationPage np, Adw.PreferencesPage pp, Adw.Avatar av, Gtk.Label name_l, Gtk.Label sub, Adw.Spinner spinner) {
            var s = App.get ().session;
            if (s == null) return;
            bool fresh_p, fresh_u;
            var p = s.refs.cached ("person-%d".printf (id), out fresh_p);
            var u = s.refs.cached ("user-%d".printf (id), out fresh_u);
            Adw.PreferencesGroup[] shown = {};
            if (p != null) {
                spinner.visible = false;
                shown = fill (id, p, u, np, pp, av, name_l, sub);
                debug ("person %d: from cache (fresh %s)", id, (fresh_p && u != null && fresh_u).to_string ());
            }
            bool fresh_ph;
            s.refs.phones_cached (id, out fresh_ph);
            if (p != null && fresh_p && u != null && fresh_u && fresh_ph) return;
            Json.Object? np_ = null;
            try {
                np_ = yield s.refs.person (id, true);
            } catch (Error e) {
                if (p != null) return;
                spinner.visible = false;
                sub.label = e.message;
                sub.visible = true;
                sub.add_css_class ("error");
                return;
            }
            try { u = yield s.refs.user (id, true); } catch (Error e) { debug ("users/%d: %s", id, e.message); }
            if (!fresh_ph) try { yield s.refs.phones (id); } catch (Error e) { debug ("phones %d: %s", id, e.message); }
            spinner.visible = false;
            foreach (var g in shown) pp.remove (g);
            fill (id, np_, u, np, pp, av, name_l, sub);
        }

        private Adw.PreferencesGroup[] fill (int id, Json.Object p, Json.Object? u, Adw.NavigationPage np, Adw.PreferencesPage pp, Adw.Avatar av, Gtk.Label name_l, Gtk.Label sub) {
            var s = App.get ().session;
            string[] parts = {};
            foreach (var k in new string[] { "firstname", "middlename", "lastname" }) if (jstr (p, k) != "") parts += jstr (p, k);
            var full = parts.length > 0 ? string.joinv (" ", parts) : person_short_name (p);
            if (full != "") { name_l.label = full; av.text = full; np.title = full; }
            if (jstr (p, "job_title") != "") { sub.label = jstr (p, "job_title"); sub.visible = true; }

            var work = group (pp, null);
            row (work, _("Department"), jstr (jobj (p, "department"), "name"));
            var mid = jint (p, "manager_id");
            if (mid > 0 && mid != id) {
                var m = new Adw.ActionRow () { title = _("Manager"), subtitle = "…", use_markup = false, activatable = true };
                m.add_css_class ("property");
                var mav = Avatars.make (mid, "", 32);
                m.add_prefix (mav);
                m.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                m.activated.connect (() => nav.push (page (mid, m.subtitle != "…" ? m.subtitle : "")));
                work.add (m);
                // руководитель — тоже из сохранённого, без сети, если есть
                bool mf;
                var mp = s.refs.cached ("person-%d".printf (mid), out mf);
                if (mp != null) { m.subtitle = person_short_name (mp); mav.text = m.subtitle; }
                if (mp == null || !mf) s.refs.person.begin (mid, false, (o, r) => {
                    try {
                        var mn = person_short_name (s.refs.person.end (r));
                        m.subtitle = mn;
                        mav.text = mn;
                    } catch (Error e) { m.subtitle = "#%d".printf (mid); }
                });
            }
            row (work, _("Personnel number"), jstr (p, "personnel_number"), true);

            var contacts = group (pp, null);
            var mail = jstr (p, "email") != "" ? jstr (p, "email") : jstr (p, "mail");
            if (mail == "" && u != null) mail = jstr (u, "mail");
            row (contacts, _("Email"), mail, true, "mailto:" + mail);
            // телефоны — со страницы /people/:id (spec 11): нажатие копирует, tel: — в меню строки
            bool ph_fresh;
            var phones = s.refs.phones_cached (id, out ph_fresh);
            if (phones != null) foreach (var e in phones.get_elements ()) phone_row (contacts, jstr (e.get_object (), "text"), jstr (e.get_object (), "tel"));
            var li = jstr (p, "linkedin");
            row (contacts, "LinkedIn", li, false, li.has_prefix ("http") ? li : "https://www.linkedin.com/in/" + li);

            var acc = group (pp, null);
            var login = jstr (p, "login") != "" ? jstr (p, "login") : (u != null ? jstr (u, "login") : "");
            row (acc, _("Login"), login, true);
            if (u != null) {
                row (acc, _("Registered"), format_date (jstr (u, "created_on")));
                row (acc, _("Last sign-in"), format_datetime (jstr (u, "last_login_on")));
            }

            var about = group (pp, _("About"));
            if (jstr (p, "background").strip () != "") {
                var l = new Gtk.Label (jstr (p, "background").strip ()) { wrap = true, xalign = 0, selectable = true };
                about.add (l);
            }

            var links = group (pp, null);
            var open = new Adw.ButtonRow () { title = _("Open Profile in Redmine"), end_icon_name = "adw-external-link-symbolic" };
            open.activated.connect (() => new Gtk.UriLauncher (s.server + "/people/%d".printf (id)).launch.begin (get_root () as Gtk.Window, null));
            links.add (open);
            foreach (var g in new Adw.PreferencesGroup[] { work, contacts, acc, about }) g.visible = g.get_row (0) != null;
            return { work, contacts, acc, about, links };
        }

        /** Телефон (spec 11): нажатие звонит (tel: — GNOME Calls и т. п.), «Копировать» — в меню строки; звонить нечем — тост с копированием. */
        private void phone_row (Adw.PreferencesGroup g, string text, string tel) {
            if (text == "") return;
            var r = new Adw.ActionRow () { title = _("Phone"), subtitle = text, use_markup = false, activatable = true, tooltip_text = "tel:" + tel };
            r.add_css_class ("property");
            r.activated.connect (() => {
                new Gtk.UriLauncher ("tel:" + tel).launch.begin (get_root () as Gtk.Window, null, (o, res) => {
                    try {
                        ((Gtk.UriLauncher) o).launch.end (res);
                    } catch (Error e) {
                        if (e is Gtk.DialogError.DISMISSED) return;
                        var t = new Adw.Toast (_("No app to make calls")) { button_label = _("Copy") };
                        t.button_clicked.connect (() => { copy_text (this, text); toasts.add_toast (new Adw.Toast (_("Copied"))); });
                        toasts.add_toast (t);
                    }
                });
            });
            var m = new Menu ();
            m.append (_("Copy"), "phone.copy");
            var ag = new SimpleActionGroup ();
            var copy = new SimpleAction ("copy", null);
            copy.activate.connect (() => { copy_text (this, text); toasts.add_toast (new Adw.Toast (_("Copied"))); });
            ag.add_action (copy);
            r.insert_action_group ("phone", ag);
            var mb = new Gtk.MenuButton () { icon_name = "view-more-symbolic", menu_model = m, valign = Gtk.Align.CENTER, tooltip_text = _("More") };
            mb.add_css_class ("flat");
            r.add_suffix (mb);
            g.add (r);
        }

        private Adw.PreferencesGroup group (Adw.PreferencesPage pp, string? t) {
            var g = new Adw.PreferencesGroup () { title = t ?? "" };
            pp.add (g);
            return g;
        }

        /** Строка «название / значение»; пустое не показываем. uri — строка открывает его, copy — кнопка копирования. */
        private void row (Adw.PreferencesGroup g, string title, string v, bool copy = false, string? uri = null) {
            if (v.strip () == "") return;
            var r = new Adw.ActionRow () { title = title, subtitle = v, use_markup = false };
            r.add_css_class ("property");
            if (copy) {
                var b = new Gtk.Button.from_icon_name ("edit-copy-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Copy") };
                b.add_css_class ("flat");
                b.clicked.connect (() => { copy_text (this, v); toasts.add_toast (new Adw.Toast (_("Copied"))); });
                r.add_suffix (b);
            }
            if (uri != null) {
                r.activatable = true;
                r.tooltip_text = uri;
                r.add_suffix (new Gtk.Image.from_icon_name ("adw-external-link-symbolic"));
                r.activated.connect (() => new Gtk.UriLauncher (uri).launch.begin (get_root () as Gtk.Window, null));
            }
            g.add (r);
        }
    }

    /**
     * Аватар и имя человека — кнопкой на карточку: вся область нажимается, курсор-указатель,
     * Tab/Enter с клавиатуры, подпись для экранного диктора. id ≤ 0 (автор неизвестен) — просто child.
     */
    public Gtk.Widget person_button (int id, string name, Gtk.Widget child) {
        if (id <= 0) return child;
        var b = new Gtk.Button () { child = child, cursor = new Gdk.Cursor.from_name ("pointer", null) };
        b.add_css_class ("flat");
        b.add_css_class ("person-link");
        b.update_property (Gtk.AccessibleProperty.LABEL, _("Profile of %s").printf (name), -1);
        b.clicked.connect (() => new PersonCard (id, name).present (b));
        return b;
    }
}
