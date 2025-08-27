#!/usr/bin/env bash
# sign-nvidia-secureboot.sh
# Debian (12/13) + Secure Boot altında NVIDIA DKMS modüllerini imzalar.
# İsteğe bağlı: Kernel güncellemesi sonrası otomatik imzalama hook'u kurar.
#
# Kullanım:
#   sudo bash sign-nvidia-secureboot.sh                 # Şimdi imzala
#   sudo bash sign-nvidia-secureboot.sh --verify        # Sadece imza kontrolü
#   sudo bash sign-nvidia-secureboot.sh --install-hook  # Kernel postinst hook kur
#   sudo bash sign-nvidia-secureboot.sh --uninstall-hook# Hook'u kaldır
#
# Varsayılan anahtar yolları: $HOME/mok/MOK.priv ve $HOME/mok/MOK.der
# Farklı yol vermek için:
#   KEY_PRIV=/yol/MOK.priv KEY_DER=/yol/MOK.der sudo -E bash sign-nvidia-secureboot.sh

set -euo pipefail

# === Ayarlar ===
KEY_PRIV="${KEY_PRIV:-$HOME/mok/MOK.priv}"
KEY_DER="${KEY_DER:-$HOME/mok/MOK.der}"

KREL="$(uname -r)"
# DKMS modülleri genelde burada; yine de birden fazla konumu tarıyoruz:
CANDIDATE_DIRS=(
  "/lib/modules/$KREL/updates/dkms"
  "/lib/modules/$KREL/extra"
  "/lib/modules/$KREL/kernel/drivers/video"
  "/lib/modules/$KREL/kernel/drivers/gpu"
)

HOOK_PATH="/etc/kernel/postinst.d/zz-nvidia-secureboot-sign"
SELF="$(readlink -f "$0")"

log(){ printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok(){  printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn(){printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }

need_root(){
  if [[ $EUID -ne 0 ]]; then
    err "Root gerekli. 'sudo bash $SELF' şeklinde çalıştır."
    exit 1
  fi
}

check_prereqs(){
  command -v kmodsign >/dev/null 2>&1 || {
    err "kmodsign bulunamadı. Kurulum için: sudo apt update && sudo apt install -y kmod"
    exit 1
  }
  [[ -f "$KEY_PRIV" && -f "$KEY_DER" ]] || {
    err "Anahtar(lar) bulunamadı:
  KEY_PRIV: $KEY_PRIV
  KEY_DER : $KEY_DER
Not: MOK anahtarını önceden 'mokutil --import' ile enroll etmiş olmalısın."
    exit 1
  }
}

find_modules(){
  # nvidia.ko, nvidia-*.ko, nvidia-peermem.ko vb.; sıkıştırılmış olanları da yakala
  local found=()
  for d in "${CANDIDATE_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r p; do found+=("$p"); done < <(find "$d" -type f \( -name "nvidia*.ko" -o -name "nvidia*.ko.xz" -o -name "nvidia*.ko.zst" \) 2>/dev/null || true)
  done
  printf '%s\n' "${found[@]}" | sort -u
}

decompress_if_needed(){
  local f="$1"
  case "$f" in
    *.ko) echo "$f";;
    *.ko.xz)
      log "Açılıyor: $f"
      xz -df "$f"
      echo "${f%.xz}"
      ;;
    *.ko.zst)
      if command -v zstd >/dev/null 2>&1; then
        log "Açılıyor: $f"
        zstd -df "$f"
        echo "${f%.zst}"
      else
        err "zstd yok ama .zst dosyası var: $f  -> sudo apt install -y zstd"
        exit 1
      fi
      ;;
    *)
      err "Tanınmayan uzantı: $f"; exit 1;;
  esac
}

sign_module(){
  local ko="$1"
  log "İmzalanıyor: $ko"
  kmodsign sha256 "$KEY_PRIV" "$KEY_DER" "$ko"
}

