#!/usr/bin/env bash
# minimal-sign.sh — Debian 13 + Secure Boot: NVIDIA modüllerini imzalar (en sade hâl)

set -e

KEY_PRIV="/home/safakb/mok/MOK.priv"
KEY_DER="/home/safakb/mok/MOK.der"
KREL="$(uname -r)"
MOD_DIR="/lib/modules/$KREL/updates/dkms"

# Ön kontroller
command -v kmodsign >/dev/null 2>&1 || { echo "kmodsign yok: sudo apt update && sudo apt install -y kmod"; exit 1; }
[ -f "$KEY_PRIV" ] || { echo "Anahtar yok: $KEY_PRIV"; exit 1; }
[ -f "$KEY_DER" ]  || { echo "Anahtar yok: $KEY_DER";  exit 1; }
[ -d "$MOD_DIR" ]  || { echo "Modül dizini yok: $MOD_DIR"; exit 1; }

cd "$MOD_DIR"

# Varsa sıkıştırılmışları aç (hata verirse yok say)
sudo xz   -df nvidia*.ko.xz  2>/dev/null || true
sudo zstd -df nvidia*.ko.zst 2>/dev/null || true

# İmzalama
for m in nvidia*.ko; do
  [ -f "$m" ] || continue
  echo "Signing $PWD/$m"
  sudo kmodsign sha256 "$KEY_PRIV" "$KEY_DER" "$m"
done

# Sistem güncelle
sudo depmod -a
sudo update-initramfs -u

# Basit doğrulama
for m in nvidia*.ko; do
  [ -f "$m" ] || continue
  printf "%s -> " "$m"
  modinfo "$m" | grep -m1 '^signer' || echo "signer yok"
done

echo "Bitti. Gerekirse: sudo reboot"
