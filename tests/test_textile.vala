/* Разбор Textile: блоки, вложенные цитаты, списки, таблицы, код, картинки, инлайн-разметка, защита от длинных строк. */
using Textile;

void test_blocks () {
    var lines = parse ("h2. Заголовок\n\nтекст *жирный*\n\n* раз\n** два\n# один\n# два\n\n|_. A |_. B |\n| 1 | 2 |\n<pre>код\n  строка</pre>\n---\n!img.png!");
    assert (lines[0].kind == Kind.HEADING && lines[0].level == 2 && lines[0].text == "Заголовок");
    var blocks = group (lines);
    BlockKind[] kinds = {};
    foreach (var b in blocks) kinds += b.kind;
    assert (kinds[0] == BlockKind.TEXT);
    assert (kinds[1] == BlockKind.TEXT && blocks[1].gap);
    assert (kinds[2] == BlockKind.LIST && blocks[2].lines.length == 4);
    assert (blocks[2].lines[1].level == 1);
    assert (blocks[2].lines[2].number == 1 && blocks[2].lines[3].number == 2);
    assert (kinds[3] == BlockKind.TABLE && blocks[3].lines[0].cells[0].header && blocks[3].lines[1].cells[1].text == "2");
    // RedCloth не требует пробела после «.»: так пишут шаблоны полей на сервере
    var hc = parse_cells ("|_.Статья |_.б/н |");
    assert (hc[0].header && hc[0].text == "Статья" && hc[1].header && hc[1].text == "б/н");
    // rowspan сдвигает ячейки следующей строки; выравнивание; модификатор после пробела — текст
    var t = group (parse ("|/2. r | b | c |\n| d | e |\n|<. л |=. ц |>. п |\n| {color:red}. x |\\2. две |"))[0].lines;
    layout_table (t);
    assert (t[0].cells[0].rowspan == 2 && t[1].cells[0].col == 1 && t[1].cells[1].col == 2);
    assert (t[2].cells[0].col == 0 && t[2].cells[1].xalign == 0.5f && t[2].cells[2].xalign == 1);
    assert (t[3].cells[0].text == "{color:red}. x" && t[3].cells[1].span == 2 && t[3].cells[1].text == "две");
    assert (kinds[4] == BlockKind.CODE && blocks[4].lines.length == 2 && blocks[4].lines[1].text == "  строка");
    assert (kinds[5] == BlockKind.RULE);
    assert (kinds[6] == BlockKind.IMAGE && blocks[6].lines[0].text == "img.png");
}

void test_quotes () {
    var lines = parse ("Иван wrote:\n> первая\n> > вложенная\n> снова\n\nbq. абзац\nцитаты");
    assert (lines[1].kind == Kind.QUOTE);
    var inner = lines[1].children;
    assert (inner[0].kind == Kind.PLAIN && inner[0].text == "первая");
    assert (inner[1].kind == Kind.QUOTE && inner[1].children[0].text == "вложенная");
    assert (lines[3].kind == Kind.QUOTE && lines[3].children.length == 2);
    // глубина ограничена: 50 уровней не роняют разбор
    var deep = string.nfill (50, '>') + " x";
    var d = parse (deep);
    int depth = 0;
    var cur = d;
    while (cur.length > 0 && cur[0].kind == Kind.QUOTE) { cur = cur[0].children; depth++; }
    assert (depth <= MAX_QUOTE_DEPTH + 1);
}

