namespace Singularity.Sharing {

    public errordomain RfbError {
        PROTOCOL,
        DENIED
    }

    public class RfbPixelFormat {
        public int bits_per_pixel = 32;
        public int depth = 24;
        public bool big_endian = false;
        public bool true_color = true;
        public uint16 red_max = 255;
        public uint16 green_max = 255;
        public uint16 blue_max = 255;
        public uint8 red_shift = 16;
        public uint8 green_shift = 8;
        public uint8 blue_shift = 0;

        public void write (ByteArray b) {
            b.append ({ (uint8) bits_per_pixel, (uint8) depth, big_endian ? 1 : 0, true_color ? 1 : 0 });
            Rfb.put16 (b, red_max);
            Rfb.put16 (b, green_max);
            Rfb.put16 (b, blue_max);
            b.append ({ red_shift, green_shift, blue_shift, 0, 0, 0 });
        }

        public static RfbPixelFormat? parse (uint8[] d) {
            var pf = new RfbPixelFormat ();
            pf.bits_per_pixel = d[0];
            pf.depth = d[1];
            pf.big_endian = d[2] != 0;
            pf.true_color = d[3] != 0;
            pf.red_max = Rfb.get16 (d, 4);
            pf.green_max = Rfb.get16 (d, 6);
            pf.blue_max = Rfb.get16 (d, 8);
            pf.red_shift = d[10];
            pf.green_shift = d[11];
            pf.blue_shift = d[12];
            if (!pf.true_color) return null;
            if (pf.bits_per_pixel != 8 && pf.bits_per_pixel != 16 && pf.bits_per_pixel != 32) return null;
            if (pf.red_max == 0 || pf.green_max == 0 || pf.blue_max == 0) return null;
            if (pf.red_shift >= pf.bits_per_pixel || pf.green_shift >= pf.bits_per_pixel
                    || pf.blue_shift >= pf.bits_per_pixel) return null;
            return pf;
        }
    }

    namespace Rfb {
        public const int TILE = 64;
        public const int32 ENC_RAW = 0;
        public const int32 ENC_COPYRECT = 1;
        public const int32 ENC_ZRLE = 16;
        public const int32 ENC_DESKTOP_SIZE = -223;
        public const int32 ENC_EXT_CLIPBOARD = -1063131698;
        public const uint32 CLIP_TEXT = 1;
        public const uint32 CLIP_CAPS = 1 << 24;
        public const uint32 CLIP_REQUEST = 1 << 25;
        public const uint32 CLIP_PEEK = 1 << 26;
        public const uint32 CLIP_NOTIFY = 1 << 27;
        public const uint32 CLIP_PROVIDE = 1 << 28;
        public const uint32 SEC_VENCRYPT = 19;
        public const uint32 VENCRYPT_X509_NONE = 260;
        public const uint32 VENCRYPT_X509_PLAIN = 262;
        public const uint32 MAX_CUT_TEXT = 1024 * 1024;

        public void put16 (ByteArray b, uint16 v) {
            b.append ({ (uint8) (v >> 8), (uint8) v });
        }

        public void put32 (ByteArray b, uint32 v) {
            b.append ({ (uint8) (v >> 24), (uint8) (v >> 16), (uint8) (v >> 8), (uint8) v });
        }

        public uint16 get16 (uint8[] d, int o) {
            return (uint16) (d[o] << 8 | d[o + 1]);
        }

        public uint32 get32 (uint8[] d, int o) {
            return (uint32) d[o] << 24 | (uint32) d[o + 1] << 16 | (uint32) d[o + 2] << 8 | (uint32) d[o + 3];
        }

        public string text (uint8[] d) {
            var sb = new StringBuilder.sized (d.length + 1);
            if (d.length > 0) sb.append_len ((string) d, d.length);
            return sb.str;
        }

        public string latin1_to_utf8 (uint8[] data) {
            var sb = new StringBuilder ();
            foreach (uint8 c in data) {
                if (c == 0) continue;
                sb.append_unichar ((unichar) c);
            }
            return sb.str;
        }

        public uint8[] utf8_to_latin1 (string text) {
            var out = new ByteArray ();
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                if (c == '\r') continue;
                out.append ({ c < 256 ? (uint8) c : (uint8) '?' });
            }
            return out.data;
        }

