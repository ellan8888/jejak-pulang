# Jejak Pulang

Aplikasi iPhone untuk merekam jalan waktu pergi ke lokasi yang tidak ada di Google Maps, lalu membuat navigasi Google Maps untuk pulang lewat jalan yang sama.

## Cara pakai

1. **Sebelum berangkat**, buka Jejak Pulang lalu tekan **Mulai Rekam**. Izinkan akses lokasi. Setelah itu boleh kunci layar atau buka aplikasi lain, rekaman tetap jalan (ada indikator biru di status bar).
2. **Sampai di lokasi**, tekan **Sampai — Selesai & Simpan**, lalu beri nama.
3. **Mau pulang**: buka rute itu → **Pulang lewat rute ini**.
   - Aplikasi membalik rute, mendeteksi belokan, dan menaruh titik singgah sedikit sesudah tiap belokan.
   - Tekan **Buka di Google Maps**. Kalau belokannya lebih dari 9, rute dipecah jadi **Bagian 1, 2, …**. Buka bagian berikutnya setelah sampai di akhir bagian sebelumnya.
   - **Tambah titik**: ketuk garis rute di peta untuk memaksa lewat jalan tertentu.
   - **Kepekaan belokan** dan sakelar tiap titik bisa diatur kalau rutenya kurang pas.
4. **Pergi lagi ke lokasi ini** memakai rekaman yang sama ke arah semula.

Fitur lain: impor/ekspor file GPX, rekaman yang terputus bisa dipulihkan kalau aplikasi tertutup paksa, dan peringatan untuk bagian yang sinyal GPS-nya hilang.

## Memasang di iPhone (gratis, lewat SideStore)

Aplikasinya di-build otomatis oleh GitHub Actions setiap ada perubahan. File `.ipa` terbaru selalu ada di:

**https://github.com/ellan8888/jejak-pulang/releases/latest**

### Sekali saja di awal
1. Pasang **SideStore** di iPhone dengan mengikuti panduan resminya: https://docs.sidestore.io (butuh laptop Windows/Mac/Linux hanya untuk langkah ini, plus Apple ID gratis).
2. Di iPhone, aktifkan **Mode Pengembang**: Pengaturan → Privasi & Keamanan → Mode Pengembang → Nyala, lalu restart.

### Memasang Jejak Pulang
1. Buka link Releases di atas lewat Safari, unduh **JejakPulang.ipa**, dan simpan ke Files.
2. Buka **SideStore** → **My Apps** → tombol **+**, lalu pilih `JejakPulang.ipa`.
3. Buka Jejak Pulang dan izinkan akses lokasi.

*Opsional:* supaya update bisa muncul di SideStore, tambahkan source:
`https://github.com/ellan8888/jejak-pulang/releases/download/latest/source.json`

### Tiap 7 hari
Aplikasi dari Apple ID gratis berlaku 7 hari. Buka SideStore → **My Apps** → **Refresh All** (VPN pendamping SideStore harus aktif). Data rute tidak hilang selama aplikasinya tidak dihapus.

> Akun Apple gratis maksimal 3 aplikasi aktif, termasuk SideStore sendiri.

## Struktur proyek

| Folder | Isi |
|---|---|
| `RouteCore/` | Logika inti (Swift Package, dites otomatis): model rute, pembersihan GPS, deteksi belokan, pemilihan titik singgah, pemecahan link, URL Google Maps, GPX, penyimpanan. |
| `JejakPulang/` | Aplikasi SwiftUI: perekam GPS (background), daftar rute, layar Pulang. |
| `project.yml` | Definisi proyek Xcode (XcodeGen). |
| `.github/workflows/build.yml` | Tes → build `.ipa` tanpa tanda tangan → rilis `latest`. |

Build lokal di Mac: `brew install xcodegen && xcodegen generate && open JejakPulang.xcodeproj`.
