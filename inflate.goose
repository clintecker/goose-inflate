// DEFLATE (RFC 1951) and the gzip header (RFC 1952), as a decoder the caller
// pulls from: `step` decodes onto an Out until a block ends or LIMIT bytes
// wait untaken, `take` hands the caller the bytes decoded so far, and
// `compact` drops what was taken, keeping the 32 KB a later copy may reach.
// A block's expanded size has no bound, so `step` stops inside one rather
// than hold it all. Input comes from a clintecker/goose-file handle or from
// bytes the caller already holds. Decoding walks Huffman codes a bit at a
// time, as Mark Adler's puff.c does. crc32.goose is the CRC-32.
namespace inflate;
import std;
import os;
import .crc32;
import file from "clintecker/goose-file@v1";

// The exit codes of a decoding error (sysexits.h): corrupt data, and an
// input that cannot be read.
let EX_DATAERR = 65;
let EX_NOINPUT = 66;

// Prints `msg` to stderr and exits with `code`. Never returns.
fn stop(code: i64, msg: const u8[:]) {
    write_stderr(msg);
    write_stderr("\n");
    exit(code);
}

// --- input ------------------------------------------------------------------------

// Bytes read from a stream at a time.
let CHUNK = 1 << 16;

// DEFLATE packs fields from the low bit of each byte up. Input arrives in
// `data`, CHUNK bytes at a time from the stream `f`, or all at once with
// `f` 0, as for a ZIP entry; `base` counts the bytes of earlier chunks.
// `buf` holds the `cnt` bits read but not used yet. It never holds a whole
// byte that is not needed, so a stored block or the gzip trailer reaches a
// byte boundary by dropping it. `who` names the tool in messages.
struct Bits { who: const u8[:] = "inflate", f: u64 = 0, base: i64 = 0, pos: i64 = 0, buf: u64 = 0, cnt: i64 = 0, data: u8[>..] }

// Malformed input: a message naming the tool, then exit 65. Never returns.
fn corrupt(s: Bits&, msg: const u8[:]) {
    stop(EX_DATAERR, str(s.who, ": ", msg));
}

// The next input byte, reading the next chunk when this one is used up.
fn byte(s: Bits&) -> u8 {
    if s.pos >= s.data.len {
        s.base += s.data.len;
        s.data.clear();
        s.pos = 0;
        let n = if s.f == 0 { 0 } else { file::file_read(s.f, CHUNK, s.data) };
        if n < 0 { stop(EX_NOINPUT, str(s.who, ": read error")); }
        if n <= 0 { corrupt(s, "compressed data ends early"); }
    }
    s.pos++;
    return s.data[s.pos - 1];
}

fn bits(s: Bits&, need: i64) -> i64 {
    while s.cnt < need {
        s.buf |= (byte(s) as u64) << (s.cnt as u64);
        s.cnt += 8;
    }
    let v = s.buf & ((1 << (need as u64)) - 1);
    s.buf >>= need as u64;
    s.cnt -= need;
    return v as i64;
}

// A little-endian field of `n` bytes, after dropping the bits held.
fn whole_bytes(s: Bits&, n: i64) -> i64 {
    s.buf = 0;
    s.cnt = 0;
    var v = 0;
    for i in n { v |= (byte(s) as i64) << (8 * i); }
    return v;
}

// Bits of input used so far.
fn bits_in(s: Bits&) -> i64 { (s.base + s.pos) * 8 - s.cnt }

// --- output -----------------------------------------------------------------------

// DEFLATE copies from at most 32 KB back. Decoded bytes collect in `data`;
// `read` is where the caller's next `take` starts. `total` counts every
// byte taken and `crc` is the CRC-32 register over them.
let WINDOW = 32768;
struct Out { crc: u32 = 0xffffffff, total: i64 = 0, read: i64 = 0, data: u8[>..] }

fn put(o: Out&, c: u8) { o.data.push(c); }

// Decoded bytes not taken yet.
fn avail(o: Out&) -> i64 { o.data.len - o.read }

// The next `n` decoded bytes, counted into the CRC-32 and the total. The
// view lasts until the next `compact`.
fn take(o: Out&, n: i64) -> const u8[:] {
    let t = o.data[o.read..o.read + n];
    o.crc = crc32_update(o.crc, t);
    o.total += n;
    o.read += n;
    return t;
}

// Drops taken bytes but the last WINDOW, which a later block may copy from.
fn compact(o: Out&) {
    let n = o.read - WINDOW;
    guard n > 0;
    var keep: u8[>..] = [];
    keep.append(o.data[n..]);
    o.data.clear();
    o.data.append(keep);
    o.read -= n;
}

// The CRC-32 of everything taken.
fn crc(o: Out&) -> i64 { o.crc ^ 0xffffffff }

