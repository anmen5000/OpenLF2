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
5. Tune INSANE!'s own numbers (SPSA): put one or more mods' .zip next to spsa.bat and double-click it. Two
   INSANE! players fight with the AI's 31 numbers nudged one way and the other; the numbers move toward
   whichever did better, round after round (12 rounds by default, one process per CPU thread), then the
   tuned numbers play the AI's own. Result: spsa\ket-qua.txt - send it to whoever maintains the AI. It can
   be stopped and started again: it goes on from the round it was in.
   A pair (CAP) is two games, same fighters and stage, sides swapped; a round (VONG) is CAP pairs in every
   process, then the processes' numbers are averaged. After each round it says how long the round took and
   about how long the rest will take. Several mods at once: put their .zip files next to it; the processes
   are dealt out among them in turn, and the check (KIEM_TRA) gives each mod's result too. A game in which
   nobody loses HP for a minute ends there, and a window stuck far longer than the others is stopped.
6. The game does not open, or closes at once: put a mod's .zip next to kiem-tra.bat, double-click it, wait
   about 2 minutes (game windows may open and close by themselves) and send kiem-tra.txt.

Files: choi.bat (play), xoi-hoc.bat (train), dau-nhieu.bat (measure), spsa.bat (tune), kiem-tra.bat (check),
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
5. Chỉnh các con số của chính INSANE! (SPSA): đặt một hay nhiều file .zip bản mod cạnh spsa.bat rồi nháy
   đúp. Hai máy INSANE! đánh nhau, 31 con số của AI nhích về hai phía ngược nhau; các số dịch về phía bản
   đánh tốt hơn, vòng này qua vòng khác (mặc định 12 vòng, mỗi luồng CPU một tiến trình), cuối cùng bản đã
   chỉnh đấu với bản gốc. Kết quả: spsa\ket-qua.txt - gửi file này cho người làm AI. Tắt giữa chừng được:
   chạy lại là làm tiếp từ vòng đang dở.
   Một cặp (CAP) là hai trận, cùng nhân vật và sân, đổi bên; một vòng (VONG) là CAP cặp ở mọi tiến trình,
   rồi lấy trung bình các số của các tiến trình. Hết mỗi vòng, file in vòng ấy mất bao lâu và còn khoảng
   bao lâu. Nhiều bản mod cùng lúc: đặt các file .zip cạnh nó; các tiến trình chia lần lượt cho từng bản
   mod, và phần kiểm tra (KIEM_TRA) cho cả kết quả của từng bản mod. Trận nào một phút không ai mất máu thì
   dừng ở đó, và cửa sổ nào treo lâu hơn hẳn các cửa sổ khác thì bị dừng.
6. Game không mở được, hay mở rồi tắt ngay: đặt file .zip bản mod cạnh kiem-tra.bat, nháy đúp, đợi khoảng
   2 phút (cửa sổ game có thể tự hiện rồi tự tắt) rồi gửi file kiem-tra.txt.

Các file: choi.bat (chơi), xoi-hoc.bat (huấn luyện), dau-nhieu.bat (đo), spsa.bat (chỉnh số), kiem-tra.bat (kiểm
tra), scripts\ (scripts của game có máy INSANE!/XOI, ghép lên scripts của game đã cài), tools\ai-bench\ (việc
huấn luyện và đo), version.txt (bộ này là phiên bản nào).
