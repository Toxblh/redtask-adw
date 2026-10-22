/*
 * Модели Redmine — тонкие обёртки над Json.Object. Сырой JSON хранится как есть:
 * кэш на диске пишется тем же текстом, что пришёл с сервера, а неизвестные поля не теряются.
 */
namespace Redmine {

    // ---- помощники чтения JSON: отсутствующее поле и null — значение по умолчанию, а не падение ----

    public int jint (Json.Object? o, string key, int def = 0) {
        if (o == null || !o.has_member (key)) return def;
        var n = o.get_member (key);
        if (n.get_node_type () != Json.NodeType.VALUE) return def;
        var t = n.get_value_type ();
        if (t == typeof (int64)) return (int) n.get_int ();
        if (t == typeof (double)) return (int) n.get_double ();
        if (t == typeof (string)) return int.parse (n.get_string ());
        if (t == typeof (bool)) return n.get_boolean () ? 1 : 0;
        return def;
    }

    public double jdouble (Json.Object? o, string key, double def = 0) {
        if (o == null || !o.has_member (key)) return def;
        var n = o.get_member (key);
        if (n.get_node_type () != Json.NodeType.VALUE) return def;
        var t = n.get_value_type ();
        if (t == typeof (int64)) return (double) n.get_int ();
        if (t == typeof (double)) return n.get_double ();
        if (t == typeof (string)) return double.parse (n.get_string ());
        return def;
    }

    /** null у поля (или поля нет) — отличается от 0: «оценки нет». */
    public bool jhas (Json.Object? o, string key) {
        return o != null && o.has_member (key) && !o.get_member (key).is_null ();
    }

    public string jstr (Json.Object? o, string key, string def = "") {
        if (o == null || !o.has_member (key)) return def;
        var n = o.get_member (key);
        if (n.get_node_type () != Json.NodeType.VALUE) return def;
        var t = n.get_value_type ();
        if (t == typeof (string)) return n.get_string () ?? def;
        if (t == typeof (int64)) return n.get_int ().to_string ();
        if (t == typeof (double)) return n.get_double ().to_string ();
        if (t == typeof (bool)) return n.get_boolean () ? "1" : "0";
        return def;
    }

    public bool jbool (Json.Object? o, string key, bool def = false) {
        if (o == null || !o.has_member (key)) return def;
        var n = o.get_member (key);
        if (n.get_node_type () != Json.NodeType.VALUE) return def;
        if (n.get_value_type () == typeof (bool)) return n.get_boolean ();
        if (n.get_value_type () == typeof (int64)) return n.get_int () != 0;
        if (n.get_value_type () == typeof (string)) return n.get_string () == "1" || n.get_string () == "true";
        return def;
    }

    public Json.Object? jobj (Json.Object? o, string key) {
        if (o == null || !o.has_member (key)) return null;
        var n = o.get_member (key);
        return n.get_node_type () == Json.NodeType.OBJECT ? n.get_object () : null;
    }

    /** Элементы-объекты массива; не массив — пусто. */
    public GenericArray<Json.Object> jarr (Json.Object? o, string key) {
        var res = new GenericArray<Json.Object> ();
        if (o == null || !o.has_member (key)) return res;
        var n = o.get_member (key);
        if (n.get_node_type () != Json.NodeType.ARRAY) return res;
        n.get_array ().foreach_element ((a, i, e) => {
            if (e.get_node_type () == Json.NodeType.OBJECT) res.add (e.get_object ());
        });
        return res;
    }

    public string json_to_string (Json.Node node, bool pretty = false) {
        var g = new Json.Generator ();
        g.pretty = pretty;
        g.set_root (node);
        return g.to_data (null);
    }

    public Json.Node? json_parse (string text) {
        var p = new Json.Parser ();
        try {
            p.load_from_data (text, -1);
            return p.get_root () != null ? p.get_root ().copy () : null;
        } catch (Error e) {
            return null;
        }
    }

