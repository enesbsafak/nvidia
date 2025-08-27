#!/usr/bin/env bash
# sign.sh - Debian 13 + Secure Boot için NVIDIA DKMS modüllerini imzalar.
# Tek komut: sudo bash ./sign.sh

set -euo pipefail

# --- Sana göre sabit yollar ---
KEY_PRIV="/home/safakb/mok/MOK.priv"
KEY_DER="/home/safakb/mok/MOK.der"

# --- Genel ayarlar ---
KREL="$(uname -r)"
CANDIDATE_DIRS=(
  "/lib/modules/$KREL/updates/dkms"
  "/lib/modules/$KREL/extra"
  "/lib/modules/$KREL/kernel/drivers/video"
  "/lib/modules/$KREL/kernel/drivers/gpu"
)

log(){ printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok(){  printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn(){printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }

# --- Ön kontrol ---
command -v kmodsign >/dev/null 2>&1 || err "kmodsign bulunamadı. 'sudo apt update && sudo apt install -y kmod' ile kur."
[[ -f "$KEY_PRIV" && -f "$KEY_DER" ]] || err "Anahtar(lar) yok:
  KEY_PRIV: $KEY_PRIV
  KEY_DER : $KEY_DER
MOK anahtarını önceden 'mokutil --import' ile enroll etmiş olmalısın."
command -v xz >/dev/null 2>&1 || warn "xz komutu bulunamadı (xz sıkıştırılmış modül varsa gerekli). 'sudo apt install -y xz-utils'."
command -v zstd >/dev/null 2>&1 || warn "zstd komutu yoksa .zst açılmaz. 'sudo apt install -y zstd'."

# --- Modülleri bul ---
find_modules() {
  local found=()
  for d in "${CANDIDATE_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r p; do found+=("$p"); done < <(
      find "$d" -type f \( -name "nvidia*.ko" -o -name "nvidia*.ko.xz" -o -name "nvidia*.ko.zst" \) 2>/dev/null || true
    )
  done
  printf '%s\n' "${found[@]}" | sort -u
}

# --- Sıkıştırılmış ise aç ---
decompress_if_needed() {
  local f="$1"
  case "$f" in
    *.ko) echo "$f";;
    *.ko.xz)
      log "Açılıyor (xz): $f"
      sudo xz -df "$f"
      echo "${f%.xz}"
      ;;
    *.ko.zst)
      if command -v zstd >/dev/null 2>&1; then
        log "Açılıyor (zstd): $f"
        sudo zstd -df "$f"
        echo "${f%.zst}"
      else
        err "zstd yok: $f açılamaz. 'sudo apt install -y zstd'."
      fi
      ;;
    *)
      err "Tanınmayan modül: $f"
      ;;
  esac
}

# --- İmzalama + Doğrulama ---
sign_one() {
  local ko="$1"
  log "İmzalanıyor: $ko"
  sudo kmodsign sha256 "$KEY_PRIV" "$KEY_DER" "$ko"
}

verify_one() {
  local ko="$1"
  local s; s="$(modinfo "$ko" 2>/dev/null | grep -m1 '^signer' || true)"
  if [[ -n "$s" ]]; then ok "$(basename "$ko") -> $s"; else warn "$(basename "$ko") -> signer yok"; fi
}

# --- Çalıştır ---
main() {
  log "NVIDIA modülleri aranıyor (kernel: $KREL)…"
  mapfile -t MODS_RAW < <(find_modules)
  [[ ${#MODS_RAW[@]} -gt 0 ]] || err "İmzalanacak NVIDIA modülü bulunamadı. (nvidia-dkms/nvidia-driver kurulu mu?)"

  declare -a KO_LIST=()
  for m in "${MODS_RAW[@]}"; do
    KO_LIST+=("$(decompress_if_needed "$m")")
  done

  for ko in "${KO_LIST[@]}"; do
    [[ -f "$ko" ]] || { warn "Dosya yok: $ko"; continue; }
    sign_one "$ko"
  done

  log "depmod + initramfs güncelleniyor…"
  sudo depmod -a
  sudo update-initramfs -u

  log "Doğrulama:"
  for ko in "${KO_LIST[@]}"; do
    [[ -f "$ko" ]] && verify_one "$ko"
  done

  ok "Bitti. Gerekirse: sudo reboot"
}

main
