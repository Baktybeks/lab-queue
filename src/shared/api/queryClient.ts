import {QueryClient} from '@tanstack/react-query';
export const queryClient=new QueryClient({defaultOptions:{
  queries:{retry:1,staleTime:0,gcTime:5*60_000,refetchOnWindowFocus:true,refetchOnReconnect:true},
  // Commands must never be repeated automatically after an uncertain response.
  mutations:{retry:false,networkMode:'always'},
}});
