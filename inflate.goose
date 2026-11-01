// DEFLATE (RFC 1951) and gzip (RFC 1952) decoded from pieces of any size:
// `start` a raw stream or `gzip_start` a gzip one, `add` pieces, `finish`.
// Decoded bytes reach the caller's block as views into the window the
// state holds, valid for the call. The state is fixed-size arrays the
// caller owns: nothing is allocated, nothing is read or written, and an
// error is `false`, with the compressed offset in `err_at` and `reason`.
// Decoding walks Huffman codes a bit at a time, as Mark Adler's puff.c
// does. crc32.goose is the CRC-32.
namespace inflate;
import std;
import .crc32;

// What went wrong. `reason` gives each one's message.
enum Why { None, Truncated, BlockType, StoredLength, NoCode, LengthCode, DistanceCode, TooFar,
           RepeatFirst, LengthsOver, BadLiteralLengths, BadDistanceLengths, TooMany, BadCodeLengths,
           NoEndCode, NotGzip, Method, Reserved, Crc, Length, Trailing }

enum Kind { Stored, Fixed, Dynamic }

fn kind_name(k: Kind) -> const u8[:] {
    match k { Stored => "stored", Fixed => "fixed", Dynamic => "dynamic" }
}

// Where the decoder is.
let IN_GZIP = 0;       // the gzip header's fixed 10 bytes
let IN_FIELDS = 1;     // the optional gzip fields its flags announce
let IN_BLOCK = 2;      // the next block's header
let IN_STORED = 3;     // a stored block's bytes
let IN_CLENS = 4;      // a dynamic block's code-length code lengths
let IN_LENS = 5;       // a dynamic block's literal/length and distance code lengths
let IN_CODES = 6;      // a coded block's symbols
let IN_TRAILER = 7;    // the gzip trailer
let IN_END = 8;
let IN_NEXT = 9;      // after a gzip trailer: zero bytes, or the next member

// What a run over the input stopped for.
let GO = 0;            // a unit is done; go on
let MORE = 1;          // the input ran out inside a unit
let FULL = 2;          // the window needs handing over
let ENDED = 3;         // a block ended
let PAUSE = 4;         // the joined carry is used up
let BAD = 5;
let DONE = 6;

// DEFLATE copies from at most WINDOW bytes back. The window holds two of
// those; when it nears full, the bytes not handed over yet are, and the
// last WINDOW move to the front. A match writes at most MATCH bytes.
let WINDOW = 32768;
let WIN = 2 * WINDOW;
let MATCH = 258;

// A unit needs at most 10 bytes (the gzip header), so fewer than CARRY
// are ever carried, and JOIN bytes of carry and piece always hold a unit.
let CARRY = 16;
let JOIN = 96;

// A canonical Huffman code as RFC 1951 §3.2.2 builds it: how many codes
// have each length, and the symbols in code order.
let MAXBITS = 15;
struct Huff { count: i64[16], symbol: i64[288] }

struct Inflate {
    phase: i64, gzip: bool, last: bool, kind: Kind,
    at: i64,                        // compressed bytes taken in
    i: i64, stop: i64,              // the read position in the input of this run, and where a
                                    // run over the carry hands over to the piece (-1: it does not)
    buf: u64, cnt: i64,             // bits taken in and not used; cnt stays under 8 between reads
    mbuf: u64, mcnt: i64, mat: i64, // the same at the start of the current unit
    left: i64,                      // a stored block's bytes left, or a gzip extra field's
    flags: i64,                     // the gzip header flags whose fields are still to read
    nlen: i64, ndist: i64, ncode: i64, index: i64,
    made: i64,                      // bytes decoded
    before: i64,                    // bytes decoded before this gzip member
    members: i64,                   // gzip members whose trailer matched
    pos: i64, sent: i64,            // the window's end, and how far it was handed over
    crc: u32,
    blocks: i64,                    // blocks ended
    block_from: i64, block_to: i64, // the input bits the last block began and ended at
    err_at: i64, why: Why, err_a: i64, err_b: i64,
    lengths: i64[316],
    clh: Huff, lc: Huff, dc: Huff,
    carry: u8[..16], join: u8[..96],
    win: u8[65536],
}

