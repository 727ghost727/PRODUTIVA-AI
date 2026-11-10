-- PRODUTIVA.AI V5.1 — Chat privado e XP/rankings
-- Execute somente depois de SUPABASE_AMIZADES.sql. Faça backup antes.
create table if not exists public.chat_messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references auth.users(id) on delete cascade,
 receiver_id uuid not null references auth.users(id) on delete cascade,
 body text not null check (char_length(body) between 1 and 2000),
 created_at timestamptz not null default now(),
 read_at timestamptz,
 constraint chat_no_self_message check(sender_id <> receiver_id)
);
create index if not exists chat_pair_created_idx on public.chat_messages(sender_id, receiver_id, created_at desc);
create table if not exists public.xp_events (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 source_type text not null check(source_type in ('task','habit','goal')),
 source_id uuid not null,
 points integer not null check(points > 0),
 created_at timestamptz not null default now(),
 unique(source_type, source_id)
);
create index if not exists xp_events_user_created_idx on public.xp_events(user_id, created_at desc);
alter table public.chat_messages enable row level security;
alter table public.xp_events enable row level security;
drop policy if exists "Friends can read chat messages" on public.chat_messages;
create policy "Friends can read chat messages" on public.chat_messages for select to authenticated
using ((auth.uid()=sender_id or auth.uid()=receiver_id) and exists (
 select 1 from public.friendships f where f.status='accepted' and
 ((f.sender_id=chat_messages.sender_id and f.receiver_id=chat_messages.receiver_id) or
 (f.sender_id=chat_messages.receiver_id and f.receiver_id=chat_messages.sender_id))));
drop policy if exists "Friends can send chat messages" on public.chat_messages;
create policy "Friends can send chat messages" on public.chat_messages for insert to authenticated
with check (auth.uid()=sender_id and exists (
 select 1 from public.friendships f where f.status='accepted' and
 ((f.sender_id=chat_messages.sender_id and f.receiver_id=chat_messages.receiver_id) or (f.sender_id=chat_messages.receiver_id and f.receiver_id=chat_messages.sender_id))));
drop policy if exists "Participants mark messages read" on public.chat_messages;
create policy "Participants mark messages read" on public.chat_messages for update to authenticated
using(auth.uid()=receiver_id) with check(auth.uid()=receiver_id);
drop policy if exists "Users read own XP events" on public.xp_events;
create policy "Users read own XP events" on public.xp_events for select to authenticated using(auth.uid()=user_id);

create or replace function public.award_productivity_xp(p_user uuid,p_type text,p_source uuid,p_points integer)
returns void language plpgsql security definer set search_path=public as $$
begin
 if p_points <= 0 then return; end if;
 insert into public.xp_events(user_id,source_type,source_id,points)
 values(p_user,p_type,p_source,p_points) on conflict(source_type,source_id) do nothing;
end; $$;
revoke all on function public.award_productivity_xp(uuid,text,uuid,integer) from public, anon, authenticated;

create or replace function public.xp_on_task_complete() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status='concluida' and (tg_op='INSERT' or old.status is distinct from 'concluida') then
  perform public.award_productivity_xp(new.user_id,'task',new.id,10);
 end if; return new;
end; $$;
drop trigger if exists trg_xp_task_complete on public.tasks;
create trigger trg_xp_task_complete after insert or update of status on public.tasks for each row execute function public.xp_on_task_complete();

create or replace function public.xp_on_habit_complete() returns trigger language plpgsql security definer set search_path=public as $$
declare v_user uuid;
begin
 if new.completed then
  select user_id into v_user from public.habits where id=new.habit_id;
  if v_user is not null then perform public.award_productivity_xp(v_user,'habit',new.id,5); end if;
 end if; return new;
end; $$;
drop trigger if exists trg_xp_habit_complete on public.habit_logs;
create trigger trg_xp_habit_complete after insert or update of completed on public.habit_logs for each row execute function public.xp_on_habit_complete();

create or replace function public.xp_on_goal_complete() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if coalesce(new.progress,0)>=100 and (tg_op='INSERT' or coalesce(old.progress,0)<100) then
  perform public.award_productivity_xp(new.user_id,'goal',new.id,50);
 end if; return new;
end; $$;
drop trigger if exists trg_xp_goal_complete on public.goals;
create trigger trg_xp_goal_complete after insert or update of progress on public.goals for each row execute function public.xp_on_goal_complete();

-- Ranking: period = week | month | all; scope = global | friends.
create or replace function public.get_productivity_ranking(p_scope text default 'global',p_period text default 'week')
returns table(user_id uuid,username text,display_name text,points bigint,position bigint)
language sql security definer set search_path=public as $$
 with eligible as (
  select p.id,p.username,p.display_name,coalesce(sum(x.points),0)::bigint pts
  from public.profiles p left join public.xp_events x on x.user_id=p.id
   and (p_period='all' or (p_period='week' and x.created_at>=date_trunc('week',now())) or (p_period='month' and x.created_at>=date_trunc('month',now())))
  where (p_scope='global' or p.id=auth.uid() or exists(select 1 from public.friendships f where f.status='accepted' and ((f.sender_id=auth.uid() and f.receiver_id=p.id) or (f.receiver_id=auth.uid() and f.sender_id=p.id))))
  group by p.id,p.username,p.display_name
 ), ranked as (select e.*,row_number() over(order by e.pts desc,e.display_name asc) pos from eligible e)
 select r.id,r.username,r.display_name,r.pts,r.pos from ranked r order by r.pos limit 100;
$$;
grant execute on function public.get_productivity_ranking(text,text) to authenticated;

-- Atualização de leitura somente pelo destinatário, sem permitir alterar remetente/conteúdo.
revoke update on public.chat_messages from authenticated;
grant update(read_at) on public.chat_messages to authenticated;
