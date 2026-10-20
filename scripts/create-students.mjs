import { readFile } from 'node:fs/promises';
import { createClient } from '@supabase/supabase-js';
import { accountAttributes, provisionStudents } from './student-accounts.mjs';

try {
  const roster = JSON.parse(await readFile(new URL('../private/students.json',import.meta.url),'utf8'));
  const seen = new Set();
  for (const student of roster) {
    accountAttributes(student);
    if (seen.has(student.login)) throw new Error('В списке повторяются логины');
    seen.add(student.login);
  }
  if (process.argv.includes('--dry-run')) {
    for (const student of roster) console.log(`${student.login} — ${student.name}`);
    console.log(`Проверено аккаунтов: ${roster.length}. Запросы в Supabase не выполнялись.`);
  } else {
    const config = await readFile(new URL('../.env',import.meta.url),'utf8');
    const url = config.match(/^VITE_SUPABASE_URL=(.+)$/m)?.[1].trim();
    const key = process.env.LAB_QUEUE_ADMIN_KEY;
    if (!url || !key) throw new Error('Запустите scripts/create-students.ps1: он запросит серверный ключ скрытым вводом.');
    if (key.startsWith('sb_publishable_')) throw new Error('Нужен серверный Secret key или service_role, а не публичный ключ.');
    const client = createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:(url,options)=>fetch(url,{...options,signal:AbortSignal.timeout(20000)})}});
    const labels = {created:'создан',exists:'уже существует, пароль не менялся',failed:'не создан'};
    const results = await provisionStudents(client.auth.admin,roster,(login,status)=>console.log(`${login}: ${labels[status]}`));
    const failed = results.filter(r=>r.status==='failed');
    console.log(`Создано: ${results.filter(r=>r.status==='created').length}; уже были: ${results.filter(r=>r.status==='exists').length}; ошибок: ${failed.length}`);
    if (failed.length) { for (const row of failed) console.log(`${row.login}: код ${row.code}`); process.exitCode = 1; }
  }
} catch(error) {
  console.error(error instanceof Error ? error.message : 'Не удалось создать аккаунты'); process.exitCode = 1;
}
