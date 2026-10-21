export function ExtraBadge({entry}: {entry: {had_extra?: boolean;carried_extra?: boolean}}) {
  if (!entry.had_extra && !entry.carried_extra) return null;
  return <span className="extra-history-badge">{entry.carried_extra ? 'Доп. с прошлой сессии' : 'Был на допзадании'}</span>;
}