// A raw DEFLATE stream, as in a ZIP entry.
fn start() -> Inflate {
    return Inflate { phase: IN_BLOCK, gzip: false, last: false, kind: Kind.Stored, at: 0, i: 0, stop: -1, buf: 0, cnt: 0,
                     mbuf: 0, mcnt: 0, mat: 0, left: 0, flags: 0, nlen: 0, ndist: 0, ncode: 0, index: 0,
                     made: 0, before: 0, members: 0, pos: 0, sent: 0, crc: 0xffffffff, blocks: 0, block_from: 0, block_to: 0,
                     err_at: -1, why: Why.None, err_a: 0, err_b: 0, lengths: [0; 316],
                     clh: Huff { .. }, lc: Huff { .. }, dc: Huff { .. }, carry: [], join: [], win: [0; 65536] };
}

// A gzip stream: members, each a header, DEFLATE data, then the trailer's
// CRC-32 and length, until the input ends. Zero bytes after a trailer are
// padding.
fn gzip_start() -> Inflate {
    var z = start();
    z.phase = IN_GZIP;
    z.gzip = true;
    return z;
}

// The CRC-32 of the bytes decoded so far; for gzip, so far in this member.
fn crc(z: Inflate&) -> i64 { z.crc ^ 0xffffffff }

// Bits of input used so far.
fn bits_in(z: Inflate&) -> i64 { z.at * 8 - z.cnt }

fn hex8(out: u8[>..]&, v: i64) { out.append("0x"); format_int(out, v, 16, 8, '0'); }

// What went wrong, as v1 worded it: one case function per Why, so a new
// error does not compile until it has its words.
fn reason(out: u8[>..]&, z: Inflate&) { say(out, z.why, z); }

fn say(out: u8[>..]&, w: Why.None,               z: Inflate&) { out.append(""); }
fn say(out: u8[>..]&, w: Why.Truncated,          z: Inflate&) { out.append("compressed data ends early"); }
fn say(out: u8[>..]&, w: Why.BlockType,          z: Inflate&) { out.append("block type 3 is reserved"); }
fn say(out: u8[>..]&, w: Why.StoredLength,       z: Inflate&) { out.append("stored block length does not match its complement"); }
fn say(out: u8[>..]&, w: Why.NoCode,             z: Inflate&) { out.append("no Huffman code matches"); }
fn say(out: u8[>..]&, w: Why.LengthCode,         z: Inflate&) { out.append("bad length code"); }
fn say(out: u8[>..]&, w: Why.DistanceCode,       z: Inflate&) { out.append("bad distance code"); }
fn say(out: u8[>..]&, w: Why.TooFar,             z: Inflate&) { out.append("a distance reaches before the start of the output"); }
fn say(out: u8[>..]&, w: Why.RepeatFirst,        z: Inflate&) { out.append("a repeat code comes before any length"); }
fn say(out: u8[>..]&, w: Why.LengthsOver,        z: Inflate&) { out.append("code lengths run past their count"); }
fn say(out: u8[>..]&, w: Why.BadLiteralLengths,  z: Inflate&) { out.append("bad literal/length code lengths"); }
fn say(out: u8[>..]&, w: Why.BadDistanceLengths, z: Inflate&) { out.append("bad distance code lengths"); }
fn say(out: u8[>..]&, w: Why.TooMany,            z: Inflate&) { out.append("too many length or distance codes"); }
fn say(out: u8[>..]&, w: Why.BadCodeLengths,     z: Inflate&) { out.append("bad code-length code"); }
fn say(out: u8[>..]&, w: Why.NoEndCode,          z: Inflate&) { out.append("no end-of-block code"); }
fn say(out: u8[>..]&, w: Why.NotGzip,            z: Inflate&) { out.append("not a gzip file"); }
fn say(out: u8[>..]&, w: Why.Reserved,           z: Inflate&) { out.append("reserved header flag bits are set"); }
fn say(out: u8[>..]&, w: Why.Method, z: Inflate&) { format(out, "compression method ", z.err_a, " is not deflate"); }
fn say(out: u8[>..]&, w: Why.Length, z: Inflate&) { format(out, "length is ", z.err_a, ", the file records ", z.err_b); }
fn say(out: u8[>..]&, w: Why.Trailing, z: Inflate&) { format(out, "the bytes after gzip member ", z.members, " are not a gzip member"); }
fn say(out: u8[>..]&, w: Why.Crc, z: Inflate&) {
    out.append("CRC-32 is ");
    hex8(out, z.err_a);
    out.append(", the file records ");
    hex8(out, z.err_b);
}

