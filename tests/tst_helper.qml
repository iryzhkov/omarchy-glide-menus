import QtQuick
import QtTest
import "../Helper.js" as Helper

// The shape of what the harness builds. What it actually does when executed --
// deadlines, cancellation, leaving nothing behind -- is checked for real in
// tests/supervisor.sh, which runs the script under bash.
TestCase {
    name: "Helper"

    readonly property var env: ({
            HOME: "/home/tester",
            USER: "tester",
            XDG_RUNTIME_DIR: "/run/user/1000",
            HYPRLAND_INSTANCE_SIGNATURE: "sig123",
            WAYLAND_DISPLAY: "wayland-1",
            OMARCHY_PATH: "/usr/share/omarchy"
        })

    function test_command_clears_the_environment_and_rebuilds_it() {
        var argv = Helper.command(5, "true", env);
        compare(argv[0], "/usr/bin/env");
        // -i is the whole point: nothing from the session's profile survives
        // except what is named right after it.
        compare(argv[1], "-i");
        verify(argv.indexOf("HOME=/home/tester") > 0);
        verify(argv.indexOf("USER=tester") > 0);
        verify(argv.indexOf("XDG_RUNTIME_DIR=/run/user/1000") > 0);
        verify(argv.indexOf("HYPRLAND_INSTANCE_SIGNATURE=sig123") > 0);
        verify(argv.indexOf("WAYLAND_DISPLAY=wayland-1") > 0);
        verify(argv.indexOf("OMARCHY_PATH=/usr/share/omarchy") > 0);
    }

    function test_command_uses_absolute_executables_only() {
        var argv = Helper.command(5, "true", env);
        for (var i = 0; i < argv.length; i++) {
            // Every element that names a program is an absolute path; the rest
            // are assignments, flags, or the script and its arguments.
            if (argv[i].indexOf("/") === 0)
                verify(argv[i].indexOf("/usr/") === 0 || argv[i].indexOf("/bin/") === 0 || argv[i].indexOf("/home/") === 0 || argv[i].indexOf("/run/") === 0);
        }
        verify(argv.indexOf("/bin/bash") > 0);
    }

    function test_command_passes_the_deadline_and_body_as_arguments() {
        // Never spliced into the supervisor: the script text is an argument, so
        // nothing in it can be read as supervisor syntax.
        var argv = Helper.command(7, "echo $(whoami)", env);
        var bashAt = argv.indexOf("/bin/bash");
        compare(argv[bashAt + 1], "-c");
        compare(argv[bashAt + 2], Helper.SUPERVISOR);
        compare(argv[bashAt + 3], "glide-menus-helper");
        compare(argv[bashAt + 4], "7");
        compare(argv[bashAt + 5], "echo $(whoami)");
    }

    function test_command_survives_a_missing_environment() {
        var argv = Helper.command(5, "true", undefined);
        // Absent values become empty assignments rather than inherited ones.
        verify(argv.indexOf("HOME=") > 0);
        verify(argv.indexOf("USER=") > 0);
    }

    function test_boundedBody_caps_one_byte_past_the_ceiling() {
        // head takes capBytes + 1 so that "we read one more than allowed" is
        // distinguishable from "the output was exactly at the ceiling".
        var body = Helper.boundedBody("cat /etc/passwd", 256);
        verify(body.indexOf("/usr/bin/head -c 257") >= 0);
        verify(body.indexOf("/usr/bin/tee /dev/fd/4") >= 0);
        verify(body.indexOf("/usr/bin/wc -c") >= 0);
        verify(body.indexOf("cat /etc/passwd") >= 0);
    }

    function test_boundedBody_reports_overflow_out_of_band() {
        var body = Helper.boundedBody("true", 256);
        // The verdict is an exit status, never a marker in the data stream.
        verify(body.indexOf("exit " + Helper.OVERFLOW_EXIT) >= 0);
        verify(body.indexOf('[ "$n" -gt 256 ]') >= 0);
    }

    function test_pipeline_is_command_around_boundedBody() {
        var argv = Helper.pipeline(5, "true", 256, env);
        var bashAt = argv.indexOf("/bin/bash");
        compare(argv[bashAt + 5], Helper.boundedBody("true", 256));
    }

    function test_runUsable_fails_closed() {
        verify(Helper.runUsable(0, 0));
        // Everything else: a failing helper, a deadline kill, an overflow, the
        // supervisor's own giving up, a crash.
        verify(!Helper.runUsable(1, 0));
        verify(!Helper.runUsable(124, 0));
        verify(!Helper.runUsable(Helper.OVERFLOW_EXIT, 0));
        verify(!Helper.runUsable(Helper.SUPERVISOR_EXIT, 0));
        verify(!Helper.runUsable(0, 1));
    }

    function test_shellQuoted_survives_a_quote() {
        compare(Helper.shellQuoted("plain"), "'plain'");
        compare(Helper.shellQuoted("it's"), "'it'\\''s'");
        compare(Helper.shellQuoted("$(whoami)"), "'$(whoami)'");
    }
}
