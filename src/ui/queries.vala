/* Фильтры и сохранённые запросы (spec 17): экран запросов, свой фильтр, условие, сохранение, список задач запроса. */
namespace Redmine {

    /** Поля-люди: значения — выбор человека (spec 8.2) и «я». */
    private bool people_field (string field) {
        return field in new string[] { "author_id", "assigned_to_id", "watcher_id", "updated_by", "last_updated_by" };
    }

    /** Предлагаемые операторы: у остальных remote-полей значения не выбираются — только операторы без значений. */
    private string[] usable_ops (Json.Object f) {
        string[] res = {};
        bool values_ok = !jbool (f, "remote") || people_field (jstr (f, "field"));
        foreach (var n in f.get_array_member ("ops").get_elements ()) {
            var op = n.get_string ();
            if (values_ok || op_without_values (op)) res += op;
        }
        return res;
    }

    private string op_label (Json.Object labels, string op) {
        return labels.has_member (op) ? labels.get_string_member (op) : op;
    }

    /** «★» у запроса: своего, серверного, недавнего. */
    private Gtk.Button query_star (Json.Object q) {
        var key = Queries.key_of (q);
        var on = Queries.get_default ().is_fav (key);
        var b = new Gtk.Button.from_icon_name (on ? "starred-symbolic" : "non-starred-symbolic") {
            valign = Gtk.Align.CENTER, tooltip_text = on ? _("Remove from Favorites") : _("Add to Favorites"),
        };
        b.add_css_class ("flat");
        b.clicked.connect (() => Queries.get_default ().set_fav (q, !Queries.get_default ().is_fav (key)));
        return b;
    }

    private Gtk.Widget page_column (Gtk.Widget child) {
        var clamp = new Adw.Clamp () { child = child, maximum_size = 860, tightening_threshold = 600 };
        return new Gtk.ScrolledWindow () { child = clamp, hscrollbar_policy = Gtk.PolicyType.NEVER, vexpand = true };
    }

    /** Шаг 2 сохранения (на сервер) с итогом тостом; нет входа на сайте — кнопка входа и повтор. */
    public async void push_query (Window? w, Json.Object q) {
        var err = yield Queries.get_default ().push (q);
        if (w == null) return;
        if (err == null) w.toast (_("Saved on the server"));
        else w.query_not_saved (err);
    }

    /**
     * Запросы проекта (pid > 0) или все (pid = 0): избранные (порядок — перетаскиванием), недавние фильтры,
     * «Мои» (свои с состоянием и личные серверные) и «Общие» (spec 17.2–17.5).
     */
    public class QueriesPage : Adw.NavigationPage, Refreshable {
        public bool refreshing { get; set; }
        private int pid;
        private Gtk.Box box;
        private ulong sig = 0;
        private bool synced = false;

        public QueriesPage (int pid) {
            Object (title: pid > 0 ? _("Queries") : _("All Queries"), tag: "queries-%d".printf (pid));
            this.pid = pid;
            var hb = new Adw.HeaderBar ();
            hb.pack_start (refresh_button (this, () => refresh ()));
            var add = new Gtk.Button.from_icon_name ("list-add-symbolic") { tooltip_text = _("New Filter") };
            add.clicked.connect (() => win_of (this)?.push_list (new FilterPage (pid)));
            hb.pack_end (add);
            box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 24 };
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = page_column (box);
            child = tv;
            sig = Queries.get_default ().changed.connect (render);
            render ();
            shown.connect (() => {
                if (synced) return;
                synced = true;
                refresh ();
                // своё, что не дошло до сервера, — ещё раз сам (раз в сессию на запрос)
                Queries.get_default ().retry_pending (false);
            });
        }

        public override void dispose () {
            if (sig != 0) Queries.get_default ().disconnect (sig);
            sig = 0;
            base.dispose ();
        }

        public void refresh () {
            if (refreshing) return;
            refreshing = true;
            Queries.get_default ().refresh_server.begin ((o, r) => {
                try {
                    Queries.get_default ().refresh_server.end (r);
                } catch (Error e) {
                    win_of (this)?.toast_error (e);
                }
                refreshing = false;
            });
        }

