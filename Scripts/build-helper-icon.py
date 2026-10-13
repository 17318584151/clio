"""从主应用图标提取辅助程序使用的 16～256 像素尺寸。"""

from pathlib import Path
import struct
import sys

source = Path(sys.argv[1]).read_bytes()
magic, size = struct.unpack('>4sI', source[:8])
assert magic == b'icns' and size == len(source)

sizes = {b'ic04', b'ic05', b'ic07', b'ic08', b'ic11', b'ic12', b'ic13'}
chunks = []
offset = 8
while offset < len(source):
    kind, length = struct.unpack('>4sI', source[offset:offset + 8])
    assert length >= 8 and offset + length <= len(source)
    if kind in sizes:
        chunks.append(source[offset:offset + length])
    offset += length

assert chunks
payload = b''.join(chunks)
Path(sys.argv[2]).write_bytes(struct.pack('>4sI', b'icns', len(payload) + 8) + payload)
