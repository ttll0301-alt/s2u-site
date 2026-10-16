-- 0002: 0001 이후 보완
--  1) 테스트 모드에서 기록만 된 초대 문자가 중복 방지 키를 차지해, 실발송을 켠 뒤 초대가 나가지 않던 문제 수정
--  2) 입금 기한 경과 건을 운영자가 직접 만료 처리 (마감 정책 'manual' 및 입금 확인 요청·확인 필요 건)
--  3) 결제(PG)·가상계좌 연동용 입금 기록 함수 (웹훅이 service_role로 호출)
--  4) 공통 링크 신청 속도 제한 (행사별 설정, 기본 1분 20건, 0 = 제한 없음)

-- ------------------------------------------------------------
-- 1) 초대 문자가 테스트 기록으로 끝나면 키를 풀어, 실발송을 켠 뒤 다시 보낼 수 있게 한다.
--    (확정·접수 안내는 상태가 바뀌는 순간에만 생기므로 그대로 둔다. 미입금 안내는 5분마다 다시 계획되므로 풀지 않는다.)
-- ------------------------------------------------------------
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
      sent_at = case when p_status in ('sent', 'test_logged') then now() end,
      dedupe_key = case when p_status = 'test_logged' and o.kind = 'invite' then o.dedupe_key || '|test|' || o.id else o.dedupe_key end
    where id = p_id;
    if p_status = 'sent' and o.kind = 'invite' then
      update rsvp_registrations set invited_at = now() where id = o.registration_id;
    end if;
  end if;
end $$;

-- ------------------------------------------------------------
-- 2) 운영자 만료 처리
-- ------------------------------------------------------------
create or replace function rsvp_admin_expire(p_reg uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations;
begin
  select * into r from rsvp_registrations where id = p_reg;
  if not found then raise exception 'not_found'; end if;
  if not rsvp_can_manage(r.event_id) then raise exception 'forbidden'; end if;
  perform 1 from rsvp_events where id = r.event_id for update;
  select * into r from rsvp_registrations where id = p_reg for update;
  if r.status <> 'payment_pending' then return rsvp_err('bad_state', '입금 대기 상태만 만료 처리할 수 있습니다.'); end if;
  update rsvp_registrations set seat = 'released', expired_at = now(), seat_held_until = null where id = p_reg;
  update rsvp_outbox set status = 'cancelled', skip_reason = 'expired'
    where registration_id = p_reg and status = 'queued';
  perform rsvp_log(r.event_id, p_reg, 'host_expire', jsonb_build_object('note', p_note, 'payment', r.payment));
  perform rsvp_promote(r.event_id);
  return jsonb_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- 3) 결제·입금 연동 결과 기록 (아직 연동 업체 없음. 웹훅 Edge Function에서 서명 검증 후 호출하도록 준비만 해 둠)
--    같은 거래 번호는 한 번만 반영되고, 금액 부족·이름 불일치·중복은 확정하지 않고 '확인 필요'로 표시한다.
-- ------------------------------------------------------------
alter table rsvp_registrations add column if not exists payment_method text;   -- null = 운영자 수동 확인
alter table rsvp_registrations add column if not exists payment_ref text;

create table if not exists rsvp_payment_events (
  id bigserial primary key,
  provider text not null,
  ref text not null,                 -- 업체 거래 번호
  registration_id uuid references rsvp_registrations(id) on delete set null,
  amount int,
  payer_name text,
  result text not null,              -- verified | flagged:<사유> | ignored:<사유>
  raw jsonb,
  at timestamptz not null default now(),
  unique (provider, ref)
);
alter table rsvp_payment_events enable row level security;
revoke all on rsvp_payment_events from public, anon, authenticated;
revoke all on sequence rsvp_payment_events_id_seq from public, anon, authenticated;

