export function ExtraBadge({entry}: {entry: {had_extra?: boolean;carried_extra?: boolean;extra_count?: number;retries?: number;outcome?: string;first_try_pass?: boolean}}) {
  const count = entry.extra_count ?? (entry.had_extra ? 1 : 0);
  const retries = entry.retries || 0;
  return <span className="medal-row">
    {entry.first_try_pass && <span className="medal" title="Легенда лабораторной — сдал с первого раза" aria-label="Легенда лабораторной — сдал с первого раза">🥇</span>}
    {count > 0 && <span className="medal medal-brain" title={`Мозговой штурм — допзаданий: ${count}${entry.carried_extra ? '. Из прошлой сессии' : ''}`} aria-label={`Мозговой штурм, допзаданий: ${count}${entry.carried_extra ? ', из прошлой сессии' : ''}`}><span aria-hidden="true">{count <= 12 ? '🧠'.repeat(count) : `🧠 × ${count}`}</span>{entry.carried_extra && <small>из прошлой сессии</small>}</span>}
    {retries > 0 && <span className="medal" title={`New Game+ — повторных попыток: ${retries}`} aria-label={`New Game+, повторных попыток: ${retries}`}>🔄 <small>×{retries}</small></span>}
    {entry.outcome === 'failed' && <span className="medal medal-failed" title="Босс оказался сильнее — не смог защитить лабораторную" aria-label="Босс оказался сильнее — не смог защитить лабораторную">💀</span>}
  </span>;
}
