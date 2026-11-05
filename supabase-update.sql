-- ============================================================
--  カワラボ手帳 / 追加アップデート（アイコン＋フレンド詳細）
--  すでに supabase.sql を実行済みの人は、これを丸ごと貼って RUN してください。
--  何度実行しても壊れません。
-- ============================================================
alter table public.profiles add column if not exists avatar text not null default '';

drop function if exists public.signup(text, text);

create or replace function signup(p_nick text, p_pass text, p_avatar text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_token uuid; v_avatar text := coalesce(left(trim(p_avatar), 120000), '');
begin
  if length(trim(p_nick)) < 1 then raise exception 'ニックネームを入れてください'; end if;
  if length(p_pass) < 4 then raise exception 'パスワードは4文字以上にしてください'; end if;
  insert into profiles(nick, pass_hash, avatar)
  values (trim(p_nick), public._hash_pass(p_pass), v_avatar);
  insert into sessions(nick) values (trim(p_nick)) returning token into v_token;
  return jsonb_build_object('nick', trim(p_nick), 'token', v_token, 'oshi', '[]'::jsonb,
                            'atts', '[]'::jsonb, 'avatar', v_avatar);
exception when unique_violation then
  raise exception 'そのニックネームはすでに使われています';
end $$;

create or replace function login(p_nick text, p_pass text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_token uuid; v_oshi jsonb; v_atts jsonb; v_avatar text;
begin
  select oshi, coalesce(avatar, '') into v_oshi, v_avatar from profiles
   where nick = trim(p_nick) and pass_hash = public._hash_pass(p_pass);
  if v_oshi is null then raise exception 'ニックネームかパスワードが違います'; end if;
  insert into sessions(nick) values (trim(p_nick)) returning token into v_token;
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', event_key, 'date', event_date, 'title', title, 'time', start_time,
           'open', open_time, 'venue', venue, 'groups', groups, 'type', etype)), '[]'::jsonb)
    into v_atts from attends where nick = trim(p_nick);
  return jsonb_build_object('nick', trim(p_nick), 'token', v_token, 'oshi', v_oshi, 'atts', v_atts,
                            'avatar', coalesce(v_avatar, ''));
end $$;

