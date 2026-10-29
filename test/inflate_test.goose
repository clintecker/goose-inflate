// inflate decodes a file made by `gzip -9 -n` back to its source, read from
// a goose-file handle and from bytes in memory, and CRC-32 gives the
// standard check value. Run from the package root:
// goose run test/inflate_test.goose
import std;
import os;
import inflate from "..";
import file from "clintecker/goose-file@v1";

// Every byte the DEFLATE stream in `s` decodes to, a step at a time.
fn decode(s: inflate::Bits&, o: inflate::Out&) -> u8[>..] {
    var z = inflate::Inflater { lc: inflate::Huff { .. }, dc: inflate::Huff { .. } };
    var got: u8[>..] = [];
    while inflate::step(z, s, o) {
        got.append(inflate::take(o, inflate::avail(o)));
        inflate::compact(o);
    }
    return got;
}

fn main() {
    assert(inflate::crc32("123456789") == 0xcbf43926);
    assert(inflate::crc32("") == 0);

    var want: u8[>..] = [];
    assert(read_file("test/data/sample.txt", want));

    // From a stream: header, data, then the trailer's CRC-32 and length.
    let f = file::file_open("test/data/sample.txt.gz");
    assert(f != 0);
    var s = inflate::Bits { who: "inflate_test", f: f, data: [] };
    var o = inflate::Out { data: [] };
    inflate::gzip_header(s);
    assert(decode(s, o) == want);
    assert(inflate::whole_bytes(s, 4) == inflate::crc(o));
    assert(inflate::whole_bytes(s, 4) == want.len);
    assert(inflate::crc(o) == inflate::crc32(want));
    file::file_close(f);

    // From bytes in memory: the same stream, with f 0.
    var gz: u8[>..] = [];
    assert(read_file("test/data/sample.txt.gz", gz));
    var m = inflate::Bits { who: "inflate_test", data: [] };
    m.data.append(gz);
    var o2 = inflate::Out { data: [] };
    inflate::gzip_header(m);
    assert(decode(m, o2) == want);
}
