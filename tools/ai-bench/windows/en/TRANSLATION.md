# English edition of the XOI kit's Windows files — translation brief

(Maintenance: the Vietnamese files in `tools/ai-bench/windows` are the originals. A change to one of them is mirrored
in its English twin here, line for line, under the rules below; `dist/make-xoi-kit.sh --en` packs this folder as
`xoi-kit-en.zip`. The structure check: strip `rem` and `echo` lines from both and the remaining command lines must
match one for one, differing only in renamed settings, renamed files and message strings.)

Source files: `tools/ai-bench/windows/*.bat`, `xuat-ban.ps1`, `xuat-ban-README.txt` (Vietnamese, written in
ASCII without diacritics, e.g. "khong co" = "không có"). Target: the same tools in English, in this folder
(`tools/ai-bench/windows/en/`), for an international edition of the kit (`xoi-kit-en.zip`).

## What changes

1. **Comments** (`rem ...` lines, and `#` comments in .ps1): translated into clear English. Keep the meaning and
   detail; do not drop a comment.
2. **Every user-visible text**: `echo` lines, messages inside `set "X=..."` strings that are printed, `pause`
   prompts, PowerShell `Write-Host`/`throw`/`Write-Error` messages, text written into result files
   (headers such as "Ket qua sau vong ..."), the README. Natural English, concise; keep the information.