create or replace function rsvp_system_record_payment(p_reg uuid, p_amount int, p_provider text, p_ref text,
    p_payer_name text default null, p_raw jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rsvp_registrations; e rsvp_events; v_result text; v_flag text;
begin
  if exists (select 1 from rsvp_payment_events where provider = p_provider and ref = p_ref) then
    return jsonb_build_object('ok', true, 'result', 'already_processed');
  end if;
  select * into r from rsvp_registrations where id = p_reg;
  if not found then
    insert into rsvp_payment_events (provider, ref, amount, payer_name, result, raw)
      values (p_provider, p_ref, p_amount, p_payer_name, 'ignored:no_registration', p_raw);
    return jsonb_build_object('ok', false, 'result', 'no_registration');
  end if;
  select * into e from rsvp_events where id = r.event_id for update;
  select * into r from rsvp_registrations where id = p_reg for update;

  if r.payment = 'verified' then v_flag := 'duplicate';
  elsif r.status <> 'payment_pending' then v_result := 'ignored:' || r.status;
  elsif e.fee is not null and coalesce(p_amount, 0) < e.fee then v_flag := 'short';
  elsif p_payer_name is not null
        and regexp_replace(lower(p_payer_name), '\s', '', 'g') not in
            (regexp_replace(lower(coalesce(r.depositor_name, '')), '\s', '', 'g'), regexp_replace(lower(r.name), '\s', '', 'g')) then
    v_flag := 'name_mismatch';
  end if;

  if v_result is null and v_flag is not null then
    update rsvp_registrations set payment = 'flagged', payment_flag = v_flag, paid_amount = p_amount,
      payment_method = p_provider, payment_ref = p_ref,
      payment_note = '자동 입금 내역: ' || coalesce(p_payer_name, '') || ' ' || coalesce(p_amount::text, '') || '원'
    where id = r.id;
    v_result := 'flagged:' || v_flag;
  elsif v_result is null then
    update rsvp_registrations set payment = 'verified', payment_flag = null, paid_amount = p_amount,
      payment_method = p_provider, payment_ref = p_ref, verified_by = null, verified_at = now(), seat_held_until = null
    where id = r.id;
    v_result := 'verified';
  end if;

  insert into rsvp_payment_events (provider, ref, registration_id, amount, payer_name, result, raw)
    values (p_provider, p_ref, r.id, p_amount, p_payer_name, v_result, p_raw);
  insert into rsvp_audit (event_id, registration_id, actor, action, detail)
    values (r.event_id, r.id, null, 'payment_auto',
            jsonb_build_object('provider', p_provider, 'ref', p_ref, 'amount', p_amount, 'payer', p_payer_name, 'result', v_result));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;

-- ------------------------------------------------------------
-- 4) 공통 링크 신청 속도 제한 (봇 대량 신청 완화. 캡차를 대신하지는 않음)
-- ------------------------------------------------------------
alter table rsvp_events add column if not exists signup_rate_per_min int not null default 20
  check (signup_rate_per_min >= 0);

create or replace function rsvp_reg_throttle() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_limit int;
begin
  select signup_rate_per_min into v_limit from rsvp_events where id = new.event_id;
  if new.source = 'link' and v_limit > 0 and (select count(*) from rsvp_registrations
       where event_id = new.event_id and source = 'link' and created_at > now() - interval '1 minute') >= v_limit then
    raise exception 'rate_limited' using hint = '잠시 후 다시 시도해 주세요.';
  end if;
  return new;
end $$;
drop trigger if exists rsvp_reg_throttle_t on rsvp_registrations;
create trigger rsvp_reg_throttle_t before insert on rsvp_registrations
  for each row execute function rsvp_reg_throttle();

-- 행사 복제 시 행사별 속도 제한도 복사
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
    reminder_enabled, reminder_offsets, reminder_hour, min_sms_gap_minutes, sms_live, signup_rate_per_min)
  select p_slug, 'draft', p_title, hero_image, intro, hosts, partners, starts_at, ends_at, venue, map_url, sessions,
    capacity, apply_deadline, allow_open_signup, is_paid, fee, bank_name, bank_account, account_holder, payment_deadline, hold_hours,
    on_deadline, prep, guide, refund_policy, contact, extra_questions, consent_defs, sms_templates,
    false, reminder_offsets, reminder_hour, min_sms_gap_minutes, false, signup_rate_per_min   -- 자동 발송·실발송은 복제본에서 꺼 둔다
  from rsvp_events where id = p_id
  returning id into new_id;
  perform rsvp_log(new_id, null, 'event_clone', jsonb_build_object('from', p_id));
  return new_id;
end $$;

-- ------------------------------------------------------------
-- 권한
-- ------------------------------------------------------------
revoke execute on function rsvp_outbox_finish(uuid, text, text, text, text, text, text, text, text, int) from public, anon, authenticated;
revoke execute on function rsvp_admin_expire(uuid, text) from public, anon;
revoke execute on function rsvp_system_record_payment(uuid, int, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function rsvp_reg_throttle() from public, anon, authenticated;
grant execute on function rsvp_outbox_finish(uuid, text, text, text, text, text, text, text, text, int) to service_role;
grant execute on function rsvp_admin_expire(uuid, text) to authenticated;
grant execute on function rsvp_system_record_payment(uuid, int, text, text, text, jsonb) to service_role;
