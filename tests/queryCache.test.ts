import {test} from 'node:test';
import assert from 'node:assert/strict';
import {QueryClient} from '@tanstack/react-query';
import {createClient,type User} from '@supabase/supabase-js';
import {queueSnapshotOptions} from '../src/entities/queue/api/snapshot.ts';
import {queryKeys} from '../src/shared/api/queryKeys.ts';
import {queryClient} from '../src/shared/api/queryClient.ts';

test('Queue requests are deduplicated and caches are isolated by account and session',async()=>{
  const cache=new QueryClient({defaultOptions:{queries:{retry:false}}});
  const calls:string[]=[];
  const client=createClient('https://example.supabase.co','public-test-key',{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:async(_url,init)=>{
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
