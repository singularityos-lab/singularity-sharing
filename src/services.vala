namespace Singularity.Sharing {

    public interface FileSharingBackend : Object {
        public abstract string id { get; }
        public abstract bool available ();
        public abstract async void start (string[] folders, bool read_only, uint port, string address) throws Error;
        public abstract void stop ();
        public abstract string address { owned get; }
        public abstract void set_password (string password);
    }

    public class WebDavBackend : Object, FileSharingBackend {
        private Identity identity;
        private WebDavServer? server = null;
        private uint listening_port = 0;
        private string password = "";

        public string id { get { return "webdav"; } }

        public WebDavBackend (Identity identity) {
            this.identity = identity;
        }

        public bool available () {
            return true;
        }

        public async void start (string[] folders, bool read_only, uint port, string address) throws Error {
            if (server == null || listening_port != port) {
                stop ();
                server = new WebDavServer (identity.certificate, folders);
                server.set_password (password);
                server.listen (port, address);
                listening_port = port;
            } else {
                server.set_folders (folders);
            }
            server.read_only = read_only;
        }

        public void stop () {
            if (server != null) server.stop ();
            server = null;
            listening_port = 0;
        }

        public void set_password (string password) {
            this.password = password;
            if (server != null) server.set_password (password);
        }

        public string address {
            owned get {
                if (server == null) return "";
                return "davs://%s.local:%u/".printf (Config.host_name (), server.port);
            }
        }
    }

    public class SambaBackend : Object, FileSharingBackend {
        private string command;
        private string[] created = {};

        public string id { get { return "samba"; } }

        public SambaBackend (string command) {
            this.command = command;
        }

        public bool available () {
            string? net = Config.find_program (command);
            if (net == null) return false;
            try {
                int status;
                Process.spawn_sync (null, { net, "usershare", "info" }, null, SpawnFlags.STDOUT_TO_DEV_NULL
                    | SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, out status);
                return Process.if_exited (status) && Process.exit_status (status) == 0;
            } catch (Error e) {
                return false;
            }
        }

        public static string share_name (string folder) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            string base_name = Path.get_basename (folder);
            while (base_name.get_next_char (ref i, out c)) {
                if (c.isalnum () || c == '-' || c == '_') sb.append_unichar (c);
                else if (c == ' ') sb.append_c ('_');
            }
            return sb.len > 0 ? sb.str.substring (0, int.min ((int) sb.len, 32)) : "Folder";
        }

        public async void start (string[] folders, bool read_only, uint port, string address) throws Error {
            stop ();
            string? net = Config.find_program (command);
            if (net == null) throw new IOError.NOT_FOUND (_("Samba is not installed."));
            foreach (string folder in folders) {
                string name = share_name (folder);
                var proc = new Subprocess.newv ({ net, "usershare", "add", name, folder, _("Shared from Singularity"),
                    read_only ? "Everyone:R" : "Everyone:F", "guest_ok=n" }, SubprocessFlags.STDERR_PIPE);
                string? err;
                yield proc.communicate_utf8_async (null, null, null, out err);
                if (!proc.get_successful ()) throw new IOError.FAILED ((err ?? "").strip ());
                created += name;
            }
        }

        public void stop () {
            string? net = Config.find_program (command);
            if (net != null) {
                foreach (string name in created) {
                    try {
                        Process.spawn_sync (null, { net, "usershare", "delete", name }, null,
                            SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, null);
                    } catch (Error e) {
                    }
                }
            }
            created = {};
        }

        public void set_password (string password) {
        }

        public string address {
            owned get { return created.length > 0 ? "smb://%s.local/".printf (Config.host_name ()) : ""; }
        }
    }

    public class MediaSharing : Singularity.SharingHost.MediaServer {
        public MediaSharing (Config config) {
            string? program = null;
            if (config.backend ("MediaSharing") != "none")
                program = Config.find_program (config.get_string ("MediaSharing", "Command", "rygel"));
            Object (program: program, state_dir: Config.state_dir ());
        }

        public void share (string[] folders) {
            start (folders, _("%s on %s").printf (Environment.get_real_name (), Config.host_name ()));
        }
    }
}
