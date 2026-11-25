#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  TLinux-Debian — Debian completo (só linha de comando) para o Termux
#
#  Uso:   bash tlinux-debian.sh [opções]
#         bash tlinux-debian.sh --help
#
#  O que faz:
#    1. instala as dependências no Termux (proot, curl, tar, xz)
#    2. baixa o rootfs oficial do Debian (imagens linuxcontainers.org)
#    3. extrai e configura: APT, idioma, fuso horário, hostname, usuário, sudo
#    4. cria o comando `tlinux` para entrar no sistema
#
#  Não precisa de root no Android.
# =============================================================================

set -u

VERSION="1.0.0"
RELEASE="trixie"            # bookworm | trixie | forky | sid
INST_NAME="debian"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BASE_DIR="$PREFIX/var/lib/tlinux"
CACHE_DIR="$PREFIX/var/cache/tlinux"
BIN_DIR="$PREFIX/bin"

USER_NAME=""
USER_PASS=""
LANG_ID=""
TZ_ID=""
HOST_NAME=""
DEV_TOOLS=""                # s | n
REINSTALL=0
UNINSTALL=0
ASSUME_YES=0
ASK_RESULT=""

# Espelhos com o mesmo layout de diretórios
MIRRORS=(
  "https://images.linuxcontainers.org/images"
  "https://mirrors.tuna.tsinghua.edu.cn/lxc-images/images"
)

# ----------------------------------------------------------------- cores / log
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_BD=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BD=""; C_0=""
fi
msg()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ utilidades
ask() {   # ask "pergunta" "padrão"  ->  ASK_RESULT
  local v=""
  if [ "$ASSUME_YES" -eq 1 ]; then ASK_RESULT="$2"; return 0; fi
  printf '%s [%s]: ' "$1" "$2"
  { read -r v </dev/tty; } 2>/dev/null || v=""
  ASK_RESULT="${v:-$2}"
}

ask_secret() {   # ask_secret "pergunta"  ->  ASK_RESULT (sem eco)
  local v=""
  if [ "$ASSUME_YES" -eq 1 ]; then ASK_RESULT=""; return 0; fi
  printf '%s' "$1"
  { read -rs v </dev/tty; } 2>/dev/null || v=""
  printf '\n'
  ASK_RESULT="$v"
}

is_yes() { case "$1" in s|S|y|Y|sim|SIM|yes|YES) return 0 ;; *) return 1 ;; esac; }

remove_dir() {   # rootfs tem diretórios sem permissão de escrita
  [ -e "$1" ] || return 0
  chmod -R u+rwX "$1" 2>/dev/null
  rm -rf "$1"
}

usage() {
  cat <<EOF
TLinux-Debian $VERSION — Debian (CLI) para o Termux

Uso: bash tlinux-debian.sh [opções]

  -r, --release NOME   bookworm, trixie (padrão), forky ou sid
  -n, --name NOME      nome da instalação (padrão: debian)
  -u, --user NOME      usuário a criar (padrão: pergunta)
      --lang LOCALE    ex.: pt_BR.UTF-8 (padrão: pergunta)
      --tz FUSO        ex.: America/Sao_Paulo (padrão: detecta do Android)
      --hostname NOME  nome da máquina (padrão: pergunta)
      --dev            instala gcc, python3, pip, cmake...
      --no-dev         não instala ferramentas de desenvolvimento
      --dir CAMINHO    onde guardar os sistemas (padrão: \$PREFIX/var/lib/tlinux)
      --reinstall      apaga e reinstala sem perguntar
      --uninstall      remove a instalação e o comando
  -y, --yes            não pergunta nada (usa padrões; usuário sem senha)
  -h, --help           mostra esta ajuda

Depois de instalado:  tlinux   (ou: tlinux --help)
EOF
}

