/* Даты с целыми секундами, разбор журнала на категории, фильтр уведомлений, «По задачам», WAF-детектор. */
using Redmine;

void test_dates () {
    // Redmine отвергает дробные секунды (422): только целые и Z
    assert (iso_seconds (1700000000123) == "2023-11-14T22:13:20Z");
    assert (parse_iso_ms ("2023-11-14T22:13:20Z") == 1700000000000);
    assert (parse_iso_ms ("2023-11-15T01:13:20+03:00") == 1700000000000);
    assert (parse_iso_ms ("2023-11-14") > 0);
    assert (parse_iso_ms ("мусор") == 0);
    assert (format_hours (2.0) == "2" && format_hours (1.5) == "1.5");
    // список значений настраиваемого поля — без висящих разделителей
    assert (json_value_display (json_parse ("[\"a\", \"b\"]")) == "a, b");
    assert (parse_hours ("1,5") == 1.5 && parse_hours ("1:30") == 1.5 && parse_hours ("x") < 0);
    assert (format_relative ("2023-11-14T22:13:20Z", 1700000000000 + 5 * 60000) == _("%d min").printf (5));
}

void test_status_kind () {
    assert (status_kind ("Новая", false) == StatusKind.TODO);
    assert (status_kind ("BACKLOG", false) == StatusKind.TODO);
    assert (status_kind ("To Do", false) == StatusKind.TODO);
    assert (status_kind ("В работе", false) == StatusKind.IN_PROGRESS);
    assert (status_kind ("Заявка обработана", false) == StatusKind.IN_PROGRESS); // исключение сильнее «^заявка»
    assert (status_kind ("Заявка подана", false) == StatusKind.TODO);
    assert (status_kind ("Закрыта", true) == StatusKind.DONE);
    assert (status_kind ("Новая", true) == StatusKind.DONE); // закрытость сильнее TODO
    assert (status_kind ("ОТКЛОНЕНА", true) == StatusKind.REJECTED);
    assert (status_kind ("Cancelled", false) == StatusKind.REJECTED);
    assert (status_kind (" Прекращено ", true) == StatusKind.REJECTED);
    var today = new DateTime.local (2026, 10, 22, 23, 30, 0);
    assert (due_delta ("2026-10-22", today) == _("today"));
    assert (due_delta ("2026-10-25", today) == _("%d d").printf (3));
    assert (due_delta ("2026-10-20", today) == _("%d d").printf (-2));
    assert (due_delta ("", today) == null);
}

Json.Object journal (string json) {
    return json_parse (json).get_object ();
}

void test_types () {
    var j = journal ("""{"id":1,"notes":"Смотри @me","details":[{"property":"attr","name":"status_id","old_value":"1","new_value":"2"},{"property":"attr","name":"assigned_to_id","old_value":"5","new_value":"7"}]}""");
    var t = journal_types (j, 7, "me");
    assert (t[0] == NotifType.MENTION && t[1] == NotifType.ASSIGNED && t[2] == NotifType.STATUS && t[3] == NotifType.COMMENT);
    var away = journal_types (journal ("""{"id":2,"details":[{"property":"attr","name":"assigned_to_id","old_value":"7","new_value":"9"}]}"""), 7);
    assert (away.length == 1 && away[0] == NotifType.REASSIGNED_AWAY);
    var other = journal_types (journal ("""{"id":3,"details":[{"property":"attr","name":"assigned_to_id","old_value":"1","new_value":"2"}]}"""), 7);
    assert (other[0] == NotifType.OTHER);
    var priv = journal_types (journal ("""{"id":4,"notes":"x","private_notes":true,"details":[]}"""), 7);
    assert (priv[0] == NotifType.PRIVATE_NOTE);
    assert (mentions ("> цитата @Me тут", "me"));
    assert (!mentions ("@meX и a@me.ru", "me"));
}

void test_filter () {
    var e = new NotifEntry () { issue_id = 1, project_id = 10, type = NotifType.STATUS, strong = false, event_id = "j1" };
    e.also[NotifType.COMMENT] = true;
    var f = new NotifFilter ();
    assert (f.notifies (e));
    f.status_closed_only = true;
    var t = f.notify_types (e);
    assert (t.length == 1 && t[0] == NotifType.COMMENT);
    f.muted.add (NotifType.COMMENT);
    assert (!f.notifies (e));
    f.muted.remove (NotifType.COMMENT);
    f.muted_projects.add (10);
    assert (!f.notifies (e));
    assert (e.key == "1-j1" && e.journal_id == 1);
    var back = NotifEntry.from_json (e.to_json ());
    assert (back.key == e.key && back.also.contains (NotifType.COMMENT) && !back.strong);
}

void test_group () {
    var tz = new TimeZone.utc ();
    var list = new GenericArray<NotifEntry> ();
    list.add (new NotifEntry () { issue_id = 1, at = 1700000000000 + DAY_MS, event_id = "a" });
    list.add (new NotifEntry () { issue_id = 2, at = 1700000000000 + 1000, event_id = "b" });
    list.add (new NotifEntry () { issue_id = 1, at = 1700000000000, event_id = "c" });
    var days = group_by_issue (list, tz);
    assert (days.length == 2 && days[0].groups.length == 1 && days[1].groups.length == 2);
    assert (days[1].groups[0].issue_id == 2);
}

void test_waf () {
    assert (waf_challenge ("application/json", 200, "text/html; charset=utf-8", null));
    assert (!waf_challenge ("application/json", 200, "text/html", "abc"));
    assert (!waf_challenge ("application/json", 200, "application/json", null));
    assert (!waf_challenge ("text/html", 200, "text/html", null));
    var b = Uri.parse ("https://my.basealt.space", UriFlags.NONE);
    assert (key_allowed (b, Uri.parse ("https://my.basealt.space/issues/1.json", UriFlags.NONE)));
    assert (!key_allowed (b, Uri.parse ("http://my.basealt.space/x", UriFlags.NONE)));
    assert (!key_allowed (b, Uri.parse ("https://evil.example/x", UriFlags.NONE)));
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C.UTF-8");
    Test.init (ref args);
    Test.add_func ("/logic/dates", test_dates);
    Test.add_func ("/logic/status-kind", test_status_kind);
    Test.add_func ("/logic/types", test_types);
    Test.add_func ("/logic/filter", test_filter);
    Test.add_func ("/logic/group", test_group);
    Test.add_func ("/logic/waf", test_waf);
    return Test.run ();
}
