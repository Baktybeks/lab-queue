import { test } from 'node:test';
import assert from 'node:assert/strict';
import { insert, ordered, promote, type Entry } from '../src/queue.ts';
function entry(id: string, priority = false, ready = false): Entry { return {id,name:id,lab:6,status:'waiting',priority,ready,position:0}; }
test('Priority is FIFO, does not interrupt current, normal registrations append', () => {
  let entries = promote(insert([],entry('current')));
  entries = insert(entries,entry('normal'));
  entries = insert(entries,entry('priority-1',true));
  entries = insert(entries,entry('priority-2',true));
  assert.equal(entries.find(e => e.status === 'current')?.id,'current');
  assert.deepEqual(ordered(entries).map(e => e.id),['priority-1','priority-2','normal']);
});
test('Ready students are FIFO ahead of priority registrations', () => {
  let entries = insert([],entry('priority',true));
  entries = insert(entries,entry('ready-1',false,true));
  entries = insert(entries,entry('ready-2',false,true));
  entries = insert(entries,entry('new-priority',true));
  assert.deepEqual(ordered(entries).map(e => e.id),['ready-1','ready-2','priority','new-priority']);
});
test('Requeued student loses priority and goes to tail', () => {
  let entries = insert([],entry('waiting',true));
  const skipped = entry('skipped',true); skipped.priority = false;
  entries = insert(entries,skipped);
  assert.deepEqual(ordered(entries).map(e => e.id),['waiting','skipped']);
  assert.equal(promote(entries).find(e => e.status === 'current')?.id,'waiting');
});
