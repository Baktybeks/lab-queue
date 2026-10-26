export function MedalLegend() {
  return <details className="medal-legend"><summary>Медали лабораторной</summary><div className="medal-legend-grid">
    <div><span>🥇</span><p><strong>Легенда лабораторной</strong><small>Сдал с первого раза</small></p></div>
    <div><span>🧠</span><p><strong>Мозговой штурм</strong><small>Не ответил на вопросы. Одна медаль за каждое допзадание</small></p></div>
    <div><span>🔄</span><p><strong>New Game+</strong><small>Повторная попытка сдачи</small></p></div>
    <div><span>💀</span><p><strong>Босс оказался сильнее</strong><small>Не смог защитить лабораторную к завершению сессии</small></p></div>
  </div></details>;
}
