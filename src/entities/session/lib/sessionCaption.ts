import type { LabSession } from '../../queue/model/queue';

function timestamp(session: LabSession) {
  for (const value of [session.created_at,session.ended_at]) {
    if (value && !Number.isNaN(Date.parse(value))) return Date.parse(value);
  }
  return null;
}

export function newestSessions(sessions: LabSession[]) {
  return [...sessions].sort((a,b) => (timestamp(b) ?? -Infinity) - (timestamp(a) ?? -Infinity)
    || b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
}

export function sessionCaption(session: LabSession, timeZone?: string) {
  const value = timestamp(session);
  const time = value !== null
    ? `${session.created_at && !Number.isNaN(Date.parse(session.created_at)) ? 'создана' : 'завершена'} ${new Intl.DateTimeFormat('ru-RU',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23',timeZone}).format(new Date(value))}`
    : `время не сохранено · #${session.id.slice(0,8)}`;
  return `${session.date} · ${time} · ${session.group}${session.teacher_name ? ` · ${session.teacher_name}` : ''}${session.ended_at ? '' : ' · идёт сейчас'}`;
}