// --- Huffman codes ----------------------------------------------------------------

// A canonical Huffman code as RFC 1951 §3.2.2 builds it: how many codes
// have each length, and the symbols in code order.
let MAXBITS = 15;
struct Huff { count: i64[16], symbol: i64[288] }

// Builds `h` from code lengths. Returns 0 for a complete code, more than 0
// for an incomplete one, and less than 0 for an oversubscribed one.
fn build(h: Huff&, lengths: const i64[:]) -> i64 {
    h.count = [0; 16];
    for l in lengths { h.count[l]++; }
    if h.count[0] == lengths.len { return 0; }
    var left = 1;
    for len in 1..MAXBITS + 1 {
        left = left * 2 - h.count[len];
        if left < 0 { return left; }
    }
    var offs: i64[16] = [0; 16];
    for len in 1..MAXBITS { offs[len + 1] = offs[len] + h.count[len]; }
    for l, sym in lengths {
        if l != 0 { h.symbol[offs[l]] = sym; offs[l]++; }
    }
    return left;
}

fn decode(s: Bits&, h: Huff&) -> i64 {
    var code = 0;
    var first = 0;
    var index = 0;
    for len in 1..MAXBITS + 1 {
        code |= bits(s, 1);
        let count = h.count[len];
        if code - count < first { return h.symbol[index + (code - first)]; }
        index += count;
        first = (first + count) * 2;
        code *= 2;
    }
    corrupt(s, "no Huffman code matches");
    return -1;
}

// --- blocks -------------------------------------------------------------------------

