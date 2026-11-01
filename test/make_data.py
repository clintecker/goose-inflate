"""Write the raw DEFLATE test data with Python's zlib.

payload.bin is 200 KB of text, runs and pseudo-random bytes, so a stream
holds several blocks and slides the 64 KB window; levelN.deflate is it
compressed at level N (0 gives stored blocks). zdict.gz is two gzip
members, the second compressed with the first's text as a preset
dictionary, so its distances reach into the first member. The output is
the same on every run. From the package root: python3 test/make_data.py
"""
import gzip
import os
import struct
import zlib

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def payload():
    text = b"".join(b"line %d: the quick brown fox jumps over the lazy dog\n" % i for i in range(1500))
    runs = b"a" * 40000 + b"ab" * 10000
    noise = bytes((i * 7919 + (i >> 5) * 104729) % 251 for i in range(60000))
    return text + runs + noise + text[:20000]


def main():
    data = payload()
    with open(os.path.join(HERE, "payload.bin"), "wb") as f:
        f.write(data)
    for level in (0, 1, 6, 9):
        c = zlib.compressobj(level, zlib.DEFLATED, -15)
        with open(os.path.join(HERE, "level%d.deflate" % level), "wb") as f:
            f.write(c.compress(data) + c.flush())
    with open(os.path.join(HERE, "zdict.gz"), "wb") as f:
        f.write(zdict_members())


def zdict_members():
    text = b"the second member copies from the first one\n" * 4
    c = zlib.compressobj(9, zlib.DEFLATED, -15, zdict=text)
    body = c.compress(text) + c.flush()
    second = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff" + body + struct.pack("<II", zlib.crc32(text), len(text))
    return gzip.compress(text, mtime=0) + second


if __name__ == "__main__":
    main()
