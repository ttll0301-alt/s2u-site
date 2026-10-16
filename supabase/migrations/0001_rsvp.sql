-- S2:U RSVP / 입금 확인 / 자동 문자
-- Supabase(Postgres) 마이그레이션. SQL Editor에 그대로 붙여 실행하거나 `supabase db push`로 적용합니다.
-- 모든 테이블은 RLS로 잠겨 있고, 공개 접근은 아래 rsvp_public_event / rsvp_get_registration /
-- rsvp_submit / rsvp_claim_payment 4개 함수로만 가능합니다. (개인 토큰이 없으면 아무것도 읽을 수 없음)

-- ============================================================
-- 0. 공통
-- ============================================================
create table if not exists rsvp_settings (
  key   text primary key,
  value text not null
);
insert into rsvp_settings (key, value) values ('site_base', 'https://sustaintoyou.com')
  on conflict (key) do nothing;

create or replace function rsvp_norm_phone(p text) returns text
language sql immutable as $$
  select case
    when d ~ '^8210\d{8}$'       then '0' || substr(d, 3)
    when d ~ '^010\d{8}$'        then d
    when d ~ '^01[16789]\d{7,8}$' then d
    else null end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) s;
$$;

create or replace function rsvp_new_token() returns text
language sql volatile as $$
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
$$;

create or replace function rsvp_fmt_kst(ts timestamptz) returns text
language sql stable as $$
  select case when ts is null then '' else
    to_char(ts at time zone 'Asia/Seoul', 'YYYY.MM.DD')
    || ' (' || (array['일','월','화','수','목','금','토'])[extract(dow from ts at time zone 'Asia/Seoul')::int + 1] || ') '
    || to_char(ts at time zone 'Asia/Seoul', 'HH24:MI') end;
$$;

-- ============================================================
-- 1. 기본 문구 (운영자가 행사별로 수정 가능)
-- ============================================================
-- 사용 가능한 치환어: {이름} {행사명} {일시} {장소} {참가비} {계좌} {입금기한} {준비물} {문의} {링크}
create or replace function rsvp_default_templates() returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'invite',    E'[S2:U] {이름}님, {행사명}에 초대합니다.\n일시 {일시}\n장소 {장소}\n참석 여부를 알려주세요: {링크}',
    'received',  E'[S2:U] {행사명} 신청이 접수되었습니다. 아직 참여 확정이 아닙니다.\n참가비 {참가비}\n입금계좌 {계좌}\n입금기한 {입금기한}\n입금 확인 후 확정 문자를 보내드립니다.\n{링크}',
    'waitlist',  E'[S2:U] {행사명} 정원이 가득 차 대기자로 등록되었습니다. 자리가 나면 문자로 안내드립니다.\n{링크}',
    'promoted',  E'[S2:U] {행사명} 자리가 생겼습니다. 아직 참여 확정이 아닙니다.\n참가비 {참가비}\n입금계좌 {계좌}\n입금기한 {입금기한}\n입금 확인 후 확정됩니다.\n{링크}',
    'confirmed', E'[S2:U] {이름}님, {행사명} 참여가 확정되었습니다.\n일시 {일시}\n장소 {장소}\n준비물 {준비물}\n신청 확인 {링크}',
    'unpaid',    E'[S2:U] {행사명} 입금이 아직 확인되지 않았습니다.\n참가비 {참가비} / {계좌}\n입금기한 {입금기한}\n이미 입금하셨다면 아래 링크에서 입금 확인 요청을 눌러주세요.\n{링크}'
  );
$$;

-- 동의 문구 초안입니다. 법률 검토를 받은 뒤 운영 화면에서 수정하세요. (본문이 바뀌면 동의 기록의 hash가 달라집니다)
create or replace function rsvp_default_consents() returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('key','privacy','required',true,'version','v1','label','개인정보 수집·이용 동의 (필수)',
      'body',E'수집 항목: 이름, 연락처, 입금자명, 신청 시 입력한 답변\n이용 목적: 행사 신청 접수, 참가 확정 및 입금 확인, 행사 관련 안내 문자 발송\n보유 기간: 행사 종료 후 1년 이내 파기\n동의를 거부할 수 있으나, 거부 시 행사 신청이 제한됩니다.'),
    jsonb_build_object('key','notice','required',true,'version','v1','label','행사 참여 유의사항 확인 (필수)',
      'body',E'행사 안내, 준비물, 취소·환불 안내를 확인했으며 이에 동의합니다.'),
    jsonb_build_object('key','photo','required',false,'version','v1','label','행사 촬영·활용 동의 (선택)',
      'body',E'행사 중 촬영된 사진·영상이 S2:U 및 협업 브랜드의 홍보 콘텐츠(홈페이지, SNS 등)에 활용될 수 있음에 동의합니다. 동의하지 않아도 행사에 참여할 수 있습니다.'),
    jsonb_build_object('key','marketing','required',false,'version','v1','label','마케팅 정보 수신 동의 (선택)',
      'body',E'S2:U 및 협업 브랜드의 이후 행사·프로그램 소식(광고성 정보)을 문자로 받는 것에 동의합니다. 동의하지 않아도 행사에 참여할 수 있습니다.')
  );
$$;

-- ============================================================
-- 2. 테이블
-- ============================================================
create table if not exists rsvp_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null default 'host' check (role in ('admin','host')),
  name    text,
  created_at timestamptz not null default now()
);

create table if not exists rsvp_events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,59}$'),
  status text not null default 'draft' check (status in ('draft','open','closed','cancelled')),
  title text not null,
  hero_image text,
  intro text,
  hosts text,                       -- 주최
  partners text,                    -- 협업 브랜드
  starts_at timestamptz not null,
  ends_at timestamptz,
  venue text,
  map_url text,
  sessions jsonb not null default '[]'::jsonb,  -- [{id,label,starts_at,capacity}]
  capacity int check (capacity is null or capacity >= 0),
  apply_deadline timestamptz,
  allow_open_signup boolean not null default true,  -- false면 개인 초대 링크로만 신청
  is_paid boolean not null default false,
  fee int check (fee is null or fee >= 0),
  bank_name text,
  bank_account text,
  account_holder text,
  payment_deadline timestamptz,
  hold_hours int check (hold_hours is null or hold_hours > 0),   -- 입금 대기자 자리 확보 시간(신청 시점부터)
  on_deadline text not null default 'expire' check (on_deadline in ('expire','manual')),
  prep text,
  guide text,
  refund_policy text,
  contact text,
  extra_questions jsonb not null default '[]'::jsonb,  -- [{id,label,type:text|select|checkbox,options:[],required}]
  consent_defs jsonb not null default rsvp_default_consents(),
  sms_templates jsonb not null default rsvp_default_templates(),
  reminder_enabled boolean not null default false,
  reminder_offsets jsonb not null default '[3,2,1]'::jsonb,   -- 행사일 기준 N일 전
  reminder_hour int not null default 10 check (reminder_hour between 0 and 23),  -- 한국 시간
  min_sms_gap_minutes int not null default 360,
  sms_live boolean not null default false,   -- 호스트가 확인 후 켜야 실제 발송 (그 전에는 테스트 기록만)
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists rsvp_staff_events (
  user_id  uuid not null references rsvp_staff(user_id) on delete cascade,
  event_id uuid not null references rsvp_events(id) on delete cascade,
  primary key (user_id, event_id)
);

