using Singularity.Sharing;

void test_dirty_tiles () {
    var tiles = new DirtyTiles (200, 100);
    assert (tiles.take (0, 0, 200, 100).length == 0);
    tiles.mark (70, 10, 5, 5);
    int[] rects = tiles.take (0, 0, 200, 100);
    assert (rects.length == 4);
    assert (rects[0] == 64 && rects[1] == 0 && rects[2] == 64 && rects[3] == 64);
    assert (tiles.take (0, 0, 200, 100).length == 0);
    tiles.mark_all ();
    rects = tiles.take (0, 0, 200, 100);
    assert (rects.length == 4);
    assert (rects[2] == 200 && rects[3] == 100);
    tiles.mark (0, 0, 10, 10);
    tiles.mark (0, 70, 10, 10);
    tiles.mark (150, 70, 10, 10);
    rects = tiles.take (0, 0, 200, 100);
    assert (rects.length == 8);
    assert (rects[0] == 0 && rects[1] == 0 && rects[2] == 64 && rects[3] == 100);
    assert (rects[4] == 128 && rects[5] == 64 && rects[6] == 64 && rects[7] == 36);
    tiles.mark (0, 0, 70, 100);
    rects = tiles.take (0, 0, 200, 100);
    assert (rects.length == 4 && rects[2] == 128 && rects[3] == 100);
    tiles.mark (0, 0, 200, 100);
    rects = tiles.take (10, 10, 20, 20);
    assert (rects.length == 4 && rects[0] == 10 && rects[2] == 20);
    tiles.mark (-50, -50, 10, 10);
    assert (tiles.take (0, 0, 200, 100).length == 0);
}

void test_pixel_format () {
    uint8[] raw = { 16, 16, 0, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0 };
    var pf = RfbPixelFormat.parse (raw);
    assert (pf != null && pf.bits_per_pixel == 16 && pf.green_max == 63 && pf.red_shift == 11);
    raw[3] = 0;
    assert (RfbPixelFormat.parse (raw) == null);
    raw[3] = 1;
    raw[0] = 24;
    assert (RfbPixelFormat.parse (raw) == null);

    uint8[] src = { 0x10, 0x20, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var dst = new uint8[4];
    Rd.convert_pixels (src, 8, 0, 0, 1, 1, dst, 32, false, 255, 255, 255, 16, 8, 0);
    assert (dst[0] == 0x10 && dst[1] == 0x20 && dst[2] == 0xff);
    var small = new uint8[2];
    Rd.convert_pixels (src, 8, 0, 0, 1, 1, small, 16, false, 31, 63, 31, 11, 5, 0);
    uint16 v = small[0] | (small[1] << 8);
    assert ((v >> 11) == 31);
    Rd.convert_pixels (src, 8, 0, 0, 1, 1, dst, 32, true, 255, 255, 255, 0, 8, 16);
    assert (dst[3] == 0xff && dst[1] == 0x10);
}

void test_text () {
    assert (Rfb.latin1_to_utf8 ({ 0x63, 0x61, 0x66, 0xe9 }) == "café");
    var latin = Rfb.utf8_to_latin1 ("café ✓\r\n");
    assert (latin.length == 7 && latin[3] == 0xe9 && latin[5] == '?' && latin[6] == '\n');
    assert (Rfb.text ({ 0x52, 0x46, 0x42 }) == "RFB");
    assert (Rfb.button_code (0) == 0x110 && Rfb.button_code (2) == 0x111 && Rfb.button_code (4) == 0);
}

void test_dav_paths () {
    string root;
    try {
        root = DirUtils.make_tmp ("sharing-test-XXXXXX");
    } catch (Error e) {
        assert_not_reached ();
    }
    root = Posix.realpath (root);
    string docs = Path.build_filename (root, "Documents");
    string other = Path.build_filename (root, "Other");
    DirUtils.create (docs, 0700);
    DirUtils.create (other, 0700);
    DirUtils.create (Path.build_filename (other, "Documents"), 0700);
    FileUtils.symlink (other, Path.build_filename (docs, "escape"));
    FileUtils.symlink ("/etc", Path.build_filename (docs, "etc"));

    var paths = new DavPaths ({ docs, Path.build_filename (other, "Documents"), "/nonexistent" });
    assert (paths.list ().size == 2);
    assert (paths.list ()[0].name == "Documents");
    assert (paths.list ()[1].name == "Documents 2");

    DavShare? share;
    assert (paths.resolve ("/Documents", out share, true) == docs);
    assert (share != null && share.root == docs);
    assert (paths.resolve ("/Documents/../Other", out share, false) == null);
    assert (paths.resolve ("/Documents/escape", out share, true) == null);
    assert (paths.resolve ("/Documents/etc/passwd", out share, false) == null);
    assert (paths.resolve ("/Documents/new.txt", out share, false) == Path.build_filename (docs, "new.txt"));
    assert (paths.resolve ("/Documents/new.txt", out share, true) == null);
    assert (paths.resolve ("/Documents/missing/new.txt", out share, false) == null);
    assert (paths.resolve ("/Nope/x", out share, false) == null);
    assert (paths.resolve ("/", out share, false) == null);
    assert (DavPaths.inside ("/a/bc", "/a/b") == false);
    assert (DavPaths.inside ("/a/b/c", "/a/b"));
}

void test_consent () {
    string json = Consent.request_json ("192.0.2.4", true, false);
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (json);
    } catch (Error e) {
        assert_not_reached ();
    }
    var obj = parser.get_root ().get_object ();
    assert (obj.get_string_member ("kind") == "remote");
    assert (obj.get_string_member ("subtitle").contains ("192.0.2.4"));
    var items = obj.get_array_member ("items");
    assert (items.get_length () == 2);
    assert (items.get_object_element (0).get_boolean_member ("selected"));
    assert (!items.get_object_element (1).get_boolean_member ("selected"));

    var answer = Consent.parse_answer ("noise\n{\"response\":0,\"choice\":\"\",\"selected\":[\"clipboard\"]}\n");
    assert (answer.allowed && !answer.control && answer.clipboard);
    answer = Consent.parse_answer ("{\"response\":1,\"choice\":\"\",\"selected\":[\"control\"]}");
    assert (!answer.allowed && !answer.control);
    assert (!Consent.parse_answer ("garbage").allowed);
    assert (!obj.has_member ("choices"));

    ScreenInfo[] screens = { new ScreenInfo ("HDMI-A-1", "Dell U2720Q", 0, 0, 1920, 1080, 2.0),
                             new ScreenInfo ("eDP-1", "Built-in", 1920, 0, 1280, 800, 1.25) };
    json = Consent.request_json ("192.0.2.4", false, true, screens, "eDP-1");
    try {
        parser.load_from_data (json);
    } catch (Error e) {
        assert_not_reached ();
    }
    obj = parser.get_root ().get_object ();
    assert (obj.get_string_member ("choice") == "eDP-1");
    var choices = obj.get_array_member ("choices");
    assert (choices.get_length () == 3);
    assert (choices.get_object_element (0).get_string_member ("id") == "all");
    assert (choices.get_object_element (1).get_string_member ("detail") == "3840 × 2160, scale 2");
    assert (choices.get_object_element (2).get_string_member ("detail") == "1600 × 1000, scale 1.25");
    answer = Consent.parse_answer ("{\"response\":0,\"choice\":\"HDMI-A-1\",\"selected\":[\"control\"]}");
    assert (answer.allowed && answer.control && answer.screen == "HDMI-A-1");
    json = Consent.request_json ("192.0.2.4", false, true, { screens[0] }, "all");
    assert (!json.contains ("choices"));
}

