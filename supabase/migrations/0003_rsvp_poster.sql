-- 0003: 행사 포스터 (RSVP 대표 이미지 · 인스타 피드/스토리)
--  운영 화면의 '포스터' 탭에서 행사 정보로 포스터를 그리고, 설정은 rsvp_events.poster에 저장한다.
--  'RSVP 대표 이미지로 적용'을 누르면 이미지를 Storage(rsvp-posters, 공개 읽기)에 올리고 hero_image에 연결한다.

alter table rsvp_events add column if not exists poster jsonb not null default '{}'::jsonb;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rsvp-posters', 'rsvp-posters', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- 업로드 경로는 <행사 id>/파일명. 담당 행사 폴더에만 올리고 지울 수 있다.
drop policy if exists rsvp_posters_insert on storage.objects;
create policy rsvp_posters_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'rsvp-posters' and rsvp_can_manage(((storage.foldername(name))[1])::uuid));
drop policy if exists rsvp_posters_update on storage.objects;
create policy rsvp_posters_update on storage.objects for update to authenticated
  using (bucket_id = 'rsvp-posters' and rsvp_can_manage(((storage.foldername(name))[1])::uuid));
drop policy if exists rsvp_posters_delete on storage.objects;
create policy rsvp_posters_delete on storage.objects for delete to authenticated
  using (bucket_id = 'rsvp-posters' and rsvp_can_manage(((storage.foldername(name))[1])::uuid));

-- 행사 복제 시 포스터 설정도 복사
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
    reminder_enabled, reminder_offsets, reminder_hour, min_sms_gap_minutes, sms_live, signup_rate_per_min, poster)
  select p_slug, 'draft', p_title, hero_image, intro, hosts, partners, starts_at, ends_at, venue, map_url, sessions,
    capacity, apply_deadline, allow_open_signup, is_paid, fee, bank_name, bank_account, account_holder, payment_deadline, hold_hours,
    on_deadline, prep, guide, refund_policy, contact, extra_questions, consent_defs, sms_templates,
    false, reminder_offsets, reminder_hour, min_sms_gap_minutes, false, signup_rate_per_min, poster   -- 자동 발송·실발송은 복제본에서 꺼 둔다
  from rsvp_events where id = p_id
  returning id into new_id;
  perform rsvp_log(new_id, null, 'event_clone', jsonb_build_object('from', p_id));
  return new_id;
end $$;
