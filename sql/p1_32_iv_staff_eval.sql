-- p1_32 · บอสสั่ง 25 พ.ย. 2569 12:00 — เปิด Interview Record ให้พนักงาน: ทดลองงาน 119 วัน (ก่อนประเมินรอบ 45/80 วัน) และประเมินประจำปี
-- ใช้ได้ทั้ง 2 แบบ: การ์ดคำถาม (สุ่มจากคลังตามตำแหน่ง ให้คะแนน 0–5 + AI ร่าง) และ บันทึกพูดคุยผลงาน (talk)
-- ผลที่รับรองแล้วแนบกับ FM-HR-01-05 (data.session_id) · คำตอบของพนักงานไม่ลบตามนโยบายผู้สมัคร (PDPA purge ใช้กับผู้สมัครเท่านั้น)

alter table public.interview_sessions
  add column if not exists purpose text not null default 'hire',
  add column if not exists staff_id uuid references public.staff(id),
  add column if not exists cycle text,
  add column if not exists talk jsonb not null default '{}'::jsonb;
alter table public.interview_sessions alter column application_id drop not null;
alter table public.interview_sessions add constraint interview_sessions_purpose_chk check (purpose in ('hire','probation','annual'));
alter table public.interview_sessions add constraint interview_sessions_subject_chk check (
  (purpose = 'hire' and application_id is not null) or (purpose <> 'hire' and staff_id is not null and application_id is null));
create unique index if not exists interview_sessions_staff_round on public.interview_sessions(staff_id, purpose, coalesce(cycle,''), round) where staff_id is not null;
create index if not exists interview_sessions_staff on public.interview_sessions(staff_id);

-- เปิด Interview Record ของพนักงาน (ทดลองงาน: cycle 'probation' · ประจำปี: ปี พ.ศ.)
create or replace function public.iv_open_staff(p_staff uuid, p_purpose text, p_cycle text default null, p_new_round boolean default false)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $$
declare st public.staff; s public.interview_sessions; pc text; fy int; r int; cy text;
begin
  select * into st from public.staff where id = p_staff;
  if st.id is null then raise exception 'ไม่พบพนักงาน'; end if;
  perform private.iv_need_write(st.company_id);
  if p_purpose not in ('probation','annual') then raise exception 'ประเภทต้องเป็น ทดลองงาน หรือ ประจำปี'; end if;
  if st.status not in ('active','intern') then raise exception 'พนักงาน % ไม่อยู่ในสถานะปฏิบัติงาน', st.employee_code; end if;
  cy := case when p_purpose = 'probation' then 'probation'
             else coalesce(nullif(trim(p_cycle),''), ((extract(year from current_date)::int + 543))::text) end;
  if p_purpose = 'annual' and cy !~ '^25[0-9]{2}$' then raise exception 'รอบประเมินประจำปีต้องเป็นปี พ.ศ. 4 หลัก'; end if;
  select * into s from public.interview_sessions where staff_id = st.id and purpose = p_purpose and coalesce(cycle,'') = cy order by round desc limit 1;
  if s.id is not null and not p_new_round then return s; end if;
  r := coalesce(s.round, 0) + 1;
  pc := st.position_code;
  if pc is null or not exists (select 1 from public.hr_positions where code = pc) then
    select p.code into pc from public.hr_positions p where p.company_id = st.company_id and (p.title = trim(st.position) or p.staff_title = trim(st.position)) limit 1;
  end if;
  fy := (extract(year from current_date)::int + 543) % 100;
  insert into public.interview_sessions(company_id, no, purpose, staff_id, cycle, position_code, round, created_by)
  values (st.company_id, format('IR-%s-%s', lpad(fy::text,2,'0'), lpad(private.next_seq(st.company_id, 'HR-IR' || fy)::text, 4, '0')), p_purpose, st.id, cy, pc, r, auth.uid())
  returning * into s;
  return s;
end $$;

-- บันทึกพูดคุยผลงาน (เฉพาะพนักงาน · ก่อนรับรองผล)
create or replace function public.iv_talk_save(p_session uuid, p_talk jsonb)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $$
declare s public.interview_sessions; t jsonb := '{}'::jsonb; k text;
begin
  s := private.iv_sess(p_session); perform private.iv_need_write(s.company_id);
  if s.purpose = 'hire' then raise exception 'บันทึกพูดคุยผลงานใช้กับพนักงานเท่านั้น'; end if;
  if s.certified_at is not null then raise exception 'รับรองผลแล้ว — เปิดแก้ไขก่อน'; end if;
  foreach k in array array['talk_at','talk_with','strengths','improve','goals','support','employee_view','actions'] loop
    if nullif(trim(p_talk->>k),'') is not null then t := t || jsonb_build_object(k, left(trim(p_talk->>k), 2000)); end if;
  end loop;
  update public.interview_sessions set talk = t || jsonb_build_object('saved_by', auth.uid(), 'saved_at', now())
   where id = s.id returning * into s;
  return s;