        public uint8[] zlib_pack (uint8[] data) throws Error {
            var sink = new MemoryOutputStream.resizable ();
            var conv = new ConverterOutputStream (sink, new ZlibCompressor (ZlibCompressorFormat.ZLIB, -1));
            size_t written;
            conv.write_all (data, out written);
            conv.close ();
            var result = sink.steal_data ();
            result.length = (int) sink.get_data_size ();
            return result;
        }

        public uint8[] zlib_unpack (uint8[] data, size_t limit) throws Error {
            var conv = new ConverterInputStream (new MemoryInputStream.from_data (data), new ZlibDecompressor (ZlibCompressorFormat.ZLIB));
            var out = new ByteArray ();
            var buf = new uint8[65536];
            while (true) {
                ssize_t n = conv.read (buf);
                if (n <= 0) break;
                if (out.len + n > limit) throw new RfbError.PROTOCOL ("clipboard data too large");
                out.append (buf[0:n]);
            }
            return out.steal ();
        }

        public uint8[] pack_clipboard_text (string text) throws Error {
            var raw = new ByteArray ();
            string crlf = text.replace ("\r\n", "\n").replace ("\n", "\r\n");
            put32 (raw, crlf.data.length + 1);
            raw.append (crlf.data);
            raw.append ({ 0 });
            return zlib_pack (raw.data);
        }

        public string? unpack_clipboard_text (uint8[] packed) throws Error {
            var raw = zlib_unpack (packed, MAX_CUT_TEXT + 8);
            if (raw.length < 4) return null;
            uint32 n = get32 (raw, 0);
            if (n > raw.length - 4) return null;
            var sb = new StringBuilder ();
            for (int i = 4; i < 4 + n; i++) {
                if (raw[i] == 0) break;
                sb.append_c ((char) raw[i]);
            }
            string text = sb.str;
            if (!text.validate ()) text = text.make_valid ();
            return text.replace ("\r\n", "\n");
        }

