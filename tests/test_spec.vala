/* Общие наборы spec/vectors.json (Android, iOS, GNOME): каждый раздел — против чистых функций ядра. */
using Redmine;

Json.Object spec;

int[] ints (Json.Array a) {
    int[] res = {};
    foreach (var n in a.get_elements ()) res += (int) n.get_int ();
    return res;
}

GenericArray<Json.Object> objs (Json.Array a) {
    var res = new GenericArray<Json.Object> ();
    foreach (var n in a.get_elements ()) res.add (n.get_object ());
    return res;
}

/** null в наборе — 0 у функции. */
int opt_int (Json.Object o, string key) {
    return o.get_member (key).is_null () ? 0 : (int) o.get_int_member (key);
}

void test_status_kind () {
    string[] kinds = { "todo", "in_progress", "done", "rejected" };
    foreach (var c in objs (spec.get_array_member ("status_kind"))) {
        var got = kinds[status_kind (c.get_string_member ("name"), c.get_boolean_member ("closed"))];
        if (got != c.get_string_member ("kind")) error ("status_kind %s: %s", c.get_string_member ("name"), got);
    }
}

void test_note_link () {
    var v = spec.get_object_member ("note_link");
    var journals = ints (v.get_array_member ("journals"));
    var server = v.get_string_member ("server");
    var issue = (int) v.get_int_member ("issue");
    foreach (var c in objs (v.get_array_member ("links")))
        assert_cmpstr (note_url (server, issue, journals, (int) c.get_int_member ("journal")), CompareOperator.EQ, c.get_string_member ("url"));
    foreach (var c in objs (v.get_array_member ("fragments")))
        assert_cmpint (journal_for_fragment (journals, c.get_string_member ("fragment")), CompareOperator.EQ, opt_int (c, "journal"));
}

void test_quote_reply () {
    foreach (var c in objs (spec.get_object_member ("quote_reply").get_array_member ("cases"))) {
        var got = quote_reply (c.get_string_member ("author"), opt_int (c, "note"), c.get_string_member ("text"), c.get_string_member ("lang"));
        var want = c.get_member ("out").is_null () ? null : c.get_string_member ("out");
        assert_cmpstr (got, CompareOperator.EQ, want);
    }
}

void test_project_pins () {
    var v = spec.get_object_member ("project_pins");
    var got = pinned_projects (objs (v.get_array_member ("projects")), ints (v.get_array_member ("pins")));
    var want = ints (v.get_array_member ("pinned"));
    assert_cmpint (got.length, CompareOperator.EQ, want.length);
    for (int k = 0; k < want.length; k++) assert_cmpint (jint (got[k], "id"), CompareOperator.EQ, want[k]);
}

void test_version_progress () {
    foreach (var c in objs (spec.get_object_member ("version_progress").get_array_member ("cases"))) {
        bool[] closed = {};
        foreach (var n in c.get_array_member ("closed").get_elements ()) closed += n.get_boolean ();
        int done, total;
        var pct = version_progress (closed, out done, out total);
        assert_cmpint (done, CompareOperator.EQ, (int) c.get_int_member ("done"));
        assert_cmpint (total, CompareOperator.EQ, (int) c.get_int_member ("total"));
        assert_cmpint (pct, CompareOperator.EQ, (int) c.get_int_member ("percent"));
    }
}

/** Задачи набора → Issue: «assignee» набора — это assigned_to Redmine, «status» — id статуса. */
GenericArray<Issue> issues_of (Json.Array a) {
    var res = new GenericArray<Issue> ();
    foreach (var c in objs (a)) {
        var o = new Json.Object ();
        o.set_int_member ("id", c.get_int_member ("id"));
        if (c.has_member ("subject")) o.set_string_member ("subject", c.get_string_member ("subject"));
        if (c.has_member ("assignee") && !c.get_member ("assignee").is_null ()) o.set_object_member ("assigned_to", c.get_object_member ("assignee"));
        if (c.has_member ("status") || c.has_member ("closed")) {
            var st = new Json.Object ();
            if (c.has_member ("status")) st.set_int_member ("id", c.get_int_member ("status"));
            if (c.has_member ("closed")) st.set_boolean_member ("is_closed", c.get_boolean_member ("closed"));
            o.set_object_member ("status", st);
        }
        res.add (new Issue (o));
    }
    return res;
}