create table if not exists rsvp_registrations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references rsvp_events(id) on delete cascade,
  token text not null unique default rsvp_new_token(),   -- 개인 링크용 추측 불가 토큰
  name text not null,
  phone text not null,
  phone_norm text not null,
  source text not null default 'link' check (source in ('host','link')),
  rsvp text not null default 'invited' check (rsvp in ('invited','attending','declined')),
  session_ids text[] not null default '{}',
  depositor_name text,
  answers jsonb not null default '{}'::jsonb,
  consents jsonb not null default '{}'::jsonb,        -- {key:{accepted,version,hash,at}}
  consent_ok boolean not null default false,          -- 필수 동의 완료
  seat text not null default 'none' check (seat in ('none','held','waitlist','released')),
  seat_held_until timestamptz,
  fee_waived boolean not null default false,
  waived_by uuid,
  payment text not null default 'not_required'
    check (payment in ('not_required','pending','claimed','verified','flagged')),
  payment_flag text check (payment_flag in ('name_mismatch','short','duplicate','other')),
  payment_note text,
  paid_amount int,
  claimed_at timestamptz,        -- 참여자가 '입금 확인 요청'을 누른 시각 (입금 확인 아님)
  verified_by uuid,
  verified_at timestamptz,
  status text not null default 'invited'
    check (status in ('invited','payment_pending','confirmed','waitlist','declined','expired')),
  invited_at timestamptz,
  applied_at timestamptz,
  cancelled_at timestamptz,
  expired_at timestamptz,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, phone_norm)
);
create index if not exists rsvp_reg_event_status on rsvp_registrations (event_id, status);

create table if not exists rsvp_outbox (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references rsvp_events(id) on delete cascade,
  registration_id uuid not null references rsvp_registrations(id) on delete cascade,
  kind text not null check (kind in ('invite','received','waitlist','promoted','confirmed','unpaid')),
  slot text not null,
  dedupe_key text not null unique,     -- 행사|참여자|종류|회차 → 같은 안내 중복 발송 방지
  status text not null default 'queued'
    check (status in ('queued','sending','sent','test_logged','skipped','failed','cancelled')),
  scheduled_at timestamptz not null default now(),
  claimed_at timestamptz,
  attempts int not null default 0,
  to_phone text,
  body text,
  provider text,
  provider_message_id text,
  provider_status text,                -- 업체가 '접수'했다는 뜻이며 단말기 수신을 보장하지 않음
  last_error text,
  skip_reason text,
  sent_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists rsvp_outbox_due on rsvp_outbox (status, scheduled_at);
create index if not exists rsvp_outbox_reg on rsvp_outbox (registration_id, created_at);

create table if not exists rsvp_audit (
  id bigserial primary key,
  event_id uuid references rsvp_events(id) on delete cascade,
  registration_id uuid references rsvp_registrations(id) on delete cascade,
  actor uuid,
  action text not null,
  detail jsonb,
  at timestamptz not null default now()
);
create index if not exists rsvp_audit_reg on rsvp_audit (registration_id, at);

-- ============================================================
-- 3. 권한 헬퍼
-- ============================================================
create or replace function rsvp_can_manage(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from rsvp_staff s
    where s.user_id = auth.uid()
      and (s.role = 'admin'
           or exists (select 1 from rsvp_staff_events se where se.user_id = s.user_id and se.event_id = p_event))
  );
$$;

create or replace function rsvp_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_staff s where s.user_id = auth.uid() and s.role = 'admin');
$$;

