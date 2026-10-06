namespace Singularity.Sharing {

    public class ConsentAnswer : Object {
        public bool allowed { get; set; default = false; }
        public bool control { get; set; default = false; }
        public bool clipboard { get; set; default = false; }
        public string screen { get; set; default = ""; }
    }

    public class Consent : Object {
        public const uint TIMEOUT_SECONDS = 60;

        public static string request_json (string peer, bool control, bool clipboard, ScreenInfo[] screens = {},
                                           string screen = ScreenFeed.ALL) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("version").add_int_value (1);
            builder.set_member_name ("kind").add_string_value ("remote");
            builder.set_member_name ("app_id").add_string_value ("");
            builder.set_member_name ("app_name").add_string_value (_("Remote Desktop"));
            builder.set_member_name ("icon").add_string_value ("preferences-desktop-remote-desktop");
            builder.set_member_name ("title").add_string_value (_("Share This Screen?"));
            builder.set_member_name ("subtitle").add_string_value (
                _("A computer at %s wants to connect with Remote Desktop.").printf (peer));
            builder.set_member_name ("body").add_string_value (
                _("Allow only people you know. You can stop sharing at any time from the top bar."));
            builder.set_member_name ("grant_label").add_string_value (_("Allow"));
            builder.set_member_name ("deny_label").add_string_value (_("Deny"));
            builder.set_member_name ("items");
            builder.begin_array ();
            add_item (builder, "control", _("Allow Control"), _("Use the mouse and keyboard of this computer"), control);
            add_item (builder, "clipboard", _("Share Clipboard"), _("Copy and paste between both computers"), clipboard);
            builder.end_array ();
            if (screens.length > 1) {
                builder.set_member_name ("choice_title").add_string_value (_("Screen"));
                builder.set_member_name ("choice").add_string_value (screen);
                builder.set_member_name ("choices");
                builder.begin_array ();
                add_choice (builder, ScreenFeed.ALL, _("All Screens"), _("Every screen, arranged as in Displays"));
                foreach (var s in screens) add_choice (builder, s.id, s.label, s.detail ());
                builder.end_array ();
            }
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.root = builder.get_root ();
            return generator.to_data (null);
        }

        private static void add_item (Json.Builder builder, string id, string label, string detail, bool selected) {
            builder.begin_object ();
            builder.set_member_name ("id").add_string_value (id);
            builder.set_member_name ("label").add_string_value (label);
            builder.set_member_name ("detail").add_string_value (detail);
            builder.set_member_name ("selected").add_boolean_value (selected);
            builder.end_object ();
        }

        private static void add_choice (Json.Builder builder, string id, string label, string detail) {
            builder.begin_object ();
            builder.set_member_name ("id").add_string_value (id);
            builder.set_member_name ("label").add_string_value (label);
            builder.set_member_name ("detail").add_string_value (detail);
            builder.end_object ();
        }

        public static ConsentAnswer parse_answer (string output) {
            var answer = new ConsentAnswer ();
            string[] lines = output.strip ().split ("\n");
            string line = lines.length > 0 ? lines[lines.length - 1].strip () : "";
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (line);
            } catch (Error e) {
                return answer;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return answer;
            var obj = root.get_object ();
            if (!obj.has_member ("response") || obj.get_int_member ("response") != 0) return answer;
            answer.allowed = true;
            if (obj.has_member ("choice") && obj.get_member ("choice").get_value_type () == typeof (string))
                answer.screen = obj.get_string_member ("choice");
            if (obj.has_member ("selected")) {
                foreach (var node in obj.get_array_member ("selected").get_elements ()) {
                    if (node.get_value_type () != typeof (string)) continue;
                    if (node.get_string () == "control") answer.control = true;
                    if (node.get_string () == "clipboard") answer.clipboard = true;
                }
            }
            return answer;
        }

        public static async ConsentAnswer ask (string peer, bool control, bool clipboard, ScreenInfo[] screens,
                                               string screen, Cancellable? cancellable) {
            Subprocess process;
            try {
                process = new Subprocess.newv ({ Config.consent_helper () },
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            } catch (Error e) {
                warning ("Cannot ask for Remote Desktop consent: %s", e.message);
                return new ConsentAnswer ();
            }
            bool timed_out = false;
            uint timeout_id = Timeout.add_seconds (TIMEOUT_SECONDS, () => {
                timed_out = true;
                process.force_exit ();
                return Source.REMOVE;
            });
            ulong cancelled_id = 0;
            if (cancellable != null) cancelled_id = cancellable.cancelled.connect (() => process.force_exit ());
            string? output = null;
            try {
                yield process.communicate_utf8_async (request_json (peer, control, clipboard, screens, screen), null, out output, null);
            } catch (Error e) {
                output = null;
            }
            if (!timed_out) Source.remove (timeout_id);
            if (cancellable != null) cancellable.disconnect (cancelled_id);
            if (output == null || !process.get_if_exited () || process.get_exit_status () != 0) return new ConsentAnswer ();
            return parse_answer (output);
        }
    }
}
