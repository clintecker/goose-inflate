// CRC-32 as PNG, ZIP and gzip define it (polynomial 0xedb88320, reflected),
// a table built once at start-up. `import inflate.crc32;` is not needed:
// the entry imports it, so it is inflate::crc32.
namespace inflate;
import std;

let CRC_TABLE = crc_table();

fn crc_table() -> u32[256] {
    var t: u32[256] = [0; 256];
    for n in 256 {
        var c = n as u32;
        for _ in 8 { c = if (c & 1) != 0 { 0xedb88320 ^ (c >> 1) } else { c >> 1 }; }
        t[n] = c;
    }
    return t;
}

// The CRC-32 of `b`, as a non-negative i64.
fn crc32(b: const u8[:]) -> i64 {
    return crc32_update(0xffffffff, b) ^ 0xffffffff;
}

// The CRC-32 register after `b`, for data that arrives in pieces: start
// from 0xffffffff, and the CRC is the last register ^ 0xffffffff.
fn crc32_update(c: u32, b: const u8[:]) -> u32 {
    var r = c;
    for x in b { r = CRC_TABLE[(r ^ x) & 0xff] ^ (r >> 8); }
    return r;
}