need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "A opção $1 precisa de um valor."; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -r|--release)  need_val "$@"; RELEASE="$2"; shift 2 ;;
      -n|--name)     need_val "$@"; INST_NAME="$2"; shift 2 ;;
      -u|--user)     need_val "$@"; USER_NAME="$2"; shift 2 ;;
      --lang)        need_val "$@"; LANG_ID="$2"; shift 2 ;;
      --tz)          need_val "$@"; TZ_ID="$2"; shift 2 ;;
      --hostname)    need_val "$@"; HOST_NAME="$2"; shift 2 ;;
      --dir)         need_val "$@"; BASE_DIR="$2"; shift 2 ;;
      --dev)         DEV_TOOLS="s"; shift ;;
      --no-dev)      DEV_TOOLS="n"; shift ;;
      --reinstall)   REINSTALL=1; shift ;;
      --uninstall)   UNINSTALL=1; shift ;;
      -y|--yes)      ASSUME_YES=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "Opção desconhecida: $1 (veja --help)" ;;
    esac
  done

  case "$RELEASE" in
    bookworm|trixie|forky|sid) ;;
    *) die "Release não suportada: $RELEASE (use bookworm, trixie, forky ou sid)" ;;
  esac
  [[ "$INST_NAME" =~ ^[a-z0-9_-]+$ ]] || die "Nome inválido: $INST_NAME (use a-z, 0-9, _ ou -)"

  INSTANCE="$BASE_DIR/$INST_NAME"
  ROOTFS="$INSTANCE/rootfs"
  if [ "$INST_NAME" = "debian" ]; then CMD_NAME="tlinux"; else CMD_NAME="tlinux-$INST_NAME"; fi
  LAUNCHER="$BIN_DIR/$CMD_NAME"
}

