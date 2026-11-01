# clintecker/goose-inflate

DEFLATE (RFC 1951) and gzip (RFC 1952) decoding for [Goose](https://github.com/aardappel/goose), fed compressed pieces of any size, and CRC-32. The state is one record of fixed-size arrays you own: nothing is allocated, nothing is read or written, and an error comes back as `false` with an offset and a reason, so the decoder sits between a file, a network buffer or an archive reader and whatever reads its output.

```goose
import inflate from "clintecker/goose-inflate@v3";

var z = inflate::gzip_start();             // inflate::start() for raw DEFLATE, as in a ZIP entry
for piece in pieces {
    let ok = inflate::add(z, piece) { out, ended => write_stdout(out); };
    if !ok { break; }
}
if !inflate::finish(z) {                    // the stream ended, and each gzip trailer matched
    var why: u8[>..] = [];
    inflate::reason(why, z);
    print("byte ", z.err_at, ": ", why);
}
```

## Functions

| Function | What it does |
|---|---|
| `start() -> Inflate` | a decoder for a raw DEFLATE stream |
| `gzip_start() -> Inflate` | a decoder for a gzip file: members until the input ends, as `cat a.gz b.gz` writes them, each a header, DEFLATE data, then the trailer's CRC-32 and length, checked; zero bytes after a trailer are padding |
| `add(z, piece) { out, ended => ... } -> bool` | decodes the next piece, from one byte up; calls the block with each run of output, a view into the decoder's window valid for the call, and with `ended` true as a block ends; false once the data are malformed, and every later call is false too |
| `finish(z) -> bool` | the end of the input: true if the stream ended (and, for gzip, no member is cut short) |
| `reason(out, z)` | what went wrong, as a sentence; `z.err_at` is the offset in the compressed data |
| `crc(z)`, `z.made`, `z.at`, `z.members` | the CRC-32 of the output so far (for gzip, in the current member), the count of all of it, the compressed bytes used, and the gzip members whose trailer matched |
| `z.blocks`, `z.kind`, `z.block_from`, `z.block_to`, `kind_name(k)` | blocks ended, the last one's kind and the input bits it began and ended at, for a per-block report |
| `crc32(bytes) -> i64`, `crc32_update(c, bytes) -> u32` | CRC-32 as PNG, ZIP and gzip define it; the second continues a register over data that arrive in pieces |

The other functions are the decoder's steps; Goose has no private functions, so they are visible, but they are not part of the interface.

The same stream gives the same output, block ends and error offset however it is cut into pieces: `test/inflate_test.goose` checks every stream whole and in pieces of 1, 7 and 65,536 bytes.

## How

Decoding goes in units: a block header, a code length, one literal or length and distance pair, a run of a stored block. Each unit reads all the bits it needs before it changes anything, at most 10 bytes, so when a piece runs out inside one the unit is undone and its bytes are carried, at most 15, into the next piece. Output goes into a 64 KB window in the state; when it nears full, what is new is handed to the block and the last 32 KB, all a later copy may reach, move to the front. Huffman codes are decoded a bit at a time, as Mark Adler's puff.c does.

## Errors

`add` and `finish` return false, `z.why` says which, and `reason` writes it, in the words v1 printed: `compressed data ends early`, `block type 3 is reserved`, `stored block length does not match its complement`, `no Huffman code matches`, `bad length code`, `bad distance code`, `a distance reaches before the start of the output`, `a repeat code comes before any length`, `code lengths run past their count`, `bad literal/length code lengths`, `bad distance code lengths`, `too many length or distance codes`, `bad code-length code`, `no end-of-block code`, `not a gzip file`, `compression method N is not deflate`, `reserved header flag bits are set`, `CRC-32 is 0x…, the file records 0x…`, `length is N, the file records M`, `the bytes after gzip member N are not a gzip member`.

## Limits

- Decoding only; no compression, and no zlib wrapper.
- Huffman codes are decoded a bit at a time: simple and checked, not the fastest.

## Versions

v1 (`@v1`) is a pull decoder over a [clintecker/goose-file](https://github.com/clintecker/goose-file) handle that exits the program on corrupt data. v2 takes pieces and returns errors, and needs no other package; its gzip decoder reads one member and ignores the bytes after it. v3 reads every member: each is decoded on its own, so a distance that reaches into an earlier member is an error, as gzip and zlib make it, and any byte after a trailer other than a zero or a gzip header is an error.

## Tests

From the package root: `goose run test/inflate_test.goose`. `python3 test/make_data.py` rebuilds the raw DEFLATE data with Python's zlib; the .gz files were made by gzip.

MIT licence (LICENSE).
