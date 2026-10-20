const messages: Record<string,string> = {
  invalid_credentials: 'Не удалось войти: проверь логин и пароль. Если аккаунта ещё нет, обратись к преподавателю.',
  email_not_confirmed: 'Email ещё не подтверждён. Открой письмо от Supabase и перейди по ссылке подтверждения, затем повтори вход.',
  email_provider_disabled: 'Вход по email отключён в Supabase. Преподавателю нужно проверить настройки Email в Authentication.',
  signup_disabled: 'Самостоятельная регистрация отключена. Получи аккаунт у преподавателя.',
  over_request_rate_limit: 'Слишком много попыток. Подожди немного и попробуй снова.',
  over_email_send_rate_limit: 'Достигнут лимит отправки писем. Подожди и попробуй снова или обратись к преподавателю.',
};
export function authError(error: unknown): string {
  if (!error || typeof error !== 'object') return 'Не удалось войти. Попробуй снова.';
  const {code,message} = error as {code?: string;message?: string};
  if (code && messages[code]) return `${messages[code]} (Код: ${code})`;
  return message || 'Не удалось войти. Попробуй снова.';
}
