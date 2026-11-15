-- PAULUS LEARNING HUB: additive database migration
-- Back up your Supabase project before running. This migration keeps the existing
-- profiles, competitions, questions and quiz-attempt data.
begin;

alter table public.profiles add column if not exists department text;
alter table public.profiles add column if not exists class_level text;
-- The old Arena registration used index_number; it is no longer required.
alter table public.profiles alter column index_number drop not null;

-- Copy the new registration metadata into the existing profile row.
create or replace function public.paulus_sync_profile_metadata()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
     set full_name = coalesce(nullif(new.raw_user_meta_data->>'full_name',''), full_name),
         department = coalesce(nullif(new.raw_user_meta_data->>'department',''), department),
         class_level = coalesce(nullif(new.raw_user_meta_data->>'class_level',''), class_level)
   where id = new.id;
  return new;
end;
$$;

drop trigger if exists zz_paulus_sync_profile_metadata on auth.users;
create trigger zz_paulus_sync_profile_metadata
after insert or update of raw_user_meta_data on auth.users
for each row execute function public.paulus_sync_profile_metadata();

-- Admin-only student directory RPC. Email addresses are not exposed to students.
create or replace function public.paulus_admin_student_directory()
returns table(id uuid, full_name text, email text, department text, class_level text)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  ) then
    raise exception 'Administrator access required';
  end if;
  return query
    select p.id, p.full_name, u.email::text, p.department, p.class_level
    from public.profiles p
    join auth.users u on u.id = p.id
    where coalesce(p.role,'student') <> 'admin'
    order by p.full_name;
end;
$$;
grant execute on function public.paulus_admin_student_directory() to authenticated;

create table if not exists public.learning_materials (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  department text not null,
  class_level text not null,
  file_path text not null,
  file_url text not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.learning_materials enable row level security;

drop policy if exists "Paulus students read their materials" on public.learning_materials;
create policy "Paulus students read their materials" on public.learning_materials
for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and
    (p.role='admin' or (p.department=learning_materials.department and p.class_level=learning_materials.class_level)))
);
drop policy if exists "Paulus admins manage materials" on public.learning_materials;
create policy "Paulus admins manage materials" on public.learning_materials
for all to authenticated using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
) with check (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
);

create table if not exists public.paulus_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  department text,
  class_level text,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.paulus_announcements enable row level security;

drop policy if exists "Paulus students read relevant announcements" on public.paulus_announcements;
create policy "Paulus students read relevant announcements" on public.paulus_announcements
for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
  or exists(select 1 from public.profiles p where p.id=auth.uid()
    and (paulus_announcements.department is null or p.department=paulus_announcements.department)
    and (paulus_announcements.class_level is null or p.class_level=paulus_announcements.class_level))
);
drop policy if exists "Paulus admins publish announcements" on public.paulus_announcements;
create policy "Paulus admins publish announcements" on public.paulus_announcements
for insert to authenticated with check (
  exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
);

-- Public file URLs are convenient for student downloads. Only admins may upload,
-- update or delete objects in this dedicated bucket.
insert into storage.buckets (id, name, public)
values ('paulus-materials', 'paulus-materials', true)
on conflict (id) do update set public = true;

drop policy if exists "Paulus admins upload materials" on storage.objects;
create policy "Paulus admins upload materials" on storage.objects
for insert to authenticated with check (
  bucket_id='paulus-materials' and exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
  )
);
drop policy if exists "Paulus admins update materials" on storage.objects;
create policy "Paulus admins update materials" on storage.objects
for update to authenticated using (
  bucket_id='paulus-materials' and exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
  )
) with check (
  bucket_id='paulus-materials' and exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
  )
);
drop policy if exists "Paulus admins delete materials" on storage.objects;
create policy "Paulus admins delete materials" on storage.objects
for delete to authenticated using (
  bucket_id='paulus-materials' and exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
  )
);
commit;

-- IMPORTANT:
-- 1. The existing project must already have public.profiles with id, full_name,
--    role and index_number columns, and the existing quiz tables/RPCs.
-- 2. Ensure your existing admin account has profiles.role = 'admin'.
-- 3. Enable Realtime for public.profiles in Supabase Database > Publications
--    (the frontend refreshes the directory when profile changes are broadcast).
