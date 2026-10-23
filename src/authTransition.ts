export function shouldResetAccount(event:string,currentUserId:string|null,nextUserId:string|null){
  return event==='SIGNED_OUT'||(event==='SIGNED_IN'&&nextUserId!==currentUserId);
}
