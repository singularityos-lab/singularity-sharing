namespace Singularity.Sharing {

    public class DavShare : Object {
        public string name { get; construct; }
        public string root { get; construct; }

        public DavShare (string name, string root) {
            Object (name: name, root: root);
        }
    }

    public class DavPaths : Object {
        private Gee.ArrayList<DavShare> shares = new Gee.ArrayList<DavShare> ();

        public DavPaths (string[] folders) {
            var used = new Gee.HashSet<string> ();
            foreach (string folder in folders) {
                string? real = Posix.realpath (folder);
                if (real == null || !FileUtils.test (real, FileTest.IS_DIR)) continue;
                string base_name = Path.get_basename (real);
                if (base_name == "" || base_name == "/") base_name = "Folder";
                string name = base_name;
                for (int n = 2; used.contains (name.down ()); n++) name = "%s %d".printf (base_name, n);
                used.add (name.down ());
                shares.add (new DavShare (name, real));
            }
        }

        public Gee.List<DavShare> list () {
            return shares.read_only_view;
        }

        public DavShare? find (string name) {
            foreach (var share in shares) if (share.name == name) return share;
            return null;
        }

        public static string[] split (string path) {
            string[] parts = {};
            foreach (string part in path.split ("/")) {
                if (part == "") continue;
                parts += part;
            }
            return parts;
        }

        public static bool inside (string path, string root) {
            return path == root || path.has_prefix (root.has_suffix ("/") ? root : root + "/");
        }

        public string? resolve (string decoded, out DavShare? share, bool must_exist) {
            share = null;
            string[] parts = split (decoded);
            if (parts.length == 0) return null;
            foreach (string part in parts) {
                if (part == "." || part == ".." || part.contains ("\\")) return null;
            }
            share = find (parts[0]);
            if (share == null) return null;
            string path = share.root;
            for (int i = 1; i < parts.length; i++) path = Path.build_filename (path, parts[i]);
            if (FileUtils.test (path, FileTest.EXISTS) || FileUtils.test (path, FileTest.IS_SYMLINK)) {
                string? real = Posix.realpath (path);
                if (real == null || !inside (real, share.root)) return null;
                return path;
            }
            if (must_exist) return null;
            string? parent = Posix.realpath (Path.get_dirname (path));
            if (parent == null || !inside (parent, share.root)) return null;
            return path;
        }
    }

    public class WebDavServer : Object {
        public bool read_only { get; set; default = true; }
        public uint port { get; private set; default = 0; }

        private Soup.Server server;
        private DavPaths paths;
        private string password = "";
        private string user;

        public WebDavServer (TlsCertificate certificate, string[] folders) throws Error {
            paths = new DavPaths (folders);
            user = Environment.get_user_name ();
            server = (Soup.Server) Object.new (typeof (Soup.Server), "tls-certificate", certificate,
                "server-header", "Singularity");
            var auth = (Soup.AuthDomainBasic) Object.new (typeof (Soup.AuthDomainBasic),
                "realm", "Singularity File Sharing");
            auth.set_auth_callback ((domain, msg, username, pass) => {
                return password != "" && username == user && Secrets.equal (pass, password);
            });
            auth.add_path ("/");
            server.add_auth_domain (auth);
            server.add_handler (null, handle);
        }

        public void set_password (string password) {
            this.password = password;
        }

        public void set_folders (string[] folders) {
            paths = new DavPaths (folders);
        }

        public Gee.List<DavShare> shares () {
            return paths.list ();
        }

        public void listen (uint port, string address = "") throws Error {
            if (address != "") {
                var inet = new InetSocketAddress.from_string (address, port);
                if (inet == null) throw new IOError.INVALID_ARGUMENT ("invalid address %s", address);
                server.listen (inet, Soup.ServerListenOptions.HTTPS);
            } else {
                server.listen_all (port, Soup.ServerListenOptions.HTTPS);
            }
            foreach (var uri in server.get_uris ()) {
                this.port = uri.get_port ();
                break;
            }
        }

        public void stop () {
            server.disconnect ();
        }

        private static string decode (string path) {
            return Uri.unescape_string (path) ?? "";
        }

        private static string href (string decoded, bool collection) {
            var sb = new StringBuilder ();
            foreach (string part in DavPaths.split (decoded)) {
                sb.append_c ('/');
                sb.append (Uri.escape_string (part, null, false));
            }
            if (sb.len == 0 || collection) sb.append_c ('/');
            return sb.str;
        }

        private void handle (Soup.Server server, Soup.ServerMessage msg, string path, HashTable<string, string>? query) {
            string method = msg.get_method ();
            string decoded = decode (msg.get_uri ().get_path ());
            msg.get_response_headers ().replace ("DAV", "1, 2");
            msg.get_response_headers ().replace ("MS-Author-Via", "DAV");
            bool writes = method == "PUT" || method == "DELETE" || method == "MKCOL" || method == "MOVE"
                || method == "COPY" || method == "PROPPATCH" || method == "LOCK" || method == "UNLOCK";
            if (writes && read_only && method != "LOCK" && method != "UNLOCK") {
                msg.set_status (Soup.Status.FORBIDDEN, null);
                return;
            }
            try {
                switch (method) {
                    case "OPTIONS":
                        msg.get_response_headers ().replace ("Allow",
                            "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK");
                        msg.set_status (Soup.Status.OK, null);
                        break;
                    case "PROPFIND":
                        propfind (msg, decoded);
                        break;
                    case "GET":
                    case "HEAD":
                        serve (msg, decoded);
                        break;
                    case "PUT":
                        put (msg, decoded);
                        break;
                    case "DELETE":
                        remove_path (msg, decoded);
                        break;
                    case "MKCOL":
                        mkcol (msg, decoded);
                        break;
                    case "MOVE":
                    case "COPY":
                        transfer (msg, decoded, method == "MOVE");
                        break;
                    case "PROPPATCH":
                        proppatch (msg, decoded);
                        break;
                    case "LOCK":
                        lock_path (msg, decoded);
                        break;
                    case "UNLOCK":
                        msg.set_status (Soup.Status.NO_CONTENT, null);
                        break;
                    default:
                        msg.set_status (Soup.Status.METHOD_NOT_ALLOWED, null);
                        break;
                }
            } catch (Error e) {
                warning ("WebDAV %s %s: %s", method, decoded, e.message);
                msg.set_status ((e is IOError.PERMISSION_DENIED) ? Soup.Status.FORBIDDEN : Soup.Status.INTERNAL_SERVER_ERROR, null);
            }
        }

        private static string http_date (int64 seconds) {
            var dt = new DateTime.from_unix_utc (seconds);
            return dt.format ("%a, %d %b %Y %H:%M:%S GMT");
        }

        private static string xml_escape (string s) {
            return Markup.escape_text (s);
        }

        private void append_entry (StringBuilder sb, string decoded, string display, FileInfo? info, bool collection) {
            sb.append ("<D:response><D:href>%s</D:href><D:propstat><D:prop>".printf (xml_escape (href (decoded, collection))));
            sb.append ("<D:displayname>%s</D:displayname>".printf (xml_escape (display)));
            if (collection) {
                sb.append ("<D:resourcetype><D:collection/></D:resourcetype>");
            } else {
                sb.append ("<D:resourcetype/>");
                if (info != null) {
                    sb.append ("<D:getcontentlength>%lld</D:getcontentlength>".printf (info.get_size ()));
                    string type = ContentType.get_mime_type (info.get_content_type () ?? "application/octet-stream")
                        ?? "application/octet-stream";
                    sb.append ("<D:getcontenttype>%s</D:getcontenttype>".printf (xml_escape (type)));
                }
            }
            if (info != null) {
                var modified = info.get_modification_date_time ();
                if (modified != null) {
                    int64 t = modified.to_unix ();
                    sb.append ("<D:getlastmodified>%s</D:getlastmodified>".printf (http_date (t)));
                    sb.append ("<D:getetag>\"%llx-%llx\"</D:getetag>".printf (t, info.get_size ()));
                }
            }
            sb.append ("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
        }

        private const string ATTRS = "standard::name,standard::display-name,standard::type,standard::size,"
            + "standard::content-type,standard::is-hidden,time::modified";

        private void propfind (Soup.ServerMessage msg, string decoded) throws Error {
            string depth = msg.get_request_headers ().get_one ("Depth") ?? "1";
            var sb = new StringBuilder ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">");
            string[] parts = DavPaths.split (decoded);
            if (parts.length == 0) {
                append_entry (sb, "/", Config.host_name (), null, true);
                if (depth != "0") {
                    foreach (var share in paths.list ()) {
                        var info = File.new_for_path (share.root).query_info (ATTRS, FileQueryInfoFlags.NONE);
                        append_entry (sb, "/" + share.name, share.name, info, true);
                    }
                }
            } else {
                DavShare? share;
                string? local = paths.resolve (decoded, out share, true);
                if (local == null) {
                    msg.set_status (Soup.Status.NOT_FOUND, null);
                    return;
                }
                var file = File.new_for_path (local);
                var info = file.query_info (ATTRS, FileQueryInfoFlags.NONE);
                bool dir = info.get_file_type () == FileType.DIRECTORY;
                append_entry (sb, decoded, parts.length == 1 ? share.name : info.get_display_name (), info, dir);
                if (dir && depth != "0") {
                    var children = file.enumerate_children (ATTRS, FileQueryInfoFlags.NONE);
                    FileInfo? child;
                    while ((child = children.next_file ()) != null) {
                        string child_path = Path.build_filename (local, child.get_name ());
                        string? real = Posix.realpath (child_path);
                        if (real == null || !DavPaths.inside (real, share.root)) continue;
                        append_entry (sb, decoded + "/" + child.get_name (), child.get_display_name (), child,
                            child.get_file_type () == FileType.DIRECTORY);
                    }
                }
            }
            sb.append ("</D:multistatus>");
            msg.set_response ("application/xml; charset=utf-8", Soup.MemoryUse.COPY, sb.str.data);
            msg.set_status (207, "Multi-Status");
        }

        private void serve (Soup.ServerMessage msg, string decoded) throws Error {
            string[] parts = DavPaths.split (decoded);
            string? local = null;
            DavShare? share = null;
            if (parts.length > 0) {
                local = paths.resolve (decoded, out share, true);
                if (local == null) {
                    msg.set_status (Soup.Status.NOT_FOUND, null);
                    return;
                }
            }
            if (local == null || FileUtils.test (local, FileTest.IS_DIR)) {
                var sb = new StringBuilder ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>");
                sb.append (xml_escape (decoded));
                sb.append ("</title></head><body><ul>");
                if (local == null) {
                    foreach (var s in paths.list ())
                        sb.append ("<li><a href=\"%s\">%s</a></li>".printf (xml_escape (href ("/" + s.name, true)), xml_escape (s.name)));
                } else {
                    var children = File.new_for_path (local).enumerate_children (ATTRS, FileQueryInfoFlags.NONE);
                    FileInfo? child;
                    while ((child = children.next_file ()) != null) {
                        bool dir = child.get_file_type () == FileType.DIRECTORY;
                        sb.append ("<li><a href=\"%s\">%s</a></li>".printf (
                            xml_escape (href (decoded + "/" + child.get_name (), dir)), xml_escape (child.get_display_name ())));
                    }
                }
                sb.append ("</ul></body></html>");
                msg.set_response ("text/html; charset=utf-8", Soup.MemoryUse.COPY, sb.str.data);
                msg.set_status (Soup.Status.OK, null);
                return;
            }
            var info = File.new_for_path (local).query_info (ATTRS, FileQueryInfoFlags.NONE);
            string type = ContentType.get_mime_type (info.get_content_type () ?? "application/octet-stream")
                ?? "application/octet-stream";
            var headers = msg.get_response_headers ();
            headers.set_content_type (type, null);
            var modified = info.get_modification_date_time ();
            if (modified != null) headers.replace ("Last-Modified", http_date (modified.to_unix ()));
            if (msg.get_method () == "HEAD") {
                headers.set_content_length (info.get_size ());
            } else if (info.get_size () > 0) {
                var mapped = new MappedFile (local, false);
                msg.get_response_body ().append_bytes (mapped.get_bytes ());
            }
            msg.set_status (Soup.Status.OK, null);
        }

        private void put (Soup.ServerMessage msg, string decoded) throws Error {
            DavShare? share;
            string? local = paths.resolve (decoded, out share, false);
            if (local == null || DavPaths.split (decoded).length < 2) {
                msg.set_status (Soup.Status.FORBIDDEN, null);
                return;
            }
            if (!FileUtils.test (Path.get_dirname (local), FileTest.IS_DIR)) {
                msg.set_status (Soup.Status.CONFLICT, null);
                return;
            }
            if (FileUtils.test (local, FileTest.IS_DIR)) {
                msg.set_status (Soup.Status.METHOD_NOT_ALLOWED, null);
                return;
            }
            bool existed = FileUtils.test (local, FileTest.EXISTS);
            var body = msg.get_request_body ().flatten ();
            File.new_for_path (local).replace_contents (body.get_data () ?? new uint8[0], null, false,
                FileCreateFlags.NONE, null);
            msg.set_status (existed ? Soup.Status.NO_CONTENT : Soup.Status.CREATED, null);
        }

        private static void delete_tree (File file) throws Error {
            var info = file.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type () == FileType.DIRECTORY) {
                var children = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child;
                while ((child = children.next_file ()) != null) delete_tree (file.get_child (child.get_name ()));
            }
            file.delete ();
        }

        private static void copy_tree (File source, File target) throws Error {
            var info = source.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type () == FileType.DIRECTORY) {
                target.make_directory ();
                var children = source.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child;
                while ((child = children.next_file ()) != null)
                    copy_tree (source.get_child (child.get_name ()), target.get_child (child.get_name ()));
            } else {
                source.copy (target, FileCopyFlags.NOFOLLOW_SYMLINKS);
            }
        }

        private void remove_path (Soup.ServerMessage msg, string decoded) throws Error {
            DavShare? share;
            string? local = paths.resolve (decoded, out share, true);
            if (local == null || DavPaths.split (decoded).length < 2) {
                msg.set_status (local == null ? Soup.Status.NOT_FOUND : Soup.Status.FORBIDDEN, null);
                return;
            }
            delete_tree (File.new_for_path (local));
            msg.set_status (Soup.Status.NO_CONTENT, null);
        }

        private void mkcol (Soup.ServerMessage msg, string decoded) throws Error {
            DavShare? share;
            string? local = paths.resolve (decoded, out share, false);
            if (local == null || DavPaths.split (decoded).length < 2) {
                msg.set_status (Soup.Status.FORBIDDEN, null);
                return;
            }
            if (FileUtils.test (local, FileTest.EXISTS)) {
                msg.set_status (Soup.Status.METHOD_NOT_ALLOWED, null);
                return;
            }
            if (!FileUtils.test (Path.get_dirname (local), FileTest.IS_DIR)) {
                msg.set_status (Soup.Status.CONFLICT, null);
                return;
            }
            File.new_for_path (local).make_directory ();
            msg.set_status (Soup.Status.CREATED, null);
        }

        private void transfer (Soup.ServerMessage msg, string decoded, bool move) throws Error {
            string? destination = msg.get_request_headers ().get_one ("Destination");
            if (destination == null) {
                msg.set_status (Soup.Status.BAD_REQUEST, null);
                return;
            }
            string dest_path;
            try {
                dest_path = decode (Uri.parse (destination, UriFlags.ENCODED).get_path ());
            } catch (Error e) {
                dest_path = decode (destination);
            }
            DavShare? share;
            DavShare? dest_share;
            string? local = paths.resolve (decoded, out share, true);
            string? target = paths.resolve (dest_path, out dest_share, false);
            if (local == null) {
                msg.set_status (Soup.Status.NOT_FOUND, null);
                return;
            }
            if (target == null || DavPaths.split (decoded).length < 2 || DavPaths.split (dest_path).length < 2) {
                msg.set_status (Soup.Status.FORBIDDEN, null);
                return;
            }
            if (DavPaths.inside (target, local)) {
                msg.set_status (Soup.Status.FORBIDDEN, null);
                return;
            }
            bool overwrite = (msg.get_request_headers ().get_one ("Overwrite") ?? "T").up () != "F";
            bool existed = FileUtils.test (target, FileTest.EXISTS);
            if (existed && !overwrite) {
                msg.set_status (Soup.Status.PRECONDITION_FAILED, null);
                return;
            }
            if (!FileUtils.test (Path.get_dirname (target), FileTest.IS_DIR)) {
                msg.set_status (Soup.Status.CONFLICT, null);
                return;
            }
            var src = File.new_for_path (local);
            var dst = File.new_for_path (target);
            if (existed) delete_tree (dst);
            if (move) src.move (dst, FileCopyFlags.NOFOLLOW_SYMLINKS);
            else copy_tree (src, dst);
            msg.set_status (existed ? Soup.Status.NO_CONTENT : Soup.Status.CREATED, null);
        }

        private void proppatch (Soup.ServerMessage msg, string decoded) throws Error {
            DavShare? share;
            if (paths.resolve (decoded, out share, true) == null) {
                msg.set_status (Soup.Status.NOT_FOUND, null);
                return;
            }
            var sb = new StringBuilder ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">");
            sb.append ("<D:response><D:href>%s</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
                .printf (xml_escape (href (decoded, false))));
            sb.append ("</D:multistatus>");
            msg.set_response ("application/xml; charset=utf-8", Soup.MemoryUse.COPY, sb.str.data);
            msg.set_status (207, "Multi-Status");
        }

        private void lock_path (Soup.ServerMessage msg, string decoded) {
            string token = "opaquelocktoken:" + Uuid.string_random ();
            var sb = new StringBuilder ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>");
            sb.append ("<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>");
            sb.append ("<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>%s</D:href></D:locktoken>".printf (token));
            sb.append ("</D:activelock></D:lockdiscovery></D:prop>");
            msg.get_response_headers ().replace ("Lock-Token", "<%s>".printf (token));
            msg.set_response ("application/xml; charset=utf-8", Soup.MemoryUse.COPY, sb.str.data);
            msg.set_status (Soup.Status.OK, null);
        }
    }
}