    public Json.Node obj_node (Json.Object o) {
        var n = new Json.Node (Json.NodeType.OBJECT);
        n.set_object (o);
        return n;
    }

    /** Значение настраиваемого поля для показа: строка или массив строк через запятую. */
    public string json_value_display (Json.Node? n) {
        if (n == null || n.is_null ()) return "";
        if (n.get_node_type () == Json.NodeType.ARRAY) {
            var parts = new GenericArray<string> ();
            n.get_array ().foreach_element ((a, i, e) => {
                var s = json_value_display (e);
                if (s != "") parts.add (s);
            });
            return string.joinv (", ", parts.data);
        }
        if (n.get_node_type () == Json.NodeType.VALUE) {
            var t = n.get_value_type ();
            if (t == typeof (string)) return n.get_string () ?? "";
            if (t == typeof (int64)) return n.get_int ().to_string ();
            if (t == typeof (double)) return n.get_double ().to_string ();
            if (t == typeof (bool)) return n.get_boolean () ? "1" : "0";
        }
        return "";
    }

    // ---- сущности ----

    public class Named : Object {
        public int id;
        public string name;
        public Named (int id, string name) { this.id = id; this.name = name; }
        public static Named? from (Json.Object? o) {
            if (o == null) return null;
            return new Named (jint (o, "id"), jstr (o, "name"));
        }
    }

    /** Вид статуса для цвета — порт statusKind из Android (Common.kt), слои те же. */
    public enum StatusKind { TODO, IN_PROGRESS, DONE, REJECTED }

    public StatusKind status_kind (string name, bool closed) {
        var n = name.strip ();
        // слой 1: точные исключения — эвристика их путает
        switch (n) {
            case "Заявка обработана": case "Заявка согласована": return StatusKind.IN_PROGRESS;
            case "Отчислен с курса": case "Заблокирован": case "Прекращено": return StatusKind.REJECTED;
        }
        var ci = RegexCompileFlags.CASELESS;
        // слой 2: ключевые слова отказа
        if (Regex.match_simple ("отклон|отказ|reject|cancel|аннул|закрыт без|не принят|недейств|упущено|неуспешно", n, ci)) return StatusKind.REJECTED;
        if (closed) return StatusKind.DONE; // слой 3: машиночитаемый признак конечности
        if (Regex.match_simple ("^(нов|созд|черновик|драфт|бэклог|backlog|to.?do|open|new|лид|1% лид|заявка|ожидание приёма)", n, ci)) return StatusKind.TODO;
        return StatusKind.IN_PROGRESS;
    }

    public class Issue : Object {
        public Json.Object o;
        public Issue (Json.Object o) { this.o = o; }

        public int id { get { return jint (o, "id"); } }
        public string subject { owned get { return jstr (o, "subject"); } }
        public string description { owned get { return jstr (o, "description"); } }
        public Named project { owned get { return Named.from (jobj (o, "project")) ?? new Named (0, ""); } }
        public Named tracker { owned get { return Named.from (jobj (o, "tracker")) ?? new Named (0, ""); } }
        public Named status { owned get { return Named.from (jobj (o, "status")) ?? new Named (0, ""); } }
        public bool status_closed { get { return jbool (jobj (o, "status"), "is_closed"); } }
        public Named priority { owned get { return Named.from (jobj (o, "priority")) ?? new Named (0, ""); } }
        public Named author { owned get { return Named.from (jobj (o, "author")) ?? new Named (0, ""); } }
        public Named? assigned_to { owned get { return Named.from (jobj (o, "assigned_to")); } }
        public Named? category { owned get { return Named.from (jobj (o, "category")); } }
        public Named? fixed_version { owned get { return Named.from (jobj (o, "fixed_version")); } }
        public int parent_id { get { return jint (jobj (o, "parent"), "id"); } }
        public string start_date { owned get { return jstr (o, "start_date"); } }
        public string due_date { owned get { return jstr (o, "due_date"); } }
        public int done_ratio { get { return jint (o, "done_ratio"); } }
        public bool is_private { get { return jbool (o, "is_private"); } }
        public string created_on { owned get { return jstr (o, "created_on"); } }
        public string updated_on { owned get { return jstr (o, "updated_on"); } }
        public string closed_on { owned get { return jstr (o, "closed_on"); } }
        public bool has_estimate { get { return jhas (o, "estimated_hours"); } }
        public double estimated_hours { get { return jdouble (o, "estimated_hours"); } }
        public double total_estimated_hours { get { return jdouble (o, "total_estimated_hours"); } }
        public double spent_hours { get { return jdouble (o, "spent_hours"); } }
        public double total_spent_hours { get { return jdouble (o, "total_spent_hours"); } }

