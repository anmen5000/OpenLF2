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
6. Publish a mod for its players, INSANE! and XOI built in: put <mod>-xoi.zip (or the mod's zip or folder)
   next to xuat-ban.bat and double-click it. It makes xuat-ban\<mod>.zip: the mod's own folder as its author
   shares it (bg, bgm, data, sprite..., its own .exe too) with OpenLF2 added - "<mod> - INSANE XOI.exe", its
   .dll files, the scripts and licenses folders, XOI's notes and numbers in xoi\. Players extract it and
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

Files: choi.bat (play), xoi-hoc.bat (train), dau-nhieu.bat (measure), spsa.bat (tune), xem.bat (watch), xuat-ban.bat (publish;
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
6. Xuất bản bản mod cho người chơi, có sẵn INSANE! và XOI: đặt <tên>-xoi.zip (hoặc file zip hay thư mục bản
   mod) cạnh xuat-ban.bat rồi nháy đúp. Kết quả: xuat-ban\<tên>.zip - nguyên thư mục gốc của bản mod như tác
   giả chia sẻ (bg, bgm, data, sprite..., cả file .exe của nó), thêm OpenLF2: "<tên> - INSANE XOI.exe", các
   file .dll, thư mục scripts và licenses, bộ nhớ và bộ số của XOI trong thư mục xoi. Người chơi giải nén rồi
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

Các file: choi.bat (chơi), xoi-hoc.bat (huấn luyện), dau-nhieu.bat (đo), spsa.bat (chỉnh số), xem.bat (xem), xuat-ban.bat (xuất
bản; phần việc trong xuat-ban.ps1, README của bản xuất bản lấy từ xuat-ban-README.txt), kiem-tra.bat (kiểm
tra), scripts\ (scripts của game có máy INSANE!/XOI, ghép lên scripts của game đã cài), tools\ai-bench\ (việc
huấn luyện và đo), version.txt (bộ này là phiên bản nào).
