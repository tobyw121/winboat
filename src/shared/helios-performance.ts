export const PERFORMANCE_PROFILES={
    baseline:{},
    cache:{HELIOS_SHADER_CACHE:'1'},
    'io-thread-low-cpu':{HELIOS_IO_THREAD:'1',HELIOS_IO_POLL_NS:'0'},
    'readback-damage':{HELIOS_READBACK_DAMAGE:'1'},
    'idle-refresh':{HELIOS_IDLE_REFRESH:'1'},
} as const;
export type PerformanceProfile=keyof typeof PERFORMANCE_PROFILES;
const defaults:Record<string,string>={HELIOS_SHADER_CACHE:'0',HELIOS_IO_THREAD:'0',HELIOS_IO_POLL_NS:'',
    HELIOS_READBACK_DAMAGE:'0',HELIOS_IDLE_REFRESH:'1'};
type Service={environment:Record<string,string>;[key:string]:unknown};
const receipt='x-winboat-performance';
export function performanceProfile<T extends Service>(service:T,name:PerformanceProfile|'restore'):T{
    const next=JSON.parse(JSON.stringify(service)) as T;
    const mutable=next as Service;
    const prior=mutable[receipt] as {before:Record<string,string|null>}|undefined;
    if(name==='restore'){
        if(!prior || !prior.before || Object.keys(prior.before).sort().join()!=Object.keys(defaults).sort().join())throw new Error('Saved performance baseline missing or invalid');
        for(const key of Object.keys(defaults)){
            const value=prior.before[key];
            if(value!==null && typeof value!=='string')throw new Error('Invalid saved performance value');
            if(value===null)delete next.environment[key];else next.environment[key]=value;
        }
        delete mutable[receipt];return next;
    }
    if(!Object.hasOwn(PERFORMANCE_PROFILES,name))throw new Error('Unknown performance profile');
    if(!prior)mutable[receipt]={schema:1,before:Object.fromEntries(Object.keys(defaults).map(k=>[k,service.environment[k]??null]))};
    Object.assign(next.environment,defaults,PERFORMANCE_PROFILES[name]);
    return next;
}

export function performanceChanges(before:Service,after:Service){
    return Object.keys(defaults).map(key=>({key,before:before.environment[key]??null,after:after.environment[key]??null})).filter(row=>row.before!==row.after);
}
