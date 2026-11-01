#!/usr/bin/env python3
"""Independent wide-integer GEMM oracle; no TensorFlow/NumPy dependency.

This is Michael's compute-only fixture format, NOT Jackie's deployment-blob ABI.
"""
import argparse
import json
import random
from pathlib import Path


def align16(n):
    return (n + 15) // 16 * 16


def hex_words(path, data):
    path.write_text("".join(f"{int.from_bytes(data[i:i+16], 'little'):032x}\n"
                            for i in range(0, len(data), 16)))


def generate(output, rows, cols):
    rng = random.Random(20261029)
    output.mkdir(parents=True, exist_ok=True)
    cases = []
    shapes = [(rows, cols, 16), (1, 1, 1), (rows, cols, 15),
              (rows, cols, 17), (1, cols, 40), (rows, 1, 31),
              (max(1, rows-1), max(1, cols-1), 33), (rows, cols, 256),
              (1, cols, 512), (rows, cols, 2), (1, cols, 640)]
    shapes += [(rng.randint(1, rows), rng.randint(1, cols), rng.choice([3,7,16,23,32,63,64,65,127]))
               for _ in range(14)]
    for i, (m,n,k) in enumerate(shapes):
        cases.append(dict(m=m,n=n,k=k,pitch=align16(k)+(16 if i%3==1 else 0),
                          ab=0 if i==0 else 32,bb=0 if i==0 else 48,
                          pb=0 if i==0 else 16,error=0,stalls=i%2))
    # Real physical padded-span, alignment, dimension, and arithmetic rejections.
    default=dict(m=rows,n=cols,k=16,pitch=16,ab=0,bb=0,pb=0,error=0,stalls=1)
    for change in [dict(m=0,error=2),dict(n=cols+1,error=2),dict(k=0,error=2),
                   dict(m=rows+1,error=2),dict(k=17,pitch=16,error=2),
                   dict(ab=1,error=3),dict(bb=3,error=3),dict(pb=1,error=3),
                   dict(pitch=17,error=3),dict(ab=16384,error=3),
                   dict(bb=16384-16,error=3),dict(pb=4096,error=3),
                   dict(k=2049,pitch=2064,error=3),
                   dict(m=1,n=1,k=1,pitch=16,overflow=1,error=8),
                   dict(m=1,n=1,k=1,pitch=16,overflow=-1,error=8)]:
        cases.append(default | change)
    # Exact capacity: both 16 KiB operands filled on 8x8, many ping-pong wraps.
    cases.append(default | dict(k=2048,pitch=2048))
    # Exact-end bounds must pass, including a wide read containing K padding.
    cases.append(default | dict(m=1,n=1,k=1,ab=16368,bb=16368,pb=4080))
    lines=[]
    manifest=[]
    for i,c in enumerate(cases):
        m,n,k=c['m'],c['n'],c['k']
        valid=c['error'] in (0,8)
        a=[[rng.randint(-128,127) for _ in range(k)] for _ in range(m)] if valid else []
        b=[[rng.randint(-128,127) for _ in range(n)] for _ in range(k)] if valid else []
        za=([0,89,-128,127][i%4])
        bias=[rng.randint(-10000,10000) for _ in range(n)] if valid else []
        if c.get('overflow'):
            a=[[c['overflow']]]; b=[[1]]; za=0
            bias=[2147483647 if c['overflow']>0 else -2147483648]
        corrected=[bias[j]-za*sum(b[t][j] for t in range(k)) for j in range(n)] if valid else []
        # Centered-input reference, independently of the raw-MAC RTL layout.
        expected=[[bias[j]+sum((a[r][t]-za)*b[t][j] for t in range(k)) for j in range(n)]
                  for r in range(m)] if valid else []
        amem=bytearray([0x5A])*16384; bmem=bytearray(16384); pmem=bytearray(4096)
        if valid:
            for r in range(m):
                for t in range(k): amem[c['ab']+r*c['pitch']+t]=a[r][t]&255
            for t in range(k):
                for j in range(n): bmem[c['bb']+t*8+j]=b[t][j]&255
            for j,s in enumerate(corrected):
                pmem[c['pb']+16*j:c['pb']+16*j+4]=s.to_bytes(4,'little',signed=True)
        d=output/f'case_{i:02d}'; d.mkdir(exist_ok=True)
        hex_words(d/'a.hex',amem);hex_words(d/'b.hex',bmem);hex_words(d/'param.hex',pmem)
        flat=[v for row in expected for v in row]
        (d/'expected.hex').write_text(''.join(f'{v&0xffffffff:08x}\n' for v in (flat+[0]*64)[:64]))
        (d/'reference.json').write_text(json.dumps(c | dict(input_zero_point=za,A=a,B=b,
            original_bias=bias,corrected_bias=corrected,expected_int32=expected),indent=2)+'\n')
        lines.append(' '.join(str(c[x]) for x in ['m','n','k','pitch','ab','bb','pb','error','stalls']))
        manifest.append(c | dict(id=i,input_zero_point=za))
    (output/'cases.txt').write_text(''.join(f'{i} {line}\n' for i,line in enumerate(lines)))
    (output/'manifest.json').write_text(json.dumps(dict(seed=20261029,rows=rows,cols=cols,
        physical_layout='A row-major padded; B[k][8 lanes]; PARAM 16 B/output channel',cases=manifest),indent=2)+'\n')
    print(f'Generated {len(cases)} compute fixtures for {rows}x{cols}: {output}')


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
    p.add_argument('--rows',type=int,default=8);p.add_argument('--cols',type=int,default=8)
    args=p.parse_args()
    if not (1<=args.rows<=8 and 1<=args.cols<=8): p.error('rows/cols must be in 1..8')
    generate(args.output,args.rows,args.cols)