void assert_ids (GenericArray<Issue> got, Json.Array want) {
    var w = ints (want);
    assert_cmpint (got.length, CompareOperator.EQ, w.length);
    for (int k = 0; k < w.length; k++) assert_cmpint (got[k].id, CompareOperator.EQ, w[k]);
}

void test_assignee_filter () {
    var v = spec.get_object_member ("assignee_filter");
    var me = (int) v.get_int_member ("me");
    var issues = issues_of (v.get_array_member ("issues"));
    var got = assignee_options (issues, me);
    var want = objs (v.get_array_member ("options"));
    assert_cmpint (got.length, CompareOperator.EQ, want.length);
    for (int k = 0; k < want.length; k++) {
        assert_cmpstr (got[k].key, CompareOperator.EQ, want[k].get_string_member ("key"));
        assert_cmpint (got[k].count, CompareOperator.EQ, (int) want[k].get_int_member ("count"));
        if (want[k].has_member ("name")) assert_cmpstr (got[k].name, CompareOperator.EQ, want[k].get_string_member ("name"));
    }
    foreach (var c in objs (v.get_array_member ("select")))
        assert_ids (filter_by_assignee (issues, c.get_string_member ("key"), me), c.get_array_member ("ids"));
}

void test_board_columns () {
    var v = spec.get_object_member ("board_columns");
    var got = board_columns (issues_of (v.get_array_member ("issues")), ints (v.get_array_member ("status_order")));
    var want = objs (v.get_array_member ("columns"));
    assert_cmpint (got.length, CompareOperator.EQ, want.length);
    for (int k = 0; k < want.length; k++) {
        assert_cmpint (got[k].status, CompareOperator.EQ, (int) want[k].get_int_member ("status"));
        assert_ids (got[k].issues, want[k].get_array_member ("ids"));
    }
}

void test_notif_image () {
    var v = spec.get_object_member ("notif_image");
    var atts = objs (v.get_array_member ("attachments"));
    foreach (var c in objs (v.get_array_member ("cases")))
        assert_cmpint (notification_image (c.get_string_member ("notes"), objs (c.get_array_member ("details")), atts), CompareOperator.EQ, opt_int (c, "image"));
}

void test_wiki_link () {
    foreach (var c in objs (spec.get_object_member ("wiki_link").get_array_member ("cases"))) {
        var l = Textile.wiki_link (c.get_string_member ("src"));
        assert (l != null);
        assert_cmpstr (l.project, CompareOperator.EQ, c.get_member ("project").is_null () ? null : c.get_string_member ("project"));
        assert_cmpstr (l.title, CompareOperator.EQ, c.get_string_member ("title"));
        assert_cmpstr (l.label, CompareOperator.EQ, c.get_string_member ("label"));
        // в тексте — ссылкой вики, которую приложение открывает у себя
        assert ("href=\"wiki:%s:%s\"".printf (l.project ?? "", Markup.escape_text (l.title)) in Textile.inline_markup ("см. " + c.get_string_member ("src")));
    }
}

void test_thumbnail_source () {
    foreach (var c in objs (spec.get_object_member ("thumbnail_source").get_array_member ("cases")))
        assert_cmpstr (thumbnail_source (c.get_string_member ("filename"), c.get_string_member ("content_type")), CompareOperator.EQ, c.get_string_member ("source"));
}

