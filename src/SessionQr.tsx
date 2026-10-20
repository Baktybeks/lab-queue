import { useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import type { LabSession } from './queue';
import { sessionLink } from './sessionLink';

export function SessionQr({session}: {session: LabSession}) {
  const url = sessionLink(location.href, session.id);
  const [message,setMessage] = useState('');
  const local = ['localhost','127.0.0.1','::1','[::1]'].includes(location.hostname);
  return <div className="session-qr"><div><h3>Вход студентов по QR</h3><p>Отсканируй → войди в аккаунт → выбери лабораторную.</p><QRCodeSVG value={url} size={200} marginSize={4} title={`Сдача ${session.group}, ${session.date}`}/></div><div><label htmlFor="session-link">Ссылка на сессию</label><input id="session-link" readOnly value={url} onFocus={e => e.target.select()}/><button type="button" className="ghost" onClick={async () => {try {await navigator.clipboard.writeText(url);setMessage('Ссылка скопирована');} catch {setMessage('Выдели и скопируй ссылку из поля выше');}}}>Скопировать ссылку</button><p role="status">{message}</p>{local && <p>Ссылка localhost не откроется с телефонов. Для занятия открой опубликованный сайт либо адрес компьютера в общей Wi-Fi сети.</p>}</div></div>;
}