# -------------------------------------------------------------- verificações
check_env() {
  [ "$(id -u)" -ne 0 ] || die "Não execute como root. Use o Termux normalmente."
  case "$PREFIX" in
    */com.termux/*) ;;
    *) die "Este script deve ser executado dentro do Termux." ;;
  esac

  case "$(uname -m)" in
    aarch64|arm64)        ARCH="arm64" ;;
    armv7l|armv8l|arm*)   ARCH="armhf" ;;
    x86_64|amd64)         ARCH="amd64" ;;
    i*86|x86)             ARCH="i386" ;;
    *) die "Arquitetura não suportada: $(uname -m)" ;;
  esac

  local free_mb
  free_mb=$(df -Pk "$PREFIX" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
  if [ -n "${free_mb:-}" ] && [ "$free_mb" -lt 1500 ]; then
    warn "Pouco espaço livre (${free_mb} MB). Recomendado: pelo menos 1,5 GB."
  fi
}

banner() {
  printf '\n%s╔══════════════════════════════════════╗%s\n' "$C_BD" "$C_0"
  printf '%s║   TLinux-Debian %-8s · Termux      ║%s\n' "$C_BD" "$VERSION" "$C_0"
  printf '%s╚══════════════════════════════════════╝%s\n\n' "$C_BD" "$C_0"
}

# --------------------------------------------------------------- desinstalar
do_uninstall() {
  if [ ! -d "$INSTANCE" ] && [ ! -f "$LAUNCHER" ]; then
    die "Nenhuma instalação '$INST_NAME' encontrada."
  fi
  if [ "$ASSUME_YES" -ne 1 ]; then
    ask "Remover '$INST_NAME' e TODOS os seus dados? (s/N)" "n"
    is_yes "$ASK_RESULT" || { msg "Cancelado."; exit 0; }
  fi
  remove_dir "$INSTANCE"
  rm -f "$LAUNCHER"
  ok "Removido."
  exit 0
}

# ------------------------------------------------------------- configuração
prepare_instance() {
  if [ -d "$INSTANCE" ]; then
    if [ -f "$INSTANCE/.complete" ] && [ "$REINSTALL" -ne 1 ]; then
      ask "'$INST_NAME' já está instalado. Apagar tudo e reinstalar? (s/N)" "n"
      is_yes "$ASK_RESULT" || { msg "Nada a fazer. Para entrar use: $CMD_NAME"; exit 0; }
    else
      msg "Removendo instalação anterior/incompleta..."
    fi
    remove_dir "$INSTANCE"
  fi
}

configure() {
  local p1 p2 def_tz re
  printf '%s── Configuração ──%s\n' "$C_BD" "$C_0"

  # usuário
  if [ -z "$USER_NAME" ]; then
    while true; do
      ask "Nome do usuário" "debian"
      if [[ "$ASK_RESULT" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && [ "$ASK_RESULT" != "root" ]; then
        USER_NAME="$ASK_RESULT"; break
      fi
      warn "Use letras minúsculas, números, _ ou - (e não use 'root')."
    done
  fi
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && [ "$USER_NAME" != "root" ] \
    || die "Nome de usuário inválido: $USER_NAME"

  # senha
  while true; do
    ask_secret "Senha de '$USER_NAME' (vazio = sem senha): "; p1="$ASK_RESULT"
    [ -z "$p1" ] && break
    ask_secret "Repita a senha: "; p2="$ASK_RESULT"
    [ "$p1" = "$p2" ] && break
    warn "As senhas não conferem. Tente de novo."
  done
  USER_PASS="$p1"

  # idioma
  if [ -z "$LANG_ID" ]; then
    ask "Idioma/locale (ex.: pt_BR.UTF-8, en_US.UTF-8)" "pt_BR.UTF-8"
    LANG_ID="$ASK_RESULT"
  fi
  re='^([a-z]{2,3}_[A-Z]{2}\.UTF-8|C\.UTF-8)$'
  [[ "$LANG_ID" =~ $re ]] || die "Locale inválido: $LANG_ID (exemplo: pt_BR.UTF-8)"

  # fuso horário
  if [ -z "$TZ_ID" ]; then
    def_tz="$(getprop persist.sys.timezone 2>/dev/null | tr -d '\r\n')"
    ask "Fuso horário" "${def_tz:-America/Sao_Paulo}"
    TZ_ID="$ASK_RESULT"
  fi
  [[ "$TZ_ID" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "Fuso horário inválido: $TZ_ID"

  # hostname
  if [ -z "$HOST_NAME" ]; then
    ask "Nome da máquina (hostname)" "$INST_NAME"
    HOST_NAME="$ASK_RESULT"
  fi
  [[ "$HOST_NAME" =~ ^[A-Za-z0-9-]+$ ]] || die "Hostname inválido: $HOST_NAME"

  # ferramentas de desenvolvimento
  if [ -z "$DEV_TOOLS" ]; then
    ask "Instalar ferramentas de desenvolvimento (gcc, python3, pip, cmake)? (s/N)" "n"
    if is_yes "$ASK_RESULT"; then DEV_TOOLS="s"; else DEV_TOOLS="n"; fi
  fi
  echo
}

# ------------------------------------------------------------- dependências
install_deps() {
  local need=() c
  for c in proot curl tar xz awk; do
    command -v "$c" >/dev/null 2>&1 || need+=("$c")
  done
  [ ${#need[@]} -eq 0 ] && return 0

  msg "Instalando dependências no Termux: ${need[*]}"
  local pk=()
  for c in "${need[@]}"; do
    case "$c" in xz) pk+=(xz-utils) ;; awk) pk+=(gawk) ;; *) pk+=("$c") ;; esac
  done
  pkg update -y >/dev/null 2>&1 || warn "pkg update falhou; tentando instalar mesmo assim."
  pkg install -y "${pk[@]}" || die "Falha ao instalar: ${pk[*]}"
}

# -------------------------------------------------------- download do rootfs
find_image() {
  local m base idx latest
  for m in "${MIRRORS[@]}"; do
    base="$m/debian/$RELEASE/$ARCH/default"
    idx=$(curl -fsSL --connect-timeout 15 "$base/" 2>/dev/null) || continue
    latest=$(printf '%s' "$idx" \
      | grep -oE 'href="(\./)?[0-9]{8}_[^"/]*/"' \
      | sed -E 's/^href="(\.\/)?//; s/"$//' \
      | sort | tail -n1)
    [ -n "$latest" ] || continue
    IMG_URL="$base/${latest}rootfs.tar.xz"
    IMG_SUMS="$base/${latest}SHA256SUMS"
    IMG_STAMP="${latest%/}"
    return 0
  done
  return 1
}

download_rootfs() {
  msg "Procurando a imagem mais recente do Debian $RELEASE ($ARCH)..."
  find_image || die "Não achei a imagem do Debian $RELEASE/$ARCH. Verifique a internet ou tente outra release."

  mkdir -p "$CACHE_DIR"
  TARBALL="$CACHE_DIR/debian-$RELEASE-$ARCH-${IMG_STAMP//[^0-9A-Za-z_]/-}.tar.xz"

  if [ -f "$TARBALL" ] && xz -t "$TARBALL" >/dev/null 2>&1; then
    ok "Usando o download em cache."
  else
    rm -f "$TARBALL"
    msg "Baixando o rootfs (pode demorar)..."
    curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$TARBALL.part" "$IMG_URL" \
      || die "Falha no download. Rode o script de novo para retomar."
    mv -f "$TARBALL.part" "$TARBALL"
  fi

  verify_rootfs
}

