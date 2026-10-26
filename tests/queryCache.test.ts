import {test} from 'node:test';
import assert from 'node:assert/strict';
import {QueryClient,QueryObserver} from '@tanstack/react-query';
import {createClient,type User} from '@supabase/supabase-js';
import {queueSnapshotOptions} from '../src/entities/queue/api/snapshot.ts';
import {queryKeys} from '../src/shared/api/queryKeys.ts';
import {queryClient} from '../src/shared/api/queryClient.ts';
import {historySessionsOptions,sessionResultsOptions} from '../src/entities/session/api/history.ts';

test('Queue requests are deduplicated and caches are isolated by account and session',async()=>{
  const cache=new QueryClient({defaultOptions:{queries:{retry:false}}});
  const calls:string[]=[];
  const client=createClient('https://example.supabase.co','public-test-key',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:async(_url,init)=>{
    assert.ok(String(_url).includes('/rpc/queue_live_snapshot'));
    calls.push(JSON.parse(String(init?.body)).target_session_id);
    await new Promise(resolve=>setTimeout(resolve,5));
    return new Response(JSON.stringify({lab:6,entries:[],admin:false,profile_name:null}),{status:200,headers:{'Content-Type':'application/json'}});
  }}});
  const user={id:'student-a',user_metadata:{display_name:'Student A'}} as User;
  try{
    const a=queueSnapshotOptions(client,user,'session-a');
    assert.equal(a.refetchInterval,5000);assert.equal(a.refetchIntervalInBackground,false);
    const [first,second]=await Promise.all([cache.fetchQuery(a),cache.fetchQuery(a)]);
    assert.deepEqual(first,second);assert.equal(first.profile_name,'Student A');assert.deepEqual(calls,['session-a']);
    await cache.fetchQuery(queueSnapshotOptions(client,user,'session-b'));
    await cache.fetchQuery(queueSnapshotOptions(client,{...user,id:'student-b'},'session-a'));
    assert.equal(calls.length,3);
    assert.equal(cache.getQueryCache().getAll().length,3);
    cache.clear();assert.equal(cache.getQueryCache().getAll().length,0);
    assert.equal(queueSnapshotOptions(client,null,null).enabled,false);
    assert.notDeepEqual(queryKeys.history('student-a'),queryKeys.history('student-b'));
  }finally{cache.clear();}
});

test('Teacher history stays disabled while closed and requests results only for the selected session',async()=>{
  const cache=new QueryClient({defaultOptions:{queries:{retry:false}}});const calls:{rpc:string;body:unknown}[]=[];
  const client=createClient('https://example.supabase.co','public-test-key',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:async(url,init)=>{
    calls.push({rpc:String(url).split('/').pop()!,body:init?.body?JSON.parse(String(init.body)):null});
    return new Response('[]',{status:200,headers:{'Content-Type':'application/json'}});
  }}});
  const closed=historySessionsOptions(client,'teacher-a',false);
  const observer=new QueryObserver(cache,closed);const unsubscribe=observer.subscribe(()=>{});
  try{
    assert.equal(calls.length,0);assert.equal(closed.enabled,false);assert.equal(closed.refetchOnWindowFocus,false);
    assert.equal(sessionResultsOptions(client,'teacher-a',null,true).enabled,false);
    assert.equal(sessionResultsOptions(client,'teacher-a','session-a',false).enabled,false);
    observer.setOptions(historySessionsOptions(client,'teacher-a',true));await observer.refetch();
    await cache.fetchQuery(sessionResultsOptions(client,'teacher-a','session-b',true));
    assert.deepEqual(calls.map(c=>c.rpc),['queue_history_sessions','queue_session_results']);
    assert.deepEqual(calls[1].body,{target_session_id:'session-b'});
    assert.notDeepEqual(closed.queryKey,historySessionsOptions(client,'teacher-b',false).queryKey);
    observer.setOptions(closed);assert.equal(calls.length,2);
  }finally{unsubscribe();cache.clear();}
});

test('Clearing an account cache cancels pending data and commands never auto-retry',async()=>{
  const cache=new QueryClient();let finish!:(value:string)=>void;
  const pending=cache.fetchQuery({queryKey:queryKeys.queue('student-a','session-a'),queryFn:({signal})=>new Promise<string>((resolve,reject)=>{
    finish=resolve;signal.addEventListener('abort',()=>reject(new Error('cancelled')),{once:true});
  })});
  const rejected=assert.rejects(pending);
  cache.clear();finish('old student data');await rejected;
  assert.equal(cache.getQueryData(queryKeys.queue('student-a','session-a')),undefined);
  assert.equal(queryClient.getDefaultOptions().mutations?.retry,false);
  cache.clear();queryClient.clear();
});

test('Missing compact RPC falls back safely during migration and excludes archives from the live cache',async()=>{
  const cache=new QueryClient({defaultOptions:{queries:{retry:false}}});let count=0;
  const client=createClient('https://example.supabase.co','public-test-key',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:async()=>{
    count++;
    const body=count===1?{code:'PGRST202',message:'Missing function'}:{lab:6,admin:true,entries:[],session:{id:'session-a'},sessions:[{id:'old'}],results:[{session_id:'session-a',outcome:'passed'},{session_id:'old',outcome:'passed'}]};
    return new Response(JSON.stringify(body),{status:count===1?404:200,headers:{'Content-Type':'application/json'}});
  }}});
  try{
    const data=await cache.fetchQuery(queueSnapshotOptions(client,{id:'teacher-a',user_metadata:{}} as User,null));
    assert.equal(count,2);assert.equal(data.passed_count,1);assert.equal('results' in data,false);assert.equal('sessions' in data,false);
  }finally{cache.clear();}
});