void test_embedded_thumbnail () {
    foreach (var c in objs (spec.get_object_member ("embedded_thumbnail").get_array_member ("cases"))) {
        var got = embedded_thumbnail (new Bytes (Base64.decode (c.get_string_member ("zip"))));
        var want = c.get_member ("out").is_null () ? null : c.get_string_member ("out");
        assert_cmpstr (got == null ? null : Base64.encode (got.get_data ()), CompareOperator.EQ, want);
    }
}

double[] doubles (Json.Array a) {
    double[] res = {};
    foreach (var n in a.get_elements ()) res += n.get_double ();
    return res;
}

void test_table_columns () {
    foreach (var c in objs (spec.get_object_member ("table_columns").get_array_member ("cases"))) {
        bool scroll;
        var got = Textile.table_columns (doubles (c.get_array_member ("min")), doubles (c.get_array_member ("max")), c.get_double_member ("avail"), out scroll);
        var want = doubles (c.get_array_member ("widths"));
        assert_cmpint (got.length, CompareOperator.EQ, want.length);
        for (int i = 0; i < want.length; i++) assert_cmpfloat_with_epsilon (got[i], want[i], 0.01);
        assert (scroll == c.get_boolean_member ("scroll"));
    }
}

string[] strs (Json.Array a) {
    string[] res = {};
    foreach (var n in a.get_elements ()) res += n.get_string ();
    return res;
}

void test_mention_query () {
    foreach (var c in objs (spec.get_object_member ("mention_query").get_array_member ("cases"))) {
        var want = c.get_member ("query").is_null () ? null : c.get_string_member ("query");
        assert_cmpstr (mention_query (c.get_string_member ("text"), (int) c.get_int_member ("cursor")), CompareOperator.EQ, want);
    }
}

void test_mention_candidates () {
    var v = spec.get_object_member ("mention_candidates");
    var parts = objs (v.get_array_member ("participants"));
    var people = objs (v.get_array_member ("people"));
    foreach (var c in objs (v.get_array_member ("cases"))) {
        var got = mention_candidates (parts, people, c.get_string_member ("query"), (int) c.get_int_member ("limit"));
        var want = ints (c.get_array_member ("ids"));
        assert_cmpint (got.length, CompareOperator.EQ, want.length);
        for (int k = 0; k < want.length; k++) assert_cmpint (jint (got[k], "id"), CompareOperator.EQ, want[k]);
    }
}

void test_recent_opened () {
    foreach (var c in objs (spec.get_object_member ("recent_opened").get_array_member ("cases"))) {
        var got = recent_opened (ints (c.get_array_member ("list")), (int) c.get_int_member ("open"));
        var want = ints (c.get_array_member ("out"));
        assert_cmpint (got.length, CompareOperator.EQ, want.length);
        for (int k = 0; k < want.length; k++) assert_cmpint (got[k], CompareOperator.EQ, want[k]);
    }
}

void test_board_filter () {
    var v = spec.get_object_member ("board_filter");
    var me = (int) v.get_int_member ("me");
    var issues = issues_of (v.get_array_member ("issues"));
    foreach (var c in objs (v.get_array_member ("cases")))
        assert_ids (board_filter (issues, me, strs (c.get_array_member ("assignees")), c.get_string_member ("query")), c.get_array_member ("ids"));
}

void test_zip_tail () {
    foreach (var c in objs (spec.get_object_member ("zip_tail").get_array_member ("cases"))) {
        var got = zip_tail_entry (c.get_int_member ("size"), new Bytes (Base64.decode (c.get_string_member ("tail"))));
        if (c.get_member ("entry").is_null ()) { assert (got == null); continue; }
        var e = c.get_object_member ("entry");
        assert (got != null);
        assert_cmpstr (got.name, CompareOperator.EQ, e.get_string_member ("name"));
        assert_cmpint ((int) got.local_offset, CompareOperator.EQ, (int) e.get_int_member ("local_offset"));
        assert_cmpint ((int) got.compressed_size, CompareOperator.EQ, (int) e.get_int_member ("compressed_size"));
        assert_cmpint ((int) got.method, CompareOperator.EQ, (int) e.get_int_member ("method"));
    }
}