void test_clipboard () {
    string text = "Perché è già così? ✓\nseconda riga";
    try {
        var packed = Rfb.pack_clipboard_text (text);
        assert (Rfb.unpack_clipboard_text (packed) == text);
        var raw = Rfb.zlib_unpack (packed, 1024);
        assert (Rfb.get32 (raw, 0) == raw.length - 4);
        assert (raw[raw.length - 1] == 0);
        assert (((string) raw[4:raw.length]).contains ("\r\nseconda"));
    } catch (Error e) {
        assert_not_reached ();
    }
    try {
        var big = new uint8[4096];
        Rfb.zlib_unpack (Rfb.zlib_pack (big), 100);
        assert_not_reached ();
    } catch (Error e) {
    }
}

void test_services () {
    assert (SambaBackend.share_name ("/home/a/My Files!") == "My_Files");
    assert (SambaBackend.share_name ("/") == "Folder");
    string conf = Singularity.SharingHost.MediaServer.rygel_config ({ "/m", "/p" }, "Name");
    assert (conf.contains ("uris=/m;/p") && conf.contains ("[MediaExport]\nenabled=true"));
    assert (Secrets.equal ("secret", "secret"));
    assert (!Secrets.equal ("secret", "secreT"));
    assert (!Secrets.equal ("secret", "secret1"));
    assert (Identity.fingerprint_of ({ 1, 2, 3 }).length == 95);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/sharing/dirty-tiles", test_dirty_tiles);
    Test.add_func ("/sharing/pixel-format", test_pixel_format);
    Test.add_func ("/sharing/text", test_text);
    Test.add_func ("/sharing/dav-paths", test_dav_paths);
    Test.add_func ("/sharing/consent", test_consent);
    Test.add_func ("/sharing/services", test_services);
    Test.add_func ("/sharing/clipboard", test_clipboard);
    return Test.run ();
}
