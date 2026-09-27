#!/usr/bin/env python3
"""Summarize p14 TSVs into median tables (results/summary-*.tsv) and print markdown."""
import csv, statistics, sys, collections, os
P = os.path.join(os.environ['SP'], 'p14', 'results')
def rows(name):
    try:
        with open(f'{P}/{name}') as f: return list(csv.DictReader(f, delimiter='\t'))
    except FileNotFoundError: return []
def med(xs): return statistics.median(xs) if xs else float('nan')
def loads(rs, keys):
    v = []
    for r in rs:
        for k in keys:
            if r.get(k): v.append(float(r[k].split()[0]))
    return (min(v), max(v)) if v else (float('nan'),)*2
out = []
b = rows('bench.tsv')
if b:
    g = collections.defaultdict(list)
    for r in b: g[(r['corpus'], int(r['threads']), int(r['S_MiB']))].append(r)
    out.append('## write (gyoshuku-bench txz): median of rounds')
    out.append('| corpus | threads | S MiB | n | elapsed s (runs) | user s | peak RSS MiB | bytes | vs S16 size | vs S16 time | outputs |')
    out.append('|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|')
    summ = []
    for corpus in ['headers','small','text','random','mixed','payload']:
        for t in [1, 8]:
            ref = g.get((corpus, t, 16))
            for n in [2, 4, 8, 16]:
                rs = g.get((corpus, t, n))
                if not rs: continue
                e = [float(r['bench_elapsed_s']) for r in rs]
                u = med([float(r['user_s']) for r in rs]); rss = med([float(r['peak_rss_mib']) for r in rs])
                size = int(rs[0]['output_bytes'])
                sizes = {r['output_bytes'] for r in rs}
                vs = ''; vt = ''
                if ref:
                    vs = f"{(size/int(ref[0]['output_bytes'])-1)*100:+.2f}%"
                    vt = f"{(med(e)/med([float(r['bench_elapsed_s']) for r in ref])-1)*100:+.1f}%"
                same = ','.join(sorted({r['vs_first_output'] for r in rs}))
                out.append(f"| {corpus} | {t} | {n} | {len(rs)} | {med(e):.3f} ({'/'.join(f'{x:.2f}' for x in e)}) | {u:.1f} | {rss:.0f} | {size:,}{'' if len(sizes)==1 else ' VARIES'} | {vs} | {vt} | {same} |")
                summ.append([corpus, t, n, len(rs), f'{med(e):.3f}', f'{u:.2f}', f'{rss:.1f}', size, vs, vt])
    with open(f'{P}/summary-bench.tsv', 'w') as f:
        f.write('corpus\tthreads\tS_MiB\truns\tmedian_elapsed_s\tmedian_user_s\tmedian_peak_rss_mib\toutput_bytes\tsize_vs_S16\ttime_vs_S16\n')
        for s in summ: f.write('\t'.join(map(str, s)) + '\n')
    lo, hi = loads(b, ['load_before', 'load_after'])
    out.append(f'load1 range over write runs: {lo:.2f}–{hi:.2f}')