void test_textile_table () {
    foreach (var c in objs (spec.get_object_member ("textile_table").get_array_member ("cases"))) {
        var got = Textile.table_rows (c.get_string_member ("src"));
        var want = c.get_array_member ("rows");
        assert_cmpint ((int) got.length, CompareOperator.EQ, (int) want.get_length ());
        for (int r = 0; r < got.length; r++) {
            var wr = objs (want.get_array_element (r));
            assert_cmpint (got[r].length, CompareOperator.EQ, wr.length);
            for (int k = 0; k < wr.length; k++) {
                assert_cmpstr (got[r][k].text, CompareOperator.EQ, wr[k].get_string_member ("text"));
                assert (got[r][k].header == wr[k].get_boolean_member ("h"));
            }
        }
    }
}

void test_custom_tables () {
    foreach (var c in objs (spec.get_object_member ("custom_tables").get_array_member ("cases"))) {
        var want = new Json.Node (Json.NodeType.ARRAY);
        want.set_array (c.get_array_member ("tables"));
        var got = new Json.Node (Json.NodeType.ARRAY);
        got.set_array (custom_tables (c.get_string_member ("html")));
        assert_cmpstr (json_to_string (got), CompareOperator.EQ, json_to_string (want));
    }
}

void test_assignee_avatars () {
    var v = spec.get_object_member ("assignee_avatars");
    var me = (int) v.get_int_member ("me");
    var issues = issues_of (v.get_array_member ("issues"));
    foreach (var c in objs (v.get_array_member ("cases"))) {
        var got = assignee_avatars (issues, me, c.get_string_member ("status"));
        var want = objs (c.get_array_member ("options"));
        assert_cmpint (got.length, CompareOperator.EQ, want.length);
        for (int k = 0; k < want.length; k++) {
            assert_cmpstr (got[k].key, CompareOperator.EQ, want[k].get_string_member ("key"));
            assert_cmpint (got[k].count, CompareOperator.EQ, (int) want[k].get_int_member ("count"));
        }
    }
}

void test_people_phones () {
    foreach (var c in objs (spec.get_object_member ("people_phones").get_array_member ("cases"))) {
        var want = new Json.Node (Json.NodeType.ARRAY);
        want.set_array (c.get_array_member ("phones"));
        var got = new Json.Node (Json.NodeType.ARRAY);
        got.set_array (people_phones (c.get_string_member ("html")));
        assert_cmpstr (json_to_string (got), CompareOperator.EQ, json_to_string (want));
    }
}

void test_journal_labels () {
    foreach (var c in objs (spec.get_object_member ("journal_labels").get_array_member ("cases"))) {
        GenericSet<string>? multiple = null;
        if (c.has_member ("multiple") && !c.get_member ("multiple").is_null ()) {
            multiple = new GenericSet<string> (str_hash, str_equal);
            foreach (var id in ints (c.get_array_member ("multiple"))) multiple.add (id.to_string ());
        }
        var got = obj_node (journal_detail_labels (c.get_string_member ("html"), objs (c.get_array_member ("journals")), multiple));
        assert_cmpstr (json_to_string (got), CompareOperator.EQ, json_to_string (c.get_member ("expected")));
    }
}