let LBASE: i64[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                      35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
let LEXT: i64[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                     3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
let DBASE: i64[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                      257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                      8193, 12289, 16385, 24577];
let DEXT: i64[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                     7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

// A length and distance pair: copy `len` bytes from `dist` bytes back in the
// output. The copy may overlap what it writes, so it goes a byte at a time,
// each byte `dist` back from the current end, which `compact` keeps in reach.
fn copy_match(s: Bits&, o: Out&, i: i64, dc: Huff&) {
    if i >= 29 { corrupt(s, "bad length code"); }
    let len = LBASE[i] + bits(s, LEXT[i]);
    let d = decode(s, dc);
    if d >= 30 { corrupt(s, "bad distance code"); }
    let dist = DBASE[d] + bits(s, DEXT[d]);
    if dist > o.data.len { corrupt(s, "a distance reaches before the start of the output"); }
    for _ in len { put(o, o.data[o.data.len - dist]); }
}

enum Kind { Stored, Fixed, Dynamic }

fn kind_name(k: Kind) -> const u8[:] {
    match k { Stored => "stored", Fixed => "fixed", Dynamic => "dynamic" }
}

// Where decoding stands between steps: inside a block or not, its kind, a
// stored block's bytes left, and a coded block's tables. All fixed size.
// `limit` is the untaken output at which `step` returns, even inside a
// block; a caller that needs more at once raises it first, or a step could
// never make the bytes it waits for.
struct Inflater {
    in_block: bool = false, last: bool = false, finished: bool = false,
    kind: Kind = Kind.Stored, left: i64 = 0, limit: i64 = 1 << 20, lc: Huff, dc: Huff,
}

// The usual `limit`.
let LIMIT = 1 << 20;

// Decodes until the current block ends or `z.limit` bytes wait in `o`, starting
// the next block first if none is open. False once the last block has
// ended. A step that ends a block leaves `z.in_block` false.
fn step(z: Inflater&, s: Bits&, o: Out&) -> bool {
    if !z.in_block {
        guard !z.finished else { return false; }
        start_block(z, s);
    }
    if z.kind == Kind.Stored { stored_part(z, s, o); } else { coded_part(z, s, o); }
    return true;
}

// A block's header: the final-block bit, the type, and a stored block's
// length or a coded block's tables.
fn start_block(z: Inflater&, s: Bits&) {
    z.last = bits(s, 1) == 1;
    z.kind = match bits(s, 2) { 0 => Kind.Stored, 1 => Kind.Fixed, 2 => Kind.Dynamic, _ => {
        corrupt(s, "block type 3 is reserved");
        Kind.Stored
    } };
    match z.kind { Stored => stored_header(z, s), Fixed => fixed_tables(z), Dynamic => dynamic_tables(z, s) }
    z.in_block = true;
}

fn end_block(z: Inflater&) {
    z.in_block = false;
    if z.last { z.finished = true; }
}

fn stored_header(z: Inflater&, s: Bits&) {
    let len = whole_bytes(s, 2);
    let nlen = whole_bytes(s, 2);
    if len != (~nlen & 0xffff) { corrupt(s, "stored block length does not match its complement"); }
    z.left = len;
}

fn stored_part(z: Inflater&, s: Bits&, o: Out&) {
    while z.left > 0 && avail(o) < z.limit { put(o, byte(s)); z.left--; }
    if z.left == 0 { end_block(z); }
}

// Symbols until the end of the block or `z.limit` bytes untaken; a match
// may run up to 258 bytes past it.
fn coded_part(z: Inflater&, s: Bits&, o: Out&) {
    while avail(o) < z.limit {
        let sym = decode(s, z.lc);
        if sym < 256 { put(o, sym as u8); continue; }
        if sym == 256 { end_block(z); return; }
        copy_match(s, o, sym - 257, z.dc);
    }
}

fn fixed_tables(z: Inflater&) {
    var lengths: i64[288] = [8; 288];
    for i in 144..256 { lengths[i] = 9; }
    for i in 256..280 { lengths[i] = 7; }
    build(z.lc, lengths);
    let dl: i64[30] = [5; 30];
    build(z.dc, dl);
}

// The order code-length code lengths arrive in (RFC 1951 §3.2.7).
let ORDER: i64[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

// Reads `n` code lengths with the code-length code `h`: 0-15 are lengths,
// 16 repeats the last length 3-6 times, 17 and 18 repeat zero.
fn read_lengths(s: Bits&, h: Huff&, lengths: i64[:], n: i64) {
    var index = 0;
    while index < n {
        let sym = decode(s, h);
        if sym < 16 { lengths[index] = sym; index++; continue; }
        var len = 0;
        var rep = 0;
        if sym == 16 {
            if index == 0 { corrupt(s, "a repeat code comes before any length"); }
            len = lengths[index - 1];
            rep = 3 + bits(s, 2);
        } else if sym == 17 { rep = 3 + bits(s, 3); }
        else { rep = 11 + bits(s, 7); }
        if index + rep > n { corrupt(s, "code lengths run past their count"); }
        for _ in rep { lengths[index] = len; index++; }
    }
}

// A literal/length or distance code may be incomplete only if it is a
// single code of one bit (RFC 1951 §3.2.7), as puff.c also requires.
fn check_code(s: Bits&, left: i64, lengths: const i64[:], what: const u8[:]) {
    var used = 0;
    var ones = 0;
    for l in lengths {
        if l != 0 { used++; }
        if l == 1 { ones++; }
    }
    if left < 0 || (left > 0 && (used != 1 || ones != 1)) { corrupt(s, str("bad ", what, " code lengths")); }
}

fn dynamic_tables(z: Inflater&, s: Bits&) {
    let nlen = bits(s, 5) + 257;
    let ndist = bits(s, 5) + 1;
    let ncode = bits(s, 4) + 4;
    if nlen > 286 || ndist > 30 { corrupt(s, "too many length or distance codes"); }
    var lengths: i64[316] = [0; 316];
    for i in ncode { lengths[ORDER[i]] = bits(s, 3); }
    var h = Huff { .. };
    if build(h, lengths[..19]) != 0 { corrupt(s, "bad code-length code"); }
    for i in 19 { lengths[i] = 0; }
    read_lengths(s, h, lengths, nlen + ndist);
    if lengths[256] == 0 { corrupt(s, "no end-of-block code"); }
    check_code(s, build(z.lc, lengths[..nlen]), lengths[..nlen], "literal/length");
    check_code(s, build(z.dc, lengths[nlen..nlen + ndist]), lengths[nlen..nlen + ndist], "distance");
}

// --- gzip ---------------------------------------------------------------------------

// Skips a zero-terminated field of a gzip header.
fn past_zero(s: Bits&) {
    while byte(s) != 0 {}
}

// The gzip header (RFC 1952): magic, method, flags, then the optional extra
// field, name, comment and header CRC the flags announce. A reserved flag
// bit may announce a field this reader does not know, so RFC 1952 rejects
// it.
fn gzip_header(s: Bits&) {
    let id1 = byte(s);
    let id2 = byte(s);
    if id1 != 0x1f || id2 != 0x8b { corrupt(s, "not a gzip file"); }
    let cm = byte(s);
    if cm != 8 { corrupt(s, str("compression method ", cm, " is not deflate")); }
    let flg = byte(s);
    if (flg & 0xe0) != 0 { corrupt(s, "reserved header flag bits are set"); }
    for _ in 6 { byte(s); }
    optional_fields(s, flg);
}

fn optional_fields(s: Bits&, flg: u8) {
    if (flg & 4) != 0 { for _ in whole_bytes(s, 2) { byte(s); } }
    if (flg & 8) != 0 { past_zero(s); }
    if (flg & 16) != 0 { past_zero(s); }
    if (flg & 2) != 0 { whole_bytes(s, 2); }
}
