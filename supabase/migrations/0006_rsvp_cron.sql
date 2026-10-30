-- 0006: 문자 발송 5분 주기 실행 (pg_cron → pg_net → Edge Function sms-dispatch)
--  호출 비밀값은 DB에서 무작위로 만들어 rsvp_settings(cron_secret)에 둔다. anon·로그인 사용자는 이 표를 읽을 수 없다.
--  함수는 Secrets에 CRON_SECRET이 있으면 그것을, 없으면 이 값을 사용한다. (저장소에는 값이 들어가지 않음)
--  다른 프로젝트에 설치할 때는 dispatch_url의 <ref>를 바꿔서 실행.
create extension if not exists pg_cron;
create extension if not exists pg_net;

insert into rsvp_settings (key, value)
values ('cron_secret', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;
insert into rsvp_settings (key, value)
values ('dispatch_url', 'https://hyqclpriumasfqtoivdx.supabase.co/functions/v1/sms-dispatch')
on conflict (key) do nothing;

create or replace function rsvp_cron_dispatch() returns bigint
language sql security definer set search_path = public as $$
  select net.http_post(
    url := (select value from rsvp_settings where key = 'dispatch_url'),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select value from rsvp_settings where key = 'cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
$$;
revoke execute on function rsvp_cron_dispatch() from public, anon, authenticated;

select cron.unschedule('rsvp-dispatch') where exists (select 1 from cron.job where jobname = 'rsvp-dispatch');
select cron.schedule('rsvp-dispatch', '*/5 * * * *', 'select public.rsvp_cron_dispatch()');
