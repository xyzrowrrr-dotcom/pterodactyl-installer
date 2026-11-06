PAKET PTERODACTYL AUTO INSTALLER + PROTECT
Target Panel: Pterodactyl v1.15.2
OS target: Ubuntu 22.04 / 24.04

ISI PAKET
- install.sh                Installer Bash utama
- protect-payload.tar.gz    23 file Protect hasil ekstraksi modul 1-15

CARA PAKAI
1. Upload kedua file ke folder yang sama pada VPS Panel.
2. Pastikan Panel Pterodactyl v1.15.2 sudah terpasang untuk menu Protect.
3. Jalankan:
   chmod +x install.sh
   sudo ./install.sh
4. Menu lama tetap tersedia:
   [1] Install Panel
   [2] Install Wings
   [3] Install Panel + Wings (1 VPS)
   [4] Create Node
   [5] Check Status
   [6] Exit
5. Menu tambahan:
   [7] Install Protect
   [8] Uninstall Protect / Restore backup
   [9] Uninstall Panel

CATATAN KEAMANAN
- Letakkan protect-payload.tar.gz satu folder dengan install.sh.
- Menu Protect hanya untuk Panel v1.15.2. Versi lain akan ditolak.
- Sebelum memasang Protect, semua file PHP payload diperiksa dengan php -l.
- File asli Panel dibackup ke /var/backups/pterodactyl-protect/<timestamp>/.
- Uninstall Protect mengembalikan file dari backup aktual, bukan file default hardcoded.
- Jika proses penyalinan atau validasi PHP gagal, installer melakukan rollback.
- Uninstall Panel meminta konfirmasi eksplisit. Database dan data server dipertahankan secara default; keduanya hanya dihapus jika frasa konfirmasi khusus dimasukkan.
- Wings, Docker, MariaDB, Redis, PHP, Nginx, sertifikat SSL, dan firewall tidak dihapus oleh menu Uninstall Panel.

BATASAN YANG WAJIB DIPERHATIKAN
- Lulus bash -n dan php -l bukan jaminan runtime. Uji di VPS staging sebelum produksi.
- Protect 10 dan Protect 13 dalam source asli membatasi pengelolaan API Key dan 2FA hanya untuk user ID 1. Ini dapat menonaktifkan pengelolaan API Key/2FA bagi user biasa. Perilaku source Protect tidak diubah diam-diam dalam paket ini.
- Protect menggunakan asumsi akun admin utama adalah user ID 1. Pastikan hal tersebut benar di database Panel sebelum dipakai.
- Payload berasal dari kumpulan Protect 1-15. Protect 15 menulis path ServersController.php yang juga ditulis modul lain; paket ini mempertahankan hasil akhir penulisan berurutan sebagaimana ekstraksi modul, sehingga file yang terakhir menang.
- Pengujian dilakukan offline pada source Panel v1.15.2. Belum dilakukan instalasi atau uji runtime pada VPS milik pengguna.
