namespace Singularity.Sharing {

    public interface ServiceAnnouncer : Object {
        public abstract string id { get; }
        public abstract async bool available ();
        public abstract async void publish (string type, string name, uint port, string[] txt) throws Error;
        public abstract async void withdraw (string type);
    }

    public class AvahiAnnouncer : Object, ServiceAnnouncer {
        private const string BUS_NAME = "org.freedesktop.Avahi";
        private DBusConnection? bus = null;
        private Gee.HashMap<string, string> groups = new Gee.HashMap<string, string> ();

        public string id { get { return "avahi"; } }

        private async DBusConnection? connection () {
            if (bus == null) {
                try {
                    bus = yield Bus.get (BusType.SYSTEM);
                } catch (Error e) {
                    return null;
                }
            }
            return bus;
        }

        public async bool available () {
            var c = yield connection ();
            if (c == null) return false;
            try {
                var ret = yield c.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant ("(s)", BUS_NAME), new VariantType ("(b)"), DBusCallFlags.NONE, 2000, null);
                if (ret.get_child_value (0).get_boolean ()) return true;
                ret = yield c.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType ("(as)"), DBusCallFlags.NONE, 2000, null);
                foreach (string name in ret.get_child_value (0).get_strv ()) if (name == BUS_NAME) return true;
            } catch (Error e) {
            }
            return false;
        }

        public async void publish (string type, string name, uint port, string[] txt) throws Error {
            yield withdraw (type);
            var c = yield connection ();
            if (c == null) throw new IOError.NOT_CONNECTED ("no system bus");
            var ret = yield c.call (BUS_NAME, "/", "org.freedesktop.Avahi.Server", "EntryGroupNew", null,
                new VariantType ("(o)"), DBusCallFlags.NONE, 5000, null);
            string path = ret.get_child_value (0).get_string ();
            var records = new VariantBuilder (new VariantType ("aay"));
            foreach (string entry in txt) {
                var bytes = new VariantBuilder (new VariantType ("ay"));
                foreach (uint8 b in entry.data) bytes.add ("y", b);
                records.add_value (bytes.end ());
            }
            yield c.call (BUS_NAME, path, "org.freedesktop.Avahi.EntryGroup", "AddService",
                new Variant ("(iiussssq@aay)", -1, -1, 0u, name, type, "", "", (uint16) port, records.end ()),
                null, DBusCallFlags.NONE, 5000, null);
            yield c.call (BUS_NAME, path, "org.freedesktop.Avahi.EntryGroup", "Commit", null, null,
                DBusCallFlags.NONE, 5000, null);
            groups[type] = path;
        }

        public async void withdraw (string type) {
            string? path = groups[type];
            if (path == null) return;
            groups.unset (type);
            var c = yield connection ();
            if (c == null) return;
            try {
                yield c.call (BUS_NAME, path, "org.freedesktop.Avahi.EntryGroup", "Free", null, null,
                    DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                debug ("Cannot withdraw %s: %s", type, e.message);
            }
        }
    }

    public class AnnouncedService : Object {
        public uint port { get; construct; }
        public string name { get; construct; }
        public string[] txt { get; construct; }

        public AnnouncedService (uint port, string name, string[] txt) {
            Object (port: port, name: name, txt: txt);
        }

        public string key () {
            return "%u\n%s\n%s".printf (port, name, string.joinv ("\n", txt));
        }
    }

    public class Announcements : Object {
        public const string REMOTE_DESKTOP = "_rfb._tcp";
        public const string FILE_SHARING = "_webdav._tcp";
        public const uint PROFILE_POLL_SECONDS = 10;

        public string backend { get; private set; default = ""; }
        public bool home { get; private set; default = true; }
        public string[] published { get; private set; default = {}; }

        private ServiceAnnouncer? announcer = null;
        private bool detected = false;
        private Gee.HashMap<string, AnnouncedService> wanted = new Gee.HashMap<string, AnnouncedService> ();
        private Gee.HashMap<string, string> current = new Gee.HashMap<string, string> ();
        private uint poll_id = 0;
        private bool syncing = false;
        private bool again = false;
        private Config config;

        public signal void changed ();

        public Announcements (Config config) {
            this.config = config;
        }

        private async ServiceAnnouncer? detect () {
            if (detected) return announcer;
            detected = true;
            string choice = config.backend ("Announce");
            if (choice == "none") return null;
            var avahi = new AvahiAnnouncer ();
            if (yield avahi.available ()) announcer = avahi;
            else if (choice == "avahi") warning ("Avahi is not running; services are not announced on the network");
            backend = announcer != null ? announcer.id : "";
            return announcer;
        }

        public void set_service (string type, bool active, uint port, string name, string[] txt = {}) {
            if (active) wanted[type] = new AnnouncedService (port, name, txt);
            else wanted.unset (type);
            sync.begin ();
        }

        private async bool read_home () {
            var firewall = Singularity.FirewallManager.get_default ();
            var status = yield firewall.refresh ();
            return status == null || status.profile == Singularity.FirewallProfile.HOME;
        }

        private async void sync () {
            if (syncing) {
                again = true;
                return;
            }
            syncing = true;
            do {
                again = false;
                yield sync_once ();
            } while (again);
            syncing = false;
        }

        private async void sync_once () {
            if (wanted.size > 0 && poll_id == 0) {
                poll_id = Timeout.add_seconds (PROFILE_POLL_SECONDS, () => {
                    sync.begin ();
                    return Source.CONTINUE;
                });
            } else if (wanted.size == 0 && poll_id != 0) {
                Source.remove (poll_id);
                poll_id = 0;
            }
            bool was_home = home;
            home = wanted.size > 0 ? yield read_home () : home;
            var a = yield detect ();
            foreach (string type in current.keys.to_array ()) {
                if (!home || !wanted.has_key (type) || wanted[type].key () != current[type]) {
                    if (a != null) yield a.withdraw (type);
                    current.unset (type);
                    message ("Stopped announcing %s", type);
                }
            }
            if (home && a != null) {
                foreach (var entry in wanted.entries) {
                    if (current.has_key (entry.key)) continue;
                    var service = entry.value;
                    try {
                        yield a.publish (entry.key, service.name, service.port, service.txt);
                        current[entry.key] = service.key ();
                        message ("Announcing %s on port %u", entry.key, service.port);
                    } catch (Error e) {
                        warning ("Cannot announce %s: %s", entry.key, e.message);
                    }
                }
            }
            string[] list = {};
            foreach (string type in current.keys) list += type;
            bool list_changed = string.joinv (",", list) != string.joinv (",", published);
            published = list;
            if (list_changed || was_home != home) changed ();
        }

        public void shutdown () {
            wanted.clear ();
            if (poll_id != 0) Source.remove (poll_id);
            poll_id = 0;
            if (announcer != null) foreach (string type in current.keys) announcer.withdraw.begin (type);
            current.clear ();
        }
    }
}