void test_inline () {
    assert (inline_markup ("*жирный* и _курсив_") == "<b>жирный</b> и <i>курсив</i>");
    // не разметка: арифметика, пути, почта
    assert (inline_markup ("2 * 3 * 4") == "2 * 3 * 4");
    // почта — не @код@, а ссылка mailto, как у сервера
    assert (inline_markup ("a@b.com or c@d.com") == "<a href=\"mailto:a@b.com\">a@b.com</a> or <a href=\"mailto:c@d.com\">c@d.com</a>");
    assert (inline_markup ("__курсив__ и **жирный**") == "<i>курсив</i> и <b>жирный</b>");
    assert (inline_markup ("snake_case_name") == "snake_case_name");
    // сноски: «текст[1]» → верхний индекс, «[1]» после пробела — как есть
    assert (inline_markup ("текст[1] и [2]") == "текст<sup>1</sup> и [2]");
    var fl = parse ("fn1. Сноска");
    assert (fl[0].kind == Kind.FOOTNOTE && fl[0].number == 1 && text_markup (fl) == "<sup>1</sup> Сноска");
    // именованные сущности
    assert (inline_markup (decode_entities ("&copy; &mdash; &laquo;x&raquo; &trade; &bogus;")) == "© — «x» ™ &amp;bogus;");
    assert (inline_markup ("well-known --force") == "well-known --force");
    assert (inline_markup ("см. #123") == "см. <a href=\"issue:123\">#123</a>");
    assert (inline_markup ("#123#note-5") == "<a href=\"issue:123:5\">#123#note-5</a>");
    assert (inline_markup ("#note-7") == "<a href=\"note:7\">#note-7</a>");
    assert (inline_markup ("https://x.ru/a_b_c.") == "<a href=\"https://x.ru/a_b_c\">https://x.ru/a_b_c</a>.");
    assert (inline_markup ("\"сайт\":https://x.ru") == "<a href=\"https://x.ru\">сайт</a>");
    assert (inline_markup ("@code@") .contains ("monospace"));
    assert (inline_markup ("a < b & c") == "a &lt; b &amp; c");
    assert (inline_markup ("в проекте project:PR, трекер") == "в проекте <a href=\"/projects/pr\">PR</a>, трекер");
    assert (inline_markup ("myproject:x") == "myproject:x");
    // упоминание с известным логином — ссылка на человека
    string? look (string l) { return l == "ivanov" ? "42|Иван Иванов" : null; }
    // как на сайте: именем без «@»
    assert (inline_markup ("привет @ivanov.", look) == "привет <a href=\"user:42\" class=\"mention\">Иван Иванов</a>.");
    assert (inline_markup ("@petrov", look) == "@petrov");
    // сущности инертны: &gt; не цитата
    var l = parse ("&gt; не цитата");
    assert (l[0].kind == Kind.PLAIN);
    assert (inline_markup (l[0].text) == "&gt; не цитата");
    // длинная строка не тормозит и не падает
    var big = string.nfill (30000, '*');
    assert (inline_markup (big).length == 30000);
    var many = "";
    for (int i = 0; i < 2000; i++) many += "<code>";
    inline_markup (many);
}

void test_mentions () {
    var ls = mention_logins ("@Ivanov и @petrov, а @code@ — нет, user:sidorov");
    assert (ls.length == 3 && ls[0] == "ivanov" && ls[1] == "petrov" && ls[2] == "sidorov");
}

void test_preview () {
    assert (preview ("bq. *важно* !img.png! \"тут\":http://x") == "важно img.png тут");
}