create or replace function friend_list(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nick text := _who(p_token); v_out jsonb;
begin
  if v_nick is null then raise exception 'ログインし直してください'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_out from (
    select f.requester as nick, 'in' as dir, f.status,
           ''::text as avatar, '[]'::jsonb as oshi
      from friends f where f.addressee = v_nick and f.status = 'pending'
    union all
    select f.addressee as nick, 'out' as dir, f.status,
           ''::text, '[]'::jsonb
      from friends f where f.requester = v_nick and f.status = 'pending'
    union all
    select p.nick, 'friend' as dir, f.status,
           coalesce(p.avatar, '') as avatar, coalesce(p.oshi, '[]'::jsonb) as oshi
      from friends f
      join profiles p on p.nick = case when f.requester = v_nick then f.addressee else f.requester end
      where (f.requester = v_nick or f.addressee = v_nick) and f.status = 'accepted'
  ) x;
  return v_out;
end $$;

create or replace function set_avatar(p_token uuid, p_avatar text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nick text := _who(p_token);
begin
  if v_nick is null then raise exception 'ログインし直してください'; end if;
  update profiles set avatar = left(coalesce(p_avatar, ''), 120000) where nick = v_nick;
end $$;

-- ============================================================
--  Web Push（アプリを閉じていても届く通知）
--  supabase.sql 実行済みの人は、このブロックだけ貼って RUN でOK
-- ============================================================
create table if not exists push_subs (
  id bigserial primary key,
  nick text not null references profiles(nick) on delete cascade,
  endpoint text not null unique,
  sub jsonb not null,
  created_at timestamptz not null default now()
);
alter table push_subs enable row level security;

create or replace function push_sub(p_token uuid, p_sub jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_nick text := _who(p_token);
begin
  if v_nick is null then raise exception 'ログインし直してください'; end if;
  insert into push_subs(nick, endpoint, sub)
  values (v_nick, p_sub->>'endpoint', p_sub)
  on conflict (endpoint) do update set nick = excluded.nick, sub = excluded.sub;
end $$;

create or replace function push_del(p_token uuid, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nick text := _who(p_token);
begin
  if v_nick is null then raise exception 'ログインし直してください'; end if;
  delete from push_subs where nick = v_nick and endpoint = p_endpoint;
end $$;

-- 送信側（GitHub Actions）が使う。パスワードは admin_list と同じ 'kawarabo2026'
create or replace function push_list(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if public._hash_pass(p_secret) <> public._hash_pass('kawarabo2026') then
    raise exception '送信用パスワードが違います';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('nick', s.nick, 'oshi', p.oshi, 'sub', s.sub)), '[]'::jsonb)
    into v_out
    from push_subs s join profiles p on p.nick = s.nick;
  return v_out;
end $$;

create or replace function push_drop(p_secret text, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public._hash_pass(p_secret) <> public._hash_pass('kawarabo2026') then
    raise exception '送信用パスワードが違います';
  end if;
  delete from push_subs where endpoint = p_endpoint;
end $$;

-- ============================================================
--  予定をクラウドで共有する ＋ 設定（OneSignal App ID）を1か所で管理
-- ============================================================
create table if not exists public.app_events (
  id text primary key,
  event_date date not null,
  open_time text default '',
  start_time text default '',
  groups jsonb not null default '[]'::jsonb,
  etype text default 'live',
  title text not null,
  venue text default '',
  note text default '',
  source text default '',
  updated_at timestamptz not null default now()
);
alter table public.app_events enable row level security;

create table if not exists public.app_config (
  k text primary key,
  v text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.app_config enable row level security;

-- 予定を全員に配る（誰でも読める）
create or replace function events_get()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_list jsonb; v_ver text;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id,
      'date', to_char(event_date, 'YYYY-MM-DD'),
      'open', open_time,
      'time', start_time,
      'groups', groups,
      'type', etype,
      'title', title,
      'venue', venue,
      'note', note,
      'source', source
    ) order by event_date, start_time), '[]'::jsonb) into v_list
  from app_events;
  select coalesce(max(updated_at)::text, '') into v_ver from app_events;
  return jsonb_build_object('ver', v_ver, 'events', v_list);
end $$;

-- 管理者だけが予定を丸ごと差し替えられる
create or replace function events_save(p_pass text, p_events jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int; v_ver text;
begin
  if public._hash_pass(p_pass) <> public._hash_pass('kawarabo2026') then
    raise exception '管理者パスワードが違います';
  end if;
  delete from app_events;
  insert into app_events(id, event_date, open_time, start_time, groups, etype, title, venue, note, source, updated_at)
  select coalesce(nullif(x.id, ''), 'e' || (row_number() over ())::text),
         x.date, coalesce(x.open, ''), coalesce(x.time, ''),
         coalesce(x.groups, '[]'::jsonb), coalesce(x.type, 'live'),
         x.title, coalesce(x.venue, ''), coalesce(x.note, ''), coalesce(x.source, ''), now()
  from jsonb_to_recordset(p_events) as x(
    id text, date date, "open" text, "time" text, groups jsonb,
    type text, title text, venue text, note text, source text
  )
  where x.title is not null and x.date is not null;
  get diagnostics v_n = row_count;
  select coalesce(max(updated_at)::text, '') into v_ver from app_events;
  return jsonb_build_object('count', v_n, 'ver', v_ver);
end $$;

-- アプリ全体の設定（今は OneSignal の App ID のみ）
create or replace function config_get()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
  from app_config where k in ('onesignal_app_id');
$$;

create or replace function config_set(p_pass text, p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public._hash_pass(p_pass) <> public._hash_pass('kawarabo2026') then
    raise exception '管理者パスワードが違います';
  end if;
  if p_key <> 'onesignal_app_id' then
    raise exception 'この設定は変更できません';
  end if;
  insert into app_config(k, v, updated_at) values (p_key, coalesce(p_value, ''), now())
  on conflict (k) do update set v = excluded.v, updated_at = now();
end $$;

grant execute on function events_get() to anon;
grant execute on function events_save(text, jsonb) to anon;
grant execute on function config_get() to anon;
grant execute on function config_set(text, text, text) to anon;
grant execute on function push_sub to anon;
grant execute on function push_del to anon;
grant execute on function push_list to anon;
grant execute on function push_drop to anon;
