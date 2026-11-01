// Every stream in test/data decoded whole and in pieces of 1, 7 and 65,536
// bytes: the output, the block count and any error must be the same each
// way. Raw DEFLATE from Python's zlib (make_data.py) must give payload.bin;
// gzip files made by gzip give their source, or the error v1 gave. Run from
// the package root: goose run test/inflate_test.goose
import std;
import os;
import inflate from "..";

fn read(name: const u8[:]) -> u8[>..] {
    var data: u8[>..] = [];
    assert(read_file(str("test/data/", name), data));
    return data;
}

// What a decode saw: the output, then a line with the blocks, the bytes of
// input used, and the error, if there was one.
fn decode(data: const u8[:], size: i64, gzip: bool) -> u8[>..] {
    var z = if gzip { inflate::gzip_start() } else { inflate::start() };
    var out: u8[>..] = [];
    var ok = true;
    var at = 0;
    var ends = 0;
    while ok && at < data.len {
        let end = min(at + size, data.len);
        ok = inflate::add(z, data[at..end]) { d, ended => out.append(d); if ended { ends++; } };
        at = end;
    }
    if ok { ok = inflate::finish(z); }
    format(out, "\n-- blocks ", z.blocks, " ended ", ends, " used ", z.at);
    if !ok { format(out, " byte ", z.err_at, ": "); inflate::reason(out, z); }
    return out;
}

fn same_every_way(name: const u8[:], gzip: bool) -> u8[>..] { every_way(name, read(name), gzip) }

fn every_way(name: const u8[:], data: const u8[:], gzip: bool) -> u8[>..] {
    let whole = decode(data, data.len, gzip);
    for size in [1, 7, 65536] {
        if decode(data, size, gzip) != whole { print(name, ": pieces of ", size, " differ"); assert(false); }
    }
    return whole;
}

fn tail(s: const u8[:]) -> const u8[:] { s[rfind(s, "\n-- ") + 1..] }

// Members one after another, as `cat a.gz b.gz` writes them; zero bytes
// after a trailer; other bytes after one; and a second member whose
// distances reach into the first (zdict.gz), which gzip refuses.
fn members() {
    let a = read("sample.txt.gz");
    let b = read("text.gz");
    var two: u8[>..] = [];
    two.append(a);
    two.append(b);
    var want: u8[>..] = [];
    want.append(read("sample.txt"));
    want.append(read("text.txt"));
    let got = every_way("two", two, true);
    assert(got[..rfind(got, "\n-- ")] == want);
    assert(find(tail(got), "byte ") < 0);
    var padded: u8[>..] = [];
    padded.append(b);
    for _ in 100 { padded.push(0); }
    let p = every_way("padded", padded, true);
    assert(p[..rfind(p, "\n-- ")] == read("text.txt"));
    assert(find(tail(p), "byte ") < 0);
    var junk: u8[>..] = [];
    junk.append(b);
    junk.append("garbage after");
    assert(ends_with(every_way("junk", junk, true), str("byte ", b.len, ": the bytes after gzip member 1 are not a gzip member")));
    var cut: u8[>..] = [];
    cut.append(b);
    cut.append(a[..5]);
    assert(ends_with(every_way("cut", cut, true), "compressed data ends early"));
    assert(ends_with(same_every_way("zdict.gz", true), "a distance reaches before the start of the output"));
}

fn main() {
    assert(inflate::crc32("123456789") == 0xcbf43926);
    assert(inflate::crc32("") == 0);

    let payload = read("payload.bin");
    for name in ["level0.deflate", "level1.deflate", "level6.deflate", "level9.deflate"] {
        let got = same_every_way(name, false);
        assert(got[..rfind(got, "\n-- ")] == payload);
        assert(find(tail(got), "byte ") < 0);
    }
    for pair in [["sample.txt.gz", "sample.txt"], ["text.gz", "text.txt"]] {
        let got = same_every_way(pair[0], true);
        assert(got[..rfind(got, "\n-- ")] == read(pair[1]));
    }
    for name in ["rand.gz", "stream.gz", "small.gz", "empty.gz"] {
        assert(find(tail(same_every_way(name, true)), "byte ") < 0);
    }
    assert(ends_with(same_every_way("badcrc.gz", true), "CRC-32 is 0x3bfe2b7e, the file records 0x3bfe2b00"));
    assert(ends_with(same_every_way("short.gz", true), "compressed data ends early"));
    assert(ends_with(same_every_way("reserved.gz", true), "byte 0: reserved header flag bits are set"));
    assert(ends_with(same_every_way("text.txt", true), "byte 0: not a gzip file"));
    members();
    print("inflate_test: ok");
}
