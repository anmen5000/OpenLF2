LF2 XOI kit: the INSANE! and XOI computer players on your PC
==============================================================
Full guide (English / Tiếng Việt): https://anmen5000.github.io/OpenLF2/xoi.html

A mod's own .exe is the original Little Fighter 2: its computer players stop at CRAZY!.
INSANE! and XOI are part of OpenLF2, which plays the same mod files.

1. Install OpenLF2 for Windows once: OpenLF2-Windows-x64.exe from
   https://github.com/anmen5000/OpenLF2/releases/latest
   (x64 is for 64-bit Windows 10 and 11, nearly every PC; x86 is only for old 32-bit Windows.)
   Choose "Install for me only". If Windows says "Windows protected your PC": More info, then Run anyway.
2. Play: put a mod's .zip next to choi.bat and double-click choi.bat, or drag the mod's .zip, its folder
   or its .exe onto choi.bat. In the game, cycle the difficulty past CRAZY! to INSANE!, then XOI.
   XOI notes: a <mod>-xoi.zip has them inside; a notes .txt is dragged onto choi.bat together with the mod.
   A window that stays blue with no pictures: open choi.bat in Notepad and set VE=software.
3. Train XOI for a mod: put the mod's .zip next to xoi-hoc.bat and double-click it (its settings are at the
   top of the file: right-click it, Edit). It makes <mod>-xoi.zip (the mod with xoi\notes.txt inside) and
   xoi-<mod>\notes.txt (the notes alone, to share).
