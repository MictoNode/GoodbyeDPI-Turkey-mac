# GoodbyeDPI-Turkey — macOS Sürümü

Bu klasör, [GoodbyeDPI-Turkey](../README.md) projesinin macOS karşılığını içerir.
Windows tarafındaki `src/` ve `windows/` klasörleri olduğu gibi durmaktadır;
bu macOS port'u onları hiçbir şekilde değiştirmez.

## Önemli farklar (önce bunları okuyun)

GoodbyeDPI, Windows'a özel olan **WinDivert** sürücüsünü kullanır. macOS'ta
böyle bir sürücü yoktur, bu yüzden tam aynı kod buraya taşınamaz. Onun
yerine bu port, aynı DPI atlatma tekniklerini saf userspace SOCKS5 proxy
olarak uygulayan **[byedpi (`ciadpi`)](https://github.com/hufrea/byedpi)**
aracını kullanır.

Sonuçlar olarak:

- TLS ClientHello bölme (`--split`), ters sıralı segment gönderme
  (`--disorder`), TLS kayıt bölme (`--tlsrec`), OOB byte (`--oob`) ve
  HTTP başlık karıştırma (`--mod-http`) **çalışır**.
- Windows'ta GoodbyeDPI'ın kullandığı **"sahte paket + düşük TTL"**
  hilesi (`--set-ttl`, `--auto-ttl`, `--fake-from-hex`) byedpi'da BSD/macOS
  için desteklenmez. Onun yerine yukarıdaki tekniklerin daha agresif
  kombinasyonu kullanılır.
- Tüm scripts'ler ve hizmet yapısı, Windows tarafındaki .cmd dosyalarını
  bire bir mantıkla yansıtır (tek seferlik çalıştırma + `launchd`
  LaunchDaemon ile otomatik başlatma).

Eğer kullandığınız ISS bu macOS sürümünde belirli sitelerle çalışmıyorsa,
Windows'ta da işe yarayan TTL-tabanlı yöntemler tek başına çalışıyor olabilir.
O durumda alternatif olarak şu projelere de göz atabilirsiniz: **SpoofDPI**,
**Throne** (TUN tabanlı, Roblox/Discord için byedpi'yi sarmalar), **zapret**.

## Hızlı Başlangıç (önerilen — Discord + engelli siteler)

Tek amaç Discord'a (güncellemeleri dahil) ve engelli sitelere girmekse
aşağıdaki akışı sırayla uygulayın. Bu akış **split tunnel** kullanır: yalnızca
`macos/split-tunnel-domains.txt` listesindeki siteler proxy'den geçer, diğer
her site doğrudan bağlanır (bozulmaz/yavaşlamaz). Ayrıntılar aşağıdaki
bölümlerde.

```bash
# Ön koşullar (bir kez): Xcode Command Line Tools + Homebrew
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 1. İndir ve derle (ciadpi'yi üretir)
git clone https://github.com/MictoNode/GoodbyeDPI-Turkey-mac.git
cd GoodbyeDPI-Turkey-mac
./macos/build.sh

# 2. Hizmeti kur — her açılışta otomatik başlar
sudo ./macos/scripts/service_install_dnsredir_turkey.sh

# 3. Split tunnel'ı aç — PAC + GOST köprüsü + GUI env'ini kurar
brew install gost
sudo ./macos/scripts/split_tunnel.sh on

# 4. Discord'u normal şekilde açın (Dock / Finder). Çalışıyorsa bir kez
#    kapatıp yeniden açın — env yalnızca sonradan açılan uygulamaları etkiler.
```

Kaldırmak için:

```bash
sudo ./macos/scripts/split_tunnel.sh off     # env + PAC + GOST kapatılır
sudo ./macos/scripts/service_remove.sh       # hizmet + ağ ayarları geri alınır
```

## Gereksinimler

- macOS 12 (Monterey) veya üstü, Intel veya Apple Silicon.
- Xcode Command Line Tools: `xcode-select --install`
- Yönetici (sudo) şifresi.
- [Discord desteği için] GOST: `brew install gost` (yalnızca
  `split_tunnel.sh on` kullanacaksanız gerekir).

## Kurulum (kaynaktan)

```bash
git clone https://github.com/MictoNode/GoodbyeDPI-Turkey-mac.git
cd GoodbyeDPI-Turkey-mac
./macos/build.sh
```

`build.sh`:

1. byedpi kaynak kodunu `macos/third_party/byedpi` altına klonlar (ilk seferde),
2. `ciadpi` ikilisini derler,
3. Derlenen ikiliyi `macos/bin/ciadpi`'ye kopyalar.

## Kullanım — Tek Seferlik (Windows'taki `turkey_dnsredir.cmd` karşılığı)

Aşağıdakilerden birini terminalde çalıştırın. Script root yetkisi ister, gerekirse
otomatik olarak `sudo` ile yeniden başlar. Ctrl-C ile çıktığınızda SOCKS proxy
ve DNS ayarları **otomatik olarak eski haline döner**.

```bash
sudo ./macos/scripts/turkey_dnsredir.sh                                  # varsayılan yöntem (Yandex DNS)
sudo ./macos/scripts/turkey_dnsredir_alternative_superonline.sh          # DNS değiştirmez
sudo ./macos/scripts/turkey_dnsredir_alternative2_superonline.sh         # DNS değiştirmez
sudo ./macos/scripts/turkey_dnsredir_alternative3_superonline.sh         # Yandex DNS
sudo ./macos/scripts/turkey_dnsredir_alternative4_superonline.sh         # Yandex DNS
sudo ./macos/scripts/turkey_dnsredir_alternative5_superonline.sh         # Yandex DNS
sudo ./macos/scripts/turkey_dnsredir_alternative6_superonline.sh         # DNS değiştirmez
```

## Kullanım — Hizmet Olarak (Windows'taki `service_install_*.cmd` karşılığı)

Bilgisayar açıldığında otomatik başlayan bir LaunchDaemon kurar:

```bash
sudo ./macos/scripts/service_install_dnsredir_turkey.sh                  # varsayılan
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative_superonline.sh
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative2_superonline.sh
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative3_superonline.sh
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative4_superonline.sh
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative5_superonline.sh
sudo ./macos/scripts/service_install_dnsredir_turkey_alternative6_superonline.sh
```

Kaldırmak için (proxy ve DNS ayarlarını da eski haline döndürür):

```bash
sudo ./macos/scripts/service_remove.sh
```

Hizmetin durumunu kontrol etmek için:

```bash
sudo launchctl print system/com.cagritaskn.goodbyedpi-turkey
tail -f /var/log/goodbyedpi-turkey.log
```

## Split tunnel — sadece belirli siteleri ciadpi'den geçirme

Yukarıdaki scripts'ler sistem geneli SOCKS proxy'si kurar, yani **tüm** TLS
trafiği desync'ten geçer. Bu, engelli olmayan siteleri de bozabilir: bölünmüş
ClientHello'yu reddeden sunucular olur (`sahibinden.com` → `sslv3 alert
illegal parameter`, `vercel.com` → timeout).

`split_tunnel.sh`, sistem geneli SOCKS ayarını bir PAC dosyasıyla değiştirir;
sadece `macos/split-tunnel-domains.txt` içindeki domainler ciadpi'ye gider,
kalan her şey doğrudan bağlanır. Bir `service_install_*` scripti kurduktan
sonra çalıştırın:

```bash
sudo ./macos/scripts/split_tunnel.sh on      # PAC'a geç
sudo ./macos/scripts/split_tunnel.sh status  # servis servis mevcut durum
sudo ./macos/scripts/split_tunnel.sh off     # sistem geneli SOCKS'a dön
```

Domain listesi ilk çalıştırmada `/usr/local/etc/goodbyedpi-turkey/` altına
kopyalanır; listeyi orada düzenleyip tekrar `on` çalıştırın. Bir sitenin
gerçekten engelli olup olmadığını `curl -s -o /dev/null -w "%{http_code}"
--noproxy '*' https://site` ile kontrol edin — `000` dönüyorsa listeye ekleyin.

`on` komutu, eşleşen domainleri `PROXY 127.0.0.1:8080` (GOST, HTTP->SOCKS5
köprüsü) üzerinden ciadpi'ye yönlendiren bir PAC üretir ve GOST'u launchd
servisi olarak kurup başlatır. GOST gerekli: `brew install gost` (Discord
güncelleyicisi SOCKS5 kullanamaz; ayrıntı: [Discord Desktop desteği](#discord-desktop-desteği)).

DNS de bölünür: `on` komutu sistem genelindeki Yandex DNS'i kaldırıp yerine
listedeki her domain için `/etc/resolver/<domain>` dosyası yazar. Böylece
yalnızca o domainler (ciadpi'nin kendi çözümlemesi dahil) Yandex üzerinden
çözülür; geri kalan tüm trafik DHCP/ISS resolver'ını kullanır ve DNS sızıntısı
olmaz. `off` komutu bu dosyaları kaldırıp tam tünel DNS'ini geri getirir.

## Yöntem ↔ Argüman Eşlemesi

| Yöntem (Windows)                          | Windows args                       | macOS byedpi args                                          | DNS         |
|-------------------------------------------|------------------------------------|------------------------------------------------------------|-------------|
| `turkey_dnsredir`                         | `-5 --set-ttl 5 --dns-addr Y`      | `--split 1+s --disorder 3+s --tlsrec 3+s --mod-http h,d`   | Yandex      |
| `turkey_dnsredir_alternative_superonline` | `--set-ttl 3`                      | `--disorder 3+s --tlsrec 3+s`                              | değiştirmez |
| `turkey_dnsredir_alternative2_*`          | `-5`                               | `--split 1+s --disorder 3+s --mod-http h,d`                | değiştirmez |
| `turkey_dnsredir_alternative3_*`          | `--set-ttl 3 --dns-addr Y`         | `--disorder 1+s --tlsrec 1+s`                              | Yandex      |
| `turkey_dnsredir_alternative4_*`          | `-5 --dns-addr Y`                  | `--split 1+s --disorder 3+s --mod-http h,d`                | Yandex      |
| `turkey_dnsredir_alternative5_*`          | `-9 --dns-addr Y`                  | `--split 1+s --tlsrec 1+s --mod-http h,d`                  | Yandex      |
| `turkey_dnsredir_alternative6_*`          | `-9`                               | `--split 1+s --tlsrec 1+s`                                 | değiştirmez |

> `h,d` = `hcsmix,dcsmix` (HTTP Host başlığını karıştırır)
> Y = Yandex DNS (`77.88.8.8` / `77.88.8.1`)
>
> Bu eşlemeleri kendi ISS'niz için iyileştirmek isterseniz
> `macos/scripts/_lib.sh` içindeki `method_args` fonksiyonunu düzenleyin —
> tüm scripts'ler bu fonksiyonu paylaşır.

## Ayarları manuel inceleme

```bash
# Aktif servisin adını bulun (Wi-Fi, Ethernet, ...)
networksetup -listallnetworkservices

# Mevcut SOCKS proxy + DNS durumunu görün
networksetup -getsocksfirewallproxy "Wi-Fi"
networksetup -getdnsservers          "Wi-Fi"

# Geri al (eğer scripts ile değil de elle ayarladıysanız)
sudo networksetup -setsocksfirewallproxystate "Wi-Fi" off
sudo networksetup -setdnsservers              "Wi-Fi" Empty
```

## Sorun giderme

- **"Operation not permitted" hatası**: Script'i mutlaka `sudo` ile çalıştırın.
  Script kendiliğinden sudo'ya geçer ama yine de yönetici şifresi sorulur.
- **"ciadpi bulunamadı"**: Önce `./macos/build.sh` çalıştırın.
- **Uygulamalar proxy'i kullanmıyor**: macOS'taki sistem genelinde SOCKS proxy
  ayarı çoğu uygulama tarafından otomatik kullanılır. Bazı uygulamalar
  (örn. Chrome belirli sürümler, bazı oyunlar) sistem proxy'sini yok sayar.
  Bu durumda söz konusu uygulamanın ayarlarından proxy'yi elle
  `127.0.0.1:1080` olarak ayarlamanız gerekebilir.
- **DNS sızıntısı**: Tam tünel modunda sistem DNS'i kasıtlı olarak Yandex'e
  ayarlanır (ISS resolver'ı engelli domainleri blok IP'sine çözdüğü için).
  Split tunnel modunda ise Yandex yalnızca listedeki domainlere `/etc/resolver/`
  dosyalarıyla uygulanır; geri kalan trafik ISS resolver'ını kullanır, sızıntı
  olmaz. Sızıntı testi hâlâ Yandex gösteriyorsa `split_tunnel.sh off` sonra
  `on` çalıştırıp DNS'i yeniden bölün.

## Discord Desktop desteği

Discord'un iki ayrı ağ bileşeni vardır ve ikisi de farklı proxy mekanizması
kullanır:

- **Uygulamanın kendisi** (Electron/Chromium) sistem PAC'ini izler.
- **Güncelleyicisi** (Squirrel) sistem PAC'ini **tamamen yok sayar**; yalnızca
  `HTTP_PROXY`/`HTTPS_PROXY` gibi ortam değişkenlerini dinler.

Bu yüzden `split_tunnel.sh on` iki şeyi birden kurar:

1. **PAC** — listedeki domainleri `PROXY 127.0.0.1:8080` üzerinden ciadpi'ye
   yönlendirir (uygulama için).
2. **GUI env köprüsü** — GOST adresini `launchctl setenv` ile oturumun ortam
   değişkenlerine ekler ve oturum açılışında tekrar uygulayan bir LaunchAgent
   kurar (`/Library/LaunchAgents/…-gost-env.plist`). GUI uygulamaları ortamı
   launchd oturumundan aldığı için, Discord'u Dock'tan açsanız bile güncelleyici
   proxy'yi görür. Güncelleme sonrası Discord'u yeniden başlatan süreç de aynı
   oturum ortamından geçtiği için env kaybolmaz — scripte dönmek gerekmez.

Bağlantı akışı:

```text
Discord uygulaması (Chromium)          Discord güncelleyici (Squirrel)
   |  sistem PAC'i                          |  oturum HTTP_PROXY env'i
   +---------------------+------------------+
                         v
              GOST HTTP proxy :8080 (launchd, KeepAlive)
                         |
                         | SOCKS5 :1080
                         v
              ciadpi (launchd, KeepAlive)
                         |
                         v
                      Internet
```

Kurulum (tek seferlik):

```bash
brew install gost
./macos/build.sh
sudo ./macos/scripts/service_install_dnsredir_turkey.sh   # ciadpi'yi servis olarak kurar
sudo ./macos/scripts/split_tunnel.sh on                   # PAC + GOST + GUI env köprüsü
```

`split_tunnel.sh on`, GOST köprüsünü ve env köprüsünü kurup başlatır.
Ardından Discord'u bir kez kapatıp normal şekilde (Finder, dock) yeniden
açın — env yalnızca sonradan açılan uygulamaları etkiler.

Kaldırmak için:

```bash
sudo ./macos/scripts/split_tunnel.sh off   # env köprüsü + PAC + GOST kapatılır
sudo ./macos/scripts/service_remove.sh     # her şey kaldırılır
```

Notlar:

- `split_tunnel.sh on` GOST bulamazsa hata verir; önce `brew install gost`.
- PAC'i düzenlemek isterseniz domainleri
  `macos/split-tunnel-domains.txt` içinde değiştirip `split_tunnel.sh on`
  komutunu tekrar çalıştırın.
- Env değişkenleri tüm GUI uygulamalarının oturumuna eklenir; yalnızca ortam
  değişkenlerini okuyan uygulamalar etkilenir (Discord güncelleyicisi gibi).
  Chromium tabanlı uygulamalar env'i yok sayıp PAC'i kullanır.
