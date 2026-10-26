import { defineConfig } from 'vite';
export default defineConfig({ base: './', build:{rollupOptions:{
  output:{manualChunks:{react:['react','react-dom'],query:['@tanstack/react-query'],supabase:['@supabase/supabase-js']}},
  onwarn(warning,warn){
    if(warning.code==='MODULE_LEVEL_DIRECTIVE'&&warning.message.includes('use client'))return;
    warn(warning);
  },
}} });
