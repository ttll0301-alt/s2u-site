-- 0004: 자리 채우기 (온라인 산사의 연등처럼, 신청하면 자리판의 한 칸이 채워진다)
--  공개 화면에는 개수만 내보낸다. 이름·연락처는 자리판에 노출하지 않는다.
--  자리 순서는 자리를 잡은 시각 순이고, 앞사람이 취소하면 뒤 번호가 한 칸씩 당겨진다.

create or replace function rsvp_public_event(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e rsvp_events; held int; v_state text; v_conf int; v_wait int;
begin
  select * into e from rsvp_events where slug = p_slug and status <> 'draft';
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select count(*) filter (where seat = 'held'), count(*) filter (where status = 'confirmed'), count(*) filter (where status = 'waitlist')
    into held, v_conf, v_wait from rsvp_registrations where event_id = e.id;
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
    'seat_board', jsonb_build_object('capacity', e.capacity, 'filled', held, 'confirmed', v_conf, 'waitlist', v_wait),
    'payment_deadline', case when e.is_paid then e.payment_deadline end));
end $$;

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
      'hold_until', r.seat_held_until,
      -- 자리판에서 내 자리 위치 (자리를 잡은 순서, 1부터)
      'seat_no', case when r.seat = 'held' then (select count(*) from rsvp_registrations x
                   where x.event_id = r.event_id and x.seat = 'held'
                     and (x.applied_at, x.created_at) <= (r.applied_at, r.created_at)) end
    ),
    'payment_info', case when show_bank then jsonb_build_object(
      'fee', e.fee, 'bank_name', e.bank_name, 'bank_account', e.bank_account, 'account_holder', e.account_holder,
      'deadline', coalesce(r.seat_held_until, e.payment_deadline)) end
  );
end $$;