/** Демо-режим (п. 6): выдуманный сервер в памяти — коды, логин, номера и total списков задач. */
void test_demo_server () {
    var v = spec.get_object_member ("demo_server");
    var base_url = v.get_string_member ("base");
    assert_cmpstr (DemoServer.BASE, CompareOperator.EQ, base_url);
    foreach (var c in objs (v.get_array_member ("translit")))
        assert_cmpstr (demo_translit (c.get_string_member ("first"), c.get_string_member ("last")), CompareOperator.EQ, c.get_string_member ("login"));
    foreach (var c in objs (v.get_array_member ("requests"))) {
        DemoServer.reset (c.get_string_member ("lang") == "ru");
        var path = c.get_string_member ("path");
        var r = DemoServer.handle (c.get_string_member ("method"), path.has_prefix ("/") ? base_url + path : path, null);
        if (r.code != c.get_int_member ("code")) error ("demo %s: %u", path, r.code);
        if (!c.has_member ("login") && !c.has_member ("ids")) continue;
        var o = json_parse (((string) r.body.get_data ()).substring (0, (long) r.body.get_size ())).get_object ();
        if (c.has_member ("login")) assert_cmpstr (jstr (jobj (o, "user"), "login"), CompareOperator.EQ, c.get_string_member ("login"));
        if (c.has_member ("ids")) {
            int[] got = {};
            foreach (var i in jarr (o, "issues")) got += jint (i, "id");
            var want = ints (c.get_array_member ("ids"));
            if (got.length != want.length) error ("demo %s: %d issues", path, got.length);
            for (int k = 0; k < want.length; k++) if (got[k] != want[k]) error ("demo %s: [%d] %d != %d", path, k, got[k], want[k]);
            assert_cmpint (jint (o, "total_count"), CompareOperator.EQ, (int) c.get_int_member ("total"));
        }
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C.UTF-8");
    Test.init (ref args);
    var p = new Json.Parser ();
    try {
        p.load_from_file (args[args.length - 1]);
    } catch (Error e) {
        error ("vectors.json: %s", e.message);
    }
    spec = p.get_root ().get_object ();
    // новый раздел в наборах без теста здесь — провал, а не тихий пропуск
    string[] known = { "_", "demo_server", "status_kind", "note_link", "quote_reply", "project_pins", "version_progress", "assignee_filter", "board_columns", "notif_image", "wiki_link", "thumbnail_source", "embedded_thumbnail", "table_columns",
        "mention_query", "mention_candidates", "recent_opened", "board_filter", "zip_tail", "textile_table", "custom_tables", "assignee_avatars", "people_phones", "journal_labels" };
    foreach (var m in spec.get_members ()) if (!(m in known)) error ("vectors.json: section %s is not tested", m);
    Test.add_func ("/spec/status_kind", test_status_kind);
    Test.add_func ("/spec/note_link", test_note_link);
    Test.add_func ("/spec/quote_reply", test_quote_reply);
    Test.add_func ("/spec/project_pins", test_project_pins);
    Test.add_func ("/spec/version_progress", test_version_progress);
    Test.add_func ("/spec/assignee_filter", test_assignee_filter);
    Test.add_func ("/spec/board_columns", test_board_columns);
    Test.add_func ("/spec/notif_image", test_notif_image);
    Test.add_func ("/spec/wiki_link", test_wiki_link);
    Test.add_func ("/spec/thumbnail_source", test_thumbnail_source);
    Test.add_func ("/spec/embedded_thumbnail", test_embedded_thumbnail);
    Test.add_func ("/spec/table_columns", test_table_columns);
    Test.add_func ("/spec/mention_query", test_mention_query);
    Test.add_func ("/spec/mention_candidates", test_mention_candidates);
    Test.add_func ("/spec/recent_opened", test_recent_opened);
    Test.add_func ("/spec/board_filter", test_board_filter);
    Test.add_func ("/spec/zip_tail", test_zip_tail);
    Test.add_func ("/spec/textile_table", test_textile_table);
    Test.add_func ("/spec/custom_tables", test_custom_tables);
    Test.add_func ("/spec/assignee_avatars", test_assignee_avatars);
    Test.add_func ("/spec/people_phones", test_people_phones);
    Test.add_func ("/spec/journal_labels", test_journal_labels);
    Test.add_func ("/spec/demo_server", test_demo_server);
    return Test.run ();
}
