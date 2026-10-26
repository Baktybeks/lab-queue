import {insert,promote,type State} from './queue';
export const empty:State={lab:6,entries:[],admin:false};
const demoKey='lab-queue-demo-v1';
export function readDemo():State{try{return JSON.parse(localStorage.getItem(demoKey)||'null')||structuredClone(empty);}catch{return structuredClone(empty);}}
export function performDemo(action:string,args:Record<string,unknown>):State{
        const next = readDemo();
        const student = next.entries.find(e => e.mine);
        const now = next.entries.find(e => e.status === 'current');
        if (action === 'join' && !student) {
          next.entries = insert(next.entries,{ id: crypto.randomUUID(), name: String(args.name), lab: Number(args.lab), status: 'waiting', off_schedule: Boolean(args.off_schedule), priority: !args.off_schedule && Number(args.lab) === next.lab, ready: false, position: 0, mine: true });
        }
        if (action === 'ready' && student?.status === 'extra') {
          student.status = 'waiting'; student.can_return_extra = true; student.ready = !student.carried_extra; student.priority = false;
          next.entries = insert(next.entries.filter(e => e.id !== student.id),student);
        }
        if (action === 'return_extra' && student?.can_return_extra) {
          student.status = 'extra'; student.ready = false; student.priority = false; student.can_return_extra = false;
        }
        if (action === 'leave') next.entries = next.entries.filter(e => !e.mine);
        if (['next','pass','extra'].includes(action) && now) {
          next.entries = next.entries.filter(e => e.id !== now.id);
          promote(next.entries);
          now.ready = false; now.priority = false; now.can_return_extra = false;
          if (action === 'next') { now.status = 'waiting'; next.entries = insert(next.entries,now); }
          if (action === 'extra') { now.extra_count = (now.extra_count || 0) + 1; now.had_extra = true; now.carried_extra = false; now.status = 'extra'; next.entries.push(now); }
        }
        if (action === 'set_lab') {
          next.lab = Number(args.lab);
          // Priority is assigned on joining; changing the lab affects future registrations.
        }
        promote(next.entries);
        localStorage.setItem(demoKey,JSON.stringify(next)); return next;

}
