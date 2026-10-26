export type Entry = { id: string; name: string; lab: number; status: 'waiting' | 'current' | 'extra' | 'deferred' | 'paused'; priority: boolean; ready: boolean; position: number; mine?: boolean; retries?: number; off_schedule?: boolean; had_extra?: boolean; carried_extra?: boolean; can_return_extra?: boolean; extra_count?: number; first_try_pass?: boolean };
export type LabSession = { id: string; date: string; group: string; ended_at: string | null; created_by?: string | null; teacher_name?: string; lab?: number; created_at?: string | null };
export type Result = { id: string; session_id: string; name: string; lab: number; retries: number; outcome: string; off_schedule?: boolean; had_extra?: boolean; carried_extra?: boolean; can_return_extra?: boolean; extra_count?: number; first_try_pass?: boolean };
export type State = { passed_count?:number; lab: number; entries: Entry[]; admin: boolean; superadmin?: boolean; available_sessions?: LabSession[]; pending_extras?: {lab: number; retries: number}[]; profile_name?: string | null; session?: LabSession | null; sessions?: LabSession[]; results?: Result[] };
export function ordered(entries: Entry[]) { return entries.filter(e => e.status === 'waiting').sort((a,b) => a.position-b.position); }
export function insert(entries: Entry[], entry: Entry) {
  const waiting = ordered(entries);
  const index = entry.ready ? waiting.findIndex(e => !e.ready) : entry.priority ? waiting.findIndex(e => !e.ready && !e.priority) : -1;
  waiting.splice(index < 0 ? waiting.length : index, 0, entry);
  waiting.forEach((e,i) => { e.position = i + 1; });
  return [...entries.filter(e => e.status !== 'waiting' && e.id !== entry.id), ...waiting];
}
export function promote(entries: Entry[]) {
  const scheduled = entries.some(e => !e.off_schedule && ['current','waiting'].includes(e.status));
  for (const entry of entries) {
    if (scheduled && entry.off_schedule && entry.status === 'waiting' && !entry.ready) entry.status = 'deferred';
    else if (!scheduled && entry.status === 'deferred') entry.status = 'waiting';
  }
  if (!entries.some(e => e.status === 'current')) { const first = ordered(entries)[0]; if (first) first.status = 'current'; }
  return entries;
}
