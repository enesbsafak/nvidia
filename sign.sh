#!/usr/bin/env bash
# Debian 13 + Secure Boot: NVIDIA DKMS modüllerini imzala
set -e

# --- Otomatik root ---
if [ "$EUID" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# --- Senin anahtarların ---
KEY_PRIV="/home/safakb/mok/MOK.priv"
KEY_DER="/home/safakb/mok/MOK.der"

# --- Kontroller ---
[ -f "$KEY_PRIV" ] || { echo "HATA: $KEY_PRIV yok"; exit 1; }
[ -f "$KEY_DER"  ] || { echo "HATA: $KEY_DER yok";  exit 1; }

KREL="$(uname -r)"
KMAJMIN="$(uname -r | awk -F. '{print $1"."$2}')"

# kmodsign yolu (önce linux-kbuild içi, sonra PATH)
KSIGN="/usr/lib/linux-kbuild-$KMAJMIN/kmodsign"
if [ ! -x "$KSIGN" ]; then
  if command -v kmodsign >/dev/null 2>&1; then
    KSIGN="$(command -v kmodsign)"
  else
    echo "HATA: kmodsign yok."
    echo "Kur:  apt update && apt install -y linux-kbuild-$KMAJMIN"
    exit 1
  fi
fi

# --- Modül dizin adayları ---
DIRS=(
  "/lib/modules/$KREL/updates/dkms"
  "/lib/modules/$KREL/extra"
  "/lib/modules/$KREL/kernel/drivers/video"
  "/lib/modules/$KREL/kernel/drivers/gpu"
)

# Modülleri topla
mods=()
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r p; do mods+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko*' 2>/dev/null || true)
done

# Benzersiz + var mı kontrol
if [ "${#mods[@]}" -eq 0 ]; then
  echo "HATA: NVIDIA modülü bulunamadı. (nvidia-dkms/nvidia-driver kurulu mu?)"
  exit 2
fi

# Sıkıştırılmışları aç
need_zstd=false
for f in "${mods[@]}"; do
  case "$f" in
    *.ko.xz)  echo "Açılıyor: $f"; xz  -df "$f" ;;  # xz-utils sistemlerde var
    *.ko.zst) echo "Açılıyor: $f"; if command -v zstd >/dev/null 2>&1; then zstd -df "$f"; else need_zstd=true; fi ;;
  esac
done
if $need_zstd; then
  echo "HATA: .zst dosyası var ama zstd yok. Kur: apt install -y zstd"
  exit 1
fi

# Yeniden liste (.ko'lara indirildi)
mods_ko=()
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r p; do mods_ko+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko' 2>/dev/null || true)
done
if [ "${#mods_ko[@]}" -eq 0 ]; then
  echo "HATA: .ko dosyası bulunamadı."
  exit 3
fi

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
