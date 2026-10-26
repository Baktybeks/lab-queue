import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loginEmail } from '../src/features/auth/lib/loginEmail.ts';
import { accountAttributes, provisionStudents } from '../scripts/student-accounts.mjs';

test('Student login matches provisioned address; existing admin email still works', () => {
  const account = accountAttributes({login:'asanov_b_r',name:'Асанов Бек Русланович'});
  assert.equal(loginEmail(' ASANOV_B_R '),account.email);
  assert.equal(loginEmail(' Teacher@Example.com '),'teacher@example.com');
  assert.equal(account.email_confirm,true);
  assert.equal(account.password,'12345678');
  assert.equal(account.user_metadata.display_name,'Асанов Бек Русланович');
});
test('Provisioning skips existing users without resetting passwords', async () => {
  const created: any[] = [];
  const admin = {
    listUsers: async () => ({data:{users:[{email:loginEmail('existing')}]},error:null}),
    createUser: async (attributes: any) => { created.push(attributes); return {error:null}; },
  };
  const result = await provisionStudents(admin,[{login:'existing',name:'Первый Студент'},{login:'new_student',name:'Второй Студент'}]);
  assert.equal(result[0].status,'exists');
  assert.equal(result[1].status,'created');
  assert.equal(created.length,1);
  assert.equal(created[0].email_confirm,true);
});
