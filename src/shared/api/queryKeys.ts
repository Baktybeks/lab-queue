export const queryKeys={
  queue:(userId:string|null,sessionId:string|null)=>['queue',userId,sessionId] as const,
  history:(userId:string|null)=>['student-history',userId] as const,
  students:(userId:string|null)=>['students',userId] as const,
};
