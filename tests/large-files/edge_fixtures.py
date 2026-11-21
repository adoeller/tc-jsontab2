from pathlib import Path
import sys

root=Path(sys.argv[1])
root.mkdir(exist_ok=True)
for size, name in [(5242880,"default-full"),(5242881,"default-stream"),(10485760,"legacy-full"),
                   (10485761,"legacy-reject"),(20971520,"override")]:
    for ext in ("json","jsonl"):
        if ext=="json":
            start=b'[{"id":0}]'
        else:
            start=b'{"id":0}\n'
        (root/f"{name}.{ext}").write_bytes(start+b' '*(size-len(start)))
(root/'refresh.jsonl').write_bytes(b'{"id":1}\n{"id":2}')
(root/'broken.jsonl').write_bytes(b'{"id":1}\n{"id":}')
body='[{"id":0,"ключ":"✓"},{"id":1,"ключ":"éТ✓"}]'
(root/'utf16le.json').write_bytes(b'\xff\xfe'+body.encode('utf-16-le'))
(root/'utf16be.json').write_bytes(b'\xfe\xff'+body.encode('utf-16-be'))
(root/'utf8bom.json').write_bytes(body.encode('utf-8-sig'))
(root/'ansi.jsonl').write_bytes(b'{"id":0,"k":"ASCII"}\n{"id":1,"k":"\xe9"}\n')
with (root/'long.jsonl').open('wb') as f:
    f.write(b'{"id":0,"kind":null,"blob":"')
    f.write(b'a'*(34*2**20))
    f.write(b'tail\\u0054oken"}\n{"id":1,"kind":"null","blob":"short"}\n{"id":2,"blob":"short"}\n')
