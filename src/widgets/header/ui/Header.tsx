type Props = { name?: string | null; admin?: boolean; superadmin?: boolean; onLogout?: () => Promise<void> };

export function Header({name,admin,superadmin,onLogout}: Props) {
  const role = superadmin ? 'Superadmin' : admin ? 'Преподаватель' : 'Студент';
  const displayName = name?.trim() || role;
  const initials = name?.trim().split(/\s+/).slice(0,2).map(part => part[0]).join('').toUpperCase() || (admin ? 'П' : 'С');
  return <header className="site-header">
    <a className="site-identity" href="#" aria-label="Лаба — главная">
      <span className="site-mark" aria-hidden="true"><svg width="28" height="28" viewBox="0 0 28 28" fill="none"><path d="M5 6.5c3-1 6-.5 9 1.5 3-2 6-2.5 9-1.5v15c-3-1-6-.5-9 1.5-3-2-6-2.5-9-1.5v-15Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/><path d="M14 8v15M8 11l3 1M8 15l3 1M17 12l3-1M17 16l3-1" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></svg></span>
      <span className="site-wordmark"><strong>Лаба<span>⁕</span></strong><span>Очередь на сдачу</span></span>
    </a>
    {onLogout ? <div className="header-account">
      <span className="account-avatar" aria-hidden="true">{initials}</span>
      <div className="account-details"><strong title={displayName}>{displayName}</strong><span><i aria-hidden="true"/>{role}</span></div>
      <button className="header-logout" onClick={onLogout} aria-label="Выйти из аккаунта"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M9 5H5v14h4M14 8l4 4-4 4M9 12h9" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg><span>Выйти</span></button>
    </div> : <span className="header-welcome">Меньше ожидания. Больше дела.</span>}
  </header>;
}