e = rows('edit.tsv')
if e:
    g = collections.defaultdict(list)
    for r in e: g[('payload' if '-payload-' in r['label'] else 'mixed', r['op'], int(r['S_MiB']))].append(r)
    out.append('\n## edit (8 threads): median of rounds')
    out.append('| base | op | S MiB | n | commit ms (runs) | encode worker ms | K5 ms | full open ms | strategy | re-encoded image B | re-encoded old image B | carried compressed B | carried/re-encoded chunks | output B |')
    out.append('|---|---|---:|---:|---|---:|---:|---:|---|---:|---:|---:|---|---:|')
    summ = []
    for base, op in [('mixed', o) for o in ['append','delete-small','rename-small-mid','rename-text256','rename-first-same','rename-folder-small']] + [('payload', o) for o in ['append','payload-delete-mid','payload-rename-mid','payload-rename-folder']]:
        for n in [2,4,8,16]:
            rs = g.get((base, op, n))
            if not rs: continue
            c = [float(r['commit_ms']) for r in rs]
            k = med([float(r['k5_ms']) for r in rs]); fo = med([float(r['full_open_ms']) for r in rs]); enc = med([float(r['encode_worker_ms']) for r in rs])
            r0 = rs[0]
            strat = ','.join(sorted({r['strategy'] for r in rs}))
            out.append(f"| {base} | {op} | {n} | {len(rs)} | {med(c):.1f} ({'/'.join(f'{x:.0f}' for x in c)}) | {enc:.1f} | {k:.1f} | {fo:.0f} | {strat} | {int(r0['reencoded_image_bytes']):,} | {int(r0['reencoded_old_image_bytes']):,} | {int(r0['carried_compressed_bytes']):,} | {r0['carried_chunks']}/{r0['reencoded_chunks']} | {int(r0['output_bytes']):,} |")
            summ.append([base, op, n, len(rs), f'{med(c):.3f}', f'{enc:.3f}', f'{k:.3f}', f'{fo:.3f}', strat, r0['reencoded_image_bytes'], r0['reencoded_old_image_bytes'], r0['carried_compressed_bytes'], r0['carried_chunks'], r0['reencoded_chunks'], r0['output_bytes']])
    with open(f'{P}/summary-edit.tsv', 'w') as f:
        f.write('base\top\tS_MiB\truns\tmedian_commit_ms\tmedian_encode_worker_ms\tmedian_k5_ms\tmedian_full_open_ms\tstrategy\treencoded_image_bytes\treencoded_old_image_bytes\tcarried_compressed_bytes\tcarried_chunks\treencoded_chunks\toutput_bytes\n')
        for s in summ: f.write('\t'.join(map(str, s)) + '\n')
    v = [float(r['load1']) for r in e]
    out.append(f'load1 at commit start: {min(v):.2f}–{max(v):.2f}')
d = rows('decode.tsv')
if d:
    g = collections.defaultdict(list)
    for r in d: g[(r['corpus'], int(r['S_MiB']), r['method'])].append(r)
    out.append('\n## decode / open: median wall s (in-process open ms for KaitoKit)')
    out.append('| corpus | S MiB | xz -T1 -dc s | xz -T0 -dc s | xz -T0 RSS MiB | KaitoKit open plain ms | KaitoKit open +layout ms | KaitoKit RSS MiB | chunks |')
    out.append('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    summ = []
    for corpus in ['headers','small','text','random','mixed','payload']:
        for n in [2,4,8,16]:
            if not any(k[0]==corpus and k[1]==n for k in g): continue
            def m(method, key):
                rs = g.get((corpus, n, method), [])
                vals = [float(r[key]) for r in rs if r[key] not in ('-', '')]
                return med(vals)
            row = [corpus, n, m('xz1','wall_s'), m('xzT0','wall_s'), m('xzT0','peak_rss_mib'), m('kk-plain','open_ms_inprocess'), m('kk-layout','open_ms_inprocess'), m('kk-layout','peak_rss_mib')]
            ch = g.get((corpus, n, 'kk-layout'), [{}])[0].get('chunks', '')
            out.append(f"| {corpus} | {n} | {row[2]:.3f} | {row[3]:.3f} | {row[4]:.0f} | {row[5]:.0f} | {row[6]:.0f} | {row[7]:.0f} | {ch} |")
            summ.append(row + [ch])
    with open(f'{P}/summary-decode.tsv', 'w') as f:
        f.write('corpus\tS_MiB\txz_T1_wall_s\txz_T0_wall_s\txz_T0_rss_mib\tkaitokit_open_plain_ms\tkaitokit_open_layout_ms\tkaitokit_layout_rss_mib\tchunks\n')
        for s in summ: f.write('\t'.join(map(str, s)) + '\n')
    lo, hi = loads(d, ['load_before', 'load_after'])
    out.append(f'load1 range over decode runs: {lo:.2f}–{hi:.2f}')
print('\n'.join(out))
