#!/usr/bin/env python3
"""Plan one-axis graphics bisection from captured A/B/A/B evidence; no VM writes."""
import argparse
import importlib.util
import json
from pathlib import Path
import re


def read(path):
    if path.stat().st_size>2097152: raise ValueError('Evidence exceeds 2 MiB')
    return json.loads(path.read_text(encoding='utf-8-sig'))


def plan(axis,candidates,trials,probe):
    if axis not in ('guest','host') or not 2<=len(candidates)<=128 or len(set(candidates))!=len(candidates):
        raise ValueError('Select guest/host and 2..128 distinct ordered candidate hashes')
    pattern=r'[0-9a-f]{64}' if axis=='guest' else r'sha256:[0-9a-f]{64}'
    if any(not isinstance(c,str) or not re.fullmatch(pattern,c) for c in candidates): raise ValueError('Candidates must be exact manifest hashes or host image IDs')
    spec=importlib.util.spec_from_file_location('comparison',Path(__file__).with_name('compare-graphics.py'))
    comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
    outcomes={};context=None;evidence=[];run_ids=set();missing_context=set()
    for trial in trials:
        if len(trial)!=4: raise ValueError('Each trial requires four captures')
        reports=[];selected=[]
        for capture in trial:
            acceptance=capture['graphics/validation']['acceptance']
            identity=acceptance['identity'];host=capture['host']['imageId']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}',host): raise ValueError('Host image identity missing')
            manifest=str(identity['manifestSha256']).lower()
            if not re.fullmatch(r'[0-9a-f]{64}',manifest): raise ValueError('Guest manifest identity missing')
            machine=identity.get('machineId')
            if not machine or 'profile' not in identity: raise ValueError('VM identity and explicit driver profile required')
            # Hold the other side and all settings constant across every trial.
            controllers=capture.get('graphics/diagnostics',{}).get('driver',{}).get('controllers',[])
            dimensions=sorted({(c.get('CurrentHorizontalResolution'),c.get('CurrentVerticalResolution')) for c in controllers
                               if type(c.get('CurrentHorizontalResolution')) is int and type(c.get('CurrentVerticalResolution')) is int})
            backend=capture.get('host',{}).get('qemuBackend',{})
            preflight=capture.get('host',{}).get('gpuPreflight',{})
            physical_ids=[d.get('deviceUuid') for d in preflight.get('devices',[]) if d.get('selected') is True]
            context_fields={'dimensions':dimensions,'backend':backend.get('backend'),'gpu':physical_ids,
                            'performance':backend.get('performance')}
            for name,value in context_fields.items():
                if value is None or value==[]:missing_context.add(name)
            fixed=(machine,host if axis=='guest' else manifest,json.dumps(identity['profile'],sort_keys=True),acceptance['comparisonKey'],json.dumps(context_fields,sort_keys=True))
            if context is not None and fixed!=context: raise ValueError('VM, fixed stack side, workload or settings changed')
            context=fixed
            run=acceptance.get('runId')
            if not run or run in run_ids: raise ValueError('Each capture must contain a distinct acceptance run')
            run_ids.add(run)
            if acceptance.get('observationErrors'): raise ValueError('Observation errors make this trial inconclusive')
            tests=[t for t in acceptance['tests'] if t['name']==probe]
            if len(tests)!=1 or tests[0].get('status') not in ('passed','failed'): raise ValueError('Selected probe must have one completed result')
            if tests[0].get('exitCode') is None: raise ValueError('Probe exit code missing')
            reports.append({**acceptance,'tests':tests})
            selected.append(manifest if axis=='guest' else host)
        result=comparison.compare(reports)
        if not result['sameProbeBytes']: raise ValueError('Selected probe bytes changed; use the pinned external validation tools')
        if selected[0]!=candidates[0] or selected[2]!=candidates[0] or selected[1]!=selected[3] or selected[1] not in candidates:
            raise ValueError('A must be the original baseline, B one listed candidate')
        statuses=[r['tests'][0]['status'] for r in reports]
        if statuses[0]!='passed' or statuses[2]!='passed' or statuses[1]!=statuses[3]: raise ValueError('Unstable A/B/A/B results; repeat before narrowing')
        if statuses[1]=='failed' and not result['reproducedFirstDivergence']: raise ValueError('Different failures across B runs; trial inconclusive')
        index=candidates.index(selected[1]);value=statuses[1]=='passed'
        if index in outcomes and outcomes[index]!=value: raise ValueError('Candidate outcome changed between trials')
        outcomes[0]=True;outcomes[index]=value
        evidence.append({'candidateIndex':index,'passed':value,'comparison':result})
    good=max((i for i,v in outcomes.items() if v),default=0)
    bad=min((i for i,v in outcomes.items() if not v),default=len(candidates)-1)
    if good>=bad: raise ValueError('Non-monotonic results: binary search is invalid; test every candidate')
    if not outcomes.get(0) or outcomes.get(len(candidates)-1) is not False:
        next_index=len(candidates)-1;status='validate-endpoints'
    elif bad-good==1:
        next_index=None;status='adjacent-boundary-observed'
    else:
        next_index=(good+bad)//2;status='test-midpoint'
    return {'schema':1,'axis':axis,'probe':probe,'status':status,'goodIndex':good,'badIndex':bad,
            'nextIndex':next_index,'nextCandidate':candidates[next_index] if next_index is not None else None,
            'contextVerified':bool(trials) and not missing_context,'missingContext':sorted(missing_context),
            'evidence':evidence,'scope':'Operator supplies ordered builds and unchanged workload. Only selected probe behavior is narrowed; monotonicity is an assumption. No installation, checkout or automatic promotion.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--axis',choices=('guest','host'),required=True)
    parser.add_argument('--candidates',type=Path,required=True,help='JSON array ordered from known-good .291 stack toward bad stack')
    parser.add_argument('--probe',required=True,help='Exact acceptance test name; use identical pinned probe bytes')
    parser.add_argument('--trial',nargs=4,type=Path,action='append',default=[],metavar=('A1','B1','A2','B2'))
    args=parser.parse_args()
    try: print(json.dumps(plan(args.axis,read(args.candidates),[[read(p) for p in trial] for trial in args.trial],args.probe),indent=2))
    except (OSError,ValueError,KeyError,TypeError) as error: parser.exit(1,str(error)+'\n')


if __name__=='__main__': main()
