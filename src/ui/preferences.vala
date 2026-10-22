/* Настройки: учётка и уведомления (категории, источники, отключённые задачи/проекты, работа в фоне). */
namespace Redmine {

    public class PreferencesDialog : Adw.PreferencesDialog {
        private Adw.PreferencesGroup muted_group;
        private GenericArray<Gtk.Widget> muted_rows = new GenericArray<Gtk.Widget> ();

        construct {
            var p = Prefs.get_default ();
            search_enabled = true;

            // ---- общие ----
            var general = new Adw.PreferencesPage () { title = _("General"), icon_name = "emblem-system-symbolic" };
            var acc = new Adw.PreferencesGroup () { title = _("Account") };
            var who = new Adw.ActionRow () { title = Markup.escape_text (p.user_name), subtitle = Markup.escape_text (p.server_url) };
            who.add_prefix (Avatars.make (p.user_id, p.user_name, 40));
            acc.add (who);
            var out_row = new Adw.ButtonRow () { title = _("Sign Out…") };
            out_row.add_css_class ("destructive-action");
            out_row.activated.connect (() => {
                var d = new Adw.AlertDialog (_("Sign Out?"), _("The API key, cached lists and notification history of this account will be removed from this device."));
                d.add_response ("cancel", _("_Cancel"));
                d.add_response ("out", _("_Sign Out"));
                d.set_response_appearance ("out", Adw.ResponseAppearance.DESTRUCTIVE);
                d.response.connect ((r) => { if (r == "out") { close (); App.get ().logout.begin (); } });
                d.present (this);
            });
            acc.add (out_row);
            general.add (acc);
            add (general);

            // ---- уведомления ----
            var notif = new Adw.PreferencesPage () { title = _("Notifications"), icon_name = "preferences-system-notifications-symbolic" };
            var main = new Adw.PreferencesGroup () { description = _("Changes in my and watched issues are checked while the app is running") };
            var on = new Adw.SwitchRow () { title = _("Notifications") };
            p.s.bind ("notifications-enabled", on, "active", SettingsBindFlags.DEFAULT);
            main.add (on);
            var interval = new Adw.ComboRow () { title = _("Check interval") };
            int[] minutes = { 5, 15, 30, 60 };
            var sl = new Gtk.StringList (null);
            foreach (var m in minutes) sl.append (_("%d min").printf (m));
            interval.model = sl;
            for (int i = 0; i < minutes.length; i++) if (minutes[i] == p.s.get_int ("poll-interval")) interval.selected = i;
            interval.notify["selected"].connect (() => p.s.set_int ("poll-interval", minutes[interval.selected]));
            on.bind_property ("active", interval, "sensitive", BindingFlags.SYNC_CREATE);
            main.add (interval);
            var bg = new Adw.SwitchRow () { title = _("Run in background"), subtitle = _("Keep checking after the window is closed and start when you log in") };
            p.s.bind ("run-in-background", bg, "active", SettingsBindFlags.DEFAULT);
            on.bind_property ("active", bg, "sensitive", BindingFlags.SYNC_CREATE);
            main.add (bg);
            var last = new Adw.ActionRow () { title = _("Last check") };
            update_last (last);
            p.s.changed["last-check"].connect (() => update_last (last));
            var now = new Gtk.Button.with_label (_("Check Now")) { valign = Gtk.Align.CENTER };
            now.clicked.connect (() => {
                now.sensitive = false;
                App.get ().poller.run.begin ((o, r) => {
                    var ok = App.get ().poller.run.end (r);
                    now.sensitive = true;
                    add_toast (new Adw.Toast (ok ? _("Checked") : _("Could not check for notifications")));
                });
            });
            last.add_suffix (now);
            main.add (last);
            var test = new Adw.ButtonRow () { title = _("Send Test Notification") };
            test.activated.connect (() => {
                var n = new GLib.Notification ("#1 " + _("Example issue"));
                n.set_body (_("Ivan Ivanov: this is how a comment notification looks"));
                App.get ().send_notification ("test", n);
            });
            main.add (test);
            notif.add (main);

            // категории по группам
            NotifGroup? cur = null;
            Adw.PreferencesGroup? g = null;
            foreach (var c in CATEGORIES) {
                if (cur == null || c.group != cur) {
                    cur = c.group;
                    g = new Adw.PreferencesGroup () { title = c.group.label () };
                    notif.add (g);
                }
                var row = new Adw.SwitchRow () { title = category_label (c.type), active = p.category_on (c.type) };
                var hint = category_hint (c.type);
                if (hint != null) { row.subtitle = hint; }
                var type = c.type;
                row.notify["active"].connect (() => p.set_category (type, row.active));
                g.add (row);
                if (c.type == NotifType.STATUS) g.add (sub_switch (_("Only closing or resolving"), "notif-status-closed-only", row));
                if (c.type == NotifType.PRIORITY) g.add (sub_switch (_("Only raising"), "notif-priority-raised-only", row));
            }

            var scopes = new Adw.PreferencesGroup () { title = _("Which issues"), description = _("A disabled source is not polled at all — its events do not reach the history either") };
            scopes.add (switch_row (_("Assigned to me"), "notif-scope-assigned"));
            scopes.add (switch_row (_("Created by me"), "notif-scope-authored"));
            scopes.add (switch_row (_("Watched"), "notif-scope-watched"));
            var fav = switch_row (_("Favorites only"), "notif-favorites-only");
            fav.subtitle = _("Of the sources above — only issues marked with a star");
            scopes.add (fav);
            notif.add (scopes);

            muted_group = new Adw.PreferencesGroup () { title = _("Muted issues and projects") };
            notif.add (muted_group);
            fill_muted ();
            p.s.changed["muted-issues"].connect (fill_muted);
            p.s.changed["muted-projects"].connect (fill_muted);

            var note = new Adw.PreferencesGroup () {
                description = _("A disabled category does not send notifications, but stays in the bell history. There are no quiet hours in the app — use the system Do Not Disturb mode."),
            };
            notif.add (note);
            add (notif);
        }

