#!/usr/bin/env bash
# Debian 13 + Secure Boot: NVIDIA DKMS modüllerini imzala (otomatik bağımlılık kurulumu)
set -e

# --- Root'a otomatik yüksel ---
if [ "$EUID" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# --- Senin anahtar yolların (MOK.key + MOK.der) ---
KEY_PRIV="/home/safakb/mok/MOK.key"
KEY_DER="/home/safakb/mok/MOK.der"

[ -f "$KEY_PRIV" ] || { echo "HATA: $KEY_PRIV yok"; exit 1; }
[ -f "$KEY_DER"  ] || { echo "HATA: $KEY_DER yok";  exit 1; }

KREL="$(uname -r)"
KMAJMIN="$(uname -r | awk -F. '{print $1"."$2}')"

APT_INSTALL() {
  # apt varsa sessiz kurulum
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$@"
  else
    echo "HATA: apt bulunamadı. Bu script Debian/Ubuntu içindir."
    exit 1
  fi
}

# --- Bağımlılıkları kur: kmodsign (linux-kbuild), xz, zstd ---
KSIGN="/usr/lib/linux-kbuild-$KMAJMIN/kmodsign"
if [ ! -x "$KSIGN" ]; then
  # Maj.Min sürüme göre dene, olmazsa sadece major (örn. 6) dene
  APT_INSTALL "linux-kbuild-$KMAJMIN" || APT_INSTALL "linux-kbuild-$(echo "$KMAJMIN" | cut -d. -f1)"
fi
# xz ve zstd gerekebilir
command -v xz   >/dev/null 2>&1 || APT_INSTALL xz-utils
command -v zstd >/dev/null 2>&1 || APT_INSTALL zstd

# kmodsign yolunu kesinleştir
if [ -x "/usr/lib/linux-kbuild-$KMAJMIN/kmodsign" ]; then
  KSIGN="/usr/lib/linux-kbuild-$KMAJMIN/kmodsign"
elif command -v kmodsign >/dev/null 2>&1; then
  KSIGN="$(command -v kmodsign)"
else
  echo "HATA: kmodsign bulunamadı. linux-kbuild paketinin kurulumu başarısız."
  exit 1
fi

# --- NVIDIA modül dizin adayları ---
DIRS=(
  "/lib/modules/$KREL/updates/dkms"
  "/lib/modules/$KREL/extra"
  "/lib/modules/$KREL/kernel/drivers/video"
  "/lib/modules/$KREL/kernel/drivers/gpu"
)

# Modülleri topla (.ko / .ko.xz / .ko.zst)
mods=()
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r p; do mods+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko*' 2>/dev/null || true)
done

if [ "${#mods[@]}" -eq 0 ]; then
  echo "HATA: NVIDIA modülü bulunamadı. (nvidia-dkms/nvidia-driver kurulu mu?)"
  exit 2
fi

# Sıkıştırılmışları aç
need_zstd=false
for f in "${mods[@]}"; do
  case "$f" in
    *.ko.xz)  echo "Açılıyor: $f"; xz  -df "$f" ;;
    *.ko.zst) echo "Açılıyor: $f"; if command -v zstd >/dev/null 2>&1; then zstd -df "$f"; else need_zstd=true; fi ;;
  esac
done
$need_zstd && { echo "HATA: .zst var ama zstd kurulumunda sorun oluştu."; exit 1; }

# Sadece .ko'ları yeniden listele
mods_ko=()
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r p; do mods_ko+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko' 2>/dev/null || true)
done
[ "${#mods_ko[@]}" -gt 0 ] || { echo "HATA: .ko dosyası bulunamadı."; exit 3; }

# İmzalama
for ko in "${mods_ko[@]}"; do
  echo "İmzalanıyor: $ko"
  "$KSIGN" sha256 "$KEY_PRIV" "$KEY_DER" "$ko"
done

# Sistem bilgilerini güncelle
depmod -a
update-initramfs -u

# Doğrulama
echo "Doğrulama:"
for ko in "${mods_ko[@]}"; do
  printf "%s -> " "$(basename "$ko")"
  modinfo "$ko" | grep -m1 '^signer' || echo "signer yok"
done

echo "Bitti. Gerekirse: reboot"
