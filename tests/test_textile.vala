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
    assert (inline_markup ("a@b.com or c@d.com") == "a@b.com or c@d.com");
    assert (inline_markup ("well-known --force") == "well-known --force");
    assert (inline_markup ("см. #123") == "см. <a href=\"issue:123\">#123</a>");
    assert (inline_markup ("#123#note-5") == "<a href=\"issue:123:5\">#123#note-5</a>");
    assert (inline_markup ("#note-7") == "<a href=\"note:7\">#note-7</a>");
    assert (inline_markup ("https://x.ru/a_b_c.") == "<a href=\"https://x.ru/a_b_c\">https://x.ru/a_b_c</a>.");
    assert (inline_markup ("\"сайт\":https://x.ru") == "<a href=\"https://x.ru\">сайт</a>");
    assert (inline_markup ("@code@") .contains ("monospace"));
    assert (inline_markup ("a < b & c") == "a &lt; b &amp; c");
    // упоминание с известным логином — ссылка на человека
    string? look (string l) { return l == "ivanov" ? "42|Иван Иванов" : null; }
    assert (inline_markup ("привет @ivanov.", look) == "привет <a href=\"user:42\">@Иван Иванов</a>.");
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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/textile/blocks", test_blocks);
    Test.add_func ("/textile/quotes", test_quotes);
    Test.add_func ("/textile/inline", test_inline);
    Test.add_func ("/textile/mentions", test_mentions);
    Test.add_func ("/textile/preview", test_preview);
    return Test.run ();
}