// --- the caller's side ------------------------------------------------------------

// Decodes the next piece, of any size from one byte up, calling the block
// with each run of decoded bytes, and with `ended` true as a block ends.
// False once the data are malformed, and every later call is false too.
fn add<F>(z: Inflate&, piece: const u8[:]) -> bool {
    guard z.why == Why.None else { return false; }
    var from = 0;
    if z.carry.len > 0 {
        z.join.clear();
        z.join.append(z.carry);
        let held = z.carry.len;
        z.join.append(piece[..min(piece.len, JOIN - held)]);
        z.carry.clear();
        z.i = 0;
        z.stop = held;
        let s = drive(z, z.join) { out, ended => F(out, ended); };
        guard s == PAUSE else { return s != BAD; }
        from = z.i - held;
    }
    z.i = 0;
    z.stop = -1;
    return drive(z, piece[from..]) { out, ended => F(out, ended); } != BAD;
}

// The end of the input: true if the stream ended, and for gzip if each
// member's trailer matched and no member is cut short.
fn finish(z: Inflate&) -> bool {
    guard z.why == Why.None else { return false; }
    if z.phase != IN_END && z.phase != IN_NEXT { z.err_at = z.at; z.why = Why.Truncated; return false; }
    return true;
}

// Runs over `d`, handing over the window when it fills or a block ends,
// until the input runs out, the stream ends or an error. Out of input
// inside a unit, the unit is undone and its bytes carried to the next piece.
fn drive<F>(z: Inflate&, d: const u8[:]) -> i64 {
    loop {
        let s = run(z, d);
        if s == FULL || s == ENDED { hand_over(z, s == ENDED) { out, ended => F(out, ended); }; continue; }
        if s == MORE { undo(z, d); z.carry.append(d[z.i..]); }
        if s == DONE { hand_over(z, false) { out, ended => F(out, ended); }; }
        if s == MORE || s == PAUSE { hand_over(z, false) { out, ended => F(out, ended); }; }
        return s;
    }
}

// The decoded bytes not handed over yet, to the block; then, if the window
// is nearly full, its last WINDOW bytes move to the front.
fn hand_over<F>(z: Inflate&, ended: bool) {
    if z.pos > z.sent || ended {
        let out = z.win[z.sent..z.pos];
        z.crc = crc32_update(z.crc, out);
        F(out, ended);
        z.sent = z.pos;
    }
    guard z.pos > WIN - MATCH;
    let from = z.pos - WINDOW;
    for k in WINDOW { z.win[k] = z.win[from + k]; }
    z.pos = WINDOW;
    z.sent = WINDOW;
}

// --- input ------------------------------------------------------------------------

// Units are read whole or not at all: each starts with a mark, and a unit
// that runs out of input is undone back to it.
fn mark(z: Inflate&, d: const u8[:]) -> i64 {
    z.mbuf = z.buf;
    z.mcnt = z.cnt;
    z.mat = z.at;
    return z.i;
}

fn undo(z: Inflate&, d: const u8[:]) {
    z.i -= z.at - z.mat;
    z.buf = z.mbuf;
    z.cnt = z.mcnt;
    z.at = z.mat;
}