3. **File names** (the kit's own files and the files they create), per this glossary — use it exactly, the names
   are shared between files:

   | Vietnamese | English |
   |---|---|
   | choi.bat | play.bat |
   | xoi-hoc.bat | train.bat |
   | dau-nhieu.bat | measure.bat |
   | spsa.bat | spsa.bat (same) |
   | hoc-sau.bat | brain.bat |
   | can-bang.bat | balance.bat |
   | can-bang-cai-dat.bat (settings file) | balance-settings.bat |
   | can-bang-<mod>\ (folder), vong-N\, gop\, truoc\, danh-sach\, bao-cao.html, du-lieu.js, nhan-vat.txt, cai-dat-do.txt, nhat-ky.txt, tong.txt, phan.txt | balance-<mod>\, round-N\, merge\, before\, list\, report.html, data.js, fighters.txt, settings-used.txt, log.txt, totals.txt, part.txt |
   | hoc-sau-cai-dat.bat / spsa-cai-dat.bat (settings files) | brain-settings.bat / spsa-settings.bat |
   | hoc-sau\ (folder), luot-N\, du-lieu\, hocN\, nao-N.txt, xong-luot.txt, gop.txt, du-lieu.zip, du-lieu.txt | brain\, round-N\, data\, trainN\, brain-N.txt, round-done.txt, gathered.txt, data.zip, count.txt |
   | hoc-sau-truoc\ (an earlier run's folder, renamed by spsa.bat), tu-spsa.txt, spsa\da-goi.txt | brain-previous\, from-spsa.txt, spsa\packed.txt |
   | hoc<p>-<c>\, nao-<p>-<c>.txt, nhin-xa.txt, kiem-tra\chon-<p>.txt | train<p>-<c>\, brain-<p>-<c>.txt, look-ahead.txt, check\choice-<p>.txt |
   | ban-ghi.txt (the folder's kind of data, package 82), nao-dau-<p>.txt (the brain there was before the run), chon-<p>.txt's `cu` (that brain kept) | records.txt, start-brain-<p>.txt, choice-<p>.txt's `old` |
   | xem.bat | watch.bat |
   | xuat-ban.bat | publish.bat |
   | xuat-ban.ps1 | publish.ps1 |
   | xuat-ban-README.txt | publish-README.txt |
   | kiem-tra.bat | check.bat |
   | kiem-tra.txt (its report) | check.txt |
   | scripts-choi (folder) | scripts-play |
   | `<mod>-xoi-truoc.zip` | `<mod>-xoi-previous.zip` |
   | ket-qua.txt / ket-qua-<seed>\ | results.txt / results-<seed>\ |
   | danh-sach.txt | fighters.txt |
   | `<mod>-xoi.zip`, `xoi-<mod>\notes.txt`, `xoi\notes.txt`, `xoi\tune.txt`, `xoi\brain.txt`, XOI.txt, openlf2.txt, out.txt, config.lua, version.txt | unchanged |

   Other intermediate files that only one .bat uses (bat-dau.lua, k-sau.txt, xong.txt, thoi-gian.txt, tong.txt,
   ban-mod.txt, cap.txt, da-goi.txt, tom-tat.txt, khong-cua-so.txt, tune-truoc.txt, start-sau.lua, xem.txt …):
   give each a short English name (start.lua, after.txt, done.txt, timing.txt, totals.txt, mod.txt, pairs.txt,
   packed.txt, summary.txt, no-window.txt, tune-previous.txt, start-after.lua, watch.txt …) and use the new name at
   **every** occurrence in that file (search the whole file for each name before and after).
4. **Settings variables** in the "CHINH O DAY" (settings) block at the top of each .bat — the ones a user edits —
   get English names, renamed at **every** use in the file (`%X%`, `!X!`, `set X=`, `set /a ...`, `if defined X`,
   `for ... %X%`, `defined`, `echo` lines that print them). Suggested names: VONG→ROUNDS, PHUT_VONG→ROUND_MINUTES,
   PHUT_KIEM_TRA→CHECK_MINUTES, SONG_SONG→PARALLEL, HAT_GIONG→SEED (if SEED is free; FIRST_SEED in spsa.bat and
   brain.bat, where SEED is used internally), PHUT_GHI→RECORD_MINUTES, AN→HIDDEN, EPOCH→EPOCHS, DOI_THU→OPPONENT,
   THU_DON→EXPLORE, TIEP_HOC_SAU→THEN_BRAIN, NHIN_XA→LOOK_AHEAD (its value tu→auto, 1,5→1.5), UU_TIEN→PRIORITY,
   VE→RENDERER, THU_GIAY→TEST_SECONDS, SO_TRAN/TRAN→GAMES, MUC→LEVEL, NHAN_VAT→FIGHTERS, GAME/PACK/NOTES/BENCH/SCRIPTS
   unchanged; in can-bang.bat: NAO→BRAIN, BO_NHAN_VAT→EXCLUDE, TONG_VAN→TOTAL_GAMES, TONG_GIO→TOTAL_HOURS,
   VU_KHI→WEAPONS, PHUT_VAN→GAME_MINUTES, GIAY_DUNG_IM→STILL_SECONDS, GIO_CHAY→RUN_HOURS, THU_TONG_GIAY→TEST_TOTAL_SECONDS,
   THU_SNAP→TEST_SNAP. A renamed variable must not collide with an existing one — check the whole file.
5. The settings block header `rem ============ CHINH O DAY ============` becomes `rem ============ SETTINGS ============`.

## What does not change

- Logic, order of commands, every `if`/`for`/`goto`/`call`, redirections, quoting, `^` escapes, `%%` doubling,
  delayed-expansion forms (`!X!`), `setlocal` lines. The English file must do exactly what the Vietnamese one does.
- Internal variable names that the user never edits (e.g. GIAY_VONG, K_NOM, TONG, XONG_LUC, DO_DANG, THU_MUC, TEN,
  DUOI, GOC, OUT, MOI, CAI, GHEP, XS, XR, MA …) and labels (`:doc_vao`, `goto doc_xong` …) stay as they are —
  renaming them is not required and risks breaking the file. (Renaming a settings variable per rule 4 is required.)
- Lua code generated by `echo ... > config.lua` lines: the Lua keys and values are code — only an embedded
  message string may be translated.
- Everything the game itself reads: `xoi\notes.txt`, `xoi\tune.txt`, `data\data.txt`, `smart.version = `, command
  line options (`--pack`, `--scripts`, `--mod`, `--renderer`, `--seed`, `--headless` …), the names of bench
  commands/modules (`duel`, `learn`, `spsa`, `show`, `list`, `smart`, `xoi`, `classic`, `spsa_start`, `ai_alt` …).
- The LF2 vocabulary: INSANE!, XOI, CRAZY!, "the mod" (bản mod), "notes" (bộ nhớ XOI = XOI's notes), "numbers"
  (thang số = the tuned numbers, xoi\tune.txt), "pair" (cặp trận = two games with sides swapped), "round" (vòng),
  "seed" (hạt giống), "process" (tiến trình), "fighter" (nhân vật), "stage" (màn/sân).

## Writing the files

- Write each file with LF line ends; they are converted to CRLF afterwards (do not insert `\r` yourself).
- Plain ASCII in .bat files (cmd shows UTF-8 wrongly); README/publish-README may use UTF-8 (they are .txt).
- Keep the first line `@echo off` and the `setlocal` lines exactly.
- A .bat's line count may differ slightly (English comments may wrap differently), but keep one command per line as
  in the original: do not split or join command lines, only comment lines.
- When done, re-read your output file against the original side by side and check: every `goto`/`call :label`
  target still exists; every renamed variable is renamed everywhere (grep the old name: zero hits); no Vietnamese
  word remains (grep for: khong, duoc, ban mod, tran, vong, phut, nhan vat, cua, file nay, dong, canh, chay, thu
  muc, bo nho, may, loi, xem, xong, dau, cai, dat, mo, tim, thay, nen, giai, gui, sua, chon, bam, nhay).
