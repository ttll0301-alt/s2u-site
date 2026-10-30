-- 0005: 보안 점검(Supabase advisor) 반영 — 남은 함수들의 search_path 고정
alter function rsvp_render(text, rsvp_events, text, text, timestamptz) set search_path = public;
alter function rsvp_err(text, text) set search_path = public;
alter function rsvp_calc_status(rsvp_registrations, rsvp_events) set search_path = public;
alter function rsvp_fmt_kst(timestamptz) set search_path = public;
alter function rsvp_has_room(rsvp_events, rsvp_registrations) set search_path = public;
alter function rsvp_hold_until(rsvp_events, rsvp_registrations) set search_path = public;
alter function rsvp_new_token() set search_path = public;
alter function rsvp_norm_phone(text) set search_path = public;
alter function rsvp_default_consents() set search_path = public;
alter function rsvp_default_templates() set search_path = public;
