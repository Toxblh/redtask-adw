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
    assert (!is_block_value ("Москва"));
    assert (is_block_value ("|_.Статья|_.Сумма|"));
    assert (is_block_value ("строка\nещё"));
    assert (is_block_value ("* Паспорт"));
    assert (!is_block_value ("*Итого* 100"));
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
    assert (!format_date_short ("2026-10-22", today).contains ("2026") && !format_date_short ("2026-10-22", today).has_suffix ("."));
    assert (format_date_short ("2025-10-22", today) == format_date ("2025-10-22"));
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

void test_server_link () {
    var S = "https://my.basealt.space";
    var l = ServerLink.parse (S, "https://my.basealt.space/issues/123");
    assert (l != null && l.kind == LinkKind.ISSUE && l.id == 123 && l.note_index == 0 && l.journal_id == 0);
    l = ServerLink.parse (S, "https://my.basealt.space/issues/123#note-4");
    assert (l.id == 123 && l.note_index == 4);
    l = ServerLink.parse (S, "https://my.basealt.space/issues/123?tab=history#change-98765");
    assert (l.id == 123 && l.journal_id == 98765 && l.note_index == 0);
    // http вместо https, хост в другом регистре, явный порт по умолчанию
    assert (ServerLink.parse (S, "http://My.BaseAlt.Space/issues/5").id == 5);
    assert (ServerLink.parse (S, "https://my.basealt.space:443/issues/5").id == 5);
    assert (ServerLink.parse (S, "https://my.basealt.space:8443/issues/5") == null);
    assert (ServerLink.parse ("https://r.example:8443", "https://r.example:8443/issues/5").id == 5);
    assert (ServerLink.parse ("https://r.example:8443", "https://r.example/issues/5") == null);
    // чужие
    assert (ServerLink.parse (S, "https://redmine.org/issues/123") == null);
    assert (ServerLink.parse (S, "https://my.basealt.space.evil.com/issues/123") == null);
    assert (ServerLink.parse (S, "ftp://my.basealt.space/issues/123") == null);
    assert (ServerLink.parse ("", "https://my.basealt.space/issues/123") == null);
    // не задача/проект/человек — в браузер
    assert (ServerLink.parse (S, "https://my.basealt.space/issues") == null);
    assert (ServerLink.parse (S, "https://my.basealt.space/issues/123.json") == null);
    assert (ServerLink.parse (S, "https://my.basealt.space/issues/123/edit") == null);
    assert (ServerLink.parse (S, "https://my.basealt.space/") == null);
    assert (ServerLink.parse (S, "https://my.basealt.space/my/page") == null);
    // проекты (с подстраницами и параметрами запроса)
    l = ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus");
    assert (l.kind == LinkKind.PROJECT && l.project == "sisyphus");
    l = ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus/issues?set_filter=1&status_id=o");
    assert (l.kind == LinkKind.PROJECT && l.project == "sisyphus");
    assert (ServerLink.parse (S, "https://my.basealt.space/projects") == null);
    // люди
    l = ServerLink.parse (S, "https://my.basealt.space/users/107");
    assert (l.kind == LinkKind.USER && l.id == 107);
    l = ServerLink.parse (S, "https://my.basealt.space/people/107?tab=activity");
    assert (l.kind == LinkKind.USER && l.id == 107);
    assert (ServerLink.parse (S, "https://my.basealt.space/users/current") == null);
    // подпуть установки
    var R = "https://host.example/redmine/";
    assert (ServerLink.parse (R, "https://host.example/redmine/issues/7#note-2").note_index == 2);
    assert (ServerLink.parse (R, "https://host.example/issues/7") == null);
    assert (ServerLink.parse (R, "https://host.example/redmine2/issues/7") == null);
    assert (ServerLink.parse (R, "https://host.example/redmine/projects/x").project == "x");
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
    Test.add_func ("/logic/server-link", test_server_link);
    return Test.run ();
}
