/* Общие куски интерфейса: строка задачи, состояния «загрузка/пусто/ошибка», аватары, миниатюры. */
namespace Redmine {

    /** Загрузка / пусто / ошибка / содержимое — один стек на экран. */
    public class StateView : Adw.Bin {
        private Gtk.Stack stack;
        private Adw.StatusPage status;
        private Gtk.Button retry;
        public signal void retry_clicked ();

        public StateView (Gtk.Widget content) {
            stack = new Gtk.Stack () { transition_type = Gtk.StackTransitionType.CROSSFADE };
            var spinner = new Adw.Spinner () { halign = Gtk.Align.CENTER, valign = Gtk.Align.CENTER, width_request = 32, height_request = 32 };
            stack.add_named (spinner, "loading");
            status = new Adw.StatusPage ();
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) { halign = Gtk.Align.CENTER };
            retry = new Gtk.Button.with_mnemonic (_("_Retry")) { halign = Gtk.Align.CENTER };
            retry.add_css_class ("pill");
            retry.clicked.connect (() => retry_clicked ());
            box.append (retry);
            box.append (captcha_button (() => retry_clicked ()));
            status.child = box;
            stack.add_named (status, "status");
            stack.add_named (content, "content");
            child = stack;
        }

        public void loading () { stack.visible_child_name = "loading"; }
        public void content () { stack.visible_child_name = "content"; }

        public void empty (string title, string icon, string? description = null) {
            status.icon_name = icon;
            status.title = title;
            status.description = description;
            retry.visible = false;
            stack.visible_child_name = "status";
        }

