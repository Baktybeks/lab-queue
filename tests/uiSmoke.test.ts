import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'vite';
import {createElement} from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {QueryClient,QueryClientProvider} from '@tanstack/react-query';

test('Reorganized UI renders queue controls, student history, and superadmin forms',async()=>{
  const server=await createServer({server:{middlewareMode:true},appType:'custom'});
  const cache=new QueryClient({defaultOptions:{queries:{retry:false}}});
  try{
    const {QueueBoard}=await server.ssrLoadModule('/src/widgets/queue-board/ui/QueueBoard.tsx');
    const entry={id:'entry-a',name:'Student A',lab:6,status:'current',position:1,priority:false,ready:false};
    const board=renderToStaticMarkup(createElement(QueueBoard,{current:entry,waiting:[],extras:[],paused:[],deferred:[],adminView:true,isAdmin:true,busy:false,perform:async()=>{},restoreExtra:()=>{},readyExtraButton:()=>null}));
    assert.ok(board.includes('Student A'));assert.ok(board.includes('Следующий'));assert.ok(board.includes('Был на допзадании'));
    const {Students}=await server.ssrLoadModule('/src/features/manage-students/ui/Students.tsx');
    cache.setQueryData(['students','superadmin'],[{id:'student-a',name:'Student A',login:'student_a'}]);
    const students=renderToStaticMarkup(createElement(QueryClientProvider,{client:cache},createElement(Students,{client:{},userId:'superadmin'})));
    assert.ok(students.includes('Student A'));assert.ok(students.includes('Создать студента'));assert.ok(students.includes('Добавить студентов через JSON'));assert.ok(students.includes('Изменение имени'));
    const {StudentHistory}=await server.ssrLoadModule('/src/widgets/student-history/ui/StudentHistory.tsx');
    cache.setQueryData(['student-history','student-a'],[]);
    const history=renderToStaticMarkup(createElement(QueryClientProvider,{client:cache},createElement(StudentHistory,{client:{},userId:'student-a',revision:''})));
    assert.ok(history.includes('<summary>Моя история сдачи</summary>'));assert.ok(history.includes('История пока пуста'));
  }finally{cache.clear();await server.close();}
});
