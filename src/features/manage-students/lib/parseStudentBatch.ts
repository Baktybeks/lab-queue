export type ImportStudent={name:string;login:string;password:string};
export function parseStudentImport(text:string,commonPassword:string):ImportStudent[]{
  let data:unknown;try{data=JSON.parse(text);}catch{throw new Error('Некорректный JSON. Проверьте кавычки и запятые.');}
  if(!Array.isArray(data)||!data.length||data.length>500)throw new Error('Нужен массив от 1 до 500 студентов.');
  const seen=new Set<string>();
  return data.map((row,index)=>{
    const value=row&&typeof row==='object'?row as Record<string,unknown>:{};
    const name=typeof value.name==='string'?value.name.trim():'';
    const login=typeof value.login==='string'?value.login.trim().toLowerCase():'';
    const password=typeof value.password==='string'?value.password:commonPassword;
    if(name.length<2||name.length>60)throw new Error(`Запись ${index+1}: имя должно содержать 2–60 символов.`);
    if(!/^[a-z0-9_]{3,64}$/.test(login))throw new Error(`Запись ${index+1}: логин — 3–64 латинские буквы, цифры или _.`);
    if(password.length<8||password.length>128)throw new Error(`Запись ${index+1}: укажите пароль 8–128 символов в JSON или в поле общего пароля.`);
    if(seen.has(login))throw new Error(`Запись ${index+1}: повторяется логин ${login}.`);
    seen.add(login);return {name,login,password};
  });
}
