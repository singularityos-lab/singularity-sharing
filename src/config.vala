namespace Singularity.Sharing {

    [CCode (cname = "SHARING_SYSCONFDIR")]
    extern const string SYSCONFDIR;
    [CCode (cname = "SHARING_CONSENT_HELPER")]
    extern const string CONSENT_HELPER;

    public class Config : Object {
        public const string FILE_NAME = "singularity/sharing.conf";

        private KeyFile keyfile = new KeyFile ();

        public string? source_path { get; private set; default = null; }

        public Config () {
            foreach (string dir in search_dirs ()) {
                string path = Path.build_filename (dir, FILE_NAME);
                if (FileUtils.test (path, FileTest.IS_REGULAR) && load (path)) return;
            }
        }

        public Config.from_file (string path) {
            load (path);
        }

        public static string[] search_dirs () {
            string[] dirs = {};
            foreach (unowned string dir in Environment.get_system_config_dirs ()) dirs += dir;
            dirs += SYSCONFDIR;
            return dirs;
        }

        private bool load (string path) {
            try {
                keyfile.load_from_file (path, KeyFileFlags.NONE);
                source_path = path;
                return true;
            } catch (Error e) {
                warning ("Cannot read %s: %s", path, e.message);
                keyfile = new KeyFile ();
                return false;
            }
        }

        public string get_string (string group, string key, string fallback) {
            try {
                if (keyfile.has_group (group) && keyfile.has_key (group, key)) {
                    string value = keyfile.get_string (group, key).strip ();
                    return value;
                }
            } catch (Error e) {
                warning ("[%s] %s: %s", group, key, e.message);
            }
            return fallback;
        }

        public string backend (string group) {
            return get_string (group, "Backend", "auto").down ();
        }

        public static string? find_program (string command) {
            if (command == "") return null;
            if (Path.is_absolute (command)) return FileUtils.test (command, FileTest.IS_EXECUTABLE) ? command : null;
            return Environment.find_program_in_path (command);
        }

        public static string host_name () {
            string contents;
            try {
                if (FileUtils.get_contents ("/proc/sys/kernel/hostname", out contents) && contents.strip () != "")
                    return contents.strip ();
            } catch (Error e) {
            }
            return Environment.get_host_name ();
        }

        public static string consent_helper () {
            if (FileUtils.test (CONSENT_HELPER, FileTest.IS_EXECUTABLE)) return CONSENT_HELPER;
            return Environment.find_program_in_path ("singularity-portal-consent") ?? CONSENT_HELPER;
        }

        private static GLib.Settings? _settings = null;

        public static GLib.Settings settings () {
            if (_settings == null) _settings = new GLib.Settings ("dev.sinty.sharing");
            return _settings;
        }

        public static string state_dir () {
            string dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "sharing");
            DirUtils.create_with_parents (dir, 0700);
            return dir;
        }
    }
}
