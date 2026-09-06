import QtQuick
import QtTest
import "../Sanitize.js" as Sanitize

TestCase {
    name: "Sanitize"

    function test_boundText_bounds_and_coerces() {
        compare(Sanitize.boundText("abcdef", 3), "abc");
        compare(Sanitize.boundText("ab", 8), "ab");
        compare(Sanitize.boundText(null, 8), "");
        compare(Sanitize.boundText(undefined, 8), "");
        compare(Sanitize.boundText(42, 8), "42");
    }

    function test_finiteNum_clamps_and_falls_back() {
        compare(Sanitize.finiteNum(5, 0, 10, 7), 5);
        compare(Sanitize.finiteNum(-5, 0, 10, 7), 0);
        compare(Sanitize.finiteNum(50, 0, 10, 7), 10);
        compare(Sanitize.finiteNum("nope", 0, 10, 7), 7);
        compare(Sanitize.finiteNum(NaN, 0, 10, 7), 7);
        compare(Sanitize.finiteNum(Infinity, 0, 10, 7), 7);
    }

    function test_sanitizeEntries_caps_the_row_count() {
        var many = [];
        for (var i = 0; i < Sanitize.MAX_MODEL_ITEMS + 500; i++)
            many.push({ id: "e" + i });
        compare(Sanitize.sanitizeEntries(many).length, Sanitize.MAX_MODEL_ITEMS);
    }

    function test_sanitizeEntries_caps_every_string_field() {
        var long = new Array(Sanitize.MAX_FIELD_CHARS + 200).join("x");
        var out = Sanitize.sanitizeEntries([{ id: long, label: long, description: long, action: long }]);
        compare(out[0].id.length, Sanitize.MAX_FIELD_CHARS);
        compare(out[0].label.length, Sanitize.MAX_FIELD_CHARS);
        compare(out[0].description.length, Sanitize.MAX_FIELD_CHARS);
        compare(out[0].action.length, Sanitize.MAX_FIELD_CHARS);
    }

    function test_sanitizeEntries_caps_aliases_in_count_and_width() {
        var aliases = [];
        for (var i = 0; i < 40; i++)
            aliases.push(new Array(Sanitize.MAX_FIELD_CHARS + 10).join("y"));
        var out = Sanitize.sanitizeEntries([{ id: "e", aliases: aliases }]);
        compare(out[0].aliases.length, Sanitize.MAX_ALIASES);
        compare(out[0].aliases[0].length, Sanitize.MAX_FIELD_CHARS);
    }

    function test_sanitizeEntries_leaves_short_content_alone() {
        var out = Sanitize.sanitizeEntries([{ id: "a", label: "Power", aliases: ["off"] }]);
        compare(out.length, 1);
        compare(out[0].label, "Power");
        compare(out[0].aliases[0], "off");
    }

    function test_sanitizeEntries_tolerates_junk() {
        compare(Sanitize.sanitizeEntries(null).length, 0);
        compare(Sanitize.sanitizeEntries("not a list").length, 0);
        // A null row stays a null row rather than throwing; the model skips it.
        compare(Sanitize.sanitizeEntries([null, { id: "a" }]).length, 2);
    }

    function test_parseMenuText_refuses_an_oversized_source() {
        // Built just past the ceiling: refused without being parsed at all.
        var huge = new Array(Sanitize.MAX_MENU_FILE_BYTES + 2).join("z");
        ignoreWarning(/menu source over/);
        compare(Sanitize.parseMenuText(huge).length, 0);
    }

    function test_parseMenuText_parses_a_normal_source() {
        var items = Sanitize.parseMenuText('{ "power": { "label": "Power" } }');
        verify(items.length > 0);
    }

    function test_parseMenuText_tolerates_nothing() {
        compare(Sanitize.parseMenuText("").length, 0);
        compare(Sanitize.parseMenuText(null).length, 0);
    }

    function test_sanitizeOptions_caps_count_and_width() {
        var many = [];
        for (var i = 0; i < Sanitize.MAX_DMENU_OPTIONS + 100; i++)
            many.push("opt");
        compare(Sanitize.sanitizeOptions(many).length, Sanitize.MAX_DMENU_OPTIONS);

        var wide = [new Array(Sanitize.MAX_OPTION_CHARS + 50).join("w")];
        compare(Sanitize.sanitizeOptions(wide)[0].length, Sanitize.MAX_OPTION_CHARS);

        compare(Sanitize.sanitizeOptions(null).length, 0);
    }

    function test_resultPath_requires_an_absolute_path() {
        compare(Sanitize.resultPath("/tmp/glide.XXXX"), "/tmp/glide.XXXX");
        // Relative would resolve against this process's working directory,
        // which is not the caller's.
        compare(Sanitize.resultPath("tmp/glide"), "");
        compare(Sanitize.resultPath(""), "");
        compare(Sanitize.resultPath(null), "");
    }

    function test_resultPath_refuses_a_newline_or_a_nul() {
        compare(Sanitize.resultPath("/tmp/a\nb"), "");
        compare(Sanitize.resultPath("/tmp/a" + String.fromCharCode(0) + "b"), "");
    }

    function test_resultPath_bounds_length() {
        var long = "/" + new Array(Sanitize.MAX_PATH_CHARS + 100).join("p");
        compare(Sanitize.resultPath(long).length, Sanitize.MAX_PATH_CHARS);
    }
}