end $$;

-- รับรองผล: ผู้สมัครต้องมีชุดคำถามที่ตรวจครบ · พนักงานใช้การ์ดคำถาม (ที่ส่งแล้ว) และ/หรือ บันทึกพูดคุยผลงาน
create or replace function public.iv_certify(p_session uuid, p_recommendation text, p_note text default null)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $function$
declare s public.interview_sessions; st public.interview_question_sets; tot int := 0; rv int := 0; ass int := 0; wsum numeric; w numeric; has_talk boolean;
begin
  s := private.iv_sess(p_session);
  if not private.can_iv_review(s.company_id) then raise exception 'ไม่มีสิทธิ์รับรองผล' using errcode = '42501'; end if;
  if p_recommendation not in ('pass','fail','more_info','pending') then raise exception 'ข้อเสนอไม่ถูกต้อง'; end if;
  st := private.iv_cur_set(s.id);
  has_talk := s.purpose <> 'hire' and exists (select 1 from jsonb_each_text(s.talk) e where e.key in ('strengths','improve','goals','support','employee_view','actions') and trim(e.value) <> '');
  if s.purpose = 'hire' or st.locked_at is not null then
    if s.status not in ('answers_received','ai_evaluated','questions_sent') then raise exception 'สถานะ % รับรองผลไม่ได้', s.status; end if;
    with it as (select x->>'question_id' qid, (x->>'weight')::numeric wt from jsonb_array_elements(st.items) x),
         lr as (select distinct on (question_id) * from public.interview_reviews where set_id = st.id order by question_id, reviewed_at desc)
    select count(*), count(lr.id), count(lr.final_score), sum(lr.final_score * it.wt) filter (where lr.final_score is not null), sum(it.wt) filter (where lr.final_score is not null)
      into tot, rv, ass, wsum, w from it left join lr on lr.question_id = it.qid;
    if rv < tot then raise exception 'ยังตรวจคะแนนไม่ครบ (% จาก % ข้อ) — HR ต้องยืนยันคะแนนทุกข้อ', rv, tot; end if;
  else
    if s.status not in ('draft','scheduled') then raise exception 'สถานะ % รับรองผลไม่ได้', s.status; end if;
    if not has_talk then raise exception 'ยังไม่มีการ์ดคำถามที่ส่งแล้ว และยังไม่ได้บันทึกพูดคุยผลงาน — ทำอย่างน้อยหนึ่งอย่างก่อนรับรอง'; end if;
  end if;
  update public.interview_sessions set status = 'hr_reviewed', recommendation = p_recommendation,
    weighted_total = case when w > 0 then round(wsum / w, 2) end, coverage = case when tot > 0 then round(ass::numeric / tot, 2) end,
    assessed = case when tot > 0 then ass end, total_items = case when tot > 0 then tot end,
    certified_by = auth.uid(), certified_at = now(), interviewer_note = coalesce(nullif(trim(p_note),''), interviewer_note)
  where id = s.id returning * into s;
  return s;
end $function$;

-- เปิดแก้ไข: กลับไปสถานะก่อนรับรอง (พนักงานที่ไม่มีชุดคำถาม → ร่าง)
create or replace function public.iv_reopen(p_session uuid, p_reason text)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $function$
declare s public.interview_sessions; st public.interview_question_sets;
begin
  s := private.iv_sess(p_session); perform private.iv_need_write(s.company_id);
  if s.status not in ('hr_reviewed','more_info_requested') then raise exception 'เปิดแก้ไขได้เฉพาะสถานะรับรองแล้ว (ยังไม่ส่งพิจารณา) หรือขอข้อมูลเพิ่ม'; end if;
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'ใส่เหตุผล'; end if;
  st := private.iv_cur_set(s.id);
  update public.interview_sessions set status = case when s.purpose <> 'hire' and st.locked_at is null then 'draft' else 'answers_received' end,
    certified_by = null, certified_at = null, interviewer_note = concat_ws(E'\n', interviewer_note, 'เปิดแก้ไข: ' || trim(p_reason))
  where id = s.id returning * into s;
  return s;
end $function$;