4. Measure: dau-nhieu.bat plays XOI against INSANE! on every pair of fighters and prints the win rate.
5. Tune XOI's numbers (SPSA): put one or more mods' .zip next to spsa.bat and double-click it. Two
   computer players fight with XOI's 77 numbers nudged one way and the other; the numbers move toward
   whichever did better, round after round (VONG rounds of PHUT_VONG minutes, 12 x 5 by default, one
   process per CPU thread), then the tuned numbers play the ones they started from for PHUT_KIEM_TRA
   minutes. The tuned numbers are XOI's alone: INSANE! keeps its own, set by hand (from package 43). Result:
   spsa\ket-qua.txt - send it to whoever maintains the AI. A night: VONG=60, PHUT_VONG=10, PHUT_KIEM_TRA=15.
   A pair is two games, same fighters and stage, sides swapped. In a round every process plays pairs until
   the minutes are up, all stopping together (no thread waits for a slower one); then the mean step per pair
   is taken, every mod weighing the same. To pause: close its window and the minimized SPSA windows; run it
   again to go on - finished rounds stay, and so does what the round under way had played (a PC cut off while
   a round's numbers were written: that round is merged again, not played again). Several mods at
   once: put their .zip files next to it; the check gives each mod's result too. A game in which nobody
   loses HP for a minute ends there, and a window stuck far longer than the others is stopped.
   Each mod's numbers: at the end it writes xoi-<mod>\tune.txt and <mod>-xoi.zip, the mod with xoi\tune.txt
   (and XOI's notes, if trained) inside: uploaded to the relay, XOI plays that mod with its own
   numbers ("mod tuned" in the match). With one mod next to it, the next run goes on from that mod's numbers.
   Several PCs: give each PC one or two mods of its own (one mod per PC gives each mod its own best numbers);
   two PCs on the same mod need different HAT_GIONG.
   DOI_THU=classic (package 58): both nudged sets play the original computer player instead of each other - the
   mod's ai\<id>.as scripts where a fighter has them (Sauce's AI, item 9) - so the numbers move toward what beats
   that opponent; a round costs twice the games, and the check reports the tuned numbers and the original ones
   against it. For tuning against one particular player; the numbers it finds suit that player first. A mod
   with no AI scripts of its own still has the two sets play each other (the CRAZY player is too weak to tune
   against), so Sauce's pack and the mods can go in together: one set of numbers for all, each pack tuned against
   the strongest player it has.
   Your own settings (VONG, PHUT_VONG, DOI_THU=classic...) are best kept in a file spsa-cai-dat.bat beside
   spsa.bat, one  set "VONG=60"  line each: a new kit's spsa.bat copied over the old one keeps them.
   "Khong gop duoc vong N" (a round not merged) with the game of packages 69-71 on Windows - its last message cut a
   process's last line of numbers in two: copy the kit of package 72 or later over the old one, keep the spsa
   folder, and run spsa.bat again; it merges that round from what was played, without playing it again.
   Pause timer (package 73): set "GIO_CHAY=8" (hours; 7,5 = seven and a half) - after that time the processes under
   way stop, keeping what they played, and spsa.bat ends; run it again later to go on. Closing spsa.bat's window
   stops its games too (from package 73: a hidden watcher; before, the games of packages 69-72 kept running in the
   background after the windows were closed - end them with  taskkill /F /IM openlf2.exe  ). A run begun with an
   older kit goes on with its own scripts under a newer kit (package 73 on; before, "flow.lua:7 ...
   set_executable_patches"); delete spsa\scripts to take the new scripts and numbers instead.
   Going on from a finished run (package 75), after updating the game and the kit, say: raise VONG (60 to 80 adds
   20 rounds) and run spsa.bat again - the added rounds start from the last round's numbers, the steps go on
   shrinking as before, they use the new kit's scripts (the new AI), and the run ends with a new check and new
   packages. Better than starting over: the numbers found still fit, and a new run begins with large steps again.
5b. XOI's brain (package 67): put one or more mods' .zip next to hoc-sau.bat and double-click it. XOI records
   every move it starts over thousands of games (against the mod's own AI scripts where it has them, Sauce's AI,
   else against itself) with what came of it, HP dealt minus HP taken over the next 1.5 seconds; then a small
   neural network is trained on the records inside the game and XOI weighs its own score of a move half with
   the network's prediction. VONG rounds of PHUT_GHI minutes (2 x 20 by default, one process per CPU thread;
   about 2,000 moves a minute a process); from the second round XOI records with the brain it just learned.
   Then a check: XOI with the brain and XOI without it against the same opponent for PHUT_KIEM_TRA minutes.
   Result: hoc-sau\ket-qua.txt - send it to whoever maintains the AI. Each mod's brain: xoi-<mod>\brain.txt,
   and <mod>-xoi.zip, the mod with xoi\brain.txt (and its numbers and notes) inside: uploaded to the relay or
   published, XOI plays that mod with the brain ("brain" in the match). A brain is for one mod. To pause: close
   the windows; run it again to go on. To learn further: raise VONG and run again (package 75: after a
   finished run, the added rounds record with the new kit's scripts, the new AI). Settings file: hoc-sau-cai-dat.bat.
   On Sauce's pack the brain took XOI from 321 to 377 games of 720 against Sauce's AI. The original zip or the
   <mod>-xoi.zip of spsa.bat/xoi-hoc.bat both do (package 68 on): XOI records with the mod's numbers and notes
   (xoi-<mod>\tune.txt and notes.txt beside the file when they exist, else those inside the zip), a -xoi.zip beside
   its original is skipped when the folder is scanned, and a -xoi.zip given is updated itself (the earlier one kept
   as -xoi-truoc.zip). DOI_THU=xoi (package 71): XOI records against itself in a mod with an AI of its own too - for
   mods whose own AI is far weaker than XOI (Dragon Ball Super's loses most of its games to XOI), where a brain
   would only learn to beat that AI; leave it empty for Sauce's pack. Run spsa.bat first, then hoc-sau.bat: the
   brain learns on top of the numbers (run a few more rounds of hoc-sau.bat after a new spsa.bat). The owner's 10
   rounds on Sauce's pack (80 threads): XOI with the brain won 57.4% of its games against Sauce's AI, without 45.8%.
   The hoc-sau folder belongs to the mods it was run with: for other mods, rename it first (hoc-sau-sauce, say) -
   hoc-sau.bat stops with a message rather than mix their data.
6. Publish a mod for its players, INSANE! and XOI built in: put <mod>-xoi.zip (or the mod's zip or folder)
   next to xuat-ban.bat and double-click it. It makes xuat-ban\<mod>.zip: the mod's own folder as its author
   shares it (bg, bgm, data, sprite..., its own .exe too) with OpenLF2 added - "<mod> - INSANE XOI.exe", its
   .dll files, the scripts and licenses folders, XOI's notes, numbers and brain in xoi\. Players extract it and
   double-click "<mod> - INSANE XOI.exe" - nothing to install, no kit, no original LF2. Needs OpenLF2 from
   package 50 (it plays the mod folder it lies in by itself; xuat-ban.bat says when the installed one is older).
   Another name: TEN at the top of xuat-ban.bat; your words for the players: edit xuat-ban-README.txt first
   ({TEN} becomes the name, {EXE} the program, {GOC} the mod's own .exe); it becomes README - INSANE XOI.txt.
   It asks whether to lock the hidden fighters (C = yes): no "options" on the players' title screen, no
   unlocking, lf2.net does nothing; CRAZY!, INSANE! and XOI stay (openlf2.txt in the mod; package 49). KHOA_AN at the top of
   xuat-ban.bat answers it beforehand.
   Publish your own mod, or one whose author allows it; keep the licenses folder in it.
7. The game does not open, or closes at once: put a mod's .zip next to kiem-tra.bat, double-click it, wait
   about 2 minutes (game windows may open and close by themselves) and send kiem-tra.txt.
8. Watch two computer players fight in the game's window (to record a clip): open xem.bat in Notepad, set QUAN1
   and QUAN2 to two fighters - by name as the game shows it (Crimson, Deep; capitals or not; the first letters
   are enough) or by id - and NAO1, NAO2 (xoi, smart = INSANE!, classic), then double-click it. VAN games, sides
   swapped every game; NEN a background by name or number (empty: random); a game still on after GIOI_HAN
   ticks (9000 = 5 minutes) is a draw; the same HAT_GIONG plays the same games again. F1 pauses, F5 runs fast,
   F4 ends the game under way (after the last, it closes the window). QUAN1 left empty: it lists the mod's
   fighters (id, name) and backgrounds into danh-sach.txt.
   It takes the mod as the other files do (a *-xoi.zip first, or drag a zip, a mod folder or a published
   mod's .exe onto it). Record with OBS Studio or Xbox Game Bar (Win+Alt+R). dau-nhieu.bat takes names in
   IDS too ("Crimson Deep").
9. INSANE! or XOI against another computer player made for LF2 - a mod's ai\<id>.as scripts, which LF2 runs
   with the AI script engine's ai.dll or ddraw.dll (Sauce's "lf2-AI VS and Stage Challenge"; package 56): in
   dau-nhieu.bat (or xem.bat) set NAO1=smart (or xoi), NAO2=classic - the original computer player, which plays
   the mod's script for each fighter that has one - and MUC=-1 (CRAZY!, the scripts' best level); IDS the
   fighters (Sauce's ten original ones: 1 2 4 5 6 7 8 9 10 11). A mod whose own .exe has none of LF2's pictures
   (moved to its UI folder, as Sauce's) needs OpenLF2 built from package 56 on; with an older one, copy LF2
   2.0a's lf2.exe (or a mod's lf2_2.0a.exe, mode Convergence has one) into the mod's folder as lf2.exe first.
10. Fighter balance (package 77): put the mod's .zip (better: <mod>-xoi.zip) next to can-bang.bat and
   double-click it. One computer player (XOI) plays both sides of every pair of fighters, on every CPU thread,
   and counts each fighter's win rate against every other one and what each of its moves brings (how often it
   is used, lands, is guarded, how much HP it takes off, how often its user is hit in it). Settings at the top:
   VONG rounds, and TONG_VAN (total games) or TONG_GIO (total hours); NHAN_VAT, BO_NHAN_VAT the fighters; NAO the
   player (xoi, smart, classic). Results in can-bang-<mod>\: bao-cao.html (open it in a browser: the ranking,
   the matchup chart, every move of every fighter; English or Vietnamese at a click) and ket-qua.txt,
   updated after every round. Close the window to pause, run it again to go on; raise TONG_VAN or TONG_GIO
   to measure more. The numbers only - what to change is the mod maker's to say. (In English: balance.bat,
   also as balance-kit.zip on the guide's page.)

Files: choi.bat (play), xoi-hoc.bat (train), dau-nhieu.bat (measure), spsa.bat (tune), hoc-sau.bat (the brain), xem.bat (watch), can-bang.bat (balance), xuat-ban.bat (publish;
its work is in xuat-ban.ps1, the published README comes from xuat-ban-README.txt), kiem-tra.bat (check),
scripts\ (the game's scripts with the computer players, laid over the installed game's), tools\ai-bench\ (the
training and measuring jobs), version.txt (which version this kit is).

----- Tiếng Việt -----
File .exe của bản mod là Little Fighter 2 gốc: máy chỉ tới CRAZY!. INSANE! và XOI nằm trong OpenLF2,
chơi được chính các file của bản mod.

1. Cài OpenLF2 cho Windows một lần: OpenLF2-Windows-x64.exe ở
   https://github.com/anmen5000/OpenLF2/releases/latest
   (x64 cho Windows 10 và 11 bản 64-bit, gần như mọi máy; x86 chỉ cho Windows 32-bit cũ.)
   Chọn "Install for me only". Windows báo "Windows protected your PC": bấm More info, rồi Run anyway.
2. Chơi: đặt file .zip bản mod cạnh choi.bat rồi nháy đúp choi.bat, hoặc kéo thả file .zip bản mod,
   thư mục bản mod hay file .exe của bản mod vào choi.bat. Trong game, ở dòng mức khó bấm qua CRAZY!
   là tới INSANE!, rồi XOI.
   Bộ nhớ XOI: file <tên>-xoi.zip có sẵn bên trong; có file bộ nhớ .txt riêng thì kéo nó cùng bản mod
   vào choi.bat.
   Cửa sổ game chỉ xanh, không có hình: mở choi.bat bằng Notepad, sửa thành VE=software.
3. Huấn luyện XOI cho một bản mod: đặt file .zip bản mod cạnh xoi-hoc.bat rồi nháy đúp (các dòng chỉnh
   ở đầu file: chuột phải, Edit). Kết quả: <tên>-xoi.zip (bản mod có xoi\notes.txt bên trong) và
   xoi-<tên>\notes.txt (riêng bộ nhớ, để chia sẻ).
4. Đo: dau-nhieu.bat cho XOI đấu INSANE! mọi cặp nhân vật và in tỉ lệ thắng.
5. Chỉnh các con số của XOI (SPSA): đặt một hay nhiều file .zip bản mod cạnh spsa.bat rồi nháy
   đúp. Hai máy đánh nhau, 77 con số của XOI nhích về hai phía ngược nhau; các số dịch về phía bản
   đánh tốt hơn, vòng này qua vòng khác (VONG vòng, mỗi vòng PHUT_VONG phút, mặc định 12 x 5; mỗi luồng CPU
   một tiến trình), cuối cùng bản đã chỉnh đấu với bản gốc trong PHUT_KIEM_TRA phút. Các số chỉnh được chỉ
   XOI dùng: INSANE! giữ các số đặt bằng tay của nó (từ gói 43). Kết quả:
   spsa\ket-qua.txt - gửi file này cho người làm AI. Một đêm: VONG=60, PHUT_VONG=10, PHUT_KIEM_TRA=15.
   Một cặp là hai trận, cùng nhân vật và sân, đổi bên. Trong một vòng, mọi tiến trình đánh liền các cặp cho
   tới hết số phút và dừng cùng lúc (không luồng nào ngồi chờ luồng chậm); rồi lấy bước dịch trung bình mỗi
   cặp, mỗi bản mod nặng như nhau. Tạm dừng: đóng cửa sổ của nó và các cửa sổ SPSA thu nhỏ; chạy lại là làm
   tiếp - các vòng đã xong được giữ, cả phần vòng đang dở đã đánh (máy mất điện đúng lúc ghi số cuối vòng:
   vòng ấy được gộp lại, không đánh lại). Nhiều bản mod cùng lúc: đặt các file .zip
   cạnh nó; phần kiểm tra cho cả kết quả từng bản mod. Trận nào một phút không ai mất máu thì dừng ở đó, và
   cửa sổ nào treo lâu hơn hẳn các cửa sổ khác thì bị dừng.
   Bộ số của từng bản mod: chạy xong, nó ghi xoi-<tên>\tune.txt và <tên>-xoi.zip, tức bản mod có xoi\tune.txt
   (và bộ nhớ XOI nếu đã huấn luyện) bên trong: tải lên relay thì XOI chơi bản mod ấy bằng bộ số
   riêng của nó (trong trận ghi "mod tuned"). Chỉ một bản mod cạnh nó thì lần sau chỉnh tiếp từ bộ số ấy.
   Nhiều máy: mỗi máy lo một hai bản mod riêng (mỗi máy một bản mod thì bản mod nào cũng có bộ số tốt nhất
   cho nó); hai máy cùng một bản mod thì đặt HAT_GIONG khác nhau.
   DOI_THU=classic (gói 58): hai bản nhích số cùng đánh với máy gốc của game thay vì đánh nhau - nhân vật nào có script
   ai\<id>.as của bản mod (AI của Sauce, mục 9) thì máy gốc chơi bằng script đó - nên các số dịch về phía thắng được
   đối thủ ấy; mỗi vòng tốn gấp đôi số trận, và phần kiểm tra ghi kết quả của bản đã chỉnh và bản gốc cùng đánh đối thủ
   ấy. Dùng để chỉnh số cho một đối thủ cụ thể; bộ số tìm được hợp với đối thủ ấy trước hết. Bản mod không có script
   AI riêng thì hai bản nhích số vẫn đánh nhau ở bản ấy (máy gốc CRAZY quá yếu để chỉnh theo), nên có thể đặt bản Sauce
   và các bản mod cùng lúc: một bộ số chung cho tất cả, bản nào cũng chỉnh theo đối thủ mạnh nhất nó có.
   Cài đặt riêng của bạn (VONG, PHUT_VONG, DOI_THU=classic...) nên để trong file spsa-cai-dat.bat cạnh spsa.bat,
   mỗi dòng một cài đặt như  set "VONG=60"  : chép đè spsa.bat của bộ mới lên thì cài đặt vẫn còn.
   Báo "Khong gop duoc vong N" với game gói 69-71 trên Windows (dòng báo cuối của game cắt đôi dòng số cuối của
   một tiến trình): chép đè bộ XOI từ gói 72 trở lên lên bộ cũ, giữ thư mục spsa, rồi chạy lại spsa.bat - nó gộp
   vòng ấy từ phần đã đánh, không đánh lại.
   Hẹn giờ tạm dừng (gói 73): đặt  set "GIO_CHAY=8"  (số giờ; 7,5 = bảy giờ rưỡi) - hết giờ, các tiến trình đang
   đánh dừng lại, giữ phần đã đánh, và spsa.bat kết thúc; lúc khác chạy lại là làm tiếp. Đóng cửa sổ spsa.bat thì các
   game của nó cũng dừng (từ gói 73: một PowerShell ẩn canh cửa sổ; trước đó game gói 69-72 vẫn chạy ngầm sau khi đóng
   các cửa sổ - tắt chúng bằng  taskkill /F /IM openlf2.exe  ). Đợt chạy bắt đầu bằng bộ XOI cũ vẫn chạy tiếp với
   scripts của nó dưới bộ mới (từ gói 73; trước đó báo "flow.lua:7 ... set_executable_patches"); muốn dùng scripts và
   bộ số mới thì xóa thư mục spsa\scripts.
   Chỉnh tiếp một đợt đã xong (gói 75), ví dụ sau khi cập nhật game và bộ XOI: tăng VONG (60 lên 80 là thêm 20 vòng)
   rồi chạy lại spsa.bat - các vòng thêm bắt đầu từ bộ số của vòng cuối, bước dịch nhỏ dần tiếp như cũ, dùng scripts
   của bộ XOI mới (AI bản mới), và cuối đợt kiểm tra, gói số lại. Tốt hơn chỉnh lại từ đầu: bộ số đã tìm vẫn dùng
   được, còn một đợt mới thì bắt đầu lại bằng bước dịch lớn.
5b. Bộ não XOI (gói 67): đặt một hay nhiều file .zip bản mod cạnh hoc-sau.bat rồi nháy đúp. XOI ghi lại mọi lần
   ra đòn trong hàng nghìn trận (đánh với script AI riêng của bản mod nếu có, AI của Sauce, không thì với chính
   nó) cùng kết quả: máu gây được trừ máu mất trong 1,5 giây sau; rồi một mạng nơ-ron nhỏ được huấn luyện trên
   dữ liệu ấy ngay trong game, và XOI lấy một nửa điểm tự tính của đòn, một nửa lời đoán của mạng. VONG lượt,
   mỗi lượt PHUT_GHI phút (mặc định 2 x 20, mỗi luồng CPU một tiến trình; mỗi tiến trình chừng 2.000 lần ra đòn
   một phút); từ lượt hai XOI ghi với bộ não vừa học. Cuối cùng kiểm tra: XOI có bộ não và XOI không có cùng đánh
   một đối thủ trong PHUT_KIEM_TRA phút. Kết quả: hoc-sau\ket-qua.txt - gửi file này cho người làm AI. Bộ não của
   từng bản mod: xoi-<tên>\brain.txt, và <tên>-xoi.zip là bản mod có xoi\brain.txt (cùng bộ số và bộ nhớ) bên trong:
   tải lên relay hay xuất bản thì XOI chơi bản mod ấy với bộ não (trong trận ghi "brain"). Mỗi bản mod một bộ
   não. Tạm dừng: đóng các cửa sổ; chạy lại là làm tiếp. Học thêm: tăng VONG rồi chạy lại (gói 75: đợt trước đã xong
   thì các lượt thêm ghi dữ liệu với scripts của bộ XOI mới, AI bản mới). File cài đặt riêng:
   hoc-sau-cai-dat.bat. Trên bản của Sauce, bộ não đưa XOI từ 321 lên 377 trận thắng trong 720 trận đấu AI của Sauce.
   Bản gốc hay bản <tên>-xoi.zip của spsa.bat/xoi-hoc.bat đều dùng được (từ gói 68): XOI ghi dữ liệu với bộ số và
   bộ nhớ của bản mod (xoi-<tên>\tune.txt và notes.txt cạnh file nếu có, không thì bộ trong file zip); file -xoi.zip
   nằm cạnh bản gốc thì bị bỏ qua khi tự quét thư mục; đưa vào chính bản -xoi.zip thì nó được cập nhật tại chỗ
   (bản trước giữ ở -xoi-truoc.zip). DOI_THU=xoi (gói 71): XOI ghi dữ liệu khi đánh với chính nó, kể cả ở bản mod
   có AI riêng - cho bản mod có AI riêng yếu hơn XOI nhiều (AI của Dragon Ball Super thua XOI phần lớn số trận),
   nơi bộ não chỉ học cách thắng AI ấy; để trống cho bản Sauce. Chạy spsa.bat trước rồi mới hoc-sau.bat: bộ não học
   trên nền bộ số (chạy spsa.bat lại thì chạy thêm vài lượt hoc-sau.bat). Lần chạy 10 lượt của chủ dự án trên bản
   Sauce (80 luồng): XOI có bộ não thắng 57,4% số trận với AI của Sauce, không có 45,8%. Thư mục hoc-sau là của
   các bản mod đã chạy với nó: chạy cho bản mod khác thì đổi tên nó trước (ví dụ hoc-sau-sauce) - hoc-sau.bat dừng và
   báo thay vì trộn dữ liệu của chúng.
6. Xuất bản bản mod cho người chơi, có sẵn INSANE! và XOI: đặt <tên>-xoi.zip (hoặc file zip hay thư mục bản
   mod) cạnh xuat-ban.bat rồi nháy đúp. Kết quả: xuat-ban\<tên>.zip - nguyên thư mục gốc của bản mod như tác
   giả chia sẻ (bg, bgm, data, sprite..., cả file .exe của nó), thêm OpenLF2: "<tên> - INSANE XOI.exe", các
   file .dll, thư mục scripts và licenses, bộ nhớ, bộ số và bộ não của XOI trong thư mục xoi. Người chơi giải nén rồi
   nháy đúp "<tên> - INSANE XOI.exe" - không cài gì, không cần bộ XOI, không cần LF2 gốc. Cần OpenLF2 từ gói 50
   (tự chơi thư mục bản mod mà nó nằm trong; xuat-ban.bat báo nếu bản đã cài cũ hơn). Muốn tên khác: dòng TEN ở
   đầu xuat-ban.bat; lời của bạn cho người chơi: sửa xuat-ban-README.txt trước ({TEN} thành tên bản xuất bản,
   {EXE} thành file chương trình, {GOC} thành file .exe gốc của bản mod); nó thành README - INSANE XOI.txt.
   Nó hỏi có khóa nhân vật ẩn không (C = có): màn hình đầu của người chơi không có nút options, không mở
   khóa được, gõ lf2.net cũng không mở; CRAZY!, INSANE!, XOI vẫn có (file openlf2.txt trong bản mod; gói 49). Dòng KHOA_AN
   ở đầu xuat-ban.bat trả lời sẵn câu này.
   Chỉ xuất bản bản mod của bạn, hoặc khi tác giả cho phép; giữ thư mục licenses trong đó.
7. Game không mở được, hay mở rồi tắt ngay: đặt file .zip bản mod cạnh kiem-tra.bat, nháy đúp, đợi khoảng
   2 phút (cửa sổ game có thể tự hiện rồi tự tắt) rồi gửi file kiem-tra.txt.
8. Xem hai máy đánh nhau trong cửa sổ game (để quay clip): mở xem.bat bằng Notepad, sửa QUAN1 và QUAN2 thành
   hai nhân vật - gõ tên như trong game (Crimson, Deep; hoa thường đều được; vài chữ đầu cũng được) hoặc id -
   và NAO1, NAO2 (xoi, smart = INSANE!, classic), lưu lại rồi nháy đúp. VAN trận, mỗi trận đổi bên; NEN là màn
   nền theo tên hay số (để trống: ngẫu nhiên); trận quá GIOI_HAN tick (9000 = 5 phút) tính hòa; cùng HAT_GIONG
   thì ra đúng các trận cũ. F1 dừng, F5 chạy nhanh, F4 bỏ trận đang xem (hết trận thì F4 đóng cửa sổ). Để trống
   QUAN1: in danh sách nhân vật (id, tên)
   và màn nền của bản mod ra danh-sach.txt. Bản mod lấy như các file khác (ưu tiên *-xoi.zip; hoặc kéo thả file
   zip, thư mục bản mod hay file .exe của bản đã xuất bản vào nó). Quay bằng OBS Studio hoặc Xbox Game Bar
   (Win+Alt+R). dau-nhieu.bat cũng nhận tên ở dòng IDS ("Crimson Deep").
9. INSANE! hay XOI đấu với một AI khác làm cho LF2 - các script ai\<id>.as của bản mod, LF2 chạy bằng ai.dll
   hay ddraw.dll của AI script engine (bản "lf2-AI VS and Stage Challenge" của Sauce; gói 56): trong
   dau-nhieu.bat (hay xem.bat) đặt NAO1=smart (hay xoi), NAO2=classic - máy gốc, nhân vật nào có script của bản
   mod thì máy gốc chơi bằng script đó - và MUC=-1 (CRAZY!, mức mạnh nhất của script); IDS là các nhân vật (10
   nhân vật gốc của Sauce: 1 2 4 5 6 7 8 9 10 11). Bản mod mà file .exe không còn hình của LF2 (dời ra thư mục
   UI, như bản của Sauce) cần OpenLF2 dựng từ gói 56 trở đi; với bản cũ hơn, chép lf2.exe của LF2 2.0a (hay
   lf2_2.0a.exe của một bản mod, mode Convergence có) vào thư mục bản mod, đặt tên lf2.exe, trước đã.
10. Cân bằng nhân vật (gói 77): đặt file .zip bản mod (tốt hơn: <tên>-xoi.zip) cạnh can-bang.bat rồi nháy đúp.
   Một máy (XOI) chơi cả hai bên mọi cặp nhân vật, trên mọi luồng CPU, rồi đếm tỉ lệ thắng của từng nhân vật
   trước từng nhân vật khác và mỗi chiêu của nó mang lại gì (dùng bao nhiêu, trúng bao nhiêu, bị đỡ, gây bao
   nhiêu máu, người dùng bị đánh trả bao nhiêu). Chỉnh ở đầu file: VONG (số vòng), và TONG_VAN (tổng số ván)
   hoặc TONG_GIO (tổng số giờ); NHAN_VAT, BO_NHAN_VAT là các nhân vật; NAO là máy (xoi, smart, classic). Kết
   quả ở can-bang-<tên>\: bao-cao.html (mở bằng trình duyệt: xếp hạng, bảng đối đầu, từng chiêu của từng nhân
   vật; bấm một nút là chuyển tiếng Anh/tiếng Việt) và ket-qua.txt, cập nhật sau mỗi vòng. Đóng cửa sổ để tạm
   dừng, chạy lại là làm tiếp; tăng TONG_VAN hay TONG_GIO để đo thêm. Báo cáo chỉ ghi số đo được - chỉnh gì là
   việc của người làm mod. (Bản tiếng Anh: balance.bat, có cả gói riêng balance-kit.zip ở trang hướng dẫn.)

Các file: choi.bat (chơi), xoi-hoc.bat (huấn luyện), dau-nhieu.bat (đo), spsa.bat (chỉnh số), hoc-sau.bat (bộ não), xem.bat (xem), can-bang.bat (cân bằng), xuat-ban.bat (xuất
bản; phần việc trong xuat-ban.ps1, README của bản xuất bản lấy từ xuat-ban-README.txt), kiem-tra.bat (kiểm
tra), scripts\ (scripts của game có máy INSANE!/XOI, ghép lên scripts của game đã cài), tools\ai-bench\ (việc
huấn luyện và đo), version.txt (bộ này là phiên bản nào).
