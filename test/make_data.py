"""Write the raw DEFLATE test data with Python's zlib.

payload.bin is 200 KB of text, runs and pseudo-random bytes, so a stream
holds several blocks and slides the 64 KB window; levelN.deflate is it
compressed at level N (0 gives stored blocks). The output is the same on
every run. From the package root: python3 test/make_data.py
"""
import os
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


if __name__ == "__main__":
    main()
