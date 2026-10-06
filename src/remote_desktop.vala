namespace Singularity.Sharing {

    public class RemoteDesktopServer : Object {
        public const uint DENY_COOLDOWN_SECONDS = 30;

        public Identity identity { get; private set; }
        public bool listening { get; private set; default = false; }
        public string error { get; private set; default = ""; }
        public uint port { get; private set; default = 0; }
        public bool available { get; private set; default = false; }
        public bool default_control { get; set; default = true; }
        public string default_screen { get; set; default = ScreenFeed.ALL; }

        public signal void sessions_changed ();
        public signal void screens_changed ();

        private Rd.Display? display = null;
        private SocketService? service = null;
        private Gee.ArrayList<RfbConnection> connections = new Gee.ArrayList<RfbConnection> ();
        private Gee.HashMap<string, ScreenFeed> feeds = new Gee.HashMap<string, ScreenFeed> ();
        private uint next_id = 1;
        private bool consent_running = false;
        private Gee.HashMap<string, int64?> denied = new Gee.HashMap<string, int64?> ();
        private string? pending_clipboard_mime = null;
        private uint screens_idle = 0;

        public RemoteDesktopServer (Identity identity) {
            this.identity = identity;
            probe ();
        }

        private bool probe () {
            if (display == null) {
                try {
                    display = new Rd.Display ();
                    display.watch_clipboard (on_clipboard);
                    display.watch_outputs (on_outputs);
                } catch (Error e) {
                    error = e.message;
                    available = false;
                    return false;
                }
            }
            available = display.can_capture ();
            if (!available) error = _("This compositor cannot share its screen.");
            return available;
        }

        private void on_outputs () {
            if (screens_idle != 0) return;
            screens_idle = Idle.add (() => {
                screens_idle = 0;
                screens_changed ();
                return Source.REMOVE;
            });
        }

        public ScreenInfo[] screens () {
            ScreenInfo[] list = {};
            if (display == null) return list;
            foreach (string name in display.get_outputs ()) {
                string description;
                int x, y, w, h;
                double scale;
                if (display.get_output_info (name, out description, out x, out y, out w, out h, out scale))
                    list += new ScreenInfo (name, description, x, y, w, h, scale);
            }
            return list;
        }

        public string resolve_screen (string wanted) {
            if (wanted == ScreenFeed.ALL || wanted == "") return ScreenFeed.ALL;
            foreach (var s in screens ()) if (s.id == wanted) return wanted;
            return ScreenFeed.ALL;
        }

        public string keyboard_layouts () {
            return display != null ? display.get_keymap_layouts () : "";
        }

        public Gee.List<RfbConnection> sessions () {
            var list = new Gee.ArrayList<RfbConnection> ();
            foreach (var c in connections) if (c.active) list.add (c);
            return list;
        }

        public void start (uint port, string address = "") {
            if (listening && this.port == port) return;
            stop ();
            if (!probe ()) return;
            service = new SocketService ();
            try {
                if (address != "") {
                    var inet = new InetSocketAddress.from_string (address, port);
                    if (inet == null) throw new IOError.INVALID_ARGUMENT ("invalid address %s", address);
                    SocketAddress effective;
                    service.add_address (inet, SocketType.STREAM, SocketProtocol.TCP, null, out effective);
                } else {
                    service.add_inet_port ((uint16) port, null);
                }
            } catch (Error e) {
                error = _("Cannot listen on port %u: %s").printf (port, e.message);
                service = null;
                notify_property ("error");
                return;
            }
            service.incoming.connect (on_incoming);
            service.start ();
            this.port = port;
            error = "";
            listening = true;
        }

        public void stop () {
            if (service != null) {
                service.stop ();
                service.close ();
                service = null;
            }
            listening = false;
            stop_all ();
        }

        public void stop_all () {
            foreach (var c in connections.to_array ()) c.close ();
        }

        public bool stop_session (uint id) {
            foreach (var c in connections) {
                if (c.id == id) {
                    c.close ();
                    return true;
                }
            }
            return false;
        }

        private bool on_incoming (SocketConnection socket, Object? source) {
            string peer = "unknown";
            try {
                var address = socket.get_remote_address () as InetSocketAddress;
                if (address != null) peer = address.address.to_string ();
            } catch (Error e) {
            }
            if (peer.has_prefix ("::ffff:")) peer = peer.substring (7);
            if (denied.has_key (peer) && denied[peer] > get_monotonic_time ()) {
                socket.close_async.begin ();
                return true;
            }
            try {
                socket.socket.set_option (6, 1, 1);
            } catch (Error e) {
            }
            adopt (socket, peer);
            return true;
        }

        public void adopt (SocketConnection socket, string peer) {
            var conn = new RfbConnection (this, next_id++, socket, peer);
            connections.add (conn);
            conn.authorized.connect (() => {
                message ("Remote Desktop session %u from %s started (control %s, screen %s)", conn.id, conn.peer,
                    conn.control ? "yes" : "no", conn.screen);
                sessions_changed ();
            });
            conn.finished.connect (() => {
                bool was_session = conn.started != 0;
                connections.remove (conn);
                release_feeds ();
                if (display != null && !any_control ()) display.release_all ();
                if (was_session) {
                    message ("Remote Desktop session %u from %s ended after sending %s bytes", conn.id, conn.peer,
                        conn.bytes_sent.to_string ());
                    sessions_changed ();
                }
            });
            conn.run.begin ();
        }

        private bool any_control () {
            foreach (var c in connections) if (c.active && c.control) return true;
            return false;
        }

        public async bool has_unattended_password () {
            var settings = Config.settings ();
            if (!settings.get_boolean ("remote-desktop-unattended")) return false;
            string? secret = yield Secrets.lookup (Secrets.REMOTE_DESKTOP);
            return secret != null && secret != "";
        }

        public async bool check_password (string user, string password) {
            if (!(yield has_unattended_password ())) return false;
            string? secret = yield Secrets.lookup (Secrets.REMOTE_DESKTOP);
            bool user_ok = user == "" || user == Environment.get_user_name ();
            return user_ok && secret != null && Secrets.equal (secret, password);
        }

        public async ConsentAnswer? request_consent (RfbConnection conn, Cancellable cancellable) {
            if (consent_running) return null;
            consent_running = true;
            var answer = yield Consent.ask (conn.peer, default_control, true, screens (),
                resolve_screen (default_screen), cancellable);
            consent_running = false;
            if (!answer.allowed) denied[conn.peer] = get_monotonic_time () + DENY_COOLDOWN_SECONDS * 1000000;
            return answer;
        }

        public ScreenFeed? feed_for (string wanted) {
            if (display == null || !display.can_capture ()) return null;
            string id = resolve_screen (wanted);
            var feed = feeds[id];
            if (feed != null && !feed.stopped) return feed;
            if (feed != null) feeds.unset (id);
            feed = new ScreenFeed (display, id);
            if (feed.stopped) return null;
            feeds[id] = feed;
            unowned ScreenFeed ended_feed = feed;
            feed.ended.connect (() => {
                foreach (var c in connections.to_array ()) if (c.uses (ended_feed)) c.close ();
                if (feeds[ended_feed.output] == ended_feed) feeds.unset (ended_feed.output);
            });
            return feed;
        }

        private void release_feeds () {
            foreach (var id in feeds.keys.to_array ()) {
                var feed = feeds[id];
                bool used = !feed.idle ();
                foreach (var c in connections) if (c.uses (feed)) used = true;
                if (!used) {
                    feeds.unset (id);
                    feed.close ();
                }
            }
        }

        public void pointer_button (uint32 code, bool pressed) {
            if (display != null) display.pointer_button (code, pressed);
        }

        public void scroll (uint32 axis, int steps) {
            if (display != null) display.pointer_axis_discrete (axis, steps);
        }

        public void key_event (uint32 keysym, bool pressed) {
            if (display != null && !display.keysym (keysym, pressed))
                debug ("No key for keysym 0x%x", keysym);
        }

        public void client_cut_text (RfbConnection from, string text) {
            if (display == null || !display.can_clipboard ()) return;
            display.set_clipboard_text (text);
            foreach (var c in connections) if (c != from) c.send_cut_text (text);
        }

        private void on_clipboard (string[] mime_types, bool own) {
            if (own || display == null) return;
            string? mime = display.text_mime_type ();
            if (mime == null) return;
            bool wanted = false;
            foreach (var c in connections) if (c.active && c.clipboard) wanted = true;
            if (!wanted) return;
            pending_clipboard_mime = mime;
            read_clipboard.begin (mime);
        }

        private async void read_clipboard (string mime) {
            int fds[2];
            if (Posix.pipe (fds) != 0) return;
            Posix.fcntl (fds[0], Posix.F_SETFD, Posix.FD_CLOEXEC);
            Posix.fcntl (fds[1], Posix.F_SETFD, Posix.FD_CLOEXEC);
            display.receive_clipboard (mime, fds[1]);
            var stream = new UnixInputStream (fds[0], true);
            var data = new ByteArray ();
            var buf = new uint8[65536];
            try {
                while (data.len < Rfb.MAX_CUT_TEXT) {
                    ssize_t n = yield stream.read_async (buf);
                    if (n <= 0) break;
                    data.append (buf[0:n]);
                }
            } catch (Error e) {
                return;
            }
            if (pending_clipboard_mime != mime) return;
            string text = Rfb.text (data.data);
            if (!text.validate ()) return;
            foreach (var c in connections) c.send_cut_text (text);
        }
    }
}