// The next `n` bits, low bit first. Out of input, the run stops.
fn bits(z: Inflate&, d: const u8[:], n: i64) -> i64 {
    while z.cnt < n {
        if z.i >= d.len { return MORE from run; }
        z.buf |= (d[z.i] as u64) << (z.cnt as u64);
        z.i++;
        z.at++;
        z.cnt += 8;
    }
    let v = z.buf & ((1 << (n as u64)) - 1);
    z.buf >>= n as u64;
    z.cnt -= n;
    return v as i64;
}

// To the next byte boundary: a whole byte is never held, so this drops
// only the bits left of the current one.
fn align(z: Inflate&) {
    z.buf = 0;
    z.cnt = 0;
}

// Malformed data, at the byte where the current unit starts. The run stops.
fn corrupt(z: Inflate&, why: Why) {
    fail_at(z, (z.mat * 8 - z.mcnt) / 8, why, 0, 0);
    return BAD from run;
}

fn fail_at(z: Inflate&, at: i64, why: Why, a: i64, b: i64) {
    z.err_at = at;
    z.why = why;
    z.err_a = a;
    z.err_b = b;
}

// --- the units ----------------------------------------------------------------------

// Units until one stops the run. Each unit reads all it needs before it
// changes anything but the bit buffer, so undoing one is resetting that.
fn run(z: Inflate&, d: const u8[:]) -> i64 {
    loop {
        let at = mark(z, d);
        if z.stop >= 0 && at >= z.stop { return PAUSE; }
        if z.pos > WIN - MATCH { return FULL; }
        let s = unit(z, d);
        if s != GO { return s; }
    }
}

fn unit(z: Inflate&, d: const u8[:]) -> i64 {
    if z.phase == IN_CODES { return symbol(z, d); }
    if z.phase == IN_BLOCK { return block_header(z, d); }
    if z.phase == IN_STORED { return stored(z, d); }
    if z.phase == IN_LENS { return length_code(z, d); }
    if z.phase == IN_CLENS { return code_length(z, d); }
    if z.phase == IN_GZIP { return gzip_header(z, d); }
    if z.phase == IN_FIELDS { return gzip_field(z, d); }
    if z.phase == IN_TRAILER { return trailer(z, d); }
    if z.phase == IN_NEXT { return next_member(z, d); }
    return DONE;
}

// --- Huffman codes ----------------------------------------------------------------

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

