import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import path from 'node:path';

test('FSD layers never import higher layers and the entry only bootstraps the app',async()=>{
  const root=path.resolve('src');
  const ranks:Record<string,number>={shared:0,entities:1,features:2,widgets:3,pages:4,app:5};
  async function inspect(dir:string):Promise<void>{
    for(const entry of await readdir(dir,{withFileTypes:true})){
      const file=path.join(dir,entry.name);
      if(entry.isDirectory()){await inspect(file);continue;}
      if(!/\.tsx?$/.test(file))continue;
      const relative=path.relative(root,file),layer=relative.split(path.sep)[0];
      if(!(layer in ranks))continue;
      const source=await readFile(file,'utf8');
      for(const match of source.matchAll(/from ['"](\.[^'"]+)['"]/g)){
        const dependency=path.relative(root,path.resolve(path.dirname(file),match[1])).split(path.sep)[0];
        if(dependency in ranks)assert.ok(ranks[dependency]<=ranks[layer],`${relative} imports upper layer ${dependency}`);
      }
    }
  }
  await inspect(root);
  const entry=await readFile(path.join(root,'main.tsx'),'utf8');
  assert.ok(!entry.includes('rpc(')&&!entry.includes('useState')&&!entry.includes('setInterval'));
});
