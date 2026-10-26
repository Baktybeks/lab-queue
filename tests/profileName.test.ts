import { test } from 'node:test';
import assert from 'node:assert/strict';
import { profileName } from '../src/entities/user/lib/profileName.ts';
test('Names load from saved profile or supported account metadata', () => {
  assert.equal(profileName(' Исправленное имя ',{display_name:'Старое имя'}),'Исправленное имя');
  assert.equal(profileName(null,{display_name:'',full_name:'Бакыт'}),'Бакыт');
  assert.equal(profileName(undefined,{first_name:'Имя',last_name:'Фамилия'}),'Имя Фамилия');
  assert.equal(profileName(null,{}),'');
});