        public uint32 button_code (int bit) {
            switch (bit) {
                case 0: return 0x110;
                case 1: return 0x112;
                case 2: return 0x111;
                case 7: return 0x113;
                default: return 0;
            }
        }
    }

    public class DirtyTiles {
        public int width { get; private set; }
        public int height { get; private set; }
        private int columns;
        private int rows;
        private bool[] tiles;

        public DirtyTiles (int width, int height) {
            this.width = width;
            this.height = height;
            columns = (width + Rfb.TILE - 1) / Rfb.TILE;
            rows = (height + Rfb.TILE - 1) / Rfb.TILE;
            tiles = new bool[int.max (columns * rows, 1)];
        }

        public void mark (int x, int y, int w, int h) {
            int x0 = int.max (x, 0) / Rfb.TILE;
            int y0 = int.max (y, 0) / Rfb.TILE;
            int x1 = int.min (x + w, width);
            int y1 = int.min (y + h, height);
            if (x1 <= 0 || y1 <= 0 || w <= 0 || h <= 0) return;
            int cx1 = (x1 - 1) / Rfb.TILE;
            int cy1 = (y1 - 1) / Rfb.TILE;
            for (int r = y0; r <= cy1 && r < rows; r++)
                for (int c = x0; c <= cx1 && c < columns; c++) tiles[r * columns + c] = true;
        }

        public void mark_all () {
            for (int i = 0; i < tiles.length; i++) tiles[i] = true;
        }

        public int[] take (int rx, int ry, int rw, int rh) {
            int[] spans = {};
            for (int r = 0; r < rows; r++) {
                int c = 0;
                while (c < columns) {
                    if (!tiles[r * columns + c]) {
                        c++;
                        continue;
                    }
                    int start = c;
                    while (c < columns && tiles[r * columns + c]) {
                        tiles[r * columns + c] = false;
                        c++;
                    }
                    bool merged = false;
                    for (int i = 0; i < spans.length; i += 4) {
                        if (spans[i] == start && spans[i + 1] == c && spans[i + 3] == r) {
                            spans[i + 3] = r + 1;
                            merged = true;
                            break;
                        }
                    }
                    if (!merged) {
                        spans += start;
                        spans += c;
                        spans += r;
                        spans += r + 1;
                    }
                }
            }
            int[] rects = {};
            for (int i = 0; i < spans.length; i += 4) {
                int x = spans[i] * Rfb.TILE;
                int y = spans[i + 2] * Rfb.TILE;
                int x2 = int.min (spans[i + 1] * Rfb.TILE, width);
                int y2 = int.min (spans[i + 3] * Rfb.TILE, height);
                int ix = int.max (x, rx);
                int iy = int.max (y, ry);
                int ix2 = int.min (x2, rx + rw);
                int iy2 = int.min (y2, ry + rh);
                if (ix2 <= ix || iy2 <= iy) continue;
                rects += ix;
                rects += iy;
                rects += ix2 - ix;
                rects += iy2 - iy;
            }
            return rects;
        }
    }

    public class RfbConnection : Object {
        public uint id { get; construct; }
        public string peer { get; construct; }
        public bool control { get; private set; default = false; }
        public bool clipboard { get; private set; default = false; }
        public int64 started { get; private set; default = 0; }
        public bool active { get; private set; default = false; }
        public bool closed { get; private set; default = false; }
        public string screen { get; private set; default = ScreenFeed.ALL; }
        public uint64 bytes_sent { get; private set; default = 0; }
        public int encoding { get; private set; default = Rfb.ENC_RAW; }
        public bool extended_clipboard { get; private set; default = false; }

        public signal void authorized ();
        public signal void finished ();

        private weak RemoteDesktopServer server;
        private SocketConnection socket;
        private IOStream stream;
        private InputStream input;
        private OutputStream output;
        private Cancellable cancel = new Cancellable ();
        private Queue<Bytes> out_queue = new Queue<Bytes> ();
        private bool writing = false;
        private SourceFunc? drained = null;
        private RfbPixelFormat format = new RfbPixelFormat ();
        private Rd.Encoder encoder = new Rd.Encoder ();
        private bool desktop_size = false;
        private bool update_requested = false;
        private int req_x;
        private int req_y;
        private int req_w;
        private int req_h;
        private DirtyTiles? dirty = null;
        private bool size_changed = false;
        private uint8 buttons = 0;
        private ScreenFeed? feed = null;
        private ulong damaged_id = 0;
        private uint32 client_clip_caps = 0;
        private bool caps_sent = false;
        private string host_text = "";

        public RfbConnection (RemoteDesktopServer server, uint id, SocketConnection socket, string peer) {
            Object (id: id, peer: peer);
            this.server = server;
            this.socket = socket;
            attach (socket);
        }

        public bool uses (ScreenFeed f) {
            return feed == f;
        }

        private void attach (IOStream s) {
            stream = s;
            var buffered = new BufferedInputStream.sized (s.input_stream, 1 << 16);
            buffered.close_base_stream = false;
            input = buffered;
            output = s.output_stream;
        }

        private async uint8[] take (size_t n) throws Error {
            var buf = new uint8[n];
            if (n == 0) return buf;
            size_t got;
            yield input.read_all_async (buf, Priority.DEFAULT, cancel, out got);
            if (got != n) throw new IOError.CONNECTION_CLOSED ("closed");
            return buf;
        }

        private async uint32 u32 () throws Error {
            return Rfb.get32 (yield take (4), 0);
        }

        private void send (uint8[] data) {
            send_bytes (new Bytes (data));
        }

        private void send_bytes (Bytes data) {
            if (closed) return;
            bytes_sent += data.get_size ();
            out_queue.push_tail (data);
            if (!writing) pump.begin ();
        }

        private async void pump () {
            writing = true;
            while (!out_queue.is_empty () && !closed) {
                var chunk = out_queue.pop_head ();
                try {
                    size_t written;
                    yield output.write_all_async (chunk.get_data (), Priority.DEFAULT, cancel, out written);
                } catch (Error e) {
                    close ();
                    break;
                }
            }
            writing = false;
            if (drained != null) {
                SourceFunc cb = (owned) drained;
                drained = null;
                Idle.add ((owned) cb);
            }
            try_update ();
        }

        private async void flush () {
            if (!writing && out_queue.is_empty ()) return;
            drained = flush.callback;
            yield;
        }

        public async void run () {
            try {
                yield handshake ();
                yield loop ();
            } catch (Error e) {
                if (!(e is IOError.CANCELLED) && !(e is IOError.CONNECTION_CLOSED))
                    message ("Remote Desktop connection from %s ended: %s", peer, e.message);
            }
            close ();
        }

        private async void fail (string reason) throws Error {
            var b = new ByteArray ();
            Rfb.put32 (b, 1);
            Rfb.put32 (b, reason.data.length);
            b.append (reason.data);
            send (b.data);
            yield flush ();
            throw new RfbError.DENIED (reason);
        }

        private async void handshake () throws Error {
            send ("RFB 003.008\n".data);
            string version = Rfb.text (yield take (12));
            if (!version.has_prefix ("RFB 003.")) throw new RfbError.PROTOCOL ("not a VNC client");
            int minor = int.parse (version.substring (8, 3));
            if (minor < 7) {
                var b = new ByteArray ();
                Rfb.put32 (b, 0);
                string reason = "This computer requires an encrypted connection";
                Rfb.put32 (b, reason.data.length);
                b.append (reason.data);
                send (b.data);
                yield flush ();
                throw new RfbError.PROTOCOL ("client too old");
            }
            send ({ 1, (uint8) Rfb.SEC_VENCRYPT });
            if ((yield take (1))[0] != Rfb.SEC_VENCRYPT) throw new RfbError.PROTOCOL ("security type refused");

            send ({ 0, 2 });
            var cv = yield take (2);
            if (cv[0] != 0 || cv[1] != 2) {
                send ({ 1 });
                yield flush ();
                throw new RfbError.PROTOCOL ("VeNCrypt version refused");
            }
            send ({ 0 });

            bool offer_plain = yield server.has_unattended_password ();
            uint32[] subtypes = offer_plain
                ? new uint32[] { Rfb.VENCRYPT_X509_PLAIN, Rfb.VENCRYPT_X509_NONE }
                : new uint32[] { Rfb.VENCRYPT_X509_NONE };
            var st = new ByteArray ();
            st.append ({ (uint8) subtypes.length });
            foreach (uint32 s in subtypes) Rfb.put32 (st, s);
            send (st.data);
            uint32 chosen = yield u32 ();
            bool known = false;
            foreach (uint32 s in subtypes) if (s == chosen) known = true;
            if (!known) {
                send ({ 0 });
                yield flush ();
                throw new RfbError.PROTOCOL ("VeNCrypt subtype %u refused".printf (chosen));
            }
            send ({ 1 });
            yield flush ();

            var tls = TlsServerConnection.new (socket, server.identity.certificate);
            tls.authentication_mode = TlsAuthenticationMode.NONE;
            yield tls.handshake_async (Priority.DEFAULT, cancel);
            attach (tls);

            bool trusted = false;
            if (chosen == Rfb.VENCRYPT_X509_PLAIN) {
                uint32 ulen = yield u32 ();
                uint32 plen = yield u32 ();
                if (ulen > 1024 || plen > 1024) throw new RfbError.PROTOCOL ("credentials too long");
                string user = Rfb.text (yield take (ulen));
                string password = Rfb.text (yield take (plen));
                trusted = yield server.check_password (user, password);
                password = "";
            }

            if (trusted) {
                control = server.default_control;
                clipboard = true;
                screen = server.resolve_screen (server.default_screen);
            } else {
                var answer = yield server.request_consent (this, cancel);
                if (answer == null || !answer.allowed) {
                    yield fail (answer == null
                        ? "Another connection is waiting for an answer. Try again later."
                        : "The person at the computer did not allow the connection.");
                }
                control = answer.control;
                clipboard = answer.clipboard;
                screen = server.resolve_screen (answer.screen != "" ? answer.screen : server.default_screen);
            }

            var ok = new ByteArray ();
            Rfb.put32 (ok, 0);
            send (ok.data);
            yield take (1);

            feed = server.feed_for (screen);
            if (feed == null || !(yield feed.wait_for_frame (cancel)))
                yield fail ("The screen of this computer cannot be captured.");
            damaged_id = feed.damaged.connect (frame_damaged);
            dirty = new DirtyTiles (feed.width, feed.height);
            dirty.mark_all ();

            var init = new ByteArray ();
            Rfb.put16 (init, (uint16) feed.width);
            Rfb.put16 (init, (uint16) feed.height);
            format.write (init);
            string name = Config.host_name ();
            Rfb.put32 (init, name.data.length);
            init.append (name.data);
            send (init.data);

            started = get_real_time () / 1000000;
            active = true;
            authorized ();
        }

        private async void loop () throws Error {
            while (!closed) {
                uint8 type = (yield take (1))[0];
                switch (type) {
                    case 0:
                        var pf = yield take (19);
                        var parsed = RfbPixelFormat.parse (pf[3:19]);
                        if (parsed == null) throw new RfbError.PROTOCOL ("unsupported pixel format");
                        format = parsed;
                        encoder.set_format (format.bits_per_pixel, format.depth, format.big_endian, format.red_max,
                            format.green_max, format.blue_max, format.red_shift, format.green_shift, format.blue_shift);
                        if (dirty != null) dirty.mark_all ();
                        break;
                    case 2:
                        var head = yield take (3);
                        uint16 n = Rfb.get16 (head, 1);
                        var list = yield take (n * 4);
                        set_encodings (list, n);
                        break;
                    case 3:
                        var req = yield take (9);
                        req_x = Rfb.get16 (req, 1);
                        req_y = Rfb.get16 (req, 3);
                        req_w = Rfb.get16 (req, 5);
                        req_h = Rfb.get16 (req, 7);
                        if (req[0] == 0 && dirty != null) {
                            encoder.invalidate ();
                            dirty.mark_all ();
                        }
                        update_requested = true;
                        try_update ();
                        break;
                    case 4:
                        var key = yield take (7);
                        if (control) server.key_event (Rfb.get32 (key, 3), key[0] != 0);
                        break;
                    case 5:
                        var ptr = yield take (5);
                        if (control) pointer_event (ptr[0], Rfb.get16 (ptr, 1), Rfb.get16 (ptr, 3));
                        break;
                    case 6:
                        var cut = yield take (7);
                        uint32 len = Rfb.get32 (cut, 3);
                        if ((len & 0x80000000) != 0) {
                            uint32 size = (uint32) (-(int32) len);
                            if (size < 4 || size > Rfb.MAX_CUT_TEXT) throw new RfbError.PROTOCOL ("clipboard message too long");
                            var payload = yield take (size);
                            if (extended_clipboard) clipboard_message (payload);
                            break;
                        }
                        if (len > Rfb.MAX_CUT_TEXT) throw new RfbError.PROTOCOL ("cut text too long");
                        var text = yield take (len);
                        if (clipboard) server.client_cut_text (this, Rfb.latin1_to_utf8 (text));
                        break;
                    default:
                        throw new RfbError.PROTOCOL ("unknown message %u".printf (type));
                }
            }
        }

        private void set_encodings (uint8[] list, int n) {
            desktop_size = false;
            bool copy_rect = false;
            bool ext_clip = false;
            int chosen = -1;
            for (int i = 0; i < n; i++) {
                int32 e = (int32) Rfb.get32 (list, i * 4);
                if (e == Rfb.ENC_DESKTOP_SIZE) desktop_size = true;
                else if (e == Rfb.ENC_COPYRECT) copy_rect = true;
                else if (e == Rfb.ENC_EXT_CLIPBOARD) ext_clip = true;
                else if (chosen < 0 && (e == Rfb.ENC_ZRLE || e == Rfb.ENC_RAW)) chosen = e;
            }
            encoding = chosen < 0 ? Rfb.ENC_RAW : chosen;
            encoder.set_encodings (encoding, copy_rect);
            debug ("Remote Desktop session %u uses encoding %d, copy rect %s, extended clipboard %s", id, encoding,
                copy_rect ? "yes" : "no", ext_clip ? "yes" : "no");
            extended_clipboard = ext_clip;
            if (extended_clipboard && clipboard && !caps_sent) {
                caps_sent = true;
                var sizes = new ByteArray ();
                Rfb.put32 (sizes, Rfb.MAX_CUT_TEXT);
                send_clipboard_ext (Rfb.CLIP_CAPS | Rfb.CLIP_TEXT | Rfb.CLIP_REQUEST | Rfb.CLIP_PEEK | Rfb.CLIP_NOTIFY
                    | Rfb.CLIP_PROVIDE, sizes.data);
            }
        }

        private void send_clipboard_ext (uint32 flags, uint8[]? body) {
            var b = new ByteArray ();
            b.append ({ 3, 0, 0, 0 });
            int n = 4 + (body != null ? body.length : 0);
            Rfb.put32 (b, (uint32) (-n));
            Rfb.put32 (b, flags);
            if (body != null) b.append (body);
            send (b.data);
        }

        private void provide_text (string text) {
            try {
                send_clipboard_ext (Rfb.CLIP_PROVIDE | Rfb.CLIP_TEXT, Rfb.pack_clipboard_text (text));
            } catch (Error e) {
                warning ("Cannot send the clipboard: %s", e.message);
            }
        }

        private void clipboard_message (uint8[] payload) {
            if (!clipboard) return;
            uint32 flags = Rfb.get32 (payload, 0);
            if ((flags & Rfb.CLIP_CAPS) != 0) {
                client_clip_caps = flags;
                return;
            }
            if ((flags & Rfb.CLIP_REQUEST) != 0 && (flags & Rfb.CLIP_TEXT) != 0) provide_text (host_text);
            if ((flags & Rfb.CLIP_PEEK) != 0)
                send_clipboard_ext (Rfb.CLIP_NOTIFY | (host_text != "" ? Rfb.CLIP_TEXT : 0), null);
            if ((flags & Rfb.CLIP_NOTIFY) != 0 && (flags & Rfb.CLIP_TEXT) != 0)
                send_clipboard_ext (Rfb.CLIP_REQUEST | Rfb.CLIP_TEXT, null);
            if ((flags & Rfb.CLIP_PROVIDE) != 0 && (flags & Rfb.CLIP_TEXT) != 0) {
                try {
                    string? text = Rfb.unpack_clipboard_text (payload[4:payload.length]);
                    if (text != null) {
                        host_text = text;
                        server.client_cut_text (this, text);
                    }
                } catch (Error e) {
                    message ("Remote Desktop session %u sent a damaged clipboard: %s", id, e.message);
                }
            }
        }

        private void pointer_event (uint8 mask, uint16 x, uint16 y) {
            if (feed != null) feed.pointer (x, y);
            for (int bit = 0; bit < 8; bit++) {
                bool now = (mask & (1 << bit)) != 0;
                bool before = (buttons & (1 << bit)) != 0;
                if (now == before) continue;
                if (bit >= 3 && bit <= 6) {
                    if (now) server.scroll (bit <= 4 ? 0 : 1, bit == 3 || bit == 5 ? -1 : 1);
                    continue;
                }
                uint32 code = Rfb.button_code (bit);
                if (code != 0) server.pointer_button (code, now);
            }
            buttons = mask;
        }

        private void frame_damaged (int[] damage, bool resized) {
            if (!active || dirty == null || feed == null) return;
            if (dirty.width != feed.width || dirty.height != feed.height) {
                dirty = new DirtyTiles (feed.width, feed.height);
                dirty.mark_all ();
                encoder.invalidate ();
                size_changed = true;
                if (!desktop_size) {
                    close ();
                    return;
                }
            } else {
                for (int i = 0; i + 3 < damage.length; i += 4) dirty.mark (damage[i], damage[i + 1], damage[i + 2], damage[i + 3]);
            }
            try_update ();
        }

        private void try_update () {
            if (!active || closed || !update_requested || writing || dirty == null || feed == null) return;
            if (size_changed) {
                size_changed = false;
                update_requested = false;
                req_x = 0;
                req_y = 0;
                req_w = feed.width;
                req_h = feed.height;
                var b = new ByteArray ();
                b.append ({ 0, 0 });
                Rfb.put16 (b, 1);
                Rfb.put16 (b, 0);
                Rfb.put16 (b, 0);
                Rfb.put16 (b, (uint16) feed.width);
                Rfb.put16 (b, (uint16) feed.height);
                Rfb.put32 (b, (uint32) Rfb.ENC_DESKTOP_SIZE);
                send (b.data);
                return;
            }
            int[] rects = dirty.take (req_x, req_y, req_w, req_h);
            if (rects.length == 0) return;
            var msg = encoder.encode (feed.framebuffer, feed.width, feed.height, feed.width * 4, rects);
            if (msg == null) return;
            update_requested = false;
            send_bytes (msg);
        }

        public void send_cut_text (string text) {
            if (!active || !clipboard) return;
            host_text = text;
            if (extended_clipboard) {
                if ((client_clip_caps & Rfb.CLIP_NOTIFY) != 0 || client_clip_caps == 0)
                    send_clipboard_ext (Rfb.CLIP_NOTIFY | Rfb.CLIP_TEXT, null);
                else
                    provide_text (text);
                return;
            }
            var data = Rfb.utf8_to_latin1 (text);
            var b = new ByteArray ();
            b.append ({ 3, 0, 0, 0 });
            Rfb.put32 (b, data.length);
            b.append (data);
            send (b.data);
        }

        public void close () {
            if (closed) return;
            closed = true;
            active = false;
            cancel.cancel ();
            if (feed != null && damaged_id != 0) feed.disconnect (damaged_id);
            damaged_id = 0;
            stream.close_async.begin (Priority.DEFAULT, null);
            if (stream != socket) socket.close_async.begin (Priority.DEFAULT, null);
            finished ();
            feed = null;
        }
    }
}
