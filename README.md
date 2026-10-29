# clintecker/goose-inflate

DEFLATE (RFC 1951) and gzip (RFC 1952) decoding for [Goose](https://github.com/aardappel/goose), as a decoder the caller pulls from, and CRC-32. Memory stays bounded however far a stream expands: a step stops at the end of a block or once 1 MB waits untaken, and only the 32 KB window a later copy may reach is kept.

```goose
import inflate from "clintecker/goose-inflate@v1";
import file from "clintecker/goose-file@v1";

let f = file::file_open("notes.txt.gz");
var s = inflate::Bits { who: "mytool", f: f, data: [] };   // or f 0 and the bytes in s.data
var o = inflate::Out { data: [] };
var z = inflate::Inflater { lc: inflate::Huff { .. }, dc: inflate::Huff { .. } };
inflate::gzip_header(s);
while inflate::step(z, s, o) {
    write_stdout(inflate::take(o, inflate::avail(o)));
    inflate::compact(o);
}
let ok = inflate::whole_bytes(s, 4) == inflate::crc(o);   // the gzip trailer's CRC-32
```

`test/inflate_test.goose` runs this on a file made by `gzip -9`, from a file handle and from bytes in memory.

## Types and functions

| Name | What it is |
|---|---|
| `Bits` | the input: a [clintecker/goose-file](https://github.com/clintecker/goose-file) handle `f` read 64 KB at a time, or `f` 0 and all the bytes in `data`; `who` names the program in error messages |
| `Out` | the output: decoded bytes in `data`, those not yet taken, the running CRC-32 and the total |
| `Inflater` | where decoding is: the block kind, whether it is inside a block, the code tables |
| `step(z, s, o) -> bool` | decodes until a block ends or 1 MB waits untaken; false after the last block |
| `avail(o)`, `take(o, n)` | bytes decoded and not yet taken; the next `n` of them as a slice, counted into the CRC-32 |
| `compact(o)` | drops what was taken, keeping the 32 KB window |
| `crc(o)`, `o.total` | the CRC-32 and the number of bytes taken |
| `gzip_header(s)` | reads and checks a gzip member header, skipping its optional fields |
| `whole_bytes(s, n)` | the next `n` bytes as a little-endian integer, from a byte boundary (a gzip trailer) |
| `bits_in(s)`, `kind_name(z.kind)` | input bits used so far, and "stored", "fixed" or "dynamic", for a per-block report |
| `crc32(bytes) -> i64`, `crc32_update(c, bytes) -> u32` | CRC-32 as PNG, ZIP and gzip define it; the second continues a register over data that arrives in pieces |

The other functions are the decoder's steps; Goose has no private functions, so they are visible, but they are not part of the interface.

## Errors

Corrupt input prints `<who>: <what is wrong>` to stderr and exits with 65 (`EX_DATAERR`); a read error on the handle exits with 66 (`EX_NOINPUT`). The decoder does not return errors to the caller.

## Limits

- Decoding only; no compression. No zlib wrapper and no ZIP container, though a ZIP entry's DEFLATE data decodes with `f` 0 and the entry's bytes in `data`.
- Huffman codes are decoded a bit at a time, as Mark Adler's puff.c does: simple and checked, not the fastest.
- The package requires clintecker/goose-file, so a program that uses only `crc32` still declares it.

MIT licence (LICENSE).