verify_rootfs() {
  local expected actual
  expected=$(curl -fsSL --connect-timeout 15 "$IMG_SUMS" 2>/dev/null \
    | awk '$2 ~ /rootfs\.tar\.xz$/ {print $1; exit}') || expected=""
  if [ -z "$expected" ]; then
    warn "Não consegui obter o checksum; verificando só a integridade do .xz."
    xz -t "$TARBALL" || { rm -f "$TARBALL"; die "Arquivo corrompido. Rode de novo."; }
    return 0
  fi
  actual=$(sha256sum "$TARBALL" | cut -d' ' -f1)
  if [ "$expected" != "$actual" ]; then
    rm -f "$TARBALL"
    die "Checksum SHA-256 não confere. Arquivo removido; rode de novo."
  fi
  ok "Checksum SHA-256 verificado."
}

extract_rootfs() {
  msg "Extraindo o sistema (alguns minutos)..."
  mkdir -p "$ROOTFS"
  proot --link2symlink -0 tar -xJf "$TARBALL" -C "$ROOTFS" \
      --exclude='./dev/*' --exclude='dev/*' --warning=no-unknown-keyword \
      2>"$INSTANCE/extract.log"
  # tar pode reclamar de itens especiais mesmo com sucesso; confira o resultado.
  if [ ! -x "$ROOTFS/usr/bin/bash" ]; then
    tail -n 5 "$INSTANCE/extract.log" >&2
    die "A extração falhou (veja $INSTANCE/extract.log)."
  fi
  rm -f "$INSTANCE/extract.log"
  chmod u+rwx "$ROOTFS"
  mkdir -p "$ROOTFS/tmp" "$ROOTFS/mnt/termux" "$ROOTFS/sdcard" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev"
  chmod 1777 "$ROOTFS/tmp"
  ok "Sistema extraído."
}

# ------------------------------------------------------- comando `tlinux`
write_launcher() {
  mkdir -p "$BIN_DIR"
  cat > "$LAUNCHER" <<'TLINUX_LAUNCHER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# TLinux — launcher gerado pelo instalador. Para recriar, reinstale.

INSTANCE="__INSTANCE__"
ROOTFS="$INSTANCE/rootfs"
FAKEPROC="$INSTANCE/fakeproc"
DEF_USER="__USER__"
CMD_NAME="__CMD__"
INST_NAME="__NAME__"
LANG_ID="__LANG__"

usage() {
cat <<EOF
Uso: $CMD_NAME [opções]

  (sem opções)          entra como '$DEF_USER'
  -r, --root            entra como root
  -u, --user USUÁRIO    entra como outro usuário
  -c, --command CMD     executa CMD e sai
  -b, --bind ORIG:DEST  monta um diretório extra (pode repetir)
      --no-sdcard       não monta o armazenamento interno em /sdcard
      --uninstall       remove este sistema e o comando
  -h, --help            mostra esta ajuda

Dentro do sistema:
  /sdcard        armazenamento interno (rode 'termux-setup-storage' antes)
  /mnt/termux    pasta HOME do Termux

Se o proot der erro de syscall/travar:  TLINUX_NO_SECCOMP=1 $CMD_NAME
EOF
}

user="$DEF_USER"
run_cmd=""
extra_binds=()
use_sdcard=1
do_uninstall=0

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--root)     user="root"; shift ;;
    -u|--user)     [ -n "${2:-}" ] || { echo "$1 precisa de um valor" >&2; exit 1; }
                   user="$2"; shift 2 ;;
    -c|--command)  [ -n "${2:-}" ] || { echo "$1 precisa de um valor" >&2; exit 1; }
                   run_cmd="$2"; shift 2 ;;
    -b|--bind)     [ -n "${2:-}" ] || { echo "$1 precisa de um valor" >&2; exit 1; }
                   extra_binds+=(-b "$2"); shift 2 ;;
    --no-sdcard)   use_sdcard=0; shift ;;
    --uninstall)   do_uninstall=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Opção desconhecida: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$do_uninstall" -eq 1 ]; then
  printf "Remover '%s' e TODOS os seus dados? [s/N] " "$INST_NAME"
  read -r a
  case "$a" in
    s|S|y|Y)
      chmod -R u+rwX "$INSTANCE" 2>/dev/null
      rm -rf "$INSTANCE"
      rm -f "$(readlink -f "$0")"
      echo "Removido." ;;
    *) echo "Cancelado." ;;
  esac
  exit 0