        public void error (Error e) {
            status.icon_name = "dialog-warning-symbolic";
            status.title = error_code (e) == 0 ? _("No Connection") : _("Could Not Load");
            status.description = e.message;
            retry.visible = true;
            stack.visible_child_name = "status";
        }
    }

    /** Строка списка задач: «#номер тема», ниже — статус · проект · исполнитель · когда. */
    public class IssueRow : Gtk.ListBoxRow {
        public Issue issue;

        public IssueRow (Issue i, bool show_project = true) {
            issue = i;
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
            box.add_css_class ("issue-row");
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var num = new Gtk.Label ("#%d".printf (i.id)) { xalign = 0, valign = Gtk.Align.START };
            num.add_css_class ("dim-label");
            num.add_css_class ("numeric");
            top.append (num);
            var subj = new Gtk.Label (i.subject) {
                xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 2,
                ellipsize = Pango.EllipsizeMode.END, hexpand = true,
            };
            if (i.status_closed) subj.add_css_class ("dim-label");
            top.append (subj);
            if (Prefs.get_default ().is_favorite (i.id)) {
                var star = new Gtk.Image.from_icon_name ("starred-symbolic") { valign = Gtk.Align.START, tooltip_text = _("Favorite") };
                star.add_css_class ("dim-label");
                top.append (star);
            }
            box.append (top);
            var parts = new GenericArray<string> ();
            parts.add (i.status.name);
            if (show_project) parts.add (i.project.name);
            var a = i.assigned_to;
            if (a != null) parts.add (a.name);
            parts.add (format_relative (i.updated_on));
            var sub = new Gtk.Label (string.joinv (" · ", parts.data)) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            sub.add_css_class ("dim-label");
            sub.add_css_class ("caption");
            box.append (sub);
            if (is_overdue (i.due_date) && !i.status_closed) {
                var due = new Gtk.Label (_("Overdue: %s").printf (format_date (i.due_date))) { xalign = 0 };
                due.add_css_class ("caption");
                due.add_css_class ("error");
                box.append (due);
            }
            child = box;
            update_property (Gtk.AccessibleProperty.LABEL, "#%d %s, %s".printf (i.id, i.subject, i.status.name), -1);
        }
    }

    /** Аватары: память → диск (24 ч) → сеть; нет фото — инициалы AdwAvatar. */
    public class Avatars : Object {
        private static HashTable<int, Gdk.Texture?>? mem = null;
        private static HashTable<int, bool>? pending = null;

        public static Adw.Avatar make (int user_id, string name, int size = 32) {
            var av = new Adw.Avatar (size, name, true);
            if (user_id > 0) load.begin (user_id, av);
            return av;
        }

        private static async void load (int id, Adw.Avatar av) {
            if (mem == null) { mem = new HashTable<int, Gdk.Texture?> (direct_hash, direct_equal); pending = new HashTable<int, bool> (direct_hash, direct_equal); }
            if (mem.contains (id)) { av.custom_image = mem[id]; return; }
            var s = App.get ().session;
            if (s == null) return;
            var key = "avatar-%d".printf (id);
            var f = File.new_for_path (Path.build_filename (s.cache.dir, key));
            try {
                var info = f.query_info (FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                var age = now_ms () - info.get_modification_date_time ().to_unix () * 1000;
                // пустой файл — «фото нет», помним 10 минут; фото — сутки
                if (age < (info.get_size () == 0 ? 10 * 60 * 1000 : DAY_MS)) {
                    Gdk.Texture? t = info.get_size () == 0 ? null : Gdk.Texture.from_file (f);
                    mem[id] = t;
                    av.custom_image = t;
                    return;
                }
            } catch (Error e) {}
            // ponytail: одновременные запросы одного аватара — второй виджет получит фото со следующей отрисовкой
            if (pending.contains (id)) return;
            pending[id] = true;
            try {
                var b = yield s.api.avatar (id);
                s.cache.save_bytes (key, b ?? new Bytes ({}));
                Gdk.Texture? t = b != null ? Gdk.Texture.from_bytes (b) : null;
                mem[id] = t;
                av.custom_image = t;
            } catch (Error e) {
                debug ("avatar %d: %s", id, e.message);
            }
            pending.remove (id);
        }
    }

    /** Картинка вложения по content_url (с ключом) — для превью в тексте и в списке файлов. */
    public async Gdk.Texture? load_attachment_texture (Json.Object att, bool thumb, Cancellable? c = null) {
        var s = App.get ().session;
        if (s == null) return null;
        var id = jint (att, "id");
        var key = (thumb ? "thumb-%d" : "att-%d").printf (id);
        var cached = s.cache.load_bytes (key);
        try {
            if (cached != null) return Gdk.Texture.from_bytes (cached);
            Bytes? b = thumb ? yield s.api.thumbnail (id, 200, c) : yield s.api.download (jstr (att, "content_url"), c);
            if (b == null) return null;
            s.cache.save_bytes (key, b);
            return Gdk.Texture.from_bytes (b);
        } catch (Error e) {
            debug ("attachment %d: %s", id, e.message);
            return null;
        }
    }

    public bool is_image_name (string name) {
        var n = name.down ();
        foreach (var ext in new string[] { ".png", ".jpg", ".jpeg", ".jpe", ".gif", ".bmp", ".webp" }) if (n.has_suffix (ext)) return true;
        return false;
    }

    /** Как Attachment.latest_attach в Redmine: имя без учёта регистра, из тёзок — самое свежее. */
    public Json.Object? resolve_attachment (string ref_name, GenericArray<Json.Object> atts) {
        var decoded = Uri.unescape_string (ref_name) ?? ref_name;
        Json.Object? best = null;
        foreach (var a in atts) {
            var fn = jstr (a, "filename").down ();
            if (fn != ref_name.down () && fn != decoded.down ()) continue;
            if (best == null || jstr (a, "created_on") > jstr (best, "created_on")
                || (jstr (a, "created_on") == jstr (best, "created_on") && jint (a, "id") > jint (best, "id"))) best = a;
        }
        return best;
    }

    /** Открыть вложение: картинка — в своём просмотре, остальное — скачать во временный каталог и системным приложением. */
    public async void open_attachment (Gtk.Widget from, Json.Object att) {
        var name = jstr (att, "filename");
        var ct = jstr (att, "content_type");
        if (is_image_name (name) || ct.has_prefix ("image/")) {
            var d = new ImageViewer (att);
            d.present (from);
            return;
        }
        var s = App.get ().session;
        if (s == null) return;
        var w = win_of (from);
        try {
            var b = yield s.api.download (jstr (att, "content_url"));
            var dir = Path.build_filename (Environment.get_user_cache_dir (), "redmine-adw", "open", jint (att, "id").to_string ());
            DirUtils.create_with_parents (dir, 0700);
            var safe = Path.get_basename (name).replace ("/", "_");
            var path = Path.build_filename (dir, safe != "" ? safe : "file");
            FileUtils.set_data (path, b.get_data ());
            var launcher = new Gtk.FileLauncher (File.new_for_path (path));
            yield launcher.launch (w, null);
        } catch (Error e) {
            if (w != null && !(e is Gtk.DialogError)) w.toast (_("Could not open the file: %s").printf (e.message));
        }
    }

    /** Просмотр картинки во весь диалог; «Открыть в просмотрщике» — системное приложение. */
    public class ImageViewer : Adw.Dialog {
        public ImageViewer (Json.Object att) {
            title = jstr (att, "filename");
            content_width = 900;
            content_height = 700;
            var pic = new Gtk.Picture () { content_fit = Gtk.ContentFit.CONTAIN, can_shrink = true, hexpand = true, vexpand = true };
            var state = new StateView (pic);
            state.loading ();
            var tv = new Adw.ToolbarView ();
            var hb = new Adw.HeaderBar ();
            var ext = new Gtk.Button.from_icon_name ("document-open-symbolic") { tooltip_text = _("Open in Viewer") };
            ext.clicked.connect (() => open_external.begin (this, att));
            hb.pack_start (ext);
            tv.add_top_bar (hb);
            tv.content = state;
            child = tv;
            load_attachment_texture.begin (att, false, null, (o, r) => {
                var t = load_attachment_texture.end (r);
                if (t != null) { pic.paintable = t; state.content (); }
                else state.empty (_("Could Not Show the File"), "image-missing-symbolic");
            });
        }

        private static async void open_external (Gtk.Widget from, Json.Object att) {
            var s = App.get ().session;
            if (s == null) return;
            try {
                var b = yield s.api.download (jstr (att, "content_url"));
                var dir = Path.build_filename (Environment.get_user_cache_dir (), "redmine-adw", "open", jint (att, "id").to_string ());
                DirUtils.create_with_parents (dir, 0700);
                var path = Path.build_filename (dir, Path.get_basename (jstr (att, "filename")));
                FileUtils.set_data (path, b.get_data ());
                yield new Gtk.FileLauncher (File.new_for_path (path)).launch (from.get_root () as Gtk.Window, null);
            } catch (Error e) {}
        }
    }

    /** Подпись-заголовок раздела внутри страницы. */
    public Gtk.Label heading (string text) {
        var l = new Gtk.Label (text) { xalign = 0, margin_top = 18, margin_bottom = 6 };
        l.add_css_class ("heading");
        return l;
    }

    public void copy_text (Gtk.Widget w, string text) {
        w.get_clipboard ().set_text (text);
    }

    public void clear_box (Gtk.Box box) {
        Gtk.Widget? c;
        while ((c = box.get_first_child ()) != null) box.remove (c);
    }

    public void clear_list (Gtk.ListBox box) {
        box.remove_all ();
    }
}
