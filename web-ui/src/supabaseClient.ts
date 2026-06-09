import { createClient } from '@supabase/supabase-js';

const supabaseUrl = 'https://tlmyxuyqngkgwgjepeed.supabase.co';
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRsbXl4dXlxbmdrZ3dnamVwZWVkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3MTcwNTIsImV4cCI6MjA5NjI5MzA1Mn0.pcCDivFiRubY05NOeUBBYvi45TNfS1bSS1oEuRluBsU';

export const supabase = createClient(supabaseUrl, supabaseAnonKey);