        public GenericArray<Json.Object> journals { owned get { return jarr (o, "journals"); } }
        public GenericArray<Json.Object> attachments { owned get { return jarr (o, "attachments"); } }
        public GenericArray<Json.Object> children { owned get { return jarr (o, "children"); } }
        public GenericArray<Json.Object> relations { owned get { return jarr (o, "relations"); } }
        public GenericArray<Json.Object> watchers { owned get { return jarr (o, "watchers"); } }
        public GenericArray<Json.Object> custom_fields { owned get { return jarr (o, "custom_fields"); } }
        /** null — сервер не прислал (задача из списка, а не полная). */
        public GenericArray<Json.Object>? allowed_statuses {
            owned get { return o.has_member ("allowed_statuses") ? jarr (o, "allowed_statuses") : null; }
        }
        /** Полная задача (с журналами) — не из списка. */
        public bool full { get { return o.has_member ("journals"); } }
    }

    public class User : Object {
        public int id;
        public string login;
        public string firstname;
        public string lastname;
        public string api_key;
        public bool admin;
        public User.from (Json.Object o) {
            id = jint (o, "id");
            login = jstr (o, "login");
            firstname = jstr (o, "firstname");
            lastname = jstr (o, "lastname");
            api_key = jstr (o, "api_key");
            admin = jbool (o, "admin");
        }
        public string display_name {
            owned get {
                var s = (firstname + " " + lastname).strip ();
                return s != "" ? s : login;
            }
        }
    }

    /** Загруженный на сервер файл — токен для вложения к комментарию/задаче. */
    public class UploadRef : Object {
        public string token;
        public string filename;
        public string? content_type;
        public string? description;
        public UploadRef (string token, string filename, string? content_type, string? description = null) {
            this.token = token; this.filename = filename; this.content_type = content_type; this.description = description;
        }
    }

    /** Человек из плагина People (или /users): имена у разных серверов называются по-разному. */
    public string person_short_name (Json.Object p) {
        var first = jstr (p, "firstname");
        if (first == "") first = jstr (p, "first_name");
        var last = jstr (p, "lastname");
        if (last == "") last = jstr (p, "last_name");
        return (first + " " + last).strip ();
    }

    /**
     * Тип связи глазами задачи viewer_id. Сервер отдаёт сохранённый тип «от issue_id к issue_to_id»
     * и для второй стороны его не переворачивает: A blocks B, открытая из B, — это «blocked».
     */
    public string relation_type_for (Json.Object r, int viewer_id) {
        var t = jstr (r, "relation_type");
        if (jint (r, "issue_to_id") != viewer_id) return t;
        switch (t) {
            case "blocks": return "blocked";
            case "blocked": return "blocks";
            case "precedes": return "follows";
            case "follows": return "precedes";
            case "duplicates": return "duplicated";
            case "duplicated": return "duplicates";
            case "copied_to": return "copied_from";
            case "copied_from": return "copied_to";
            default: return t;
        }
    }

    public int relation_other (Json.Object r, int viewer_id) {
        var a = jint (r, "issue_id");
        return a == viewer_id ? jint (r, "issue_to_id") : a;
    }
}
