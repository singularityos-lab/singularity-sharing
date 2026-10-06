namespace Singularity.Sharing {

    public class Secrets : Object {
        public const string REMOTE_DESKTOP = "remote-desktop";
        public const string FILE_SHARING = "file-sharing";

        private static Secret.Schema? _schema = null;

        private static Secret.Schema schema () {
            if (_schema == null) {
                _schema = new Secret.Schema ("dev.sinty.Sharing", Secret.SchemaFlags.NONE,
                    "kind", Secret.SchemaAttributeType.STRING);
            }
            return _schema;
        }

        public static bool valid_kind (string kind) {
            return kind == REMOTE_DESKTOP || kind == FILE_SHARING;
        }

        public static async string? lookup (string kind) {
            try {
                return yield Secret.password_lookup (schema (), null, "kind", kind);
            } catch (Error e) {
                warning ("Cannot read the %s password: %s", kind, e.message);
                return null;
            }
        }

        public static async void store (string kind, string password) throws Error {
            string label = kind == REMOTE_DESKTOP ? _("Remote Desktop password") : _("File Sharing password");
            yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, label, password, null, "kind", kind);
        }

        public static async void clear (string kind) throws Error {
            yield Secret.password_clear (schema (), null, "kind", kind);
        }

        public static bool equal (string a, string b) {
            uint8[] x = a.data;
            uint8[] y = b.data;
            uint diff = x.length ^ y.length;
            for (int i = 0; i < int.max (x.length, y.length); i++) {
                uint8 p = i < x.length ? x[i] : 0;
                uint8 q = i < y.length ? y[i] : 0;
                diff |= p ^ q;
            }
            return diff == 0;
        }
    }

    public class Identity : Object {
        public TlsCertificate certificate { get; private set; }
        public string fingerprint { get; private set; default = ""; }

        public Identity () throws Error {
            string dir = Config.state_dir ();
            string cert = Path.build_filename (dir, "tls.crt");
            string key = Path.build_filename (dir, "tls.key");
            if (!FileUtils.test (cert, FileTest.IS_REGULAR) || !FileUtils.test (key, FileTest.IS_REGULAR))
                Rd.tls_generate (cert, key, Environment.get_host_name ());
            certificate = new TlsCertificate.from_files (cert, key);
            fingerprint = fingerprint_of (certificate.certificate.data);
        }

        public static string fingerprint_of (uint8[] der) {
            var sum = Checksum.compute_for_data (ChecksumType.SHA256, der);
            var sb = new StringBuilder ();
            for (int i = 0; i < sum.length; i += 2) {
                if (sb.len > 0) sb.append_c (':');
                sb.append (sum.substring (i, 2).up ());
            }
            return sb.str;
        }
    }
}
