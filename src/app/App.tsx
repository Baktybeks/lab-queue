import {QueryClientProvider} from '@tanstack/react-query';
import {queryClient} from '../shared/api/queryClient';
import {QueuePage} from '../pages/queue/ui/QueuePage';
import './styles/style.css';
export function App(){return <QueryClientProvider client={queryClient}><QueuePage/></QueryClientProvider>;}
