import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseStudentImport} from '../src/parseStudentBatch.ts';
import {shouldResetAccount} from '../src/authTransition.ts';

test('JSON import validates the whole batch and resolves individual or common passwords',()=>{
  const rows=parseStudentImport(JSON.stringify([{name:'  Student One  ',login:' ONE_A '},{name:'Student Two',login:'two_b',password:'Individual123'}]),'Common123');
  assert.deepEqual(rows,[{name:'Student One',login:'one_a',password:'Common123'},{name:'Student Two',login:'two_b',password:'Individual123'}]);
  assert.throws(()=>parseStudentImport('bad','Common123'),/JSON/);
  assert.throws(()=>parseStudentImport('{}','Common123'),/массив/);
  assert.throws(()=>parseStudentImport('[]','Common123'),/массив/);
  assert.throws(()=>parseStudentImport(JSON.stringify(Array(501).fill({})),'Common123'),/500/);
  assert.throws(()=>parseStudentImport(JSON.stringify([{name:'Student One',login:'ONE'},{name:'Student Two',login:'one'}]),'Common123'),/повторяется/);
  assert.throws(()=>parseStudentImport('[{"name":"Student","login":"student"}]',''),/пароль/);
  assert.throws(()=>parseStudentImport('[{"name":"Student","login":"bad@mail.ru"}]','Common123'),/логин/);
  assert.throws(()=>parseStudentImport('[{"name":"X","login":"student"}]','Common123'),/имя/);
  assert.throws(()=>parseStudentImport('[{"name":"Student","login":"student","password":""}]','Common123'),/пароль/);
});

test('Focus reauthentication keeps the same account visible while signout or another account resets it',()=>{
  assert.equal(shouldResetAccount('SIGNED_IN','student-a','student-a'),false);
  assert.equal(shouldResetAccount('TOKEN_REFRESHED','student-a','student-a'),false);
  assert.equal(shouldResetAccount('INITIAL_SESSION','student-a','student-a'),false);
  assert.equal(shouldResetAccount('SIGNED_OUT','student-a',null),true);
  assert.equal(shouldResetAccount('SIGNED_IN','student-a','student-b'),true);
  assert.equal(shouldResetAccount('SIGNED_IN',null,'student-a'),true);
});
