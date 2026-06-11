# Spiker Kurulum Paketleri

Bu repo, Spiker uygulamasının herkese açık Windows kurulum paketini yayınlar.

Spiker, Windows için Türkçe SAPI5 sesidir. Kurulumdan sonra ekran okuyucular ve SAPI5 destekleyen uygulamalar içinde `Spiker` sesini seçerek kullanabilirsiniz.

## Hızlı Kurulum

En kolay yöntem:

1. `Windows + R` tuşlarına basın.
2. Açılan Çalıştır penceresine şu komutu yapıştırın.
3. Enter'a basın ve açılan Spiker kurulum penceresini takip edin.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/hasan-ozdemir/spiker-setup/main/spiker-setup.ps1 | iex"
```

Bu komut, bu repodaki küçük `spiker-setup.ps1` wrapper scriptini indirip çalıştırır. Wrapper, GitHub API üzerinden `main` dalının son commit SHA'sını alır ve gerçek kurulum iş akışını o committeki `spiker-setup-downloader.ps1` dosyasına devreder. Script Windows PowerShell 5.1 ve yönetici izni gerektirir; gerekirse kendini bu oturumda yeniden başlatır ve Windows izin penceresini açar. İzin verdikten sonra en son yayınlanan sıkıştırılmış `spiker-setup.exe` dosyası `%LOCALAPPDATA%\Temp\spiker-setup` klasörüne indirilir.

Kurulum paketi arada 7-Zip penceresi göstermeden sessizce açılır ve Spiker kurulum asistanı başlar. Kurulum asistanı açıldığında PowerShell penceresi otomatik gizlenir. Kurulum başarıyla tamamlandığında geçici `%LOCALAPPDATA%\Temp\spiker-setup` klasörü içindeki dosyalarla birlikte silinir.

## Elle İndirme

Komut kullanmak istemezseniz:

1. Bu repodaki Releases bölümünü açın.
2. En son release içindeki `spiker-setup.exe` dosyasını indirin.
3. Dosyayı çalıştırın ve kurulum penceresini takip edin.

Güncel release:

https://github.com/hasan-ozdemir/spiker-setup/releases/download/latest/spiker-setup.exe

## Kurulumdan Sonra

Kurulum tamamlandığında Spiker, Windows'a SAPI5 sesi olarak eklenir. Kullandığınız ekran okuyucu veya konuşma uygulamasının ses ayarlarından `Spiker` sesini seçebilirsiniz.

Kurulum paketi `C:\prodyum\spiker` altına kurulur. Mevcut ayarlar korunur; güncelleme sırasında `spiker.ini` ve `logs` klasörü silinmez.

## Güvenlik Notu

`spiker-setup.ps1` yalnızca bu repodaki `latest` release alias'ı altındaki `spiker-setup.exe` dosyasını indirir. İndirme HTTPS üzerinden yapılır. Script, sıkıştırılmış dış paketin değil gerçek Spiker kurulum asistanının çıkış sonucunu kontrol eder; kullanıcı isteğiyle kapatma normal kabul edilir, gerçek kurulum hataları hangi adımda ne beklenirken ne olduğu bilgisiyle bildirilir. İndirme tamamlanana kadar geçici `.download` dosyası kullanılır; başarılı kurulumdan sonra geçici kurulum dosyaları silinir, başarısız kurulumda `%LOCALAPPDATA%\Temp\spiker-setup` klasörü tanılama için bırakılır.

## Yayın Akışı

Özel `hasan-ozdemir/spiker` reposunda `main` dalına yapılan her push yeni `spiker-setup.exe` paketini üretir. Bu public repo son kurulumu `latest` release alias'ı altında yayınlar. Eski version release'ler normalde temizlenir; `release-pins.json` içinde pinlenen release tag'leri korunur.
