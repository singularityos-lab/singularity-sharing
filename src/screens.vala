namespace Singularity.Sharing {

    public class FrameWaiter : Object {
        private SourceFunc? callback;

        public FrameWaiter (owned SourceFunc callback) {
            this.callback = (owned) callback;
        }

        public void wake () {
            if (callback == null) return;
            SourceFunc cb = (owned) callback;
            callback = null;
            Idle.add ((owned) cb);
        }
    }

    public class ScreenInfo : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public int x { get; construct; }
        public int y { get; construct; }
        public int width { get; construct; }
        public int height { get; construct; }
        public double scale { get; construct; }

        public ScreenInfo (string id, string label, int x, int y, int width, int height, double scale) {
            Object (id: id, label: label, x: x, y: y, width: width, height: height, scale: scale);
        }

        public string detail () {
            string size = "%d × %d".printf ((int) Math.round (width * scale), (int) Math.round (height * scale));
            if (scale != 1.0) return _("%s, scale %s").printf (size, scale_text (scale));
            return size;
        }

        public static string scale_text (double scale) {
            string text = "%.2f".printf (scale);
            while (text.has_suffix ("0")) text = text.substring (0, text.length - 1);
            if (text.has_suffix (".")) text = text.substring (0, text.length - 1);
            return text;
        }
    }

    public class ScreenFeed : Object {
        public const string ALL = "all";

        public string output { get; construct; }
        public int width { get; private set; default = 0; }
        public int height { get; private set; default = 0; }
        public bool has_frame { get; private set; default = false; }
        public bool stopped { get; private set; default = false; }
        public uint8[] framebuffer = new uint8[0];

        public signal void damaged (int[] damage, bool resized);
        public signal void ended ();

        private Rd.Screen? screen = null;
        private Gee.ArrayList<FrameWaiter> waiters = new Gee.ArrayList<FrameWaiter> ();

        public ScreenFeed (Rd.Display display, string output) {
            Object (output: output);
            screen = Rd.Screen.create (display, output == ALL ? null : output, true, on_frame, on_stopped);
            if (screen == null) stopped = true;
        }

        public async bool wait_for_frame (Cancellable cancellable) {
            if (stopped) return false;
            if (has_frame) return true;
            waiters.add (new FrameWaiter (wait_for_frame.callback));
            bool fired = false;
            uint timeout = Timeout.add_seconds (5, () => {
                fired = true;
                wake_waiters ();
                return Source.REMOVE;
            });
            yield;
            if (!fired) Source.remove (timeout);
            return has_frame && !cancellable.is_cancelled ();
        }

        private void wake_waiters () {
            var list = waiters;
            waiters = new Gee.ArrayList<FrameWaiter> ();
            foreach (var w in list) w.wake ();
        }

        private void on_frame (uint8[] data, int w, int h, int stride, int[] damage) {
            size_t size = (size_t) w * h * 4;
            bool resized = w != width || h != height || framebuffer.length != size;
            if (resized) {
                framebuffer = new uint8[size];
                width = w;
                height = h;
                Memory.copy (framebuffer, data, size);
            } else {
                for (int i = 0; i + 3 < damage.length; i += 4) {
                    int x = int.max (damage[i], 0);
                    int y = int.max (damage[i + 1], 0);
                    int x2 = int.min (damage[i] + damage[i + 2], w);
                    int y2 = int.min (damage[i + 1] + damage[i + 3], h);
                    for (int row = y; row < y2; row++) {
                        size_t o = (size_t) row * stride + (size_t) x * 4;
                        Memory.copy (&framebuffer[o], &data[o], (size_t) (x2 - x) * 4);
                    }
                }
            }
            bool first = !has_frame;
            has_frame = true;
            if (first) wake_waiters ();
            int[] all = { 0, 0, w, h };
            damaged (resized || first ? all : damage, resized && !first);
        }

        private void on_stopped () {
            if (stopped) return;
            stopped = true;
            has_frame = false;
            wake_waiters ();
            ended ();
        }

        public void pointer (int x, int y) {
            if (screen != null && !stopped) screen.pointer_motion (x, y);
        }

        public bool idle () {
            return waiters.size == 0;
        }

        public void close () {
            stopped = true;
            screen = null;
            wake_waiters ();
        }
    }
}
