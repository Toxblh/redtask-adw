/* Колокольчик: история уведомлений — Лента или По задачам, фильтр по группам, непрочитанное (spec 19), отключение задачи/проекта. */
namespace Redmine {

    public class NotificationsSection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        public bool refreshing { get; set; }
        private GLib.ListStore store = new GLib.ListStore (typeof (LazyRow));
        private uint render_id = 0;
        private StateView state;
        private Adw.ToggleGroup view_mode;
        private Gtk.DropDown group_filter;
        private Gtk.Button mark_all;
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
                queue_render ();
            });
            top.append (view_mode);
            string[] labels = { _("All"), NotifGroup.ME.label (), NotifGroup.DISCUSSION.label (), NotifGroup.PROGRESS.label (), NotifGroup.DEADLINES.label (), NotifGroup.PROJECTS.label () };
            group_filter = new Gtk.DropDown.from_strings (labels) { tooltip_text = _("Show"), valign = Gtk.Align.CENTER };
            group_filter.notify["selected"].connect (queue_render);
            top.append (group_filter);
            box.append (top);
            mark_all = new Gtk.Button.with_label (_("Mark All as Read")) { halign = Gtk.Align.END, margin_end = 12, visible = false };
            mark_all.add_css_class ("flat");
            mark_all.clicked.connect (() => ReadState.get_default ().mark_all ());
            box.append (mark_all);

            // виртуальный список: из 500 событий виджеты строятся только около видимой области
            var list = lazy_list (store);
            var sw = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };
            state = new StateView (sw) { vexpand = true };
            state.retry_clicked.connect (() => refresh ());
            box.append (state);
            child = box;
            map.connect (bind_session);
            ReadState.get_default ().changed.connect (() => { if (get_mapped ()) queue_render (); });
        }

        private void bind_session () {
            var s = App.get ().session;
            if (s == null || s == bound) return;
            if (bound != null && changed_id != 0) bound.notifs.disconnect (changed_id);
            bound = s;
            changed_id = s.notifs.changed.connect (() => { if (get_mapped ()) queue_render (); });
        }

        /** Открытие списка ничего не помечает (spec 19.2): прочитанным уведомление делает открытие задачи. */
        public void shown () {
            var s = App.get ().session;
            if (s == null) return;
            bind_session ();
            queue_render ();
            if (s.notifs.needs_backfill () && !backfilling) backfill.begin (s);
        }

        public void refresh () {
            var s = App.get ().session;
            if (s == null || refreshing) return;
            refreshing = true;
            App.get ().poller.run.begin ((o, r) => {
                var ok = App.get ().poller.run.end (r);
                refreshing = false;
                queue_render ();
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
            queue_render ();
        }

        /** Несколько поводов подряд (показ, changed) — одна перерисовка. */
        private void queue_render () {
            if (render_id != 0) return;
            render_id = Idle.add (() => { render_id = 0; render (); return Source.REMOVE; });
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

        private LazyRow day_header (string date) {
            var t = day_title (date);
            return new LazyRow (() => list_heading (t, true));
        }

        private LazyRow lazy (owned RowBuild build, int issue, int note) {
            return new LazyRow ((owned) build, () => { if (issue > 0) win_of (this)?.open_issue (issue, note); });
        }

        private void render () {
            var s = App.get ().session;
            if (s == null) return;
            var all = s.notifs.load ();
            mark_all.visible = unread_notifications (all) > 0;
            var shown = new GenericArray<NotifEntry> ();
            foreach (var e in all) if (passes (e)) shown.add (e);
            var rows = new Object[0];
            if (shown.length == 0) {
                lazy_fill (store, rows);
                if (!backfilling) state.empty (_("No Notifications Yet"), "preferences-system-notifications-symbolic",
                    _("Comments, mentions and changes in your issues will appear here"));
                return;
            }
            var tz = new TimeZone.local ();
            if (view_mode.active_name == "issues") {
                foreach (var day in group_by_issue (shown, tz)) {
                    rows += day_header (day.date);
                    foreach (var g in day.groups) rows += group_item (g);
                }
            } else {
                string? cur = null;
                foreach (var e in shown) {
                    var d = local_day (e.at, tz);
                    if (d != cur) { rows += day_header (d); cur = d; }
                    rows += entry_item (e);
                }
            }
            state.content ();
            lazy_fill (store, rows);
        }

        private LazyRow entry_item (NotifEntry e) { return lazy (() => entry_row (e), e.issue_id, e.journal_id); }
        private LazyRow group_item (NotifIssueGroup g) { return lazy (() => group_row (g), g.issue_id, g.journal_id); }

        /** Контейнер строки с контекстным меню. */
        private Gtk.Box base_row (Gtk.Orientation o, int spacing, int issue_id, string subject, int project_id, string project) {
            var row = new Gtk.Box (o, spacing);
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

        private Gtk.Widget entry_row (NotifEntry e) {
            var b = base_row (Gtk.Orientation.HORIZONTAL, 10, e.issue_id, e.subject, e.project_id, e.project);
            b.margin_top = 6; b.margin_bottom = 6;
            b.margin_start = 4; b.margin_end = 4;
            var unread = notif_unread (e);
            // точка слева: место под неё есть и у прочитанных — строки не прыгают
            var dot = unread_dot (true);
            dot.opacity = unread ? 1 : 0;
            b.append (dot);
            if (e.avatar_user_id != 0) b.append (Avatars.make (e.avatar_user_id, e.author, 32));
            else {
                var icon = new Gtk.Image.from_icon_name (category_icon (e.type)) { pixel_size = 20, width_request = 32, valign = Gtk.Align.START };
                b.append (icon);
            }
            var col = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var t = new Gtk.Label ("#%d %s".printf (e.issue_id, e.subject)) { xalign = 0, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
            if (unread) t.add_css_class ("heading");
            head.append (t);
            var tm = new Gtk.Label (new DateTime.from_unix_local (e.at / 1000).format ("%H:%M"));
            tm.add_css_class ("dim-label");
            tm.add_css_class ("caption");
            head.append (tm);
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
            if (e.image_id != 0) b.append (thumb (e.image_id));
            return b;
        }

        /** Миниатюра картинки события справа в строке истории. */
        private Gtk.Widget thumb (int id) {
            var pic = new Gtk.Picture () { width_request = 40, height_request = 40, content_fit = Gtk.ContentFit.COVER, valign = Gtk.Align.CENTER, visible = false };
            pic.add_css_class ("rich-image");
            var att = new Json.Object ();
            att.set_int_member ("id", id);
            load_attachment_texture.begin (att, true, null, (o, r) => {
                var t = load_attachment_texture.end (r);
                if (t != null) { pic.paintable = t; pic.visible = true; }
            });
            return pic;
        }

        private Gtk.Widget group_row (NotifIssueGroup g) {
            var e = g.latest;
            var col = base_row (Gtk.Orientation.VERTICAL, 4, g.issue_id, e.subject, e.project_id, e.project);
            col.margin_top = 8; col.margin_bottom = 8;
            col.margin_start = 6; col.margin_end = 6;
            bool unread = false;
            foreach (var x in g.entries) if (notif_unread (x)) unread = true;
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var dot = unread_dot (true);
            dot.opacity = unread ? 1 : 0;
            head.append (dot);
            var t = new Gtk.Label ("#%d %s".printf (g.issue_id, e.subject)) { xalign = 0, wrap = true, lines = 2, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
            if (unread) t.add_css_class ("heading");
            head.append (t);
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
            return col;
        }
    }

    /** Уведомление непрочитано (spec 19.1): его время новее рубежа и просмотра задачи. */
    public bool notif_unread (NotifEntry e) { return ReadState.get_default ().unread_at (e.issue_id, e.at); }

    public int unread_notifications (GenericArray<NotifEntry> all) {
        int n = 0;
        foreach (var e in all) if (notif_unread (e)) n++;
        return n;
    }
}
