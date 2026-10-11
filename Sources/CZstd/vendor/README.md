# Zstandard decoder

`zstddeclib.c` is the unmodified single-file decoder generated from Facebook's
[Zstandard v1.5.7](https://github.com/facebook/zstd/tree/v1.5.7).
It is compiled into Clio; reading compressed logs requires no installed tool.
The BSD license is in `LICENSE`.

To regenerate, unpack the official v1.5.7 source archive and run:

```sh
cd zstd-1.5.7/build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

`include/CZstd.h` exposes only the streaming decoder functions used by Clio.