        private void run (Json.Object q) {
            var qs = Queries.get_default ();
            var iq = qs.issue_query (q, pid);
            if (iq != null) win_of (this)?.push_list (new QueryIssuesPage (qs.title_of (q), iq, q));
        }

        private void render () {
            clear_box (box);
            var qs = Queries.get_default ();
            var top = boxed_list ();
            top.margin_top = 6;
            var nf = new Adw.ButtonRow () { title = _("New Filter"), start_icon_name = "list-add-symbolic" };
            nf.activated.connect (() => win_of (this)?.push_list (new FilterPage (pid)));
            top.append (nf);
            box.append (top);

            if (qs.favs.length > 0) {
                box.append (heading (_("Favorite Queries")));
                var l = boxed_list ();
                for (int i = 0; i < qs.favs.length; i++) l.append (fav_row (i));
                box.append (l);
            }

            var rec = new GenericArray<Json.Object> ();
            foreach (var r in qs.recent) if (pid == 0 || jint (r, "project_id") == pid) rec.add (r);
            if (rec.length > 0) {
                box.append (heading (_("Recent Filters")));
                var l = boxed_list ();
                foreach (var r in rec) l.append (recent_row (r));
                box.append (l);
            }

            GenericArray<Json.Object> mine, shared;
            qs.groups (pid, out mine, out shared);
            box.append (heading (_("Mine")));
            if (mine.length == 0) {
                var e = new Gtk.Label (_("No saved queries yet")) { xalign = 0 };
                e.add_css_class ("dim-label");
                box.append (e);
            } else {
                var l = boxed_list ();
                foreach (var q in mine) l.append (q.has_member ("local_id") ? local_row (q) : server_row (q));
                box.append (l);
            }
            if (shared.length > 0) {
                box.append (heading (_("Shared")));
                var l = boxed_list ();
                foreach (var q in shared) l.append (server_row (q));
                box.append (l);
            }
        }

        private Adw.ActionRow base_row (Json.Object q, string title) {
            var row = new Adw.ActionRow () { title = Markup.escape_text (title), activatable = true, title_lines = 2, subtitle_lines = 3 };
            row.activated.connect (() => run (q));
            return row;
        }

        private Gtk.Widget server_row (Json.Object q) {
            var row = base_row (q, jstr (q, "name"));
            row.add_suffix (query_star (q));
            return row;
        }

        private Gtk.Widget recent_row (Json.Object r) {
            var row = base_row (r, Queries.summary (r.get_array_member ("filters")));
            var save = new Gtk.Button.with_label (_("Save")) { valign = Gtk.Align.CENTER };
            save.add_css_class ("flat");
            save.clicked.connect (() => new SaveQueryDialog (jint (r, "project_id"), r.get_array_member ("filters"), r.get_array_member ("sort"), null).present (this));
            row.add_suffix (save);
            row.add_suffix (query_star (r));
            return row;
        }

