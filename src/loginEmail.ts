// Reserved internal domain for username/password accounts; no mail is sent.
export function loginEmail(login: string) {
  const value = login.trim().toLowerCase();
  return value.includes('@') ? value : `${value}@students.lab-queue.invalid`;
}
