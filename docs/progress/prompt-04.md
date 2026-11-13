# Prompt 4: Admin web panel (F14) — progress note

Branch: `prompt-04-admin-panel` (from `prompt-03-identity-verification`
at 57f5147). Date: 13 Nov 2026. The coordinator gave "go" on the owner's
behalf.

**Status: in progress.** This note is updated as work lands.

## Plan

1. Functions: admin access guard (claims + TOTP second factor + 8 h
   session), blocking function lets allow-listed admin accounts (admin
   claim, no phone number) sign in with email and password, everyone else
   is still refused. Admin sign-ins written to the audit log.
2. Functions: callables for admins (create, list, disable; super admin
   only), users (search, detail, suspend / unsuspend / ban), schools and
   areas (save, approve or merge "Other" schools), reports (list), audit
   log (list). Verification decisions record the parent and child name
   check (spec section 3).
3. Rules: audit log readable by admins with two-step sign-in, never
   writable; new collections closed; emulator tests.
4. Flutter web admin panel: entrypoints `lib/admin/main_admin_<flavor>.dart`,
   own router and shell, same design system, AR + EN, RTL.
5. Hosting target `admin`, CI build, SETUP, COSTS, tests, screenshots.