        private Gtk.Widget local_row (Json.Object q) {
            var qs = Queries.get_default ();
            var row = base_row (q, qs.title_of (q));
            var st = jstr (q, "state");
            string sub;
            if (st == "server") sub = jstr (q, "description");
            else if (st == "sending") sub = _("Saving to the server…");
            else sub = _("Only on this device") + (jstr (q, "reason") != "" ? " · " + jstr (q, "reason") : "");
            row.subtitle = Markup.escape_text (sub);
            if (st == "local") {
                var push = new Gtk.Button.from_icon_name ("document-send-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Save on Server") };
                push.add_css_class ("flat");
                push.clicked.connect (() => push_query.begin (win_of (this), q));
                row.add_suffix (push);
            }
            row.add_suffix (query_star (q));
            var m = new Menu ();
            if (st == "local") m.append (_("Save on Server"), "q.push");
            m.append (_("Edit"), "q.edit");
            m.append (_("Delete"), "q.delete");
            var g = new SimpleActionGroup ();
            var a_push = new SimpleAction ("push", null);
            a_push.activate.connect (() => push_query.begin (win_of (this), q));
            g.add_action (a_push);
            var a_edit = new SimpleAction ("edit", null);
            a_edit.activate.connect (() => win_of (this)?.push_list (new FilterPage (pid, q)));
            g.add_action (a_edit);
            var a_del = new SimpleAction ("delete", null);
            a_del.activate.connect (() => delete_local.begin (q));
            g.add_action (a_del);
            row.insert_action_group ("q", g);
            var mb = new Gtk.MenuButton () { icon_name = "view-more-symbolic", menu_model = m, valign = Gtk.Align.CENTER, tooltip_text = _("More") };
            mb.add_css_class ("flat");
            row.add_suffix (mb);
            return row;
        }

        private async void delete_local (Json.Object q) {
            var qs = Queries.get_default ();
            try {
                yield qs.remove (q, false);
            } catch (Error e) {
                var d = new Adw.AlertDialog (_("Not Deleted on the Server"), Queries.reason_of (e) + "\n\n" + _("Delete only on this device?"));
                d.add_response ("cancel", _("_Cancel"));
                d.add_response ("device", _("_Delete on Device"));
                d.set_response_appearance ("device", Adw.ResponseAppearance.DESTRUCTIVE);
                d.response.connect ((r) => {
                    if (r == "device") qs.remove.begin (q, true, (o, res) => { try { qs.remove.end (res); } catch (Error e2) {} });
                });
                d.present (this);
            }
        }

        /** Избранное: перетаскивание за ручку меняет порядок (и в боковой панели). */
        private Gtk.Widget fav_row (int i) {
            var qs = Queries.get_default ();
            var f = qs.favs[i];
            var title = qs.title_of (f);
            var row = base_row (f, title != "" ? title : _("Deleted query"));
            row.add_prefix (new Gtk.Image.from_icon_name ("list-drag-handle-symbolic") { tooltip_text = _("Drag to reorder") });
            row.add_suffix (query_star (f));
            var ds = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
            ds.prepare.connect ((x, y) => {
                var v = Value (typeof (int));
                v.set_int (i);
                return new Gdk.ContentProvider.for_value (v);
            });
            ds.drag_begin.connect ((drag) => ds.set_icon (new Gtk.WidgetPaintable (row), 0, 0));
            row.add_controller (ds);
            var dt = new Gtk.DropTarget (typeof (int), Gdk.DragAction.MOVE);
            dt.drop.connect ((val, x, y) => {
                var from = val.get_int ();
                // перерисовка списка — после завершения перетаскивания
                Idle.add (() => { qs.move_fav (from, i); return Source.REMOVE; });
                return true;
            });
            row.add_controller (dt);
            return row;
        }
    }

    private const string[] SORT_FIELDS = { "", "updated_on", "created_on", "priority", "status", "id", "due_date", "subject", "assigned_to" };

    private string[] sort_labels () {
        return { _("Default"), _("Updated"), _("Created"), _("Priority"), _("Status"), _("Number"), _("Due date"), _("Subject"), _("Assignee") };
    }

    /** Свой фильтр (spec 17.2): условия «поле · оператор · значения», «+ Условие», сортировка; «Применить» и «Сохранить». */
    public class FilterPage : Adw.NavigationPage {
        private int pid;
        private Json.Object? editing;
        private Json.Array filters = new Json.Array ();
        private Json.Array? catalog = null;
        private Json.Object labels = new Json.Object ();
        private Gtk.ListBox conds;
        private Adw.ButtonRow add_row;
        private Adw.ComboRow sort_by;
        private Adw.SwitchRow desc;
        private Gtk.Label note;

        public FilterPage (int pid, Json.Object? editing = null, Json.Array? preset = null) {
            Object (title: editing != null ? jstr (editing, "name") : _("Filter"), tag: "filter-%d".printf (pid));
            this.pid = pid;
            this.editing = editing;
            var src = editing != null ? editing.get_array_member ("filters") : preset;
            if (src != null) foreach (var n in src.get_elements ()) filters.add_object_element (n.get_object ());

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 24 };
            box.append (heading (_("Conditions")));
            conds = boxed_list ();
            box.append (conds);
            add_row = new Adw.ButtonRow () { title = _("Add Condition"), start_icon_name = "list-add-symbolic", sensitive = false };
            add_row.activated.connect (() => edit_condition (null));
            note = new Gtk.Label ("") { xalign = 0, wrap = true, margin_top = 6, visible = false };
            note.add_css_class ("dim-label");
            note.add_css_class ("caption");
            box.append (note);

            box.append (heading (_("Sort")));
            var sl = boxed_list ();
            sort_by = new Adw.ComboRow () { title = _("Sort by"), model = new Gtk.StringList (sort_labels ()) };
            desc = new Adw.SwitchRow () { title = _("Descending"), active = true };
            sort_by.bind_property ("selected", desc, "sensitive", BindingFlags.SYNC_CREATE, (b, from, ref to) => { to = from.get_uint () > 0; return true; });
            var sort = editing != null ? editing.get_array_member ("sort") : null;
            if (sort != null && sort.get_length () > 0) {
                var a = sort.get_array_element (0);
                for (int k = 1; k < SORT_FIELDS.length; k++) if (SORT_FIELDS[k] == a.get_string_element (0)) sort_by.selected = k;
                desc.active = a.get_string_element (1) == "desc";
            }
            sl.append (sort_by);
            sl.append (desc);
            box.append (sl);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { halign = Gtk.Align.CENTER, margin_top = 24, homogeneous = true };
            var save = new Gtk.Button.with_mnemonic (_("_Save…"));
            save.add_css_class ("pill");
            save.clicked.connect (open_save);
            var apply = new Gtk.Button.with_mnemonic (_("_Apply"));
            apply.add_css_class ("pill");
            apply.add_css_class ("suggested-action");
            apply.clicked.connect (on_apply);
            buttons.append (save);
            buttons.append (apply);
            box.append (buttons);

            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = page_column (box);
            child = tv;
            render ();
            load_catalog.begin ();
        }

        /** Каталог: из кэша сразу (любого возраста), старше суток — обновить из сети (spec 17.1). */
        private async void load_catalog () {
            var s = App.get ().session;
            if (s == null) return;
            bool fresh;
            var c = s.refs.catalog_cached (pid, out fresh);
            if (c != null) set_catalog (c);
            if (fresh) return;
            if (c == null) show_note (_("Loading filters…"));
            try {
                set_catalog (yield s.refs.catalog (pid));
            } catch (Error e) {
                if (catalog == null) show_note (_("Could not load filters: %s").printf (e.message));
            }
        }

        private void show_note (string? text) {
            note.label = text ?? "";
            note.visible = text != null;
        }

        private void set_catalog (Json.Object c) {
            catalog = c.get_array_member ("filters");
            labels = c.get_object_member ("labels") ?? new Json.Object ();
            add_row.sensitive = true;
            show_note (null);
        }

        public void open_save () {
            var d = new SaveQueryDialog (pid, filters, sort_json (), editing);
            d.saved.connect ((q) => { if (editing != null) title = jstr (q, "name"); });
            d.present (this);
        }

        public Json.Array sort_json () {
            var a = new Json.Array ();
            if (sort_by.selected > 0 && sort_by.selected < SORT_FIELDS.length) {
                var p = new Json.Array ();
                p.add_string_element (SORT_FIELDS[sort_by.selected]);
                p.add_string_element (desc.active ? "desc" : "asc");
                a.add_array_element (p);
            }
            return a;
        }

        private void render () {
            conds.remove_all ();
            for (int i = 0; i < (int) filters.get_length (); i++) {
                var f = filters.get_object_element (i);
                var idx = i;
                var row = new Adw.ActionRow () {
                    title = Markup.escape_text (jstr (f, "name", jstr (f, "field"))), activatable = true, subtitle_lines = 3,
                    subtitle = Markup.escape_text ((jstr (f, "op_label", jstr (f, "op")) + " " + jstr (f, "text")).strip ()),
                };
                var rm = new Gtk.Button.from_icon_name ("list-remove-symbolic") { valign = Gtk.Align.CENTER, tooltip_text = _("Remove Condition") };
                rm.add_css_class ("flat");
                rm.clicked.connect (() => { filters.remove_element (idx); render (); });
                row.add_suffix (rm);
                row.activated.connect (() => edit_condition (idx));
                conds.append (row);
            }
            conds.append (add_row);
        }

        public void edit_condition (int? idx) {
            if (catalog == null) return;
            var used = new GenericSet<string> (str_hash, str_equal);
            foreach (var n in filters.get_elements ()) used.add (jstr (n.get_object (), "field"));
            var d = new ConditionDialog (catalog, labels, used, idx != null ? filters.get_object_element (idx) : null);
            d.done.connect ((c) => {
                if (idx != null) {
                    var rebuilt = new Json.Array ();
                    for (int k = 0; k < (int) filters.get_length (); k++) rebuilt.add_object_element (k == idx ? c : filters.get_object_element (k));
                    filters = rebuilt;
                } else filters.add_object_element (c);
                render ();
            });
            d.present (this);
        }

        private void on_apply () {
            var qs = Queries.get_default ();
            var sort = sort_json ();
            qs.remember (pid, filters, sort);
            var iq = new IssueQuery () { params = filter_params (filters, sort), project_id = pid };
            win_of (this)?.push_list (new QueryIssuesPage (Queries.summary (filters), iq, qs.recent[0]));
        }
    }

    /** Условие: поиск по каталогу → оператор и значения. */
    public class ConditionDialog : Adw.Dialog {
        public signal void done (Json.Object cond);
        private Json.Object labels;
        private Adw.NavigationView nav;
        private Adw.ToastOverlay toasts;

        public ConditionDialog (Json.Array catalog, Json.Object labels, GenericSet<string> used, Json.Object? existing) {
            this.labels = labels;
            title = _("Condition");
            content_width = 440;
            content_height = 600;
            nav = new Adw.NavigationView ();
            toasts = new Adw.ToastOverlay () { child = nav };
            child = toasts;
            if (existing != null) {
                foreach (var n in catalog.get_elements ())
                    if (jstr (n.get_object (), "field") == jstr (existing, "field")) nav.add (editor (n.get_object (), existing));
                if (nav.visible_page == null) nav.add (picker (catalog, used));
            } else nav.add (picker (catalog, used));
        }

        private Adw.NavigationPage picker (Json.Array catalog, GenericSet<string> used) {
            var entry = new Gtk.SearchEntry () { placeholder_text = _("Find a field"), margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
            var list = new Gtk.ListBox ();
            list.add_css_class ("navigation-sidebar");
            foreach (var n in catalog.get_elements ()) {
                var f = n.get_object ();
                if (used.contains (jstr (f, "field")) || usable_ops (f).length == 0) continue;
                var row = new Gtk.ListBoxRow ();
                row.child = new Gtk.Label (jstr (f, "name")) { xalign = 0, margin_top = 8, margin_bottom = 8, margin_start = 6, wrap = true };
                row.set_data<string> ("key", fold (jstr (f, "name") + " " + jstr (f, "field")));
                row.set_data<Json.Object> ("filter", f);
                list.append (row);
            }
            list.set_filter_func ((r) => fold (entry.text.strip ()) == "" || r.get_data<string> ("key").contains (fold (entry.text.strip ())));
            entry.search_changed.connect (() => list.invalidate_filter ());
            entry.activate.connect (() => {
                for (var r = list.get_first_child (); r != null; r = r.get_next_sibling ())
                    if (r.get_child_visible ()) { list.row_activated ((Gtk.ListBoxRow) r); return; }
            });
            list.row_activated.connect ((r) => nav.push (editor (r.get_data<Json.Object> ("filter"), null)));
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (entry);
            box.append (new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER });
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (new Adw.HeaderBar ());
            tv.content = box;
            var page = new Adw.NavigationPage (tv, _("Add Condition"));
            page.shown.connect (() => entry.grab_focus ());
            return page;
        }

        /** Значение «id → подпись» выбранных: порядок — как отмечали. */
        private class Picked {
            public GenericArray<string> ids = new GenericArray<string> ();
            public HashTable<string, string> names = new HashTable<string, string> (str_hash, str_equal);
            public void set_on (string id, string name, bool on) {
                names[id] = name;
                for (uint k = 0; k < ids.length; k++) if (ids[k] == id) { if (!on) ids.remove_index (k); return; }
                if (on) ids.add (id);
            }
        }

        private Adw.NavigationPage editor (Json.Object f, Json.Object? existing) {
            var ops = usable_ops (f);
            var field = jstr (f, "field");
            var op_names = new Gtk.StringList (null);
            foreach (var op in ops) op_names.append (op_label (labels, op));
            var op_row = new Adw.ComboRow () { title = _("Operator"), model = op_names };
            var picked = new Picked ();
            var entries = new GenericArray<Adw.EntryRow> ();
            if (existing != null) {
                for (int k = 0; k < ops.length; k++) if (ops[k] == jstr (existing, "op")) op_row.selected = k;
                var texts = jhas (existing, "texts") ? existing.get_array_member ("texts") : new Json.Array ();
                uint k = 0;
                foreach (var n in existing.get_array_member ("values").get_elements ()) {
                    var id = n.get_string ();
                    picked.set_on (id, k < texts.get_length () ? texts.get_string_element (k) : id, true);
                    k++;
                }
            }
            var values = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) { margin_start = 12, margin_end = 12, margin_top = 12, margin_bottom = 24 };
            var ol = boxed_list ();
            ol.append (op_row);
            body.append (ol);
            body.append (values);

            var is_people = people_field (field);
            var list_values = f.get_array_member ("values");
            Callback build_values = () => {
                clear_box (values);
                entries.remove_range (0, entries.length);
                var op = op_row.selected < ops.length ? ops[op_row.selected] : "";
                var arity = op_arity (op);
                if (arity == 0) return;
                if (is_people) {
                    var l = boxed_list ();
                    var me = new Gtk.CheckButton () { active = "me" in picked.ids.data, valign = Gtk.Align.CENTER };
                    me.toggled.connect (() => picked.set_on ("me", _("me"), me.active));
                    var mr = new Adw.ActionRow () { title = _("Me"), activatable_widget = me };
                    mr.add_prefix (me);
                    l.append (mr);
                    foreach (var id in picked.ids.data) if (id != "me") l.append (check_row (picked, id, picked.names[id] ?? id, true));
                    var add = new Adw.ButtonRow () { title = _("Add Person…"), start_icon_name = "list-add-symbolic" };
                    add.activated.connect (() => {
                        var d = new PersonPickerDialog (new MentionSource ()) { title = _("Add Person"), want_login = false };
                        d.chosen.connect ((pid, name) => {
                            if (pid.to_string () in picked.ids.data) return;
                            picked.set_on (pid.to_string (), name, true);
                            int people = 0;
                            foreach (var x in picked.ids) if (x != "me") people++;
                            l.insert (check_row (picked, pid.to_string (), name, true), people);
                        });
                        d.present (this);
                    });
                    l.append (add);
                    values.append (l);
                    return;
                }
                if (list_values.get_length () > 0) {
                    var l = boxed_list ();
                    if (list_values.get_length () > 12) {
                        var se = new Gtk.SearchEntry () { placeholder_text = _("Find a value") };
                        se.search_changed.connect (() => l.invalidate_filter ());
                        l.set_filter_func ((r) => fold (se.text.strip ()) == "" || (r.get_data<string> ("key") ?? "").contains (fold (se.text.strip ())));
                        values.append (se);
                    }
                    foreach (var n in list_values.get_elements ()) {
                        var pair = n.get_array ();
                        var id = pair.get_string_element (1);
                        var name = pair.get_string_element (0);
                        var r = check_row (picked, id, name.strip (), id in picked.ids.data);
                        r.set_data<string> ("key", fold (name));
                        l.append (r);
                    }
                    values.append (l);
                    return;
                }
                // текст, число, дата: одно поле, у «между» — два; t-/t+ — число дней
                var days = op.has_suffix ("t-") || op.has_suffix ("t+");
                var l = boxed_list ();
                for (int k = 0; k < arity; k++) {
                    var e = new Adw.EntryRow () {
                        title = days ? _("Days") : (arity == 2 ? (k == 0 ? _("From") : _("To")) : _("Value")),
                        text = k < picked.ids.length ? picked.ids[k] : "",
                    };
                    if (days) e.input_purpose = Gtk.InputPurpose.DIGITS;
                    entries.add (e);
                    l.append (e);
                }
                values.append (l);
            };
            build_values ();
            op_row.notify["selected"].connect (() => build_values ());

            var ok = new Gtk.Button.with_mnemonic (existing != null ? _("_Done") : _("_Add"));
            ok.add_css_class ("suggested-action");
            ok.clicked.connect (() => {
                var op = op_row.selected < ops.length ? ops[op_row.selected] : "";
                var vals = new Json.Array ();
                var shown = new GenericArray<string> ();
                if (op_arity (op) > 0) {
                    if (entries.length > 0) {
                        foreach (var e in entries) if (e.text.strip () != "") { vals.add_string_element (e.text.strip ()); shown.add (e.text.strip ()); }
                    } else foreach (var id in picked.ids) { vals.add_string_element (id); shown.add (picked.names[id] ?? id); }
                    if (vals.get_length () == 0 || (op == "><" && vals.get_length () < 2)) {
                        toasts.add_toast (new Adw.Toast (_("Choose a value")));
                        return;
                    }
                }
                var c = new Json.Object ();
                c.set_string_member ("field", field);
                c.set_string_member ("op", op);
                c.set_array_member ("values", vals);
                c.set_string_member ("name", jstr (f, "name"));
                c.set_string_member ("op_label", op_label (labels, op));
                c.set_string_member ("text", string.joinv (", ", shown.data));
                var texts = new Json.Array ();
                foreach (var t in shown) texts.add_string_element (t);
                c.set_array_member ("texts", texts);
                done (c);
                close ();
            });
            var hb = new Adw.HeaderBar ();
            hb.pack_end (ok);
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = page_column (body);
            return new Adw.NavigationPage (tv, jstr (f, "name"));
        }

        private Adw.ActionRow check_row (Picked picked, string id, string name, bool on) {
            var c = new Gtk.CheckButton () { active = on, valign = Gtk.Align.CENTER };
            c.toggled.connect (() => picked.set_on (id, name, c.active));
            var r = new Adw.ActionRow () { title = Markup.escape_text (name), activatable_widget = c };
            r.add_prefix (c);
            return r;
        }
    }

    /** «Сохранить» (spec 17.3): имя, описание, видимость (мне / всем / ролям), для всех проектов. У себя — сразу, на сервер — следом. */
    public class SaveQueryDialog : FormDialog {
        public signal void saved (Json.Object q);
        private int pid;
        private Json.Array filters;
        private Json.Array sort;
        private Json.Object? existing;
        private Adw.EntryRow name_row;
        private Adw.EntryRow description;
        private Adw.ComboRow visibility;
        private Adw.SwitchRow for_all;
        private Gtk.ListBox roles;
        private GenericArray<Gtk.CheckButton> role_checks = new GenericArray<Gtk.CheckButton> ();
        private GenericSet<int> want_roles = new GenericSet<int> (direct_hash, direct_equal);
        // видимость формы: 0 — мне, 2 — всем, 1 — ролям
        private const int[] VIS = { 0, 2, 1 };

        public SaveQueryDialog (int pid, Json.Array filters, Json.Array sort, Json.Object? existing) {
            this.pid = pid;
            this.filters = filters;
            this.sort = sort;
            this.existing = existing;
            setup (_("Save Query"), _("_Save"), 480, 600);
            var main = boxed_list ();
            name_row = new Adw.EntryRow () { title = _("Name"), text = existing != null ? jstr (existing, "name") : "" };
            description = new Adw.EntryRow () { title = _("Description"), text = existing != null ? jstr (existing, "description") : "" };
            main.append (name_row);
            main.append (description);
            content_box.append (main);
            var vis = boxed_list ();
            visibility = new Adw.ComboRow () { title = _("Visible to"), model = new Gtk.StringList ({ _("Only me"), _("All users"), _("These roles") }) };
            for_all = new Adw.SwitchRow () { title = _("For all projects"), active = pid == 0 || (existing != null && jint (existing, "project_id") == 0), sensitive = pid > 0 };
            vis.append (visibility);
            vis.append (for_all);
            content_box.append (vis);
            roles = boxed_list ();
            content_box.append (roles);
            if (existing != null) {
                for (int k = 0; k < VIS.length; k++) if (VIS[k] == jint (existing, "visibility")) visibility.selected = k;
                foreach (var n in existing.get_array_member ("role_ids").get_elements ()) want_roles.add ((int) n.get_int ());
            }
            visibility.notify["selected"].connect (sync_roles);
            sync_roles ();
            var hint = new Gtk.Label (_("The query is kept on this device and sent to the server through the website session.")) { xalign = 0, wrap = true };
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            content_box.append (hint);
            focus_widget = name_row;
            load_roles.begin ();
        }

        private void sync_roles () { roles.visible = VIS[visibility.selected] == 1; }

        private async void load_roles () {
            var s = App.get ().session;
            if (s == null) return;
            try {
                foreach (var r in yield s.refs.roles ()) {
                    var c = new Gtk.CheckButton () { active = want_roles.contains (jint (r, "id")), valign = Gtk.Align.CENTER };
                    c.set_data<int> ("id", jint (r, "id"));
                    role_checks.add (c);
                    var row = new Adw.ActionRow () { title = Markup.escape_text (jstr (r, "name")), activatable_widget = c };
                    row.add_prefix (c);
                    roles.append (row);
                }
            } catch (Error e) {
                roles.append (new Adw.ActionRow () { title = Markup.escape_text (_("Could not load roles: %s").printf (e.message)) });
            }
        }

        protected override async void submit () {
            var n = name_row.text.strip ();
            if (n == "") {
                toasts.add_toast (new Adw.Toast (_("Enter a name")));
                return;
            }
            int[] role_ids = {};
            foreach (var c in role_checks) if (c.active) role_ids += c.get_data<int> ("id");
            var vis = VIS[visibility.selected];
            if (vis == 1 && role_ids.length == 0) {
                toasts.add_toast (new Adw.Toast (_("Choose at least one role")));
                return;
            }
            var w = get_root () as Window;
            var q = Queries.get_default ().save (existing, pid, n, description.text.strip (), vis, role_ids, for_all.active, filters, sort);
            saved (q);
            close ();
            w?.toast (_("Saved on this device"));
            yield push_query (w, q);
        }
    }

    /** Задачи своего фильтра, недавнего или запроса: «★», у фильтра — «Сохранить». */
    public class QueryIssuesPage : Adw.NavigationPage, Refreshable {
        public bool refreshing { get; set; }
        private IssueList list;
        private Gtk.Button? star = null;
        private ulong sig = 0;

        public QueryIssuesPage (string title, IssueQuery iq, Json.Object? q) {
            Object (title: title, tag: "query-issues");
            list = new IssueList (ListKind.QUERY, iq.project_id, iq);
            list.bind_property ("refreshing", this, "refreshing");
            var hb = new Adw.HeaderBar ();
            hb.pack_start (refresh_button (this, () => refresh ()));
            if (q != null) {
                star = new Gtk.Button ();
                star.clicked.connect (() => Queries.get_default ().set_fav (q, !Queries.get_default ().is_fav (Queries.key_of (q))));
                hb.pack_end (star);
                Callback sync = () => {
                    var on = Queries.get_default ().is_fav (Queries.key_of (q));
                    star.icon_name = on ? "starred-symbolic" : "non-starred-symbolic";
                    star.tooltip_text = on ? _("Remove from Favorites") : _("Add to Favorites");
                };
                sync ();
                sig = Queries.get_default ().changed.connect (() => sync ());
                if (q.has_member ("filters") && !q.has_member ("local_id")) {
                    var save = new Gtk.Button.from_icon_name ("document-save-symbolic") { tooltip_text = _("Save Query") };
                    save.clicked.connect (() => new SaveQueryDialog (jint (q, "project_id"), q.get_array_member ("filters"), q.get_array_member ("sort"), null).present (this));
                    hb.pack_end (save);
                }
            }
            var tv = new Adw.ToolbarView ();
            tv.add_top_bar (hb);
            tv.content = list;
            child = tv;
            shown.connect (() => list.shown ());
        }

        public override void dispose () {
            if (sig != 0) Queries.get_default ().disconnect (sig);
            sig = 0;
            base.dispose ();
        }

        public void refresh () { list.refresh (); }
    }

    /** Избранный запрос — раздел боковой панели под «Мои задачи» (spec 17.5, GNOME). */
    public class QuerySection : Adw.Bin, Section {
        public Adw.ViewStackPage page { get; set; }
        public bool refreshing { get; set; }
        private IssueList list;

        public QuerySection (IssueQuery iq) {
            list = new IssueList (ListKind.QUERY, iq.project_id, iq);
            list.bind_property ("refreshing", this, "refreshing", BindingFlags.SYNC_CREATE);
            child = list;
        }

        public void shown () { list.shown (); }
        public void refresh () { list.refresh (); }
        public void start_search () { list.start_search (); }
    }
}
