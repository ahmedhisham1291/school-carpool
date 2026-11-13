# Review: design-followups-01

Branch `design-followups-01`, commit `1e7e46b` on main `e945fe4`. Reviewed
`git diff main..HEAD` (11 files, +59 / -27) against the non-blocking items
in docs/reviews/integrate-design-into-main-review.md.

## Verdict: PASS

## CI

Run 43449903171 on `1e7e46b`: **success**, all three jobs. `flutter
analyze`: "No issues found!"; `flutter test`: "+168 ~116: All tests
passed!"; screenshots "+116: All tests passed!"; Functions and rules
tests: success; Web and Android compile (staging): success.

## Items from the integration review

1. **Error reason: fixed.** Sign-out and withdraw now show
   `errorOfflineShort` ("No connection. Try again." / "لا يوجد اتصال.
   حاول مرة أخرى.") when `failure.isOffline`, otherwise the short
   generic text. Both messages were added to the snackbar one-line test
   (count 9 to 11).
2. **200 percent threshold: fixed.** All three x2 button checks are back
   to 0.75 (at most 25 percent shrink), matching the design test. The
   test was made stricter, and wording was shortened to pass it. That is
   the right direction.
3. **"And..." subtitles: fixed.** "A photo of their school ID card" /
   "صورة بطاقة المدرسة", "Only if you drive, with car details" / "فقط إذا
   كنت ستقود، مع بيانات السيارة" read on their own.
4. **Double gutter: fixed.** `AppListRow(inset: false)` is an additive
   option (default `true`, so no other screen changes). Only the children
   rows inside the verification steps use it.
5. **Shutter icon: on the scale** (`AppIconSize.lg`).

Behavior is unchanged apart from item 1. No rules, Functions, router,
pubspec or security/privacy file is touched. The AR and EN ARB files have
the same keys. No test or doc still uses an old string.

## Blocking

None.

## Non-blocking

1. **EN "Accept all" on the terms screen.** The screen has an optional
   WhatsApp opt-in box. "Accept all" suggests the button also turns that
   on, but it only accepts the three required documents, and is enabled
   only after they are ticked. The behavior is correct and consent is
   still recorded correctly, but the label can mislead on a consent
   screen. It also no longer matches the Arabic "موافقة ومتابعة" (Agree and
   continue). Suggest "I agree" or "Agree and continue", if that passes
   the x2 test.
2. **Shutter icon shrank from 40 to 28.** `lg` is the right token by
   name, but the main camera button now has a smaller icon in an 88 dp
   button. Consider a dedicated step (for example `AppIconSize.shutter`
   = 40) or `xl`. Check the screenshot on an iPhone.
3. **EN/AR drift on renamed buttons.** "Get verified" vs "ابدأ التحقق"
   (Start verification) and "Verify account" vs "اذهب إلى التحقق" (Go to
   verification) are fine, but the two languages now say slightly
   different things. Align them when the Arabic is next revised.