        private void update_last (Adw.ActionRow r) {
            var ms = Prefs.get_default ().s.get_int64 ("last-check");
            r.subtitle = ms == 0 ? _("never") : new DateTime.from_unix_local (ms / 1000).format ("%-d %b, %H:%M").strip ();
        }

        private string? category_hint (string type) {
            switch (type) {
                case NotifType.MENTION: return _("Comments with my login in any issue I can see, not only mine. Mentions in issue descriptions are not tracked");
                case NotifType.DUE_SOON: return _("For issues assigned to me; one reminder per due date");
                case NotifType.NEW_ISSUE: return _("Other people's new issues in projects I am a member of. While off, the server is not asked about them and they do not reach the history");
                default: return null;
            }
        }

        private Adw.SwitchRow switch_row (string title, string key) {
            var r = new Adw.SwitchRow () { title = title };
            Prefs.get_default ().s.bind (key, r, "active", SettingsBindFlags.DEFAULT);
            return r;
        }

        private Adw.SwitchRow sub_switch (string title, string key, Adw.SwitchRow parent) {
            var r = switch_row (title, key);
            r.add_css_class ("indent");
            r.margin_start = 0;
            parent.bind_property ("active", r, "sensitive", BindingFlags.SYNC_CREATE);
            return r;
        }

        private void fill_muted () {
            foreach (var w in muted_rows) muted_group.remove (w);
            muted_rows = new GenericArray<Gtk.Widget> ();
            var p = Prefs.get_default ();
            add_muted (p.muted ("muted-issues"), "muted-issues", true);
            add_muted (p.muted ("muted-projects"), "muted-projects", false);
            if (muted_rows.length == 0) {
                var empty = new Adw.ActionRow () { title = _("Nothing is muted"), subtitle = _("Mute an issue from its notification or menu, an issue or project — from the bell context menu") };
                muted_group.add (empty);
                muted_rows.add (empty);
            }
        }

        private void add_muted (HashTable<int, string> items, string key, bool issue) {
            foreach (var id in items.get_keys ()) {
                var name = items[id];
                var r = new Adw.ActionRow () {
                    title = Markup.escape_text (issue ? "#%d %s".printf (id, name) : name),
                    subtitle = issue ? _("Issue") : _("Project"),
                };
                var b = new Gtk.Button.with_label (_("Unmute")) { valign = Gtk.Align.CENTER };
                b.clicked.connect (() => Prefs.get_default ().set_muted (key, id, name, false));
                r.add_suffix (b);
                muted_group.add (r);
                muted_rows.add (r);
            }
        }
    }
}
