/* Фильтры и сохранённые запросы (spec 17): каталог со страницы задач, параметры issues.json, веб-форма запроса. */
namespace Redmine {

    /** JSON-объект сразу после marker в тексте (скрипт страницы): скобки считаются, строки JSON пропускаются; нет — null. */
    private Json.Object? json_after (string text, string marker) {
        var at = text.index_of (marker);
        if (at < 0) return null;
        var start = text.index_of_char ('{', at + marker.length);
        if (start < 0) return null;
        int depth = 0;
        bool in_str = false;
        for (int i = start; i < text.length; i++) {
            var c = text[i];
            if (in_str) {
                if (c == '\\') i++;
                else if (c == '"') in_str = false;
                continue;
            }
            if (c == '"') in_str = true;
            else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) {
                var n = json_parse (text.substring (start, i - start + 1));
                return n != null && n.get_node_type () == Json.NodeType.OBJECT ? n.get_object () : null;
            }
        }
        return null;
    }

    private string node_text (Json.Node n) {
        if (n.get_node_type () != Json.NodeType.VALUE) return "";
        if (n.get_value_type () == typeof (string)) return n.get_string ();
        if (n.get_value_type () == typeof (int64)) return n.get_int ().to_string ();
        return n.get_value ().strdup_contents ();
    }

    /**
     * Каталог фильтров (набор filter_catalog): availableFilters и operatorByType из HTML страницы задач.
     * Элемент — {field, name, type, ops[], values[[подпись, id]], remote}, порядок — как на странице.
     */
    public GenericArray<Json.Object> filter_catalog (string html) {
        var res = new GenericArray<Json.Object> ();
        var avail = json_after (html, "var availableFilters =");
        var by_type = json_after (html, "var operatorByType =") ?? new Json.Object ();
        if (avail == null) return res;
        foreach (var field in avail.get_members ()) {
            var src = avail.get_member (field).get_node_type () == Json.NodeType.OBJECT ? avail.get_object_member (field) : null;
            if (src == null) continue;
            var type = jstr (src, "type");
            var o = new Json.Object ();
            o.set_string_member ("field", field);
            o.set_string_member ("name", jstr (src, "name"));
            o.set_string_member ("type", type);
            var ops = new Json.Array ();
            if (by_type.has_member (type)) foreach (var n in by_type.get_array_member (type).get_elements ()) ops.add_string_element (node_text (n));
            o.set_array_member ("ops", ops);
            var values = new Json.Array ();
            if (src.has_member ("values") && src.get_member ("values").get_node_type () == Json.NodeType.ARRAY)
                foreach (var v in src.get_array_member ("values").get_elements ()) {
                    if (v.get_node_type () != Json.NodeType.ARRAY || v.get_array ().get_length () < 2) continue;
                    var pair = new Json.Array ();
                    pair.add_string_element (node_text (v.get_array ().get_element (0)));
                    pair.add_string_element (node_text (v.get_array ().get_element (1)));
                    values.add_array_element (pair);
                }
            o.set_array_member ("values", values);
            o.set_boolean_member ("remote", jbool (src, "remote"));
            res.add (o);
        }
        return res;
    }

    /** Подписи операторов со страницы (на языке сервера); нет — пусто. */
    public Json.Object operator_labels (string html) {
        return json_after (html, "var operatorLabels =") ?? new Json.Object ();
    }

    /** Оператор без значений (spec 17.1). */
    public bool op_without_values (string op) {
        return op in new string[] { "o", "c", "*", "!*", "t", "ld", "w", "lw", "l2w", "m", "lm", "y", "nd", "nw", "nm", "*o", "!o" };
    }

    /** Сколько полей ввода у оператора: 0, 1 (число дней, текст, дата) или 2 (><). */
    public int op_arity (string op) {
        if (op_without_values (op)) return 0;
        return op == "><" ? 2 : 1;
    }

    private void add_conditions (Query q, Json.Array filters) {
        foreach (var n in filters.get_elements ()) {
            var f = n.get_object ();
            var field = jstr (f, "field");
            var op = jstr (f, "op");
            q.add ("f[]", field).add ("op[%s]".printf (field), op);
            if (op_without_values (op) || !f.has_member ("values")) continue;
            foreach (var v in f.get_array_member ("values").get_elements ()) q.add ("v[%s][]".printf (field), node_text (v));
        }
    }

    /** Условия и сортировка ([[поле, направление]]) → параметры issues.json (набор filter_params). */
    public Query filter_params (Json.Array filters, Json.Array sort) {
        var q = new Query ().add ("set_filter", "1");
        add_conditions (q, filters);
        var parts = new GenericArray<string> ();
        foreach (var s in sort.get_elements ()) {
            var a = s.get_array ();
            parts.add (a.get_string_element (0) + ":" + a.get_string_element (1));
        }
        if (parts.length > 0) q.add ("sort", string.joinv (",", parts.data));
        return q;
    }

    /** Поля веб-формы запроса после authenticity_token (набор query_form). visibility: 0 — мне, 1 — ролям, 2 — всем. */
    public Query query_form (string name, string description, int visibility, int[] role_ids, bool for_all, Json.Array filters, Json.Array sort) {
        var q = new Query ().add ("query[name]", name).add ("query[description]", description).add ("query[visibility]", visibility.to_string ());
        if (visibility == 1) foreach (var r in role_ids) q.add ("query[role_ids][]", r.to_string ());
        if (for_all) q.add ("query_is_for_all", "1");
        add_conditions (q, filters);
        int i = 0;
        foreach (var s in sort.get_elements ()) {
            var a = s.get_array ();
            var k = "query[sort_criteria][%d][]".printf (i++);
            q.add (k, a.get_string_element (0)).add (k, a.get_string_element (1));
        }
        return q;
    }

    /** Location ответа 302 на сохранение → id запроса; не список задач с query_id — 0 (набор query_saved). */
    public int query_saved_id (string location) {
        MatchInfo m;
        if (!/^(?:https?:\/\/[^\/]+)?(?:\/projects\/[^\/?#]+)?\/issues\?(?:[^#]*&)?query_id=(\d+)/.match (location, 0, out m)) return 0;
        return int.parse (m.fetch (1));
    }

    /** Текст #errorExplanation из ответа формы; нет — null. */
    public string? form_error (string html) {
        MatchInfo m;
        if (!/<div[^>]*id="errorExplanation"[^>]*>([\s\S]*?)<\/div>/.match (html, 0, out m)) return null;
        var items = new GenericArray<string> ();
        // MatchInfo держит строку, по которой искал, — она должна жить, пока идём по совпадениям
        var inner = m.fetch (1);
        MatchInfo li;
        if (/<li>([\s\S]*?)<\/li>/.match (inner, 0, out li)) {
            try {
                do { items.add (html_text (li.fetch (1))); } while (li.next ());
            } catch (RegexError e) {}
        }
        return items.length > 0 ? string.joinv ("; ", items.data) : html_text (inner);
    }
}