fi

if [ ! -x "$ROOTFS/usr/bin/bash" ]; then
  echo "Sistema não encontrado em $ROOTFS" >&2
  exit 1
fi

# DNS: o Android não tem /etc/resolv.conf utilizável
if [ -L "$ROOTFS/etc/resolv.conf" ] || [ ! -s "$ROOTFS/etc/resolv.conf" ]; then
  rm -f "$ROOTFS/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
fi

# Arquivos /proc que o Android bloqueia para apps: usa versões falsas
make_fake_proc() {
  case "$1" in
    loadavg) echo "0.12 0.07 0.02 2/165 765" ;;
    uptime)  echo "18423.62 18423.62" ;;
    version) echo "Linux version 6.2.1-tlinux (tlinux@termux) (gcc 12.2.0) #1 SMP PREEMPT_DYNAMIC" ;;
    vmstat)  printf 'nr_free_pages 100000\nnr_inactive_anon 0\nnr_active_anon 0\npgpgin 0\npgpgout 0\npswpin 0\npswpout 0\n' ;;
    stat)
      local n i
      n=$(nproc 2>/dev/null || echo 4)
      echo "cpu  1957 0 2877 93280 262 342 254 87 0 0"
      for ((i=0; i<n; i++)); do echo "cpu$i 245 0 360 11660 32 42 31 11 0 0"; done
      echo "intr 0"
      echo "ctxt 140223"
      echo "btime 1680020856"
      echo "processes 772"
      echo "procs_running 2"
      echo "procs_blocked 0"
      echo "softirq 0 0 0 0 0 0 0 0 0 0 0"
      ;;
  esac
}

mkdir -p "$FAKEPROC" "$ROOTFS/tmp" "$ROOTFS/mnt/termux" "$ROOTFS/sdcard"

binds=(
  -b /dev
  -b /dev/urandom:/dev/random
  -b /proc
  -b /proc/self/fd:/dev/fd
  -b /proc/self/fd/0:/dev/stdin
  -b /proc/self/fd/1:/dev/stdout
  -b /proc/self/fd/2:/dev/stderr
  -b /sys
  -b "$ROOTFS/tmp:/dev/shm"
)

for f in stat loadavg uptime version vmstat; do
  if ! cat "/proc/$f" >/dev/null 2>&1; then
    [ -s "$FAKEPROC/$f" ] || make_fake_proc "$f" > "$FAKEPROC/$f"
    binds+=(-b "$FAKEPROC/$f:/proc/$f")
  fi
done

[ -d "${HOME:-}" ] && binds+=(-b "$HOME:/mnt/termux")

if [ "$use_sdcard" -eq 1 ] && ls /storage/emulated/0 >/dev/null 2>&1; then
  binds+=(-b /storage/emulated/0:/sdcard)
fi

# Necessário para o proot funcionar no Termux
unset LD_PRELOAD
export PROOT_TMP_DIR="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
[ "${TLINUX_NO_SECCOMP:-0}" = "1" ] && export PROOT_NO_SECCOMP=1

if [ "$user" = "root" ]; then
  if [ -n "$run_cmd" ]; then
    shell=(/bin/bash --login -c "$run_cmd")
  else
    shell=(/bin/bash --login)
  fi
else
  if [ -n "$run_cmd" ]; then
    shell=(/bin/su -l "$user" -c "$run_cmd")
  else
    shell=(/bin/su -l "$user")
  fi
fi