create or replace function rsvp_log(p_event uuid, p_reg uuid, p_action text, p_detail jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into rsvp_audit (event_id, registration_id, actor, action, detail)
  values (p_event, p_reg, auth.uid(), p_action, p_detail);
$$;

-- ============================================================
-- 4. 상태 계산 / 문구 렌더
-- ============================================================
-- 확정 조건: 참여 신청 + 필수 동의 + 자리 확보 + (무료 | 참가비 면제 | 입금 확인)
-- 참여자의 '입금했습니다'(claimed)는 확정 조건이 아니다.
create or replace function rsvp_calc_status(r rsvp_registrations, e rsvp_events) returns text
language plpgsql stable as $$
begin
  if r.expired_at is not null then return 'expired'; end if;
  if r.rsvp = 'declined' then return 'declined'; end if;
  if r.rsvp = 'invited' then return 'invited'; end if;
  if not r.consent_ok then return 'invited'; end if;
  if r.seat = 'waitlist' then return 'waitlist'; end if;
  if r.seat <> 'held' then return 'invited'; end if;
  if not e.is_paid or r.fee_waived or r.payment = 'verified' then return 'confirmed'; end if;
  return 'payment_pending';
end $$;

create or replace function rsvp_render(p_tpl text, e rsvp_events, p_name text, p_token text, p_hold timestamptz)
returns text language plpgsql stable as $$
declare
  v_base text := (select value from rsvp_settings where key = 'site_base');
  v_deadline timestamptz := coalesce(p_hold, e.payment_deadline);
  t text := coalesce(p_tpl, '');
begin
  t := replace(t, '{이름}', coalesce(p_name, ''));
  t := replace(t, '{행사명}', e.title);
  t := replace(t, '{일시}', rsvp_fmt_kst(e.starts_at));
  t := replace(t, '{장소}', coalesce(e.venue, ''));
  t := replace(t, '{참가비}', case when e.is_paid then to_char(coalesce(e.fee, 0), 'FM999,999,999') || '원' else '무료' end);
  t := replace(t, '{계좌}', btrim(coalesce(e.bank_name, '') || ' ' || coalesce(e.bank_account, '')
                      || case when e.account_holder is not null then ' (' || e.account_holder || ')' else '' end));
  t := replace(t, '{입금기한}', coalesce(nullif(rsvp_fmt_kst(v_deadline), ''), '별도 안내'));
  t := replace(t, '{준비물}', coalesce(e.prep, '별도 안내 없음'));
  t := replace(t, '{문의}', coalesce(e.contact, ''));
  t := replace(t, '{링크}', v_base || '/rsvp/?e=' || e.slug || '&t=' || coalesce(p_token, ''));
  return t;
end $$;

-- ============================================================
-- 5. 정원 / 자리 확보
--    모든 신청·취소·만료 처리는 행사 행(row)을 FOR UPDATE로 잠근 뒤 진행해 동시 신청에도 정원을 넘지 않는다.
-- ============================================================
create or replace function rsvp_has_room(e rsvp_events, r rsvp_registrations) returns boolean
language plpgsql stable as $$
declare sid text; used int; scap int;
begin
  if e.capacity is not null then
    select count(*) into used from rsvp_registrations x
      where x.event_id = e.id and x.id <> r.id and x.seat = 'held';
    if used >= e.capacity then return false; end if;
  end if;
  for sid in select unnest(r.session_ids) loop
    select nullif(s->>'capacity', '')::int into scap
      from jsonb_array_elements(e.sessions) s where s->>'id' = sid;
    if scap is not null then
      select count(*) into used from rsvp_registrations x
        where x.event_id = e.id and x.id <> r.id and x.seat = 'held' and sid = any (x.session_ids);
      if used >= scap then return false; end if;
    end if;
  end loop;
  return true;
end $$;

create or replace function rsvp_hold_until(e rsvp_events, r rsvp_registrations) returns timestamptz
language sql stable as $$
  select case
    when not e.is_paid or r.fee_waived then null
    when e.on_deadline = 'expire' then
      least(e.payment_deadline, case when e.hold_hours is not null then now() + make_interval(hours => e.hold_hours) end)
    else case when e.hold_hours is not null then now() + make_interval(hours => e.hold_hours) end
  end;
$$;

-- 호출자가 행사 행 잠금을 쥐고 있어야 한다.
create or replace function rsvp_seat_one(p_reg uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e rsvp_events; r rsvp_registrations;
begin
  select * into r from rsvp_registrations where id = p_reg for update;
  select * into e from rsvp_events where id = r.event_id;
  if rsvp_has_room(e, r) then
    update rsvp_registrations set
      seat = 'held',
      seat_held_until = rsvp_hold_until(e, r),
      payment = case when e.is_paid and not fee_waived then 'pending' else 'not_required' end,
      payment_flag = null, claimed_at = null
    where id = p_reg;
  else
    update rsvp_registrations set seat = 'waitlist', seat_held_until = null, payment = 'not_required' where id = p_reg;
  end if;
end $$;

-- 입금 기한/확보 시간이 지난 '입금 대기' 자리를 해제한다. 입금 확인 요청(claimed)·확인 필요(flagged)는 운영자 검토 대상이므로 자동 해제하지 않는다.
create or replace function rsvp_sweep_event(p_event uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update rsvp_registrations r set seat = 'released', expired_at = now(), seat_held_until = null
  where r.event_id = p_event and r.rsvp = 'attending' and r.seat = 'held' and r.payment = 'pending'
    and r.seat_held_until is not null and r.seat_held_until < now();
  get diagnostics n = row_count;
  if n > 0 then perform rsvp_promote(p_event); end if;
  return n;
end $$;

-- 빈 자리가 생기면 대기자를 신청 순서대로 올린다.
create or replace function rsvp_promote(p_event uuid) returns int
language plpgsql security definer set search_path = public as $$
declare e rsvp_events; w rsvp_registrations; n int := 0;
begin
  select * into e from rsvp_events where id = p_event;
  if e.status <> 'open' or e.starts_at <= now() then return 0; end if;
  if e.is_paid and e.payment_deadline is not null and e.payment_deadline <= now() and e.on_deadline = 'expire' then
    return 0;   -- 입금 기한이 지난 뒤에는 자동 승급하지 않음
  end if;
  for w in select * from rsvp_registrations
           where event_id = p_event and seat = 'waitlist' and rsvp = 'attending'
           order by applied_at, created_at loop
    if rsvp_has_room(e, w) then
      perform rsvp_seat_one(w.id);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ============================================================
-- 6. 트리거: 상태 재계산 + 상태 전이 시 안내 문자 예약
-- ============================================================
create or replace function rsvp_reg_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare e rsvp_events;
begin
  select * into e from rsvp_events where id = new.event_id;
  new.updated_at := now();
  new.status := rsvp_calc_status(new, e);
  if new.status = 'confirmed' then
    if tg_op = 'INSERT' then
      new.confirmed_at := now();
    elsif old.status is distinct from 'confirmed' then
      new.confirmed_at := now();
    end if;
  else
    new.confirmed_at := null;
  end if;
  return new;
end $$;

create or replace function rsvp_enqueue(p_event uuid, p_reg uuid, p_kind text, p_slot text) returns void
language sql security definer set search_path = public as $$
  insert into rsvp_outbox (event_id, registration_id, kind, slot, dedupe_key)
  values (p_event, p_reg, p_kind, p_slot, p_event || '|' || p_reg || '|' || p_kind || '|' || p_slot)
  on conflict (dedupe_key) do nothing;
$$;

create or replace function rsvp_reg_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_prev text;
begin
  if tg_op = 'UPDATE' then
    if old.status = new.status then return new; end if;
    v_prev := old.status;
  end if;
  if new.status = 'confirmed' then
    perform rsvp_enqueue(new.event_id, new.id, 'confirmed', 'c1');
  elsif new.status = 'payment_pending' then
    if v_prev = 'waitlist' then
      perform rsvp_enqueue(new.event_id, new.id, 'promoted', 'p1');
    else
      perform rsvp_enqueue(new.event_id, new.id, 'received', 'r1');
    end if;
  elsif new.status = 'waitlist' then
    perform rsvp_enqueue(new.event_id, new.id, 'waitlist', 'w1');
  end if;
  return new;
end $$;

drop trigger if exists rsvp_reg_before_t on rsvp_registrations;
create trigger rsvp_reg_before_t before insert or update on rsvp_registrations
  for each row execute function rsvp_reg_before();
drop trigger if exists rsvp_reg_after_t on rsvp_registrations;
create trigger rsvp_reg_after_t after insert or update on rsvp_registrations
  for each row execute function rsvp_reg_after();

-- 행사 취소·일정/입금기한 변경: 대기 중인 미입금 안내를 취소한다. (미입금 안내는 발송 시점마다 일정을 다시 계산하므로 새 일정이 자동 반영됨)
create or replace function rsvp_event_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function rsvp_event_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update rsvp_outbox set status = 'cancelled', skip_reason = 'event_cancelled'
      where event_id = new.id and status = 'queued';
  elsif new.starts_at is distinct from old.starts_at
     or new.payment_deadline is distinct from old.payment_deadline
     or new.reminder_offsets is distinct from old.reminder_offsets
     or new.reminder_hour is distinct from old.reminder_hour
     or (new.reminder_enabled = false and old.reminder_enabled = true) then
    update rsvp_outbox set status = 'cancelled', skip_reason = 'event_rescheduled'
      where event_id = new.id and status = 'queued' and kind = 'unpaid';
  end if;
  return new;
end $$;

drop trigger if exists rsvp_event_touch_t on rsvp_events;
create trigger rsvp_event_touch_t before update on rsvp_events
  for each row execute function rsvp_event_after();
drop trigger if exists rsvp_event_changed_t on rsvp_events;
create trigger rsvp_event_changed_t after update on rsvp_events
  for each row execute function rsvp_event_changed();

-- ============================================================
-- 7. 공개 RPC (로그인 없이 호출, 개인 토큰으로만 개인 데이터 접근)
-- ============================================================
create or replace function rsvp_view(r rsvp_registrations, e rsvp_events) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare show_bank boolean := e.is_paid and r.status = 'payment_pending';
begin
  return jsonb_build_object(
    'ok', true,
    'registration', jsonb_build_object(
      'name', r.name,
      'phone_masked', left(r.phone, 3) || '-****-' || right(r.phone, 4),
      'rsvp', r.rsvp, 'status', r.status, 'payment', r.payment, 'payment_flag', r.payment_flag,
      'seat', r.seat, 'session_ids', to_jsonb(r.session_ids), 'depositor_name', r.depositor_name,
      'answers', r.answers, 'consents', (select coalesce(jsonb_object_agg(k, v->'accepted'), '{}'::jsonb) from jsonb_each(r.consents) c(k, v)),
      'fee_waived', r.fee_waived, 'claimed_at', r.claimed_at, 'confirmed_at', r.confirmed_at,
      'hold_until', r.seat_held_until
    ),
    'payment_info', case when show_bank then jsonb_build_object(
      'fee', e.fee, 'bank_name', e.bank_name, 'bank_account', e.bank_account, 'account_holder', e.account_holder,
      'deadline', coalesce(r.seat_held_until, e.payment_deadline)) end
  );
end $$;

create or replace function rsvp_public_event(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e rsvp_events; held int; v_state text;
begin
  select * into e from rsvp_events where slug = p_slug and status <> 'draft';
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select count(*) into held from rsvp_registrations where event_id = e.id and seat = 'held';
  v_state := case
    when e.status = 'cancelled' then 'cancelled'
    when e.status = 'closed' or (e.apply_deadline is not null and e.apply_deadline < now()) or e.starts_at < now() then 'closed'
    else 'open' end;
  return jsonb_build_object('ok', true, 'event', jsonb_build_object(
    'slug', e.slug, 'title', e.title, 'hero_image', e.hero_image, 'intro', e.intro, 'hosts', e.hosts, 'partners', e.partners,
    'starts_at', e.starts_at, 'ends_at', e.ends_at, 'venue', e.venue, 'map_url', e.map_url,
    'sessions', e.sessions, 'apply_deadline', e.apply_deadline, 'allow_open_signup', e.allow_open_signup,
    'is_paid', e.is_paid, 'fee', case when e.is_paid then e.fee end,
    'prep', e.prep, 'guide', e.guide, 'refund_policy', e.refund_policy, 'contact', e.contact,
    'extra_questions', e.extra_questions, 'consent_defs', e.consent_defs,
    'state', v_state,
    'seats_left', case when e.capacity is null then null else greatest(e.capacity - held, 0) end,
    'payment_deadline', case when e.is_paid then e.payment_deadline end));
end $$;

create or replace function rsvp_get_registration(p_slug text, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e rsvp_events; r rsvp_registrations;
begin
  select * into e from rsvp_events where slug = p_slug and status <> 'draft';
  if not found or p_token is null or length(p_token) < 32 then return jsonb_build_object('ok', false, 'error', 'invalid_link'); end if;
  select * into r from rsvp_registrations where event_id = e.id and token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_link'); end if;
  return rsvp_view(r, e);
end $$;

create or replace function rsvp_err(p_code text, p_msg text) returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'error', p_code, 'message', p_msg) $$;

create or replace function rsvp_submit(p_slug text, p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e rsvp_events; r rsvp_registrations;
  v_name text; v_phone text; v_norm text; v_rsvp text; v_dep text;
  v_sessions text[] := '{}'; v_answers jsonb := '{}'::jsonb; v_cons jsonb := '{}'::jsonb;
  v_ok boolean := true; d jsonb; q jsonb; a text; sid text; v_acc boolean;
  v_new boolean := false; v_reattend boolean;
begin
  select * into e from rsvp_events where slug = p_slug and status <> 'draft' for update;   -- 행사 단위 직렬화
  if not found then return rsvp_err('not_found', '행사를 찾을 수 없습니다.'); end if;
  if e.status <> 'open' or e.starts_at < now() or (e.apply_deadline is not null and e.apply_deadline < now()) then
    return rsvp_err('closed', '신청이 마감되었습니다.');
  end if;

  perform rsvp_sweep_event(e.id);
  v_rsvp := p_payload->>'rsvp';
  if v_rsvp not in ('attending', 'declined') then return rsvp_err('bad_rsvp', '참여 여부를 선택해 주세요.'); end if;

  if p_token is not null then
    select * into r from rsvp_registrations where event_id = e.id and token = p_token;
    if not found then return rsvp_err('invalid_link', '유효하지 않은 링크입니다.'); end if;
    v_name := coalesce(nullif(btrim(p_payload->>'name'), ''), r.name);
    v_norm := r.phone_norm; v_phone := r.phone;
  else
    if not e.allow_open_signup then return rsvp_err('invite_only', '초대받은 분만 신청할 수 있습니다. 문자로 받은 개인 링크를 이용해 주세요.'); end if;
    if v_rsvp <> 'attending' then return rsvp_err('bad_rsvp', '신청 링크에서는 참여 신청만 가능합니다.'); end if;
    v_name := btrim(coalesce(p_payload->>'name', ''));
    v_phone := btrim(coalesce(p_payload->>'phone', ''));
    v_norm := rsvp_norm_phone(v_phone);
    if v_name = '' or length(v_name) > 40 then return rsvp_err('bad_name', '이름을 입력해 주세요.'); end if;
    if v_norm is null then return rsvp_err('bad_phone', '휴대폰 번호를 확인해 주세요.'); end if;
    select * into r from rsvp_registrations where event_id = e.id and phone_norm = v_norm;
    if found then
      return rsvp_err('duplicate', '이미 신청된 번호입니다. 신청 때 받은 문자의 링크에서 확인·수정해 주세요.');
    end if;
  end if;

  if v_rsvp = 'attending' then
    -- 회차
    if jsonb_array_length(e.sessions) > 0 then
      select coalesce(array_agg(x), '{}') into v_sessions from jsonb_array_elements_text(coalesce(p_payload->'session_ids', '[]'::jsonb)) x;
      if cardinality(v_sessions) = 0 then return rsvp_err('session_required', '참여할 회차를 선택해 주세요.'); end if;
      foreach sid in array v_sessions loop
        if not exists (select 1 from jsonb_array_elements(e.sessions) s where s->>'id' = sid) then
          return rsvp_err('bad_session', '선택한 회차를 확인해 주세요.');
        end if;
      end loop;
    end if;
    -- 입금자명
    v_dep := nullif(btrim(coalesce(p_payload->>'depositor_name', '')), '');
    if e.is_paid and not coalesce(r.fee_waived, false) and v_dep is null then
      return rsvp_err('depositor_required', '입금자명을 입력해 주세요.');
    end if;
    -- 추가 질문
    for q in select * from jsonb_array_elements(e.extra_questions) loop
      a := nullif(btrim(coalesce(p_payload->'answers'->>(q->>'id'), '')), '');
      if coalesce((q->>'required')::boolean, false) and a is null then
        return rsvp_err('answer_required', '"' || (q->>'label') || '" 항목을 입력해 주세요.');
      end if;
      if a is not null then v_answers := v_answers || jsonb_build_object(q->>'id', left(a, 500)); end if;
    end loop;
    -- 동의 (문구/버전은 서버에 저장된 정의를 기준으로 기록)
    for d in select * from jsonb_array_elements(e.consent_defs) loop
      v_acc := coalesce((p_payload->'consents'->>(d->>'key'))::boolean, false);
      if coalesce((d->>'required')::boolean, false) and not v_acc then
        v_ok := false;
        return rsvp_err('consent_required', '필수 동의 항목에 동의해 주세요: ' || (d->>'label'));
      end if;
      v_cons := v_cons || jsonb_build_object(d->>'key', jsonb_build_object(
        'accepted', v_acc, 'version', d->>'version', 'hash', left(md5(coalesce(d->>'body', '')), 8), 'at', now()));
    end loop;
  end if;

  if r.id is null then
    insert into rsvp_registrations (event_id, name, phone, phone_norm, source, rsvp, session_ids, depositor_name,
                                    answers, consents, consent_ok, applied_at)
    values (e.id, v_name, v_phone, v_norm, 'link', 'attending', v_sessions, v_dep, v_answers, v_cons, v_ok, now())
    returning * into r;
    v_new := true;
    perform rsvp_log(e.id, r.id, 'apply', jsonb_build_object('via', 'open_link'));
    perform rsvp_seat_one(r.id);
  else
    if v_rsvp = 'declined' then
      update rsvp_registrations set rsvp = 'declined', name = v_name, cancelled_at = now(),
        seat = case when seat in ('held', 'waitlist') then 'released' else seat end,
        seat_held_until = null, expired_at = null
      where id = r.id;
      perform rsvp_log(e.id, r.id, 'decline', null);
      perform rsvp_promote(e.id);
    else
      v_reattend := r.rsvp <> 'attending' or r.expired_at is not null;
      if r.status = 'confirmed' and r.session_ids is distinct from v_sessions then
        return rsvp_err('locked', '확정 후에는 회차를 바꿀 수 없습니다. 문의처로 연락해 주세요.');
      end if;
      update rsvp_registrations set
        rsvp = 'attending', name = v_name, session_ids = v_sessions,
        depositor_name = coalesce(v_dep, depositor_name), answers = v_answers,
        consents = v_cons, consent_ok = v_ok,
        applied_at = case when v_reattend then now() else applied_at end,
        cancelled_at = null, expired_at = null,
        seat = case when v_reattend then 'none' else seat end
      where id = r.id;
      perform rsvp_log(e.id, r.id, case when v_reattend then 'apply' else 'update' end, null);
      if v_reattend then perform rsvp_seat_one(r.id); end if;
    end if;
  end if;

  select * into r from rsvp_registrations where id = r.id;
  return rsvp_view(r, e) || jsonb_build_object('created', v_new, 'token', r.token);
end $$;

-- 참여자가 '입금했습니다'를 누르면 입금 확인 요청으로만 기록한다. 확정은 운영자의 입금 확인이 있어야 한다.
create or replace function rsvp_claim_payment(p_slug text, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e rsvp_events; r rsvp_registrations;
begin
  select * into e from rsvp_events where slug = p_slug and status in ('open', 'closed') for update;
  if not found then return rsvp_err('not_found', '행사를 찾을 수 없습니다.'); end if;
  select * into r from rsvp_registrations where event_id = e.id and token = p_token;
  if not found then return rsvp_err('invalid_link', '유효하지 않은 링크입니다.'); end if;
  if r.status = 'payment_pending' and r.payment in ('pending', 'claimed') then
    update rsvp_registrations set payment = 'claimed', claimed_at = now() where id = r.id;
    perform rsvp_log(e.id, r.id, 'payment_claimed', null);
    select * into r from rsvp_registrations where id = r.id;
  end if;
  return rsvp_view(r, e);
end $$;

-- ============================================================
-- 8. 운영자 RPC (staff 로그인 필요)
-- ============================================================
create or replace function rsvp_admin_clone_event(p_id uuid, p_title text, p_slug text) returns uuid
language plpgsql security definer set search_path = public as $$
declare src rsvp_events; new_id uuid;
begin
  if not rsvp_is_admin() then raise exception 'forbidden'; end if;
  select * into src from rsvp_events where id = p_id;
  if not found then raise exception 'not_found'; end if;
  insert into rsvp_events (slug, status, title, hero_image, intro, hosts, partners, starts_at, ends_at, venue, map_url, sessions,
    capacity, apply_deadline, allow_open_signup, is_paid, fee, bank_name, bank_account, account_holder, payment_deadline, hold_hours,
    on_deadline, prep, guide, refund_policy, contact, extra_questions, consent_defs, sms_templates,
    reminder_enabled, reminder_offsets, reminder_hour, min_sms_gap_minutes, sms_live)
  select p_slug, 'draft', p_title, hero_image, intro, hosts, partners, starts_at, ends_at, venue, map_url, sessions,
    capacity, apply_deadline, allow_open_signup, is_paid, fee, bank_name, bank_account, account_holder, payment_deadline, hold_hours,
    on_deadline, prep, guide, refund_policy, contact, extra_questions, consent_defs, sms_templates,
    false, reminder_offsets, reminder_hour, min_sms_gap_minutes, false      -- 자동 발송·실발송은 복제본에서 꺼 둔다
  from rsvp_events where id = p_id
  returning id into new_id;
  perform rsvp_log(new_id, null, 'event_clone', jsonb_build_object('from', p_id));
  return new_id;
end $$;

-- p_rows: [{name, phone, waive_fee}]
create or replace function rsvp_admin_add_registrations(p_event uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_norm text; v_added int := 0; v_dup jsonb := '[]'; v_bad jsonb := '[]'; rid uuid;
begin
  if not rsvp_can_manage(p_event) then raise exception 'forbidden'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_norm := rsvp_norm_phone(x->>'phone');
    if v_norm is null or btrim(coalesce(x->>'name', '')) = '' then
      v_bad := v_bad || jsonb_build_array(x); continue;
    end if;
    if exists (select 1 from rsvp_registrations where event_id = p_event and phone_norm = v_norm) then
      v_dup := v_dup || jsonb_build_array(x); continue;
    end if;
    insert into rsvp_registrations (event_id, name, phone, phone_norm, source, fee_waived, waived_by)
    values (p_event, btrim(x->>'name'), v_norm, v_norm, 'host',
            coalesce((x->>'waive_fee')::boolean, false),
            case when coalesce((x->>'waive_fee')::boolean, false) then auth.uid() end)
    returning id into rid;
    perform rsvp_log(p_event, rid, 'host_add', jsonb_build_object('waive_fee', coalesce((x->>'waive_fee')::boolean, false)));
    v_added := v_added + 1;
  end loop;
  return jsonb_build_object('added', v_added, 'duplicates', v_dup, 'invalid', v_bad);
end $$;

-- 초대 문자 예약. p_ids가 null이면 아직 초대 문자를 받지 않은 미응답자 전체.
create or replace function rsvp_admin_send_invites(p_event uuid, p_ids uuid[], p_resend boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations; n int := 0; v_slot text;
begin
  if not rsvp_can_manage(p_event) then raise exception 'forbidden'; end if;
  for r in select * from rsvp_registrations
           where event_id = p_event and rsvp = 'invited'
             and (p_ids is null or id = any (p_ids))
             and (p_resend or invited_at is null) loop
    v_slot := case when p_resend then 'm' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint else 'i1' end;
    perform rsvp_enqueue(p_event, r.id, 'invite', v_slot);
    n := n + 1;
  end loop;
  perform rsvp_log(p_event, null, 'invite_enqueued', jsonb_build_object('count', n, 'resend', p_resend));
  return n;
end $$;

-- 입금 처리. p_action: verify | flag | unverify
--  verify : 입금 확인 → 확정 문자 자동 발송(트리거). 금액 부족/입금자명 불일치는 p_force 없이는 확인 대상(flagged)으로만 표시.
create or replace function rsvp_admin_payment(p_reg uuid, p_action text, p_amount int default null,
    p_seen_name text default null, p_flag text default null, p_note text default null, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations; e rsvp_events; v_flag text;
  norm_seen text; norm_dep text; norm_name text;
begin
  select * into r from rsvp_registrations where id = p_reg;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(r.event_id) then raise exception 'forbidden'; end if;
  select * into e from rsvp_events where id = r.event_id for update;
  select * into r from rsvp_registrations where id = p_reg for update;

  if p_action = 'verify' then
    if not e.is_paid or r.fee_waived then return rsvp_err('not_required', '입금 확인이 필요 없는 신청입니다.'); end if;
    if r.seat <> 'held' or r.rsvp <> 'attending' then
      return rsvp_err('no_seat', '자리가 확보된 신청이 아닙니다. (대기·취소·만료 상태)');
    end if;
    if r.payment = 'verified' then
      update rsvp_registrations set payment = 'flagged', payment_flag = 'duplicate',
        payment_note = coalesce(p_note, '이미 입금 확인된 신청에 중복 입금 처리 시도') where id = r.id;
      perform rsvp_log(r.event_id, r.id, 'payment_flag', jsonb_build_object('flag', 'duplicate'));
      return rsvp_err('already_verified', '이미 입금 확인된 신청입니다. 중복 입금으로 표시했습니다.');
    end if;
    v_flag := null;
    if p_amount is not null and e.fee is not null and p_amount < e.fee then v_flag := 'short'; end if;
    if v_flag is null and p_seen_name is not null and btrim(p_seen_name) <> '' then
      norm_seen := regexp_replace(lower(p_seen_name), '\s', '', 'g');
      norm_dep  := regexp_replace(lower(coalesce(r.depositor_name, '')), '\s', '', 'g');
      norm_name := regexp_replace(lower(r.name), '\s', '', 'g');
      if norm_seen <> norm_dep and norm_seen <> norm_name then v_flag := 'name_mismatch'; end if;
    end if;
    if v_flag is not null and not p_force then
      update rsvp_registrations set payment = 'flagged', payment_flag = v_flag,
        payment_note = p_note, paid_amount = p_amount where id = r.id;
      perform rsvp_log(r.event_id, r.id, 'payment_flag', jsonb_build_object('flag', v_flag, 'amount', p_amount, 'seen_name', p_seen_name));
      return jsonb_build_object('ok', true, 'flagged', v_flag);
    end if;
    update rsvp_registrations set payment = 'verified', payment_flag = null, payment_note = p_note,
      paid_amount = coalesce(p_amount, e.fee), verified_by = auth.uid(), verified_at = now(), seat_held_until = null
    where id = r.id;
    perform rsvp_log(r.event_id, r.id, 'payment_verified',
      jsonb_build_object('amount', coalesce(p_amount, e.fee), 'seen_name', p_seen_name, 'forced', p_force, 'would_flag', v_flag));
  elsif p_action = 'flag' then
    update rsvp_registrations set payment = 'flagged', payment_flag = coalesce(p_flag, 'other'), payment_note = p_note where id = r.id;
    perform rsvp_log(r.event_id, r.id, 'payment_flag', jsonb_build_object('flag', coalesce(p_flag, 'other'), 'note', p_note));
  elsif p_action = 'unverify' then
    -- 이미 나간 확정 문자는 회수할 수 없다.
    update rsvp_registrations set payment = 'pending', payment_flag = null, verified_by = null, verified_at = null,
      paid_amount = null, claimed_at = null,
      seat_held_until = rsvp_hold_until(e, r)
    where id = r.id;
    perform rsvp_log(r.event_id, r.id, 'payment_unverified', jsonb_build_object('note', p_note));
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsvp_admin_waive_fee(p_reg uuid, p_waive boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations; e rsvp_events;
begin
  select * into r from rsvp_registrations where id = p_reg;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(r.event_id) then raise exception 'forbidden'; end if;
  select * into e from rsvp_events where id = r.event_id for update;
  select * into r from rsvp_registrations where id = p_reg for update;
  if p_waive then
    update rsvp_registrations set fee_waived = true, waived_by = auth.uid(),
      payment = case when seat = 'held' then 'not_required' else payment end, payment_flag = null, seat_held_until = null
    where id = r.id;
  else
    update rsvp_registrations set fee_waived = false, waived_by = null,
      payment = case when seat = 'held' and e.is_paid then 'pending' else payment end,
      seat_held_until = case when seat = 'held' then rsvp_hold_until(e, r) else seat_held_until end
    where id = r.id;
  end if;
  perform rsvp_log(r.event_id, r.id, case when p_waive then 'fee_waived' else 'fee_waive_cancelled' end, null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsvp_admin_cancel(p_reg uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations;
begin
  select * into r from rsvp_registrations where id = p_reg;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(r.event_id) then raise exception 'forbidden'; end if;
  perform 1 from rsvp_events where id = r.event_id for update;
  update rsvp_registrations set rsvp = 'declined', cancelled_at = now(),
    seat = case when seat in ('held', 'waitlist') then 'released' else seat end, seat_held_until = null, expired_at = null
  where id = p_reg;
  update rsvp_outbox set status = 'cancelled', skip_reason = 'registration_cancelled'
    where registration_id = p_reg and status = 'queued';
  perform rsvp_log(r.event_id, p_reg, 'host_cancel', jsonb_build_object('note', p_note));
  perform rsvp_promote(r.event_id);
  return jsonb_build_object('ok', true);
end $$;

-- 수동 발송/재발송. 발송 직전에 현재 상태를 다시 확인하므로 조건에 맞지 않으면 skipped 처리된다.
create or replace function rsvp_admin_enqueue(p_reg uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations;
begin
  select * into r from rsvp_registrations where id = p_reg;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(r.event_id) then raise exception 'forbidden'; end if;
  perform rsvp_enqueue(r.event_id, r.id, p_kind, 'm' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint);
  perform rsvp_log(r.event_id, r.id, 'sms_manual_enqueue', jsonb_build_object('kind', p_kind));
end $$;

create or replace function rsvp_admin_retry(p_outbox uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o rsvp_outbox;
begin
  select * into o from rsvp_outbox where id = p_outbox;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(o.event_id) then raise exception 'forbidden'; end if;
  if o.status not in ('failed', 'skipped') then raise exception 'not_retryable'; end if;
  update rsvp_outbox set status = 'queued', attempts = 0, scheduled_at = now(), last_error = null, skip_reason = null where id = p_outbox;
  perform rsvp_log(o.event_id, o.registration_id, 'sms_retry', jsonb_build_object('outbox', p_outbox));
end $$;

-- 발송 문구 미리보기 (p_reg가 없으면 샘플 값)
create or replace function rsvp_admin_preview_sms(p_event uuid, p_kind text, p_reg uuid default null, p_template text default null) returns text
language plpgsql stable security definer set search_path = public as $$
declare e rsvp_events; r rsvp_registrations;
begin
  if not rsvp_can_manage(p_event) then raise exception 'forbidden'; end if;
  select * into e from rsvp_events where id = p_event;
  if p_reg is not null then select * into r from rsvp_registrations where id = p_reg and event_id = p_event; end if;
  return rsvp_render(coalesce(p_template, e.sms_templates->>p_kind), e,
                     coalesce(r.name, '홍길동'), coalesce(r.token, 'SAMPLE_TOKEN'), r.seat_held_until);
end $$;

-- 해당 문구로 실제 발송될 대상 수 (활성화 전 확인용)
create or replace function rsvp_admin_reminder_targets(p_event uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int;
begin
  if not rsvp_can_manage(p_event) then raise exception 'forbidden'; end if;
  select count(*) into n from rsvp_registrations r
   where r.event_id = p_event and r.status = 'payment_pending' and r.payment = 'pending'
     and (r.seat_held_until is null or r.seat_held_until > now());
  return n;
end $$;

create or replace function rsvp_admin_set_sms_live(p_event uuid, p_live boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not rsvp_can_manage(p_event) then raise exception 'forbidden'; end if;
  update rsvp_events set sms_live = p_live where id = p_event;
  perform rsvp_log(p_event, null, case when p_live then 'sms_live_on' else 'sms_live_off' end, null);
end $$;

-- 관리자만: 이메일로 담당자 권한 부여 (대상은 한 번 로그인해 auth.users에 있어야 함)
create or replace function rsvp_admin_grant(p_email text, p_event uuid, p_role text default 'host') returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not rsvp_is_admin() then raise exception 'forbidden'; end if;
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then raise exception 'user_not_found: 먼저 해당 이메일로 /admin/ 로그인을 한 번 하도록 안내하세요'; end if;
  insert into rsvp_staff (user_id, role) values (uid, case when p_role = 'admin' then 'admin' else 'host' end)
    on conflict (user_id) do nothing;
  if p_event is not null then
    insert into rsvp_staff_events (user_id, event_id) values (uid, p_event) on conflict do nothing;
  end if;
end $$;

-- ============================================================
-- 9. 발송 파이프라인 (service_role 전용: Edge Function이 호출)
-- ============================================================
-- (1) 만료 정리 + 대기자 승급 + 미입금 안내 예약. 5분마다 호출해도 dedupe_key 덕분에 중복되지 않는다.
create or replace function rsvp_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e rsvp_events; d_off int; slot_ts timestamptz; v_label text; v_expired int := 0; v_planned int := 0; n int;
begin
  for e in select * from rsvp_events where status = 'open' for update skip locked loop
    v_expired := v_expired + rsvp_sweep_event(e.id);
    if e.reminder_enabled and e.is_paid and e.starts_at > now() then
      for d_off in select (jsonb_array_elements_text(e.reminder_offsets))::int loop
        slot_ts := ((((e.starts_at at time zone 'Asia/Seoul')::date - d_off)::timestamp
                     + make_interval(hours => e.reminder_hour)) at time zone 'Asia/Seoul');
        -- 정해진 시각이 지났고, 3시간 이내인 회차만 (서버가 오래 멈췄다 돌아와도 지난 회차를 몰아서 보내지 않음)
        if slot_ts <= now() and now() - slot_ts <= interval '3 hours' then
          v_label := 'D-' || d_off || '@' || to_char(slot_ts at time zone 'Asia/Seoul', 'YYYYMMDD');
          insert into rsvp_outbox (event_id, registration_id, kind, slot, dedupe_key)
          select e.id, r.id, 'unpaid', v_label, e.id || '|' || r.id || '|unpaid|' || v_label
          from rsvp_registrations r
          where r.event_id = e.id and r.status = 'payment_pending' and r.payment = 'pending'
            and r.applied_at < slot_ts                               -- 정해진 시각 이후에 신청했다면 그 회차는 건너뛰고 다음 회차부터
            and (r.seat_held_until is null or r.seat_held_until > now())
            and (e.payment_deadline is null or e.payment_deadline > now())
            and not exists (select 1 from rsvp_outbox o
                            where o.registration_id = r.id and o.kind in ('received', 'unpaid', 'promoted', 'waitlist')
                              and o.status in ('queued', 'sending', 'sent', 'test_logged')
                              and o.created_at > now() - make_interval(mins => e.min_sms_gap_minutes))
          on conflict (dedupe_key) do nothing;
          get diagnostics n = row_count;
          v_planned := v_planned + n;
        end if;
      end loop;
    end if;
  end loop;
  return jsonb_build_object('expired', v_expired, 'planned', v_planned);
end $$;

-- (2) 발송 대상 가져오기 (동시 실행해도 같은 행을 두 번 가져가지 않음)
create or replace function rsvp_claim_outbox(p_limit int default 50) returns setof rsvp_outbox
language sql security definer set search_path = public as $$
  update rsvp_outbox set status = 'sending', attempts = attempts + 1, claimed_at = now()
  where id in (
    select id from rsvp_outbox
    where (status = 'queued' and scheduled_at <= now())
       or (status = 'sending' and claimed_at < now() - interval '10 minutes')
    order by scheduled_at limit p_limit for update skip locked)
  returning *;
$$;

-- (3) 발송 직전 최신 상태 재확인 + 문구 생성
create or replace function rsvp_outbox_prepare(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o rsvp_outbox; r rsvp_registrations; e rsvp_events; v_ok boolean := true; v_reason text;
begin
  select * into o from rsvp_outbox where id = p_id;
  select * into r from rsvp_registrations where id = o.registration_id;
  select * into e from rsvp_events where id = o.event_id;
  if r.id is null or e.id is null then return jsonb_build_object('action', 'skip', 'reason', 'missing'); end if;
  if e.status = 'cancelled' then return jsonb_build_object('action', 'skip', 'reason', 'event_cancelled'); end if;

  v_ok := case o.kind
    when 'invite'    then r.rsvp = 'invited' and e.status = 'open'
    when 'received'  then r.status = 'payment_pending'
    when 'promoted'  then r.status = 'payment_pending'
    when 'waitlist'  then r.status = 'waitlist'
    when 'confirmed' then r.status = 'confirmed'
    when 'unpaid'    then r.status = 'payment_pending' and r.payment = 'pending' and e.starts_at > now()
                          and (r.seat_held_until is null or r.seat_held_until > now())
                          and (e.payment_deadline is null or e.payment_deadline > now())
    else false end;
  if not v_ok then v_reason := 'state_changed:' || r.status || '/' || r.payment; end if;

  if v_ok and o.kind = 'unpaid' then
    if now() - o.scheduled_at > interval '3 hours' then v_ok := false; v_reason := 'stale';
    elsif o.slot not like 'm%' and exists (
        select 1 from rsvp_outbox x where x.registration_id = r.id and x.id <> o.id
          and x.kind in ('received', 'unpaid', 'promoted', 'waitlist') and x.status in ('sent', 'test_logged')
          and x.sent_at > now() - make_interval(mins => e.min_sms_gap_minutes)) then
      v_ok := false; v_reason := 'min_gap';
    end if;
  end if;

  if not v_ok then return jsonb_build_object('action', 'skip', 'reason', v_reason); end if;
  return jsonb_build_object('action', 'send', 'live', e.sms_live, 'to', r.phone_norm,
    'body', rsvp_render(e.sms_templates->>o.kind, e, r.name, r.token, r.seat_held_until));
end $$;

-- (4) 결과 기록. p_status: sent | test_logged | skipped | failed | retry
create or replace function rsvp_outbox_finish(p_id uuid, p_status text, p_provider text default null, p_msg_id text default null,
    p_provider_status text default null, p_error text default null, p_body text default null, p_to text default null,
    p_reason text default null, p_retry_minutes int default 5) returns void
language plpgsql security definer set search_path = public as $$
declare o rsvp_outbox;
begin
  select * into o from rsvp_outbox where id = p_id;
  if p_status = 'retry' then
    update rsvp_outbox set status = 'queued', scheduled_at = now() + make_interval(mins => p_retry_minutes),
      last_error = p_error, provider = coalesce(p_provider, provider) where id = p_id;
  else
    update rsvp_outbox set status = p_status, provider = p_provider, provider_message_id = p_msg_id,
      provider_status = p_provider_status, last_error = p_error, body = p_body, to_phone = p_to, skip_reason = p_reason,
      sent_at = case when p_status in ('sent', 'test_logged') then now() end where id = p_id;
    if p_status = 'sent' and o.kind = 'invite' then
      update rsvp_registrations set invited_at = now() where id = o.registration_id;
    end if;
  end if;
end $$;

-- ============================================================
-- 10. RLS / 권한
-- ============================================================
alter table rsvp_settings       enable row level security;
alter table rsvp_staff          enable row level security;
alter table rsvp_staff_events   enable row level security;
alter table rsvp_events         enable row level security;
alter table rsvp_registrations  enable row level security;
alter table rsvp_outbox         enable row level security;
alter table rsvp_audit          enable row level security;

revoke all on rsvp_settings, rsvp_staff, rsvp_staff_events, rsvp_events, rsvp_registrations, rsvp_outbox, rsvp_audit
  from public, anon, authenticated;
revoke all on sequence rsvp_audit_id_seq from public, anon, authenticated;

grant select on rsvp_staff, rsvp_staff_events, rsvp_registrations, rsvp_outbox, rsvp_audit to authenticated;
grant select, insert, update on rsvp_events to authenticated;

drop policy if exists staff_self on rsvp_staff;
create policy staff_self on rsvp_staff for select to authenticated using (user_id = auth.uid());
drop policy if exists staff_events_self on rsvp_staff_events;
create policy staff_events_self on rsvp_staff_events for select to authenticated using (user_id = auth.uid() or rsvp_is_admin());

drop policy if exists events_read on rsvp_events;
create policy events_read on rsvp_events for select to authenticated using (rsvp_can_manage(id));
drop policy if exists events_insert on rsvp_events;
create policy events_insert on rsvp_events for insert to authenticated with check (rsvp_is_admin());
drop policy if exists events_update on rsvp_events;
create policy events_update on rsvp_events for update to authenticated using (rsvp_can_manage(id)) with check (rsvp_can_manage(id));

drop policy if exists reg_read on rsvp_registrations;
create policy reg_read on rsvp_registrations for select to authenticated using (rsvp_can_manage(event_id));
drop policy if exists outbox_read on rsvp_outbox;
create policy outbox_read on rsvp_outbox for select to authenticated using (rsvp_can_manage(event_id));
drop policy if exists audit_read on rsvp_audit;
create policy audit_read on rsvp_audit for select to authenticated using (rsvp_can_manage(event_id));

-- 함수 실행 권한: 기본 공개 권한을 모두 회수한 뒤 필요한 것만 부여
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'rsvp\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant execute on function rsvp_public_event(text), rsvp_get_registration(text, text),
                          rsvp_submit(text, text, jsonb), rsvp_claim_payment(text, text) to anon, authenticated;
grant execute on function rsvp_can_manage(uuid), rsvp_is_admin() to authenticated;
grant execute on function
  rsvp_admin_clone_event(uuid, text, text), rsvp_admin_add_registrations(uuid, jsonb),
  rsvp_admin_send_invites(uuid, uuid[], boolean),
  rsvp_admin_payment(uuid, text, int, text, text, text, boolean), rsvp_admin_waive_fee(uuid, boolean),
  rsvp_admin_cancel(uuid, text), rsvp_admin_enqueue(uuid, text), rsvp_admin_retry(uuid),
  rsvp_admin_preview_sms(uuid, text, uuid, text), rsvp_admin_reminder_targets(uuid),
  rsvp_admin_set_sms_live(uuid, boolean), rsvp_admin_grant(text, uuid, text) to authenticated;
grant execute on function rsvp_tick(), rsvp_claim_outbox(int), rsvp_outbox_prepare(uuid),
  rsvp_outbox_finish(uuid, text, text, text, text, text, text, text, text, int) to service_role;