/* Текст комментария в один TextView: какие блоки текут вместе, интервалы и куски буфера с тегами и ссылками. */
void test_flow () {
    var bs = group (parse ("абзац\n\n* пункт\n<pre>код</pre>\n---\nbq. цитата\n\n|a|b|\n\n!x.png!\n\n> текст\n> |t|\n\n{{collapse(x)\nвнутри\n}}"));
    BlockKind[] k = {};
    bool[] f = {};
    foreach (var b in bs) { k += b.kind; f += is_flow (b); }
    assert (k[0] == BlockKind.TEXT && f[0]);
    assert (k[1] == BlockKind.LIST && f[1]);
    assert (k[2] == BlockKind.CODE && f[2]);
    assert (k[3] == BlockKind.RULE && f[3]);
    assert (k[4] == BlockKind.QUOTE && f[4]);   // цитата из текста — в общий поток
    assert (k[5] == BlockKind.TABLE && !f[5]);
    assert (k[6] == BlockKind.IMAGE && !f[6]);
    assert (k[7] == BlockKind.QUOTE && !f[7]);  // с таблицей внутри — отдельным виджетом
    assert (k[8] == BlockKind.COLLAPSE && !f[8]);
    // интервалы: абзац 10, рядом с кодом/цитатой/линией 6, иначе вплотную
    assert (gap_before (null, bs[0]) == 0 && gap_before (bs[0], bs[1]) == 10);
    assert (gap_before (bs[1], bs[2]) == 6 && gap_before (bs[2], bs[3]) == 6);
    var tt = group (parse ("a\n* b"));
    assert (gap_before (tt[0], tt[1]) == 0);

    // markup → куски: теги стопкой, ссылка внутри жирного, спецсимволы как есть
    var r = markup_runs (inline_markup ("x *жирный \"ссылка\":http://e.org и* @код@ a & <b>"));
    var sb = new StringBuilder ();
    foreach (var x in r) sb.append (x.text);
    assert (sb.str == "x жирный ссылка и код a & <b>");
    Run? link = null;
    foreach (var x in r) if (x.text == "ссылка") link = x;
    assert (link != null && link.href == "http://e.org" && "b" in link.tags && "link" in link.tags);
    foreach (var x in r) if (x.text == "код") assert (x.tags.length == 1 && x.tags[0] == "code");
    var h = markup_runs (text_markup (parse ("h1. Big\nh4. small\n{{hello}}")));
    assert (h[0].text == "Big" && h[0].tags[0] == "h1");
    // строка под заголовком — его продолжение (RedCloth: «h2. X<br />…»)
    assert (h[2].text == "small\n" && h[2].tags[0] == "h3");
    assert (h[3].text == "hello" && "macro" in h[3].tags && "h3" in h[3].tags);
    var u = markup_runs (inline_markup ("#5 и @Ivan", (l) => l == "ivan" ? "7|Иван" : null));
    assert (u[0].href == "issue:5" && u[2].href == "user:7" && u[2].text == "Иван");
    // закрытая задача — серая и зачёркнутая, подсказка «Трекер: тема (Статус)» — title ссылки
    var c = markup_runs (inline_markup ("#5#note-2 и #6 и user#7", (k) => k == "issue#5" ? "C|Ошибка: <x> (Закрыта)" : (k == "issue#6" ? "O|Задача: y (Новая)" : (k == "user#7" ? "7|Пальгунов Антон" : null))));
    assert (c[0].href == "issue:5:2" && "closed" in c[0].tags && c[0].title == "Ошибка: <x> (Закрыта)");
    assert (c[2].href == "issue:6" && !("closed" in c[2].tags) && c[2].title == "Задача: y (Новая)");
    assert (c[4].href == "user:7" && c[4].text == "Пальгунов Антон" && c[4].tags[0] == "mention");
    var ids = issue_ids ("#5, #5#note-2, #note-3, @#6@ и #7");
    assert (ids.length == 3 && ids[0] == 5 && ids[2] == 7);
}

/* Ячейки таблиц: стиль «{…}.» (только безопасные значения), th по центру, пустые строки. */
void test_cells () {
    var c = parse_cells ("|{background:#ffc}. стиль |{color:red; font-weight:bold}. x |{background:url(javascript:x); color:expression(1)}. y |");
    assert (c[0].bg == "#ffc" && c[0].fg == null && c[0].text == "стиль");
    assert (c[1].fg == "red" && c[1].bold && c[1].bg == null);
    assert (c[2].bg == null && c[2].fg == null && c[2].text == "y");
    var a = parse_cells ("|{text-align:right;background-color:rgb(1, 2, 3)}. r |_. h |_<. hl |{font-weight:700}. b |");
    assert (a[0].xalign == 1 && a[0].bg == "rgb(1, 2, 3)");
    assert (a[1].header && a[1].xalign == 0.5f && a[2].header && a[2].xalign == 0);
    assert (a[3].bold);
    // модификатор после пробела — текст, как у сервера
    var t = parse_cells ("| {color:red}. x |");
    assert (t[0].text == "{color:red}. x" && t[0].fg == null);
    // пустая строка таблицы: ячейки есть, текст пустой — высоту держит рендер
    var e = parse ("|_. A |_. B |
|  |  |");
    assert (e[1].kind == Kind.ROW && e[1].cells.length == 2 && e[1].cells[0].text == "" && e[1].cells[1].text == "");
    // строка под пунктом списка — продолжение пункта, «h2.» там не заголовок
    var li = parse ("* Тест
h2. X
Y");
    assert (li.length == 1 && li[0].kind == Kind.ITEM && li[0].text == "Тест\nh2. X\nY");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/textile/blocks", test_blocks);
    Test.add_func ("/textile/quotes", test_quotes);
    Test.add_func ("/textile/inline", test_inline);
    Test.add_func ("/textile/cells", test_cells);
    Test.add_func ("/textile/mentions", test_mentions);
    Test.add_func ("/textile/preview", test_preview);
    Test.add_func ("/textile/flow", test_flow);
    return Test.run ();
}