exec proot \
  --link2symlink \
  --kill-on-exit \
  --sysvipc \
  -0 \
  --kernel-release=6.2.1-tlinux \
  -r "$ROOTFS" \
  -w /root \
  "${binds[@]}" "${extra_binds[@]}" \
  /usr/bin/env -i \
    HOME=/root \
    USER=root \
    LANG="$LANG_ID" \
    TERM="${TERM:-xterm-256color}" \
    COLORTERM="${COLORTERM:-}" \
    TMPDIR=/tmp \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games \
  "${shell[@]}"
TLINUX_LAUNCHER_EOF

  sed -i \
    -e "s|__INSTANCE__|$INSTANCE|g" \
    -e "s|__USER__|$USER_NAME|g" \
    -e "s|__CMD__|$CMD_NAME|g" \
    -e "s|__NAME__|$INST_NAME|g" \
    -e "s|__LANG__|$LANG_ID|g" \
    "$LAUNCHER"
  chmod 755 "$LAUNCHER"
}

# ----------------------------------------- configuração interna do Debian
write_setup_script() {
  local f="$ROOTFS/root/.tlinux-setup.sh" nopass=0
  [ -z "$USER_PASS" ] && nopass=1
  mkdir -p "$ROOTFS/root"
  {
    printf 'T_USER=%q\nT_LANG=%q\nT_TZ=%q\nT_HOST=%q\nT_REL=%q\nT_DEV=%q\nT_NOPASS=%q\n' \
      "$USER_NAME" "$LANG_ID" "$TZ_ID" "$HOST_NAME" "$RELEASE" "$DEV_TOOLS" "$nopass"
    cat <<'TLINUX_SETUP_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

say() { printf '\n\033[1;34m>>\033[0m %s\n' "$*"; }
avail() { local p; for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 && printf '%s ' "$p"; done; }

say "Configurando o APT"
cat > /etc/apt/apt.conf.d/99tlinux <<'EOF'
APT::Sandbox::User "root";
Acquire::Retries "3";
EOF
# impede que pacotes tentem iniciar serviços (não há systemd aqui)
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list
KEYRING=""
[ -f /usr/share/keyrings/debian-archive-keyring.gpg ] \
  && KEYRING="Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
if [ "$T_REL" = "sid" ]; then
  SUITES="sid"; WITH_SEC=0
else
  SUITES="$T_REL ${T_REL}-updates"; WITH_SEC=1
fi
{
  printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s\nComponents: main contrib non-free non-free-firmware\n%s\n' "$SUITES" "$KEYRING"
  if [ "$WITH_SEC" = 1 ]; then
    printf '\nTypes: deb\nURIs: http://deb.debian.org/debian-security\nSuites: %s-security\nComponents: main contrib non-free non-free-firmware\n%s\n' "$T_REL" "$KEYRING"
  fi
} > /etc/apt/sources.list.d/debian.sources
: > /etc/apt/sources.list

say "Atualizando índices e instalando o sistema base"
apt-get update
apt-get -y --no-install-recommends install sudo locales tzdata ca-certificates apt-utils

BASE_PKGS="curl wget git nano vim less procps htop psmisc bash-completion openssh-client iproute2 iputils-ping net-tools dnsutils unzip zip xz-utils bzip2 file tree gnupg lsb-release"
# shellcheck disable=SC2046
apt-get -y --no-install-recommends install $(avail $BASE_PKGS)

if [ "$T_DEV" = "s" ]; then
  say "Instalando ferramentas de desenvolvimento"
  # shellcheck disable=SC2046
  apt-get -y --no-install-recommends install $(avail build-essential python3 python3-pip python3-venv pkg-config cmake jq)
fi

say "Idioma: $T_LANG"
if [ "$T_LANG" != "C.UTF-8" ]; then
  { echo "$T_LANG UTF-8"; echo "en_US.UTF-8 UTF-8"; } | sort -u > /etc/locale.gen
  locale-gen
fi
echo "LANG=$T_LANG" > /etc/default/locale
cat > /etc/profile.d/00-tlinux-locale.sh <<'EOF'
[ -r /etc/default/locale ] && . /etc/default/locale && export LANG
EOF

say "Fuso horário: $T_TZ"
if [ -f "/usr/share/zoneinfo/$T_TZ" ]; then
  ln -sf "/usr/share/zoneinfo/$T_TZ" /etc/localtime
  echo "$T_TZ" > /etc/timezone
else
  echo "aviso: fuso '$T_TZ' não existe; usando UTC"
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime
  