fn decode(z: Inflate&, d: const u8[:], h: Huff&) -> i64 {
    var code = 0;
    var first = 0;
    var index = 0;
    for len in 1..MAXBITS + 1 {
        code |= bits(z, d, 1);
        let count = h.count[len];
        if code - count < first { return h.symbol[index + (code - first)]; }
        index += count;
        first = (first + count) * 2;
        code *= 2;
    }
    corrupt(z, Why.NoCode);
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

// A block's header: the final-block bit, the type, and a stored block's
// length or a dynamic block's three counts. A fixed block's tables are
// built here.
fn block_header(z: Inflate&, d: const u8[:]) -> i64 {
    let last = bits(z, d, 1) == 1;
    let kind = bits(z, d, 2);
    if kind == 3 { corrupt(z, Why.BlockType); }
    if kind == 0 { return stored_header(z, d, last); }
    if kind == 1 { fixed_tables(z); z.phase = IN_CODES; }
    else { dynamic_counts(z, d); }
    z.last = last;
    z.kind = if kind == 1 { Kind.Fixed } else { Kind.Dynamic };
    return GO;
}

fn stored_header(z: Inflate&, d: const u8[:], last: bool) -> i64 {
    align(z);
    let len = bits(z, d, 16);
    let nlen = bits(z, d, 16);
    if len != (~nlen & 0xffff) { corrupt(z, Why.StoredLength); }
    z.left = len;
    z.last = last;
    z.kind = Kind.Stored;
    z.phase = IN_STORED;
    if len == 0 { return end_block(z); }
    return GO;
}

// As many of a stored block's bytes as the piece and the window hold.
fn stored(z: Inflate&, d: const u8[:]) -> i64 {
    let k = min(min(z.left, d.len - z.i), WIN - z.pos);
    guard k > 0 else { return MORE; }
    for b in d[z.i..z.i + k] { z.win[z.pos] = b; z.pos++; }
    z.i += k;
    z.at += k;
    z.made += k;
    z.left -= k;
    if z.left == 0 { return end_block(z); }
    return GO;
}

fn end_block(z: Inflate&) -> i64 {
    z.blocks++;
    z.block_from = z.block_to;
    z.block_to = bits_in(z);
    z.phase = if !z.last { IN_BLOCK } else if z.gzip { IN_TRAILER } else { IN_END };
    return ENDED;
}

// One literal, the end of the block, or a length and distance pair: copy
// `len` bytes from `dist` back. The copy may overlap what it writes, so it
// goes a byte at a time.
fn symbol(z: Inflate&, d: const u8[:]) -> i64 {
    let sym = decode(z, d, z.lc);
    if sym < 256 { z.win[z.pos] = sym as u8; z.pos++; z.made++; return GO; }
    if sym == 256 { return end_block(z); }
    let i = sym - 257;
    if i >= 29 { corrupt(z, Why.LengthCode); }
    let len = LBASE[i] + bits(z, d, LEXT[i]);
    let ds = decode(z, d, z.dc);
    if ds >= 30 { corrupt(z, Why.DistanceCode); }
    let dist = DBASE[ds] + bits(z, d, DEXT[ds]);
    if dist > z.made - z.before { corrupt(z, Why.TooFar); }
    for _ in len { z.win[z.pos] = z.win[z.pos - dist]; z.pos++; }
    z.made += len;
    return GO;
}

fn fixed_tables(z: Inflate&) {
    var lengths: i64[288] = [8; 288];
    for i in 144..256 { lengths[i] = 9; }
    for i in 256..280 { lengths[i] = 7; }
    build(z.lc, lengths);
    let dl: i64[30] = [5; 30];
    build(z.dc, dl);
}

// The order code-length code lengths arrive in (RFC 1951 §3.2.7).
let ORDER: i64[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

fn dynamic_counts(z: Inflate&, d: const u8[:]) {
    let nlen = bits(z, d, 5) + 257;
    let ndist = bits(z, d, 5) + 1;
    let ncode = bits(z, d, 4) + 4;
    if nlen > 286 || ndist > 30 { corrupt(z, Why.TooMany); }
    z.nlen = nlen;
    z.ndist = ndist;
    z.ncode = ncode;
    z.index = 0;
    z.lengths = [0; 316];
    z.phase = IN_CLENS;
}

// One code-length code length; after the last, that code is built.
fn code_length(z: Inflate&, d: const u8[:]) -> i64 {
    let l = bits(z, d, 3);
    z.lengths[ORDER[z.index]] = l;
    z.index++;
    guard z.index == z.ncode else { return GO; }
    if build(z.clh, z.lengths[..19]) != 0 { corrupt(z, Why.BadCodeLengths); }
    z.lengths = [0; 316];
    z.index = 0;
    z.phase = IN_LENS;
    return GO;
}

// One code-length symbol: 0-15 is a length, 16 repeats the last length
// 3-6 times, 17 and 18 repeat zero. After the last, the codes are built.
fn length_code(z: Inflate&, d: const u8[:]) -> i64 {
    let n = z.nlen + z.ndist;
    let sym = decode(z, d, z.clh);
    var len = sym;
    var rep = 1;
    if sym == 16 { rep = 3 + bits(z, d, 2); }
    else if sym == 17 { rep = 3 + bits(z, d, 3); len = 0; }
    else if sym == 18 { rep = 11 + bits(z, d, 7); len = 0; }
    if sym == 16 && z.index == 0 { corrupt(z, Why.RepeatFirst); }
    if sym == 16 { len = z.lengths[z.index - 1]; }
    if z.index + rep > n { corrupt(z, Why.LengthsOver); }
    for _ in rep { z.lengths[z.index] = len; z.index++; }
    if z.index == n { codes_built(z); }
    return GO;
}

// A literal/length or distance code may be incomplete only if it is a
// single code of one bit (RFC 1951 §3.2.7), as puff.c also requires.
fn code_ok(left: i64, lengths: const i64[:]) -> bool {
    var used = 0;
    var ones = 0;
    for l in lengths {
        if l != 0 { used++; }
        if l == 1 { ones++; }
    }
    return left >= 0 && (left == 0 || (used == 1 && ones == 1));
}

fn codes_built(z: Inflate&) {
    let nlen = z.nlen;
    let n = nlen + z.ndist;
    if z.lengths[256] == 0 { corrupt(z, Why.NoEndCode); }
    if !code_ok(build(z.lc, z.lengths[..nlen]), z.lengths[..nlen]) { corrupt(z, Why.BadLiteralLengths); }
    if !code_ok(build(z.dc, z.lengths[nlen..n]), z.lengths[nlen..n]) { corrupt(z, Why.BadDistanceLengths); }
    z.phase = IN_CODES;
}

// --- gzip ---------------------------------------------------------------------------

// The gzip header's fixed part (RFC 1952): magic, method, flags, time,
// extra flags and system. A reserved flag bit may announce a field this
// reader does not know, so RFC 1952 rejects it.
fn gzip_header(z: Inflate&, d: const u8[:]) -> i64 {
    let id = bits(z, d, 16);
    let cm = bits(z, d, 8);
    let flg = bits(z, d, 8);
    for _ in 3 { bits(z, d, 16); }
    if id != 0x8b1f { corrupt(z, if z.members > 0 { Why.Trailing } else { Why.NotGzip }); }
    if cm != 8 { fail_at(z, z.mat + 2, Why.Method, cm, 0); return BAD; }
    if (flg & 0xe0) != 0 { corrupt(z, Why.Reserved); }
    z.flags = flg;
    z.phase = IN_FIELDS;
    return GO;
}

// The optional fields, in order: extra (its length, then its bytes), name
// and comment (each to a zero byte), and the header CRC.
fn gzip_field(z: Inflate&, d: const u8[:]) -> i64 {
    if z.left > 0 { return skip(z, d); }
    if (z.flags & 4) != 0 { z.left = bits(z, d, 16); z.flags &= ~4; return GO; }
    if (z.flags & 8) != 0 { if bits(z, d, 8) == 0 { z.flags &= ~8; } return GO; }
    if (z.flags & 16) != 0 { if bits(z, d, 8) == 0 { z.flags &= ~16; } return GO; }
    if (z.flags & 2) != 0 { bits(z, d, 16); z.flags &= ~2; return GO; }
    z.phase = IN_BLOCK;
    z.block_to = bits_in(z);
    return GO;
}

fn skip(z: Inflate&, d: const u8[:]) -> i64 {
    let k = min(z.left, d.len - z.i);
    guard k > 0 else { return MORE; }
    z.i += k;
    z.at += k;
    z.left -= k;
    return GO;
}

// The CRC-32 and length of the member's decoded data, checked against all
// of it.
fn trailer(z: Inflate&, d: const u8[:]) -> i64 {
    align(z);
    let want = bits(z, d, 32);
    let size = bits(z, d, 32);
    let n = z.made - z.before;
    if crc(z) != want { fail_at(z, z.at - 8, Why.Crc, crc(z), want); return BAD; }
    if (n & 0xffffffff) != size { fail_at(z, z.at - 4, Why.Length, n, size); return BAD; }
    z.members++;
    z.phase = IN_NEXT;
    return GO;
}

// After a trailer: a zero byte, which is padding, or the start of the next
// member, which is read again as its header. A member is decoded on its
// own: its CRC-32 and length start over, and no distance reaches into the
// members before it.
fn next_member(z: Inflate&, d: const u8[:]) -> i64 {
    if bits(z, d, 8) == 0 { return GO; }
    undo(z, d);
    z.crc = 0xffffffff;
    z.before = z.made;
    z.last = false;
    z.phase = IN_GZIP;
    return GO;
}
