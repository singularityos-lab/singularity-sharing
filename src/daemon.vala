namespace Singularity.Sharing {

    [DBus (name = "dev.sinty.Sharing1")]
    public class Service : Object {
        private weak Daemon daemon;

        public signal void changed ();

        public Service (Daemon daemon) {
            this.daemon = daemon;
        }

        public HashTable<string, Variant> get_state () throws Error {
            return daemon.state ();
        }

        public async void set_password (string kind, string password) throws Error {
            if (!Secrets.valid_kind (kind)) throw new IOError.INVALID_ARGUMENT ("unknown password kind");
            if (password.char_count () < 6) throw new IOError.INVALID_ARGUMENT (_("Use at least 6 characters."));
            yield Secrets.store (kind, password);
            yield daemon.reload_passwords ();
        }

        public async void clear_password (string kind) throws Error {
            if (!Secrets.valid_kind (kind)) throw new IOError.INVALID_ARGUMENT ("unknown password kind");
            yield Secrets.clear (kind);
            yield daemon.reload_passwords ();
        }

        public void stop_session (uint id) throws Error {
            if (!daemon.remote.stop_session (id)) throw new IOError.NOT_FOUND ("no such session");
        }

        public void stop_all_sessions () throws Error {
            daemon.remote.stop_all ();
        }

        public void accept_connection (UnixInputStream socket, string peer) throws Error {
            if (!Config.settings ().get_boolean ("remote-desktop-enabled") || !daemon.remote.available)
                throw new IOError.NOT_SUPPORTED ("Remote Desktop is off");
            int fd = Posix.dup (socket.fd);
            if (fd < 0) throw new IOError.FAILED ("cannot take the connection");
            var sock = new Socket.from_fd (fd);
            if (sock.family != SocketFamily.IPV4 && sock.family != SocketFamily.IPV6 && sock.family != SocketFamily.UNIX)
                throw new IOError.INVALID_ARGUMENT ("not a stream socket");
            string label = peer.strip () != "" ? peer.strip () : _("a relayed connection");
            daemon.remote.adopt (SocketConnection.factory_create_connection (sock), label);
        }
    }

    public class Daemon : Object {
        public Config config { get; private set; }
        public Identity identity { get; private set; }
        public RemoteDesktopServer remote { get; private set; }
        public MediaSharing media { get; private set; }
        public Announcements announcements { get; private set; }

        private FileSharingBackend? files = null;
        private string file_error = "";
        private bool file_active = false;
        private bool has_rd_password = false;
        private bool has_files_password = false;
        private Service service;
        private uint changed_idle = 0;

        public Daemon () throws Error {
            config = new Config ();
            identity = new Identity ();
            remote = new RemoteDesktopServer (identity);
            media = new MediaSharing (config);
            announcements = new Announcements (config);
            files = pick_file_backend ();
            service = new Service (this);
            remote.sessions_changed.connect (emit_changed);
            remote.screens_changed.connect (emit_changed);
            announcements.changed.connect (emit_changed);
            remote.notify.connect (emit_changed);
            media.notify.connect (emit_changed);
            Config.settings ().changed.connect ((key) => apply.begin ());
        }

        private FileSharingBackend? pick_file_backend () {
            string choice = config.backend ("FileSharing");
            var samba = new SambaBackend (config.get_string ("FileSharing", "SambaCommand", "net"));
            switch (choice) {
                case "none": return null;
                case "samba": return samba;
                case "webdav": return new WebDavBackend (identity);
                default:
                    if (Config.settings ().get_string ("file-sharing-protocol") == "samba" && samba.available ()) return samba;
                    return new WebDavBackend (identity);
            }
        }

        public void register (DBusConnection connection) throws Error {
            connection.register_object ("/dev/sinty/Sharing", service);
        }

        private void emit_changed () {
            if (changed_idle != 0) return;
            changed_idle = Idle.add (() => {
                changed_idle = 0;
                service.changed ();
                return Source.REMOVE;
            });
        }

        public async void reload_passwords () {
            string? rd = yield Secrets.lookup (Secrets.REMOTE_DESKTOP);
            string? fs = yield Secrets.lookup (Secrets.FILE_SHARING);
            has_rd_password = rd != null && rd != "";
            has_files_password = fs != null && fs != "";
            if (files != null) files.set_password (fs ?? "");
            emit_changed ();
        }

        public async void apply () {
            var s = Config.settings ();
            remote.default_control = !s.get_boolean ("remote-desktop-view-only");
            remote.default_screen = s.get_string ("remote-desktop-screen");
            if (s.get_boolean ("remote-desktop-enabled")) remote.start (s.get_uint ("remote-desktop-port"), config.get_string ("RemoteDesktop", "ListenAddress", ""));
            else remote.stop ();
            announcements.set_service (Announcements.REMOTE_DESKTOP, remote.listening, remote.port, Config.host_name ());

            if (media.available && s.get_boolean ("media-sharing-enabled")) media.share (s.get_strv ("media-folders"));
            else media.stop ();

            var wanted_backend = pick_file_backend ();
            if (files != null && wanted_backend != null && files.id != wanted_backend.id) {
                files.stop ();
                files = wanted_backend;
                yield reload_passwords ();
            }
            string[] folders = s.get_strv ("shared-folders");
            if (files != null && s.get_boolean ("file-sharing-enabled") && folders.length > 0) {
                try {
                    yield files.start (folders, s.get_boolean ("file-sharing-read-only"), s.get_uint ("file-sharing-port"),
                        config.get_string ("FileSharing", "ListenAddress", ""));
                    file_active = true;
                    file_error = "";
                } catch (Error e) {
                    file_active = false;
                    file_error = e.message;
                    files.stop ();
                }
            } else if (files != null) {
                files.stop ();
                file_active = false;
                file_error = "";
            }
            announcements.set_service (Announcements.FILE_SHARING, file_active && files != null && files.id == "webdav",
                s.get_uint ("file-sharing-port"), Config.host_name (),
                { "path=/" });
            emit_changed ();
        }

        public void shutdown () {
            announcements.shutdown ();
            remote.stop ();
            media.stop ();
            if (files != null) files.stop ();
        }

        public HashTable<string, Variant> state () {
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            t["FileSharingBackend"] = files != null ? files.id : "";
            t["FileSharingActive"] = file_active;
            t["FileSharingAddress"] = files != null && file_active ? files.address : "";
            t["FileSharingError"] = file_error;
            t["FileSharingHasPassword"] = has_files_password;
            t["SambaAvailable"] = new SambaBackend (config.get_string ("FileSharing", "SambaCommand", "net")).available ();
            t["MediaSharingAvailable"] = media.available;
            t["MediaSharingBackend"] = media.backend;
            t["MediaSharingActive"] = media.active;
            t["MediaSharingError"] = media.error;
            t["RemoteDesktopAvailable"] = remote.available;
            t["RemoteDesktopActive"] = remote.listening;
            t["RemoteDesktopProtocol"] = "vnc";
            t["RemoteDesktopPort"] = remote.port;
            t["RemoteDesktopAddress"] = remote.listening
                ? "vnc://%s.local:%u".printf (Config.host_name (), remote.port) : "";
            t["RemoteDesktopFingerprint"] = identity.fingerprint;
            t["RemoteDesktopError"] = remote.error;
            t["RemoteDesktopHasPassword"] = has_rd_password;
            t["RemoteDesktopScreen"] = remote.default_screen;
            t["RemoteDesktopKeyboard"] = remote.keyboard_layouts ();
            var screens = new VariantBuilder (new VariantType ("a(ssiiiid)"));
            foreach (var info in remote.screens ())
                screens.add ("(ssiiiid)", info.id, info.label, info.x, info.y, info.width, info.height, info.scale);
            t["Screens"] = screens.end ();
            t["AnnounceBackend"] = announcements.backend;
            t["Announced"] = new Variant.strv (announcements.published);
            t["NetworkProfileHome"] = announcements.home;
            t["UserName"] = Environment.get_user_name ();
            var sessions = new VariantBuilder (new VariantType ("a(ussbbx)"));
            foreach (var c in remote.sessions ())
                sessions.add ("(ussbbx)", c.id, c.peer, "vnc", c.control, c.clipboard, c.started);
            t["Sessions"] = sessions.end ();
            return t;
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            var loop = new MainLoop ();
            Daemon daemon;
            try {
                daemon = new Daemon ();
            } catch (Error e) {
                printerr ("singularity-sharing: %s\n", e.message);
                return 1;
            }
            Bus.own_name (BusType.SESSION, "dev.sinty.Sharing", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        daemon.register (conn);
                    } catch (Error e) {
                        printerr ("singularity-sharing: %s\n", e.message);
                        loop.quit ();
                    }
                },
                () => {
                    daemon.reload_passwords.begin ((o, r) => {
                        daemon.reload_passwords.end (r);
                        daemon.apply.begin ();
                    });
                },
                () => {
                    printerr ("singularity-sharing: another instance owns dev.sinty.Sharing\n");
                    loop.quit ();
                });
            Unix.signal_add (Posix.Signal.TERM, () => {
                loop.quit ();
                return Source.REMOVE;
            });
            Unix.signal_add (Posix.Signal.INT, () => {
                loop.quit ();
                return Source.REMOVE;
            });
            loop.run ();
            daemon.shutdown ();
            return 0;
        }
    }
}
