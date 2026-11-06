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

    /** «Обновить» — в начале шапки своей панели (HIG: основные действия в начале header bar), вместо «потянуть вниз» с Android/iOS. */
    public Gtk.Button refresh_button (owned Callback on_click) {
        var b = new Gtk.Button.from_icon_name ("view-refresh-symbolic") { tooltip_text = _("Refresh") };
        b.clicked.connect (() => on_click ());
        return b;
    }

    /** Строка списка задач: «#номер тема», ниже — статус · проект · исполнитель · когда. */
    /** Статус пилюлей: полупрозрачный фон и цветной текст по виду (style.css, .status-pill). */
    public Gtk.Label status_pill (string name, bool closed) {
        var l = new Gtk.Label (name) { ellipsize = Pango.EllipsizeMode.END, max_width_chars = 20, valign = Gtk.Align.CENTER };
        l.css_classes = { "status-pill", "caption", status_class (name, closed) };
        return l;
    }

    public string status_class (string name, bool closed) {
        string[] cls = { "todo", "in-progress", "done", "rejected" };
        return cls[status_kind (name, closed)];
    }

    /** Подпись строки: пилюля статуса и текст после неё («Статус · проект»). */
    public Gtk.Widget status_line (string status, bool closed, string rest) {
        var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        b.append (status_pill (status, closed));
        if (rest != "") {
            var l = new Gtk.Label (rest) { xalign = 0, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
            l.add_css_class ("dim-label");
            l.add_css_class ("caption");
            b.append (l);
        }
        return b;
    }

    /** Строка списка — раскладка карточки IssueCard с Android. */
    public class IssueRow : Gtk.ListBoxRow {
        public Issue issue;
        private Gtk.Image star;

        public void sync_star () { star.visible = Favorites.get_default ().has (issue.id); }

        private static Gtk.Label caption (string text, bool dim = true) {
            var l = new Gtk.Label (text) { xalign = 0, ellipsize = Pango.EllipsizeMode.END };
            l.add_css_class ("caption");
            if (dim) l.add_css_class ("dim-label");
            return l;
        }

        public IssueRow (Issue i, bool show_project = true) {
            issue = i;
            var closed = i.status_closed;
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            box.add_css_class ("issue-row");
            // выполненные приглушены, тема зачёркнута — как в веб-Redmine
            if (closed) box.opacity = 0.55;

            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            top.append (status_pill (i.status.name, closed));
            var tr = caption ("%s #%d".printf (i.tracker.name, i.id));
            tr.hexpand = true;
            tr.add_css_class ("numeric");
            top.append (tr);
            top.append (caption (format_relative (i.updated_on)));
            star = new Gtk.Image.from_icon_name ("starred-symbolic") { tooltip_text = _("Favorite") };
            star.add_css_class ("dim-label");
            top.append (star);
            sync_star ();
            box.append (top);

            var subj = new Gtk.Label (i.subject) {
                xalign = 0, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 2,
                ellipsize = Pango.EllipsizeMode.END,
            };
            subj.add_css_class ("heading");
            if (closed) subj.add_css_class ("closed-issue");
            box.append (subj);
            if (show_project) box.append (caption (i.project.name));

            var meta = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_top = 4 };
            var pc = priority_class (i.priority.name);
            meta.append (icon_text ("emoji-flags-symbolic", i.priority.name, pc));
            if (i.due_date != "") {
                var overdue = is_overdue (i.due_date) && !closed;
                var delta = closed ? null : due_delta (i.due_date);
                meta.append (icon_text ("x-office-calendar-symbolic", format_date_short (i.due_date) + (delta != null ? " · " + delta : ""), overdue ? "error" : "dim-label"));
            }
            var a = i.assigned_to;
            if (a != null) {
                var who = caption (a.name);
                who.hexpand = true;
                who.xalign = 1;
                who.max_width_chars = 18;
                meta.append (who);
                meta.append (Avatars.make (a.id, a.name, 28));
            }
            box.append (meta);

            if (i.done_ratio > 0) {
                var prog = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_top = 2 };
                prog.append (new Gtk.LevelBar.for_interval (0, 100) { value = i.done_ratio, hexpand = true, valign = Gtk.Align.CENTER });
                prog.append (caption ("%d %%".printf (i.done_ratio)));
                box.append (prog);
            }
            child = box;
            update_property (Gtk.AccessibleProperty.LABEL, "#%d %s, %s".printf (i.id, i.subject, i.status.name), -1);
        }

        private static Gtk.Box icon_text (string icon, string text, string css) {
            var b = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 3);
            b.add_css_class (css);
            b.append (new Gtk.Image.from_icon_name (icon) { pixel_size = 14 });
            var l = new Gtk.Label (text);
            l.add_css_class ("caption");
            b.append (l);
            return b;
        }

        /** priorityColor с Android: срочные — красным, высокий — акцентом, прочие приглушены. */
        private static string priority_class (string name) {
            var n = name.casefold ();
            if ("immediate" in n || "немедл" in n || "urgent" in n || "срочн" in n) return "error";
            if ("high" in n || "высок" in n) return "accent";
            return "dim-label";
        }
    }

    /**
     * Аватары: «кэшировать максимально, дальше только обновлять». Файл на диске показываем сразу, любого возраста;
     * старше суток — фоном перезапрашиваем и подменяем, ошибка сети оставляет старое. Пустой файл — «фото нет», 10 минут.
     * Декодируем асинхронно с уменьшением до 128 px — в памяти маленькая текстура, а не мегабайтное фото.
     */
    public class Avatars : Object {
        private static HashTable<int, Gdk.Texture?>? mem = null;
        /** Идёт загрузка: все виджеты этого человека, им раздаётся и снимок с диска, и свежее фото. */
        private static HashTable<int, GenericArray<Adw.Avatar>>? waiting = null;
        private const int PX = 128;

        public static Adw.Avatar make (int user_id, string name, int size = 32) {
            var av = new Adw.Avatar (size, name, true);
            if (user_id > 0) load (user_id, av);
            return av;
        }

        private static void load (int id, Adw.Avatar av) {
            if (mem == null) {
                mem = new HashTable<int, Gdk.Texture?> (direct_hash, direct_equal);
                waiting = new HashTable<int, GenericArray<Adw.Avatar>> (direct_hash, direct_equal);
            }
            if (mem.contains (id)) av.custom_image = mem[id];
            var list = waiting[id];
            if (list != null) { list.add (av); return; }
            if (mem.contains (id)) return;
            list = new GenericArray<Adw.Avatar> ();
            list.add (av);
            waiting[id] = list;
            fetch.begin (id);
        }

        private static void publish (int id, Gdk.Texture? t) {
            mem[id] = t;
            var list = waiting[id];
            if (list != null) foreach (var av in list) av.custom_image = t;
        }

        /** Разбор и уменьшение в отдельном потоке: главный поток не ждёт мегабайтных фото. */
        private static async Gdk.Texture? decode (Bytes b) {
            Gdk.Texture? result = null;
            new Thread<void> ("avatar", () => {
                result = scale (b);
                Idle.add (decode.callback);
            });
            yield;
            return result;
        }

        // встроенные загрузчики GTK (png/jpeg) и масштаб Pixbuf из памяти — без внешних загрузчиков gdk-pixbuf/glycin
        private static Gdk.Texture? scale (Bytes b) {
            try {
                var t = Gdk.Texture.from_bytes (b);
                if (t.width <= PX && t.height <= PX) return t;
                var d = new Gdk.TextureDownloader (t);
                d.set_format (Gdk.MemoryFormat.R8G8B8A8);
                size_t stride;
                var px = d.download_bytes (out stride);
                var pb = new Gdk.Pixbuf.from_bytes (px, Gdk.Colorspace.RGB, true, 8, t.width, t.height, (int) stride);
                var k = (double) PX / int.max (t.width, t.height);
                var sm = pb.scale_simple (int.max (1, (int) (t.width * k)), int.max (1, (int) (t.height * k)), Gdk.InterpType.HYPER);
                return new Gdk.MemoryTexture (sm.width, sm.height, Gdk.MemoryFormat.R8G8B8A8, sm.read_pixel_bytes (), sm.rowstride);
            } catch (Error e) {
                debug ("avatar decode: %s", e.message);
                return null;
            }
        }

        private static async void fetch (int id) {
            var s = App.get ().session;
            if (s == null) { waiting.remove (id); return; }
            var key = "avatar-%d".printf (id);
            var f = File.new_for_path (Path.build_filename (s.cache.dir, key));
            var have = false;
            var fresh = false;
            try {
                var info = yield f.query_info_async (FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                var age = now_ms () - info.get_modification_date_time ().to_unix () * 1000;
                if (info.get_size () == 0) {
                    fresh = age < 10 * 60 * 1000;
                    if (fresh) publish (id, null);
                } else {
                    var t = yield decode (yield f.load_bytes_async (null, null));
                    if (t != null) { publish (id, t); have = true; }
                    fresh = have && age < DAY_MS;
                }
            } catch (Error e) {}
            if (!fresh) {
                try {
                    var html = yield s.api.people_page (id);
                    if (html != null) s.refs.learn_phones (id, html); // телефоны — из того же ответа (spec 11)
                    var b = html != null ? yield s.api.avatar_from_page (html) : null;
                    s.cache.save_bytes (key, b ?? new Bytes ({}));
                    publish (id, b != null ? yield decode (b) : null);
                } catch (Error e) {
                    debug ("avatar %d: %s", id, e.message); // старое фото (если было) остаётся
                }
            }
            waiting.remove (id);
        }
    }

    /** Сервер ответил «миниатюры нет» (404 и т. п.) — не спрашиваем снова до перезапуска. */
    GenericSet<int>? no_thumb = null;

    /** Картинка вложения по content_url (с ключом) — для превью в тексте и в списке файлов. */
    public async Gdk.Texture? load_attachment_texture (Json.Object att, bool thumb, Cancellable? c = null) {
        var s = App.get ().session;
        if (s == null) return null;
        var id = jint (att, "id");
        var key = (thumb ? "thumb-%d" : "att-%d").printf (id);
        var cached = s.cache.load_bytes (key);
        if (no_thumb == null) no_thumb = new GenericSet<int> (direct_hash, direct_equal);
        try {
            if (cached != null) return Gdk.Texture.from_bytes (cached);
            if (thumb && id in no_thumb) return null;
            Bytes? b = thumb ? yield s.api.thumbnail (id, 200, c) : yield s.api.download (jstr (att, "content_url"), c);
            if (b == null) {
                if (thumb) no_thumb.add (id);
                return null;
            }
            s.cache.save_bytes (key, b);
            return Gdk.Texture.from_bytes (b);
        } catch (Error e) {
            debug ("attachment %d: %s", id, e.message);
            return null;
        }
    }

    /** Куда open_attachment кладёт скачанный файл. */
    string open_path (Json.Object att) {
        var safe = Path.get_basename (jstr (att, "filename")).replace ("/", "_");
        return Path.build_filename (Environment.get_user_cache_dir (), "redtask", "open", jint (att, "id").to_string (), safe != "" ? safe : "file");
    }

    /** Миниатюра, встроенная в уже скачанный документ (spec 4.1); файла нет — null. Разбор zip — в отдельном потоке. */
    async Gdk.Texture? load_embedded_thumbnail (Json.Object att) {
        var s = App.get ().session;
        if (s == null) return null;
        var key = "thumb-%d".printf (jint (att, "id"));
        Bytes? b = s.cache.load_bytes (key);
        try {
            if (b == null) {
                var data = yield File.new_for_path (open_path (att)).load_bytes_async (null, null);
                SourceFunc cb = load_embedded_thumbnail.callback;
                new Thread<void> ("thumb", () => { b = embedded_thumbnail (data); Idle.add ((owned) cb); });
                yield;
                if (b == null) return null;
                s.cache.save_bytes (key, b);
            }
            return Gdk.Texture.from_bytes (b);
        } catch (Error e) {
            return null; // не скачан или миниатюра не читается — значок
        }
    }

    /**
     * Миниатюра документа без открытия (spec 4.1): Range на хвост, 206 — запись миниатюры по zip_tail и второй Range;
     * 200 — сервер Range не умеет: до 1 МБ файл дочитывается в кэш открытия, больше — обрыв. Результат — навсегда:
     * thumb-ID или отметка nothumb-ID. null — миниатюры нет (или сбой сети: тогда спросим при следующем показе).
     */
    async Bytes? remote_embedded_thumbnail (Json.Object att) {
        var s = App.get ().session;
        if (s == null) return null;
        var id = jint (att, "id");
        var size = (int64) jdouble (att, "filesize");
        var u = jstr (att, "content_url");
        Bytes? thumb = null;
        try {
            uint code;
            // размер известен заранее: больше 1 МБ — целиком не качаем, ответ 200 рвём, не читая (у my.basealt.space нет Content-Length)
            var got = yield s.api.get_range (u, "bytes=-65536", size <= (1 << 20) ? (1 << 20) : 0, out code);
            if (got != null && code == 200) {
                var path = open_path (att);
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_data (path, got.get_data ());
                thumb = yield in_thread (() => embedded_thumbnail (got));
            } else if (got != null && code == 206) {
                var e = zip_tail_entry (size, got);
                if (e != null) {
                    // ponytail: «extra» локального заголовка — с запасом 1 КБ; длиннее — миниатюры не будет
                    var end = e.local_offset + 30 + e.name.length + e.compressed_size + 1024;
                    var local = yield s.api.get_range (u, "bytes=%lld-%lld".printf (e.local_offset, int64.min (end, size) - 1), 0, out code);
                    if (local != null && code == 206) thumb = yield in_thread (() => zip_entry_data (e, local));
                }
            }
        } catch (Error err) {
            debug ("thumbnail %d: %s", id, err.message);
            return null;
        }
        if (thumb != null) s.cache.save_bytes ("thumb-%d".printf (id), thumb);
        else s.cache.save_bytes ("nothumb-%d".printf (id), new Bytes ({}));
        return thumb;
    }

    delegate Bytes? BytesJob ();

    async Bytes? in_thread (owned BytesJob job) {
        Bytes? res = null;
        SourceFunc cb = in_thread.callback;
        new Thread<void> ("thumb", () => { res = job (); Idle.add ((owned) cb); });
        yield;
        return res;
    }

    /** Очередь миниатюр без открытия: не больше 2 запросов сразу и только для строк, что видны в прокрутке. */
    namespace RemoteThumbs {
        public delegate void Done (Gdk.Texture t);

        class Job {
            public weak Gtk.Widget row;
            public Json.Object att;
            public Done done;
        }

        GenericArray<Job>? pending = null;
        int running = 0;
        /** Вложение в работе: тот же файл в списке задачи и в комментарии — один запрос. */
        GenericSet<int>? busy = null;

        public void add (Gtk.Widget row, Json.Object att, owned Done done) {
            if (pending == null) {
                pending = new GenericArray<Job> ();
                busy = new GenericSet<int> (direct_hash, direct_equal);
            }
            var j = new Job () { row = row, att = att, done = (owned) done };
            pending.add (j);
            row.map.connect (pump);
            row.unmap.connect (() => pending.remove (j));
            pump ();
        }

        /** Строка на экране: целиком или частью внутри своей прокрутки. */
        bool in_view (Gtk.Widget row) {
            if (!row.get_mapped ()) return false;
            var sw = row.get_ancestor (typeof (Gtk.ScrolledWindow)) as Gtk.ScrolledWindow;
            if (sw == null) return true;
            if (sw.get_data<bool> ("thumbs") == false) {
                sw.set_data<bool> ("thumbs", true);
                sw.vadjustment.value_changed.connect (pump_later);
            }
            Graphene.Rect r;
            if (!row.compute_bounds (sw, out r)) return false;
            return r.origin.y + r.size.height > 0 && r.origin.y < sw.get_height ();
        }

        uint later = 0;

        /** После прокрутки: строки встают на места только к следующей раскладке. */
        void pump_later () {
            if (later != 0) return;
            later = Timeout.add (150, () => { later = 0; pump (); return Source.REMOVE; });
        }

        void pump () {
            if (pending == null) return;
            for (int k = 0; k < pending.length && running < 2; k++) {
                var j = pending[k];
                if (j.row == null) { pending.remove_index (k--); continue; }
                var id = jint (j.att, "id");
                if (busy.contains (id) || !in_view (j.row)) continue;
                pending.remove_index (k--);
                var s = App.get ().session;
                if (s == null) continue;
                var ready = s.cache.load_bytes ("thumb-%d".printf (id));
                if (ready != null || s.cache.load_bytes ("nothumb-%d".printf (id)) != null) {
                    try { if (ready != null) j.done (Gdk.Texture.from_bytes (ready)); } catch (Error e) {}
                    continue;
                }
                running++;
                busy.add (id);
                remote_embedded_thumbnail.begin (j.att, (o, r) => {
                    var b = remote_embedded_thumbnail.end (r);
                    running--;
                    busy.remove (id);
                    if (b != null) {
                        try { j.done (Gdk.Texture.from_bytes (b)); } catch (Error e) {}
                    }
                    pump ();
                });
            }
        }
    }

    /** Строка файла: значок или миниатюра, размер · автор · когда; нажатие — просмотр или скачивание. */
    public Adw.ActionRow attachment_row (Json.Object att) {
        var name = jstr (att, "filename");
        var row = new Adw.ActionRow () {
            title = Markup.escape_text (name),
            subtitle = Markup.escape_text (human_size (jint (att, "filesize")) + " · " + jstr (jobj (att, "author"), "name") + " · " + format_relative (jstr (att, "created_on"))),
            activatable = true, title_lines = 2,
        };
        var icon = new Gtk.Image.from_icon_name (file_icon (name, jstr (att, "content_type"))) { pixel_size = 32 };
        row.add_prefix (icon);
        var src = thumbnail_source (name, jstr (att, "content_type"));
        var has_thumb = false;
        AsyncReadyCallback show = (o, r) => {
            var t = src == "server" ? load_attachment_texture.end (r) : load_embedded_thumbnail.end (r);
            if (t != null) { icon.paintable = t; icon.pixel_size = 40; has_thumb = true; }
        };
        if (src == "server") load_attachment_texture.begin (att, true, null, show);
        if (src == "embedded") load_embedded_thumbnail.begin (att, (o, r) => {
            var t = load_embedded_thumbnail.end (r);
            if (t != null) { icon.paintable = t; icon.pixel_size = 40; has_thumb = true; return; }
            var s = App.get ().session;
            if (s == null || s.cache.load_bytes ("nothumb-%d".printf (jint (att, "id"))) != null) return;
            RemoteThumbs.add (row, att, (tex) => {
                if (has_thumb) return;
                icon.paintable = tex;
                icon.pixel_size = 40;
                has_thumb = true;
            });
        });
        row.activated.connect ((r) => open_attachment.begin (r, att, (o, res) => {
            open_attachment.end (res);
            // только что скачали документ — его миниатюра уже есть
            if (src == "embedded" && !has_thumb) load_embedded_thumbnail.begin (att, show);
        }));
        return row;
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

    /** Открыть вложение: картинка — в своём просмотре, остальное — скачать во временный каталог и показать в Sushi, без него — системным приложением. */
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
            var path = open_path (att);
            // уже скачан (открывали или качали ради миниатюры): вложения в Redmine не меняются
            var f = File.new_for_path (path);
            if (!f.query_exists () || f.query_info (FileAttribute.STANDARD_SIZE, 0).get_size () != (int64) jdouble (att, "filesize")) {
                var b = yield s.api.download (jstr (att, "content_url"));
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_data (path, b.get_data ());
            }
            if (yield show_in_sushi (path)) return;
            var launcher = new Gtk.FileLauncher (File.new_for_path (path));
            yield launcher.launch (w, null);
        } catch (Error e) {
            if (w != null && !(e is Gtk.DialogError)) w.toast (_("Could not open the file: %s").printf (e.message));
        }
    }

    /** Предпросмотр в GNOME Sushi (как пробел в «Файлах»); false — Sushi нет или отказал, открываем системным приложением. */
    async bool show_in_sushi (string path) {
        try {
            var bus = yield Bus.get (BusType.SESSION);
            var uri = File.new_for_path (path).get_uri ();
            // Sushi 47+: (uri, окно, закрыть-если-открыт, токен активации); раньше — без токена
            try {
                yield bus.call ("org.gnome.NautilusPreviewer", "/org/gnome/NautilusPreviewer", "org.gnome.NautilusPreviewer2", "ShowFile",
                    new Variant ("(ssbs)", uri, "", false, ""), null, DBusCallFlags.NONE, 10000, null);
            } catch (DBusError.INVALID_ARGS e) {
                yield bus.call ("org.gnome.NautilusPreviewer", "/org/gnome/NautilusPreviewer", "org.gnome.NautilusPreviewer2", "ShowFile",
                    new Variant ("(ssb)", uri, "", false), null, DBusCallFlags.NONE, 10000, null);
            }
            return true;
        } catch (Error e) {
            return false;
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
                var dir = Path.build_filename (Environment.get_user_cache_dir (), "redtask", "open", jint (att, "id").to_string ());
                DirUtils.create_with_parents (dir, 0700);
                var path = Path.build_filename (dir, Path.get_basename (jstr (att, "filename")));
                FileUtils.set_data (path, b.get_data ());
                yield new Gtk.FileLauncher (File.new_for_path (path)).launch (from.get_root () as Gtk.Window, null);
            } catch (Error e) {}
        }
    }

    /** Контекстное меню у точки нажатия; после закрытия снимается с виджета. */
    public void popup_menu (Gtk.Widget row, MenuModel m, double x, double y) {
        var pop = new Gtk.PopoverMenu.from_model (m) { has_arrow = true, pointing_to = { (int) x, (int) y, 1, 1 } };
        pop.set_parent (row);
        pop.closed.connect (() => Idle.add (() => { pop.unparent (); return Source.REMOVE; }));
        pop.popup ();
    }

    /** Виджет в карточке (.card): текст описания, вики, обзора проекта. */
    public Gtk.Widget card (Gtk.Widget w) {
        var c = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        c.add_css_class ("card");
        c.append (w);
        return c;
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

    public delegate Gtk.Widget RowBuild ();
    public delegate void RowAction ();

    /**
     * Строка виртуального списка (lazy_list): виджет строится, только когда строка рядом с видимой областью, —
     * тысячи проектов и сотни событий не создают тысячи виджетов. act == null — заголовок раздела (не выбирается и не нажимается).
     */
    public class LazyRow : Object {
        public string key = "";
        public RowBuild build;
        public RowAction? act;
        public LazyRow (owned RowBuild build, owned RowAction? act = null) { this.build = (owned) build; this.act = (owned) act; }
    }

    /** Gtk.ListView над моделью LazyRow: внешний вид .navigation-sidebar, нажатие и Enter — act строки. */
    public Gtk.ListView lazy_list (ListModel model) {
        var f = new Gtk.SignalListItemFactory ();
        f.bind.connect ((o) => {
            var li = (Gtk.ListItem) o;
            var r = (LazyRow) li.item;
            li.activatable = li.focusable = r.act != null;
            li.selectable = false;
            li.child = r.build ();
        });
        f.unbind.connect ((o) => ((Gtk.ListItem) o).child = null);
        var lv = new Gtk.ListView (new Gtk.NoSelection (model), f) { single_click_activate = true };
        lv.add_css_class ("navigation-sidebar");
        lv.activate.connect ((pos) => {
            var r = (LazyRow) lv.model.get_item (pos);
            if (r != null && r.act != null) r.act ();
        });
        return lv;
    }

    /**
     * Замена строк виртуального списка. GtkListView сразу строит виджеты ~200 строкам (замер: 500 событий — 200 строк,
     * 250 мс до первого кадра) — первые 30 сейчас, остальные — после отрисовки кадра.
     */
    public void lazy_fill (GLib.ListStore store, Object[] rows) {
        var gen = store.get_data<uint> ("gen") + 1;
        store.set_data<uint> ("gen", gen);
        var first = int.min (rows.length, 30);
        store.splice (0, store.get_n_items (), rows[0:first]);
        if (rows.length == first) return;
        var rest = new Object[0];
        for (var i = first; i < rows.length; i++) rest += rows[i];
        Idle.add (() => {
            if (store.get_data<uint> ("gen") == gen) store.splice (first, store.get_n_items () - first, rest);
            return Source.REMOVE;
        });
    }

    /** Заголовок раздела в списке. */
    public Gtk.Widget list_heading (string text, bool dim = false) {
        var l = new Gtk.Label (text) { xalign = 0, margin_start = 6, margin_top = 12, margin_bottom = dim ? 4 : 6 };
        l.add_css_class ("heading");
        if (dim) l.add_css_class ("dim-label");
        return l;
    }
}
