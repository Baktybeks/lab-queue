export function accountAttributes(student) {
  if (!/^[a-z0-9_]+$/.test(student.login)) throw new Error('Недопустимый логин');
  if (typeof student.name !== 'string' || student.name.trim().length < 2 || student.name.trim().length > 60) throw new Error('Некорректное ФИО');
  return {
    email: `${student.login}@students.lab-queue.invalid`,
    password: '12345678',
    email_confirm: true,
    user_metadata: { display_name: student.name.trim(), login: student.login },
    app_metadata: { provisioned_by: 'lab-queue-roster' },
  };
}
export async function provisionStudents(admin, roster, report = () => {}) {
  const emails = new Set();
  let page = 1;
  while (true) {
    const {data,error} = await admin.listUsers({page,perPage:1000});
    if (error) throw new Error(`Не удалось прочитать пользователей: ${error.code || error.status || 'ошибка API'}`);
    for (const user of data.users) if (user.email) emails.add(user.email.toLowerCase());
    if (data.users.length < 1000) break;
    page++;
  }
  const results = [];
  for (const student of roster) {
    const attributes = accountAttributes(student);
    if (emails.has(attributes.email)) { results.push({login:student.login,status:'exists'}); report(student.login,'exists'); continue; }
    const {error} = await admin.createUser(attributes);
    if (error) {
      results.push({login:student.login,status:'failed',code:error.code || error.status || 'api_error'});
      report(student.login,'failed');
    } else {
      emails.add(attributes.email); results.push({login:student.login,status:'created'}); report(student.login,'created');
    }
  }
  return results;
}