verify_module(){
  local ko="$1"
  local s
  s="$(modinfo "$ko" 2>/dev/null | grep -m1 '^signer' || true)"
  if [[ -n "$s" ]]; then
    ok "$(basename "$ko") -> $s"
  else
    warn "$(basename "$ko") -> signer bilgisi yok"
  fi
}

run_sign(){
  need_root
  check_prereqs

  local mods raw ko signed=0
  raw="$(find_modules || true)"
  if [[ -z "$raw" ]]; then
    err "İmzalanacak NVIDIA modülü bulunamadı. DKMS kurulumu doğru mu? (nvidia-driver / nvidia-dkms paketi)"
    exit 2
  fi

  mapfile -t mods <<<"$raw"

  declare -a KO_LIST=()
  for m in "${mods[@]}"; do
    ko="$(decompress_if_needed "$m")"
    KO_LIST+=("$ko")
  done

  for ko in "${KO_LIST[@]}"; do
    sign_module "$ko" && ((signed++)) || warn "İmzalanamadı: $ko"
  done

  log "depmod + initramfs güncelleniyor…"
  depmod -a
  update-initramfs -u

  ok "$signed adet modül imzalandı."
  log "Doğrulama:"
  for ko in "${KO_LIST[@]}"; do verify_module "$ko"; done

  ok "Bitti. Gerekirse: sudo reboot"
}

install_hook(){
  need_root
  check_prereqs

  cat > "$HOOK_PATH" <<'HOOK'
#!/usr/bin/env bash
# Kernel güncellemesi sonrası NVIDIA modüllerini imzala (Secure Boot)
set -euo pipefail

KEY_PRIV="${KEY_PRIV:-/root/mok/MOK.priv}"
KEY_DER="${KEY_DER:-/root/mok/MOK.der}"

SELF_SCRIPT="/usr/local/sbin/sign-nvidia-secureboot.sh"

if [[ -x "$SELF_SCRIPT" ]]; then
  # Anahtarlar root altında değilse HOME altını dene (yaygın kullanım)
  if [[ ! -f "$KEY_PRIV" || ! -f "$KEY_DER" ]]; then
    KEY_PRIV="${KEY_PRIV:-$HOME/mok/MOK.priv}"
    KEY_DER="${KEY_DER:-$HOME/mok/MOK.der}"
  fi
  KEY_PRIV="$KEY_PRIV" KEY_DER="$KEY_DER" bash "$SELF_SCRIPT" >/var/log/nvidia-secureboot-sign.log 2>&1 || true
fi
HOOK

  chmod +x "$HOOK_PATH"

  # Script’i sisteme kopyala ki hook çalıştırabilsin:
  install -Dm755 "$SELF" /usr/local/sbin/sign-nvidia-secureboot.sh

  ok "Hook kuruldu: $HOOK_PATH"
  ok "Bu makinada kernel güncellemesinden sonra otomatik imzalama çalışacaktır."
}

uninstall_hook(){
  need_root
  rm -f "$HOOK_PATH" /usr/local/sbin/sign-nvidia-secureboot.sh
  ok "Hook ve yardımcı script kaldırıldı."
}

verify_only(){
  local raw mods
  raw="$(find_modules || true)"
  if [[ -z "$raw" ]]; then
    err "Modül bulunamadı."
    exit 2
  fi
  mapfile -t mods <<<"$raw"
  for m in "${mods[@]}"; do
    [[ "$m" == *.xz || "$m" == *.zst ]] && warn "$(basename "$m") sıkıştırılmış; önce imzalama gerekir."
    [[ "$m" == *.ko ]] && verify_module "$m"
  done
}

case "${1:-}" in
  --install-hook)   install_hook ;;
  --uninstall-hook) uninstall_hook ;;
  --verify)         verify_only ;;
  ""|--run)         run_sign ;;
  *) err "Geçersiz seçenek: $1
Kullanım: $0 [--install-hook | --uninstall-hook | --verify]
Varsayılan (parametresiz): imzalama işlemini yapar."; exit 1;;
esac
