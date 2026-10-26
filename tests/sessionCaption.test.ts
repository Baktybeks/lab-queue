import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sessionCaption, newestSessions } from '../src/entities/session/lib/sessionCaption.ts';
const session = {id:'12345678-1234-1234-1234-123456789012',date:'2026-10-21',group:'Пи-4-26',ended_at:null,created_at:'2026-10-21T03:04:05Z'};
test('Session creation time is converted to the teacher browser timezone', () => {
  assert.match(sessionCaption(session,'Asia/Bishkek'),/09:04:05/);
  assert.match(sessionCaption(session,'UTC'),/03:04:05/);
  assert.match(sessionCaption(session,'Asia/Bishkek'),/идёт сейчас/);
});
test('Legacy sessions show known completion time and sort by newest timestamp, not UUID or class date', () => {
  const old = {...session,id:'00000000',group:'Пи-4-26',created_at:null,ended_at:'2026-10-21T02:00:00Z'};
  const latest = {...old,id:'77777777',group:'Пи-5-26',ended_at:'2026-10-21T04:00:00Z'};
  assert.match(sessionCaption(latest,'Asia/Bishkek'),/завершена 21.10.2026, 10:00:00/);
  assert.equal(newestSessions([old,latest])[0].group,'Пи-5-26');
  assert.equal(newestSessions([old,{...latest,created_at:'2026-10-22T01:00:00Z',date:'2026-10-20'}])[0].group,'Пи-5-26');
});
test('Older sessions do not get invented creation times and remain distinguishable', () => {
  assert.match(sessionCaption({...session,created_at:null}),/время не сохранено · #12345678/);
  assert.doesNotMatch(sessionCaption({...session,ended_at:'2026-10-21T05:00:00Z'}),/идёт сейчас/);
});
