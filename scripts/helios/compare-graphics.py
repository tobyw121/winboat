#!/usr/bin/env python3
"""Compare saved A/B/A/B reports without installing or enabling drivers."""
import argparse
import json
import math
from pathlib import Path
import statistics


def percentile(values, fraction):
    ordered=sorted(values)
    if not ordered: return None
    position=(len(ordered)-1)*fraction
    lower=int(position);upper=min(lower+1,len(ordered)-1)
    return ordered[lower]+(ordered[upper]-ordered[lower])*(position-lower)


def frame_summary(values):
    if any(type(v) not in (int,float) or not math.isfinite(v) or not 0<v<=60000 for v in values):
        raise ValueError('Frame durations must be finite milliseconds in (0,60000]')
    return {'samples':len(values),'medianMs':percentile(values,.5),
            'p95Ms':percentile(values,.95),'p99Ms':percentile(values,.99)}


def compare(reports):
    if len(reports)!=4 or [r.get('label') for r in reports]!=['A1','B1','A2','B2']:
        raise ValueError('Supply reports in A1/B1/A2/B2 order')
    scopes={r.get('comparisonKey') for r in reports}
    if len(scopes)!=1 or None in scopes:
        raise ValueError('Reports require the same explicit workload/settings comparisonKey')
    if all('tests' in r and 'identity' in r for r in reports):
        versions=[r['identity']['version'] for r in reports]
        if versions[0]!=versions[2] or versions[1]!=versions[3]: raise ValueError('Driver version changed within a comparison arm')
        signatures=[{t['name']:t.get('sha256') for t in r['tests']} for r in reports]
        equal=all(s==signatures[0] for s in signatures) and all(signatures[0].values())
        pairs=[]
        for a,b in ((0,1),(2,3)):
            other={t['name']:t for t in reports[b]['tests']}
            first=None
            for row in reports[a]['tests']:
                target=other.get(row['name'])
                if target is None or any(row.get(k)!=target.get(k) for k in ('status','exitCode','codes')):
                    first={'test':row['name'],'baselineStatus':row.get('status'),'baselineCode':row.get('exitCode'),
                           'candidateStatus':target.get('status') if target else 'missing',
                           'candidateCode':target.get('exitCode') if target else None,
                           'sameProbeBytes':bool(target and row.get('sha256') and row['sha256']==target.get('sha256'))}
                    break
            pairs.append({'baseline':reports[a]['label'],'candidate':reports[b]['label'],'firstDivergence':first})
        return {'schema':1,'comparisonKey':reports[0]['comparisonKey'],'driverVersions':versions,'sameProbeBytes':bool(equal),
                'pairs':pairs,'reproducedFirstDivergence':pairs[0]['firstDivergence'] is not None and pairs[0]['firstDivergence']==pairs[1]['firstDivergence'],
                'runs':[{'label':r['label'],'automatedPassed':r['automatedPassed'],'tests':r['tests']} for r in reports],
                'scope':'Different probe hashes limit attribution to the driver. Manual visual and recovery checks remain separate.'}
    summaries=[r.get('summary',{}) for r in reports]
    pairs=[]
    for a,b in ((0,1),(2,3)):
        av=summaries[a].get('meanCpuPercentOfOneCore');bv=summaries[b].get('meanCpuPercentOfOneCore')
        valid=all(type(v) in (float,int) and math.isfinite(v) and v>=0 for v in (av,bv))
        pairs.append({'baseline':reports[a]['label'],'candidate':reports[b]['label'],
                      'cpuPercentagePointDelta':bv-av if valid else None})
    return {'schema':1,'comparisonKey':reports[0]['comparisonKey'],'pairs':pairs,
            'frameTimes':[r.get('frameTimes') for r in reports],
            'scope':'Paired observations only. Workload equality is operator-supplied; no automatic promotion or causality claim.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports',nargs=4,type=Path)
    args=parser.parse_args()
    try:
        reports=[]
        for path in args.reports:
            if path.stat().st_size>1048576: raise ValueError('Report exceeds 1 MiB')
            reports.append(json.loads(path.read_text()))
        print(json.dumps(compare(reports),indent=2))
    except (OSError,ValueError,TypeError) as error: parser.exit(1,str(error)+'\n')


if __name__=='__main__': main()
