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
    // разделы проекта, вехи и страницы вики — в приложении
    assert (ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus/roadmap").tab == "versions");
    assert (ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus").tab == "overview");
    assert (ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus/issues").tab == "");
    assert (ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus/wiki").tab == "wiki");
    l = ServerLink.parse (S, "https://my.basealt.space/projects/sisyphus/wiki/%D0%9A%D0%B0%D0%BA_%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D0%B0%D1%82%D1%8C");
    assert (l.kind == LinkKind.WIKI && l.project == "sisyphus" && l.title == "Как_работать");
    l = ServerLink.parse (S, "https://my.basealt.space/versions/42");
    assert (l.kind == LinkKind.VERSION && l.id == 42);
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

void test_favourites () {
    // как на странице задачи: ссылка плагина вставляется скриптом; состояние — по data-method
    var on = "<meta name=\"csrf-token\" content=\"pq_x-1\" />\n$(link).before('<a class=\"issue-244551-favourite icon icon-favourites-on\" data-remote=\"true\" rel=\"nofollow\" data-method=\"delete\" href=\"/favourites/fav?object_id=244551&amp;object_type=issue\">Убрать из избранного</a>')";
    var off = "<a class=\"issue-244293-favourite icon icon-favourites-off\" data-remote=\"true\" rel=\"nofollow\" data-method=\"post\" href=\"/favourites/fav?object_id=244293&amp;object_type=issue\">Добавить в избранное</a>"
        + "<a class=\"issue-244293-watcher icon icon-fav\" data-method=\"delete\" href=\"/watchers/watch\">";
    assert (fav_link_state (on, 244551) == 1);
    assert (fav_link_state (off, 244293) == 0); // «Не следить» с delete рядом — не звезда
    assert (fav_link_state (off, 24429) == -1); // чужой номер-префикс
    assert (fav_link_state ("<a href=\"/login\">Войти</a>", 244293) == -1); // не вошли на сайт
    assert (csrf_token (on) == "pq_x-1");
    assert (csrf_token (off) == null);
    // миграция: только то, чего нет на сервере, без повторов и мусора, в прежнем порядке
    var server = new GenericSet<int> (direct_hash, direct_equal);
    server.add (244551);
    var todo = fav_to_migrate ({ 5, 244551, 7, 5, 0 }, server);
    assert (todo.length == 2 && todo[0] == 5 && todo[1] == 7);
    assert (fav_to_migrate ({}, server).length == 0);
    assert (fav_to_migrate ({ 244551 }, server).length == 0);
}

// CSV-экспорт Redmine — источник подписей для полей, которые REST отдаёт числами (как GuardsTest на Android)
void test_csv () {
    var rows = parse_csv ("\xEF\xBB\xBF#;Формат публикации;Каналы;Бюджет\n248260;Интервью;\"ИТ СМИ; \"\"свои\"\"\";\"строка 1\nстрока 2\"\n");
    assert (rows.length == 2);
    assert (rows[0].length == 4 && rows[0][0] == "#" && rows[0][1] == "Формат публикации" && rows[0][3] == "Бюджет");
    assert (rows[1][0] == "248260" && rows[1][1] == "Интервью" && rows[1][2] == "ИТ СМИ; \"свои\"" && rows[1][3] == "строка 1\nстрока 2");
    var en = parse_csv ("#,Type,Empty\r\n5,\"a,b\",\"\"\r\n");
    assert (en.length == 2 && en[0].length == 3 && en[0][2] == "Empty");
    assert (en[1].length == 3 && en[1][0] == "5" && en[1][1] == "a,b" && en[1][2] == "");
    assert (parse_csv ("").length == 0);
    // подписи: только поля-идентификаторы, по имени колонки, и только если текст отличается от сырого значения
    var fields = new GenericArray<Json.Object> ();
    foreach (var j in new string[] { "{\"id\":7,\"name\":\"Продукт(ы)\",\"value\":[\"88\",\"89\"]}", "{\"id\":8,\"name\":\"Тип\",\"value\":\"216\"}",
                                     "{\"id\":9,\"name\":\"Сумма\",\"value\":\"12\"}", "{\"id\":10,\"name\":\"Дата\",\"value\":\"2026-10-22\"}",
                                     "{\"id\":11,\"name\":\"Пусто\",\"value\":\"\"}" })
        fields.add (json_parse (j).get_object ());
    assert (cf_id_like (fields[0]) && cf_id_like (fields[1]) && !cf_id_like (fields[3]) && !cf_id_like (fields[4]));
    var l = cf_labels_from_csv (parse_csv ("#;Сумма;Продукт(ы)\n5;12;Альт Сервер, Альт Рабочая станция\n"), fields);
    assert (jstr (l, "7") == "Альт Сервер, Альт Рабочая станция");
    assert (!l.has_member ("8")); // колонки нет — сервер её пропустил
    assert (!l.has_member ("9")); // совпадает с сырым значением
    assert (cf_display (l, fields[0]) == "Альт Сервер, Альт Рабочая станция" && cf_display (l, fields[1]) == "216");
    assert (cf_labels_from_csv (parse_csv (""), fields).get_size () == 0);
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
    Test.add_func ("/logic/favourites", test_favourites);
    Test.add_func ("/logic/csv", test_csv);
    return Test.run ();
}
