/* Колокольчик: история уведомлений — Лента или По задачам, фильтр по группам, непрочитанное, отключение задачи/проекта. */
namespace Redmine {

    public class NotificationsSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        private Gtk.ListBox list;
        private StateView state;
        private Adw.ToggleGroup view_mode;
        private Gtk.DropDown group_filter;
        private GenericSet<string> unread = new GenericSet<string> (str_hash, str_equal);
        private bool backfilling = false;
        private ulong changed_id = 0;
        private Session? bound = null;

        construct {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            view_mode = new Adw.ToggleGroup () { hexpand = true, homogeneous = true };
            view_mode.add (new Adw.Toggle () { name = "feed", label = _("Feed") });
            view_mode.add (new Adw.Toggle () { name = "issues", label = _("By Issue") });
            view_mode.active_name = Prefs.get_default ().s.get_boolean ("notif-by-issue") ? "issues" : "feed";
            view_mode.notify["active-name"].connect (() => {
                Prefs.get_default ().s.set_boolean ("notif-by-issue", view_mode.active_name == "issues");
                render ();
            });
            top.append (view_mode);
            string[] labels = { _("All"), NotifGroup.ME.label (), NotifGroup.DISCUSSION.label (), NotifGroup.PROGRESS.label (), NotifGroup.DEADLINES.label (), NotifGroup.PROJECTS.label () };
            group_filter = new Gtk.DropDown.from_strings (labels) { tooltip_text = _("Show"), valign = Gtk.Align.CENTER };
            group_filter.notify["selected"].connect (render);
            top.append (group_filter);
            box.append (top);

            list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => {
                var id = row.get_data<int> ("issue");
                if (id > 0) win_of (this)?.open_issue (id, row.get_data<int> ("note"));
            });
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => refresh ());
            box.append (state);
            child = box;
            map.connect (bind_session);
        }

        /** Счётчик непрочитанного на значке раздела — от истории текущей учётки. */
        private void bind_session () {
            var s = App.get ().session;
            if (s == null || s == bound) return;
            if (bound != null && changed_id != 0) bound.notifs.disconnect (changed_id);
            bound = s;
            changed_id = s.notifs.changed.connect (() => {
                if (!get_mapped ()) win_of (this)?.set_unread (s.notifs.unread_count ());
                else render ();
            });
            win_of (this)?.set_unread (s.notifs.unread_count ());
        }

        public void shown () {
            var s = App.get ().session;
            if (s == null) return;
            bind_session ();
            // открытие колокольчика: подсветить новое и пометить всё прочитанным
            foreach (var k in s.notifs.take_unread ().get_values ()) unread.add (k);
            win_of (this)?.set_unread (0);
            render ();
            if (s.notifs.needs_backfill () && !backfilling) backfill.begin (s);
        }

        public void refresh () {
            var s = App.get ().session;
            if (s == null) return;
            App.get ().poller.run.begin ((o, r) => {
                var ok = App.get ().poller.run.end (r);
                foreach (var k in s.notifs.take_unread ().get_values ()) unread.add (k);
                render ();
                if (!ok) win_of (this)?.toast (_("Could not check for notifications"));
            });
        }

        public void start_search () {}

        /** Первый показ: события «моих» задач за 7 дней, без системных уведомлений. */
        private async void backfill (Session s) {
            backfilling = true;
            if (s.notifs.load ().length == 0) state.loading ();
            try {
                yield App.get ().poller.backfill (s);
            } catch (Error e) {
                if (s.notifs.load ().length == 0) { state.error (e); backfilling = false; return; }
            }
            backfilling = false;
            render ();
        }

        private bool passes (NotifEntry e) {
            var g = group_filter.selected;
            if (g == 0) return true;
            foreach (var t in e.types ()) if ((uint) group_of (t) == g - 1) return true;
            return false;
        }

        private string day_title (string date) {
            var now = new DateTime.now_local ();
            if (date == now.format ("%Y-%m-%d")) return _("Today");
            if (date == now.add_days (-1).format ("%Y-%m-%d")) return _("Yesterday");
            return format_date (date);
        }

        private void day_header (string date) {
            var row = new Gtk.ListBoxRow () { activatable = false, selectable = false };
            var l = new Gtk.Label (day_title (date)) { xalign = 0, margin_start = 6, margin_top = 12, margin_bottom = 4 };
            l.add_css_class ("heading");
            l.add_css_class ("dim-label");
            row.child = l;
            list.append (row);
        }

        private void render () {
            var s = App.get ().session;
            if (s == null) return;
            list.remove_all ();
            var all = s.notifs.load ();
            var shown = new GenericArray<NotifEntry> ();
            foreach (var e in all) if (passes (e)) shown.add (e);
            if (shown.length == 0) {
                if (!backfilling) state.empty (_("No Notifications Yet"), "preferences-system-notifications-symbolic",
                    _("Comments, mentions and changes in your issues will appear here"));
                return;
            }
            var tz = new TimeZone.local ();
            if (view_mode.active_name == "issues") {
                foreach (var day in group_by_issue (shown, tz)) {
                    day_header (day.date);
                    foreach (var g in day.groups) list.append (group_row (g));
                }
            } else {
                string? cur = null;
                foreach (var e in shown) {
                    var d = local_day (e.at, tz);
                    if (d != cur) { day_header (d); cur = d; }
                    list.append (entry_row (e));
                }
            }
            state.content ();
        }

        private Gtk.ListBoxRow base_row (int issue_id, int note, string subject, int project_id, string project) {
            var row = new Gtk.ListBoxRow ();
            row.set_data<int> ("issue", issue_id);
            row.set_data<int> ("note", note);
            // контекстное меню (правая кнопка / долгое нажатие): отключить уведомления по задаче или проекту
            var g = new SimpleActionGroup ();
            var p = Prefs.get_default ();
            var mi = new SimpleAction ("mute-issue", null);
            mi.activate.connect (() => {
                var on = !p.muted ("muted-issues").contains (issue_id);
                p.set_muted ("muted-issues", issue_id, subject, on);
                win_of (this)?.toast (on ? _("Notifications for #%d are off").printf (issue_id) : _("Notifications for #%d are on").printf (issue_id));
            });
            g.add_action (mi);
            var mp = new SimpleAction ("mute-project", null);
            mp.set_enabled (project_id != 0);
            mp.activate.connect (() => {
                var on = !p.muted ("muted-projects").contains (project_id);
                p.set_muted ("muted-projects", project_id, project, on);
                win_of (this)?.toast (on ? _("Notifications for project “%s” are off").printf (project) : _("Notifications for project “%s” are on").printf (project));
            });
            g.add_action (mp);
            row.insert_action_group ("n", g);
            var m = new Menu ();
            m.append (p.muted ("muted-issues").contains (issue_id) ? _("Notify About Issue") : _("Mute Issue"), "n.mute-issue");
            if (project_id != 0) m.append (p.muted ("muted-projects").contains (project_id) ? _("Notify About Project") : _("Mute Project"), "n.mute-project");
            // меню создаётся по требованию и отцепляется при закрытии: висящий дочерний попап ряд не отпускает
            var click = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
            click.pressed.connect ((n, x, y) => popup_menu (row, m, x, y));
            row.add_controller (click);
            var lp = new Gtk.GestureLongPress () { touch_only = true };
            lp.pressed.connect ((x, y) => popup_menu (row, m, x, y));
            row.add_controller (lp);
            return row;
        }

        private void popup_menu (Gtk.Widget row, MenuModel m, double x, double y) {
            var pop = new Gtk.PopoverMenu.from_model (m) { has_arrow = true, pointing_to = { (int) x, (int) y, 1, 1 } };
            pop.set_parent (row);
            pop.closed.connect (() => Idle.add (() => { pop.unparent (); return Source.REMOVE; }));
            pop.popup ();
        }

        private Gtk.Widget unread_dot (bool on) {
            var d = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { valign = Gtk.Align.CENTER, visible = on };
            d.add_css_class ("unread-dot");
            d.update_property (Gtk.AccessibleProperty.LABEL, _("New"), -1);
            return d;
        }

        private Gtk.Widget entry_row (NotifEntry e) {
            var row = base_row (e.issue_id, e.journal_id, e.subject, e.project_id, e.project);
            var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) { margin_top = 6, margin_bottom = 6, margin_start = 4, margin_end = 4 };
            if (e.avatar_user_id != 0) b.append (Avatars.make (e.avatar_user_id, e.author, 32));
            else {
                var icon = new Gtk.Image.from_icon_name (category_icon (e.type)) { pixel_size = 20, width_request = 32, valign = Gtk.Align.START };
                b.append (icon);
            }
            var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var t = new Gtk.Label ("#%d %s".printf (e.issue_id, e.subject)) { xalign = 0, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
            t.add_css_class ("heading");
            head.append (t);
            var tm = new Gtk.Label (new DateTime.from_unix_local (e.at / 1000).format ("%H:%M"));
            tm.add_css_class ("dim-label");
            tm.add_css_class ("caption");
            head.append (tm);
            head.append (unread_dot (unread.contains (e.key)));
            col.append (head);
            foreach (var l in e.lines) {
                var ll = new Gtk.Label (l) { xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 3, ellipsize = Pango.EllipsizeMode.END };
                col.append (ll);
            }
            var cat = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            var ci = new Gtk.Image.from_icon_name (category_icon (e.type)) { pixel_size = 12 };
            ci.add_css_class ("dim-label");
            cat.append (ci);
            var cl = new Gtk.Label (category_label (e.type) + (e.project != "" ? " · " + e.project : "")) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            cl.add_css_class ("dim-label");
            cl.add_css_class ("caption");
            cat.append (cl);
            col.append (cat);
            b.append (col);
            row.child = b;
            return row;
        }

        private Gtk.Widget group_row (NotifIssueGroup g) {
            var e = g.latest;
            var row = base_row (g.issue_id, g.journal_id, e.subject, e.project_id, e.project);
            var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) { margin_top = 8, margin_bottom = 8, margin_start = 6, margin_end = 6 };
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var t = new Gtk.Label ("#%d %s".printf (g.issue_id, e.subject)) { xalign = 0, wrap = true, lines = 2, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
            t.add_css_class ("heading");
            head.append (t);
            head.append (unread_dot (g.unread (unread)));
            col.append (head);
            // что происходило: значки категорий без повторов; кто: аватары участников
            var meta = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var seen = new GenericSet<string> (str_hash, str_equal);
            foreach (var x in g.entries) foreach (var ty in x.types ()) {
                if (seen.contains (ty)) continue;
                seen.add (ty);
                var im = new Gtk.Image.from_icon_name (category_icon (ty)) { pixel_size = 14, tooltip_text = category_label (ty) };
                im.add_css_class ("dim-label");
                meta.append (im);
            }
            var people = new GenericSet<int> (direct_hash, direct_equal);
            foreach (var x in g.entries) {
                if (x.avatar_user_id == 0 || people.contains (x.avatar_user_id)) continue;
                people.add (x.avatar_user_id);
                meta.append (Avatars.make (x.avatar_user_id, x.author, 20));
            }
            var cnt = new Gtk.Label (ngettext ("%u event", "%u events", g.entries.length).printf (g.entries.length)) { hexpand = true, xalign = 1 };
            cnt.add_css_class ("dim-label");
            cnt.add_css_class ("caption");
            meta.append (cnt);
            col.append (meta);
            var last = new Gtk.Label (e.lines.length > 0 ? e.lines[0] : "") { xalign = 0, wrap = true, lines = 2, ellipsize = Pango.EllipsizeMode.END };
            col.append (last);
            row.child = col;
            return row;
        }
    }
}