-- เอกสารพิจารณาที่แนบ Interview Record: FM-HR-01-03 (ผู้สมัคร) · FM-HR-01-05 (ทดลองงาน)
create or replace function private.iv_form_gate() returns trigger language plpgsql security definer set search_path = '' as $function$
declare sid uuid := private.try_uuid(new.data->>'session_id'); s public.interview_sessions;
begin
  if new.form not in ('FM-HR-01-03','FM-HR-01-05') or sid is null then return new; end if;
  select * into s from public.interview_sessions where id = sid;
  if s.id is null then raise exception 'ไม่พบ Interview Record ที่อ้างอิง'; end if;
  if new.form = 'FM-HR-01-03' then
    if s.purpose <> 'hire' then raise exception 'Interview Record % ไม่ใช่ของผู้สมัคร', s.no; end if;
    if new.status = 'submitted' and private.try_uuid(new.data->>'application_id') is distinct from s.application_id then raise exception 'ใบสัมภาษณ์อ้างใบสมัครคนละใบกับ Interview Record %', s.no; end if;
  else
    if s.purpose <> 'probation' then raise exception 'Interview Record % ไม่ใช่ของการทดลองงาน', s.no; end if;
    if new.staff_id is distinct from s.staff_id then raise exception 'Interview Record % เป็นของพนักงานคนอื่น', s.no; end if;
  end if;
  if new.status = 'submitted' and s.certified_at is null then raise exception 'Interview Record % ยังไม่ได้รับรองผลโดย HR — รับรองก่อนส่งพิจารณา', s.no; end if;
  return new;
end $function$;

create or replace function private.iv_from_form() returns trigger language plpgsql security definer set search_path = '' as $function$
declare sid uuid := private.try_uuid(new.data->>'session_id'); st text;
begin
  if new.form not in ('FM-HR-01-03','FM-HR-01-05') or sid is null then return new; end if;
  st := case
    when new.status in ('submitted','reviewed') then 'pending_approval'
    when new.status = 'approved' and new.result = 'fail' then 'rejected'
    when new.status = 'approved' and (new.result in ('pass','retry') or new.form = 'FM-HR-01-05') then 'approved'
    when new.status = 'approved' then 'pending_approval'
    when new.status in ('returned','rejected') then 'more_info_requested'
    else null end;
  update public.interview_sessions set iv_form_id = new.id, status = coalesce(st, status)
   where id = sid and status not in ('applicant_notified','archived')
     and (st is not null or iv_form_id is null);
  return new;
end $function$;

-- แจ้งผล/เก็บแฟ้ม: ลบคำตอบเฉพาะผู้สมัครที่ไม่ได้รับเลือก (พนักงานเก็บไว้เป็นประวัติการประเมิน)
create or replace function public.iv_notified(p_session uuid, p_template text)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $$
declare s public.interview_sessions; was text;
begin
  s := private.iv_sess(p_session); perform private.iv_need_write(s.company_id);
  if s.status not in ('approved','rejected') then raise exception 'แจ้งผลได้หลังผู้มีอำนาจพิจารณาแล้วเท่านั้น'; end if;
  was := s.status;
  insert into public.hr_notification_events(company_id, session_id, case_id, template) values (s.company_id, s.id, s.case_id, coalesce(p_template,'RESULT'));
  update public.interview_sessions set status = 'applicant_notified', notified_by = auth.uid(), notified_at = now() where id = s.id returning * into s;
  if was = 'rejected' and s.purpose = 'hire' then perform private.iv_purge(s.id); select * into s from public.interview_sessions where id = s.id; end if;
  return s;
end $$;

create or replace function public.iv_archive(p_session uuid)
returns public.interview_sessions language plpgsql security definer set search_path = '' as $$
declare s public.interview_sessions;
begin
  s := private.iv_sess(p_session); perform private.iv_need_write(s.company_id);
  if s.status not in ('applicant_notified','rejected','approved') then raise exception 'เก็บเข้าแฟ้มได้หลังพิจารณา/แจ้งผลแล้ว'; end if;
  update public.interview_sessions set status = 'archived' where id = s.id returning * into s;
  if s.purpose = 'hire' and not private.iv_is_selected(s.application_id) then perform private.iv_purge(s.id); select * into s from public.interview_sessions where id = s.id; end if;
  return s;
end $$;

revoke all on function public.iv_open_staff(uuid, text, text, boolean) from public, anon;
revoke all on function public.iv_talk_save(uuid, jsonb) from public, anon;
grant execute on function public.iv_open_staff(uuid, text, text, boolean) to authenticated;
grant execute on function public.iv_talk_save(uuid, jsonb) to authenticated;
