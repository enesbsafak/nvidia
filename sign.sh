#!/usr/bin/env bash
# Debian 13 + Secure Boot: NVIDIA DKMS modüllerini imzala (otomatik bağımlılıklar, kmodsign/sign-file fallback)
set -euo pipefail

# --- Root'a otomatik yüksel ---
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# --- Anahtar yolları (senin dosyaların) ---
KEY_PRIV="/home/safakb/mok/MOK.key"
KEY_DER="/home/safakb/mok/MOK.der"

[[ -f "$KEY_PRIV" ]] || { echo "HATA: $KEY_PRIV yok"; exit 1; }
[[ -f "$KEY_DER"  ]] || { echo "HATA: $KEY_DER yok";  exit 1; }

KREL="$(uname -r)"
KMAJMIN="$(awk -F. '{print $1"."$2}' <<<"$KREL")"

APT(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

# --- Gerekli araçlar: xz, zstd, headers, kbuild (opsiyonel) ---
command -v xz   >/dev/null 2>&1 || APT xz-utils
command -v zstd >/dev/null 2>&1 || APT zstd
dpkg -s "linux-headers-$KREL" >/dev/null 2>&1 || APT "linux-headers-$KREL"
# kmodsign bazı sürümlerde yok olabilir, ama deneriz:
dpkg -s "linux-kbuild-$KMAJMIN" >/dev/null 2>&1 || APT "linux-kbuild-$KMAJMIN" || true

# --- İmzalama aracını belirle: kmodsign varsa onu, yoksa sign-file ---
KSIGN=""
if [[ -x "/usr/lib/linux-kbuild-$KMAJMIN/kmodsign" ]]; then
  KSIGN="/usr/lib/linux-kbuild-$KMAJMIN/kmodsign"
elif command -v kmodsign >/dev/null 2>&1; then
  KSIGN="$(command -v kmodsign)"
fi

SIGN_FILE=""
if [[ -x "/usr/src/linux-headers-$KREL/scripts/sign-file" ]]; then
  SIGN_FILE="/usr/src/linux-headers-$KREL/scripts/sign-file"
fi

if [[ -z "$KSIGN" && -z "$SIGN_FILE" ]]; then
  echo "HATA: kmodsign ya da scripts/sign-file bulunamadı."
  echo "Lütfen şu paketlerin kurulu olduğundan emin ol: linux-headers-$KREL ve (varsa) linux-kbuild-$KMAJMIN"
  exit 1
fi

echo "[*] Kullanılacak imzalama aracı: $([[ -n "$KSIGN" ]] && echo kmodsign || echo sign-file)"

# --- NVIDIA modül dizin adayları ---
DIRS=(
  "/lib/modules/$KREL/updates/dkms"
  "/lib/modules/$KREL/extra"
  "/lib/modules/$KREL/kernel/drivers/video"
  "/lib/modules/$KREL/kernel/drivers/gpu"
)

# Modülleri topla (.ko/.ko.xz/.ko.zst)
mods=()
for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r p; do mods+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko*' 2>/dev/null || true)
done

if [[ ${#mods[@]} -eq 0 ]]; then
  echo "HATA: NVIDIA modülü bulunamadı. (nvidia-dkms/nvidia-driver kurulu mu?)"
  exit 2
fi

# Sıkıştırılmışları aç
need_zstd=false
for f in "${mods[@]}"; do
  case "$f" in
    *.ko.xz)  echo "[*] Açılıyor (xz): $f";  xz  -df "$f" ;;
    *.ko.zst) echo "[*] Açılıyor (zstd): $f"; if command -v zstd >/dev/null 2>&1; then zstd -df "$f"; else need_zstd=true; fi ;;
  esac
done
$need_zstd && { echo "HATA: .zst var ama zstd yok/çalışmıyor"; exit 1; }

# Yeniden sadece .ko'ları listele
mods_ko=()
for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r p; do mods_ko+=("$p"); done < <(find "$d" -type f -name 'nvidia*.ko' 2>/dev/null || true)
done
[[ ${#mods_ko[@]} -gt 0 ]] || { echo "HATA: .ko dosyası bulunamadı."; exit 3; }

# İmzalama (kmodsign öncelik; yoksa sign-file)
for ko in "${mods_ko[@]}"; do
  echo "[*] İmzalanıyor: $ko"
  if [[ -n "$KSIGN" ]]; then
    "$KSIGN" sha256 "$KEY_PRIV" "$KEY_DER" "$ko"
  else
    # sign-file: <hash> <priv> <x509.der> <module.ko>
    "$SIGN_FILE" sha256 "$KEY_PRIV" "$KEY_DER" "$ko"
  fi
done

# Sistem bilgisini güncelle
echo "[*] depmod + initramfs güncelleniyor…"
depmod -a
update-initramfs -u

# Doğrulama
echo "[*] Doğrulama:"
for ko in "${mods_ko[@]}"; do
  printf "%s -> " "$(basename "$ko")"
  modinfo "$ko" | grep -m1 '^signer' || echo "signer yok"
done

echo "[+] Bitti. Gerekirse: reboot"
