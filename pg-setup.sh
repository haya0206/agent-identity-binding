#!/usr/bin/env bash
#
# pg-setup.sh — sudo 없이 홈 디렉토리에 PostgreSQL 클라이언트/서버 설치·운영
#
#   설치 위치:  ~/pg          (바이너리, conda-forge 환경)
#               ~/pgdata      (데이터 디렉토리 = DB 본체)
#               ~/.pg-local.env (환경변수, source 해서 사용)
#
#   전부 홈 아래에만 들어가므로 uninstall 로 흔적 없이 지워집니다.
#
# 사용법:  ./pg-setup.sh <command> [options]
#          ./pg-setup.sh help
#
set -euo pipefail

# ---------------------------------------------------------------- 설정값
# 환경변수로 덮어쓸 수 있습니다:  PG_PREFIX=~/pg17 ./pg-setup.sh install
PG_PREFIX="${PG_PREFIX:-$HOME/pg}"
PG_DATA="${PG_DATA:-$HOME/pgdata}"
PG_PORT="${PG_PORT:-5433}"
PG_VERSION="${PG_VERSION:-}"          # 예: 17  (비우면 conda-forge 최신)
PG_ENV_FILE="${PG_ENV_FILE:-$HOME/.pg-local.env}"
MAMBA_BIN="${MAMBA_BIN:-$HOME/.local/bin/micromamba}"
MAMBA_ROOT="${MAMBA_ROOT:-$HOME/.micromamba}"

# 튜닝 (공유 서버 기준 보수적으로 잡음)
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-256MB}"
PG_WORK_MEM="${PG_WORK_MEM:-16MB}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-20}"

SYSTEMD_UNIT="$HOME/.config/systemd/user/pg-local.service"
CONF_MARK_BEGIN="# --- pg-setup.sh managed block (do not edit below) ---"
CONF_MARK_END="# --- end pg-setup.sh managed block ---"

# ---------------------------------------------------------------- 출력
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_OFF=
fi
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s경고%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s오류%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
run()  { printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_OFF"; "$@"; }

# ---------------------------------------------------------------- 유틸
pgbin() { printf '%s/bin/%s' "$PG_PREFIX" "$1"; }

have_binaries() { [ -x "$(pgbin psql)" ]; }
have_cluster()  { [ -s "$PG_DATA/PG_VERSION" ]; }

require_binaries() {
  have_binaries || die "PostgreSQL 바이너리가 없습니다. 먼저 '$0 install' 을 실행하세요."
}
require_cluster() {
  have_cluster || die "데이터 디렉토리($PG_DATA)가 초기화되지 않았습니다. '$0 install' 을 실행하세요."
}

server_running() {
  have_binaries && have_cluster && "$(pgbin pg_ctl)" -D "$PG_DATA" status >/dev/null 2>&1
}

tcp_port_in_use() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3<&- || :; return 0; }
  return 1
}

mamba_arch() {
  case "$(uname -m)" in
    x86_64)        echo linux-64 ;;
    aarch64|arm64) echo linux-aarch64 ;;
    ppc64le)       echo linux-ppc64le ;;
    *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
  esac
}

confirm() {
  local prompt="$1" answer
  if [ ! -t 0 ]; then
    die "확인이 필요한 작업입니다. 대화형 터미널에서 실행하거나 --force 를 사용하세요."
  fi
  printf '%s' "$prompt"
  read -r answer
  [ "$answer" = "yes" ]
}

# ---------------------------------------------------------------- 설치
mamba_works() {
  MAMBA_ROOT_PREFIX="$MAMBA_ROOT" "$MAMBA_BIN" --no-rc --no-env --version >/dev/null 2>&1
}

install_micromamba() {
  local refresh="${1:-no}"

  if [ "$refresh" = yes ] && [ -e "$MAMBA_BIN" ]; then
    info "micromamba 강제 재설치 — 기존 바이너리 제거"
    rm -f "$MAMBA_BIN"
  fi

  if [ -x "$MAMBA_BIN" ]; then
    if mamba_works; then
      ok "micromamba 이미 있음 ($MAMBA_BIN, $(MAMBA_ROOT_PREFIX="$MAMBA_ROOT" "$MAMBA_BIN" --no-rc --no-env --version 2>/dev/null))"
      return
    fi
    warn "기존 micromamba 가 정상 실행되지 않습니다 ($MAMBA_BIN) — 다시 내려받습니다."
    rm -f "$MAMBA_BIN"
  fi

  command -v curl >/dev/null || die "curl 이 필요합니다."
  command -v tar  >/dev/null || die "tar 이 필요합니다."

  info "micromamba 내려받는 중 ($(mamba_arch))"
  mkdir -p "$(dirname "$MAMBA_BIN")"
  curl -fsSL "https://micro.mamba.pm/api/micromamba/$(mamba_arch)/latest" \
    | tar -xj -C "$(dirname "$MAMBA_BIN")" --strip-components=1 bin/micromamba
  chmod +x "$MAMBA_BIN"

  mamba_works || die "내려받은 micromamba 도 실행되지 않습니다.
  glibc 가 너무 오래됐을 수 있습니다:  ldd --version
  이 경우 도커나 uv 기반(pgserver) 방식을 쓰셔야 합니다."
  ok "micromamba 설치 완료"
}

install_postgres() {
  local spec="postgresql"
  [ -n "$PG_VERSION" ] && spec="postgresql=$PG_VERSION"

  if have_binaries; then
    ok "PostgreSQL 바이너리 이미 있음 ($("$(pgbin psql)" --version))"
    return
  fi

  info "conda-forge 에서 $spec 설치 → $PG_PREFIX"
  # --no-rc/--no-env: 손상되거나 이상한 ~/.condarc 의 영향을 받지 않도록
  MAMBA_ROOT_PREFIX="$MAMBA_ROOT" run "$MAMBA_BIN" create -y --no-rc --no-env \
    -p "$PG_PREFIX" -c conda-forge "$spec"
  ok "설치 완료: $("$(pgbin psql)" --version)"
}

init_cluster() {
  if have_cluster; then
    ok "데이터 디렉토리 이미 초기화됨 ($PG_DATA, PG $(cat "$PG_DATA/PG_VERSION"))"
    return
  fi
  if [ -e "$PG_DATA" ] && [ -n "$(ls -A "$PG_DATA" 2>/dev/null)" ]; then
    die "$PG_DATA 가 비어있지 않은데 유효한 클러스터도 아닙니다. 직접 확인 후 정리하세요."
  fi

  info "클러스터 초기화 → $PG_DATA"
  local locale=C.UTF-8
  if ! locale -a 2>/dev/null | grep -qix 'C.utf8\|C.UTF-8'; then
    warn "C.UTF-8 로케일이 없어 C 로 대체합니다."
    locale=C
  fi

  "$(pgbin initdb)" -D "$PG_DATA" -U "$(id -un)" \
    --encoding=UTF8 --locale="$locale" \
    --auth-local=trust --auth-host=scram-sha-256
  ok "초기화 완료"
}

write_config() {
  require_cluster
  local conf="$PG_DATA/postgresql.conf" listen

  if [ "$USE_TCP" = "yes" ]; then
    listen="localhost"
    if tcp_port_in_use "$PG_PORT"; then
      warn "포트 $PG_PORT 가 이미 사용 중입니다. PG_PORT 를 바꿔서 다시 실행하세요."
    fi
  else
    listen=""
  fi

  info "postgresql.conf 갱신 (listen_addresses='$listen', port=$PG_PORT)"
  # 기존 관리 블록 제거 후 다시 추가 (재실행해도 중복되지 않음)
  sed -i "/^${CONF_MARK_BEGIN}$/,/^${CONF_MARK_END}$/d" "$conf"
  cat >> "$conf" <<EOF
$CONF_MARK_BEGIN
listen_addresses = '$listen'
unix_socket_directories = '$PG_DATA'
port = $PG_PORT
shared_buffers = $PG_SHARED_BUFFERS
work_mem = $PG_WORK_MEM
max_connections = $PG_MAX_CONNECTIONS
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
$CONF_MARK_END
EOF

  if [ "$USE_TCP" = "yes" ]; then
    warn "TCP 모드입니다. 같은 서버의 다른 사용자도 접속을 시도할 수 있으니"
    warn "  ALTER ROLE \"$(id -un)\" PASSWORD '...';  로 반드시 비밀번호를 거세요."
  fi
  ok "설정 반영 (적용하려면 restart)"
}

write_env_file() {
  info "환경변수 파일 작성 → $PG_ENV_FILE"
  cat > "$PG_ENV_FILE" <<EOF
# pg-setup.sh 가 생성함. 셸에서 'source $PG_ENV_FILE' 하세요.
# 여러 번 source 해도 PATH 가 중복되지 않습니다.
case ":\$PATH:" in
  *":$PG_PREFIX/bin:"*) : ;;                   # 이미 들어있음 — 아무것도 안 함
  *) export PATH="$PG_PREFIX/bin:\$PATH" ;;    # 시스템 바이너리보다 우선
esac
# 시스템 openssl 등을 가리는 게 싫으면 위 줄을 아래로 바꾸세요:
#   *) export PATH="\$PATH:$PG_PREFIX/bin" ;;
export PGDATA="$PG_DATA"
export PGHOST="$PG_DATA"
export PGPORT=$PG_PORT
export PGUSER="$(id -un)"
EOF
  ok "작성 완료"
}

link_shellrc() {
  local rc="$HOME/.bashrc" line="[ -f $PG_ENV_FILE ] && . $PG_ENV_FILE"
  [ -f "$HOME/.zshrc" ] && [ -n "${ZSH_VERSION:-}" ] && rc="$HOME/.zshrc"
  if grep -qF "$PG_ENV_FILE" "$rc" 2>/dev/null; then
    ok "$rc 에 이미 등록됨"
    return
  fi
  printf '\n# pg-setup.sh\n%s\n' "$line" >> "$rc"
  ok "$rc 에 추가함 (새 셸부터 적용)"
}

cmd_install() {
  local client_only=no
  USE_TCP=no
  local link_rc=no
  local refresh_mamba=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --client-only)   client_only=yes ;;
      --tcp)           USE_TCP=yes ;;
      --shellrc)       link_rc=yes ;;
      --refresh-mamba) refresh_mamba=yes ;;
      --port)          PG_PORT="${2:?--port 값 필요}"; shift ;;
      --version)       PG_VERSION="${2:?--version 값 필요}"; shift ;;
      *) die "알 수 없는 옵션: $1  ('$0 help' 참고)" ;;
    esac
    shift
  done

  install_micromamba "$refresh_mamba"
  install_postgres

  if [ "$client_only" = yes ]; then
    write_env_file
    [ "$link_rc" = yes ] && link_shellrc
    ok "클라이언트 전용 설치 완료 — psql, pg_dump 등을 쓸 수 있습니다."
    printf '\n다음 명령으로 셸에 적용:  %ssource %s%s\n' "$C_GRN" "$PG_ENV_FILE" "$C_OFF"
    return
  fi

  init_cluster
  write_config
  write_env_file
  [ "$link_rc" = yes ] && link_shellrc

  cat <<EOF

$C_GRN설치 완료.$C_OFF

  셸에 적용:    source $PG_ENV_FILE
  서버 시작:    $0 start
  접속:         $0 psql
  자동 기동:    $0 autostart on
  전부 삭제:    $0 uninstall

EOF
}

# ---------------------------------------------------------------- 운영
cmd_start() {
  require_binaries; require_cluster
  if server_running; then ok "이미 실행 중입니다."; return; fi
  info "서버 시작"
  "$(pgbin pg_ctl)" -D "$PG_DATA" -l "$PG_DATA/server.log" -w -t 60 start
  ok "기동됨 (소켓: $PG_DATA, 포트: $PG_PORT)"
}

cmd_stop() {
  require_binaries; require_cluster
  if ! server_running; then ok "이미 멈춰 있습니다."; return; fi
  info "서버 종료"
  "$(pgbin pg_ctl)" -D "$PG_DATA" -m fast -w -t 60 stop
  ok "종료됨"
}

cmd_restart() { cmd_stop; cmd_start; }

cmd_reload() {
  require_binaries; require_cluster
  server_running || die "서버가 실행 중이 아닙니다."
  "$(pgbin pg_ctl)" -D "$PG_DATA" reload
  ok "설정 다시 읽음"
}

cmd_status() {
  printf '%s바이너리%s   %s\n' "$C_BLU" "$C_OFF" \
    "$(have_binaries && "$(pgbin psql)" --version || echo '미설치')"
  printf '%s데이터%s     %s\n' "$C_BLU" "$C_OFF" \
    "$(have_cluster && echo "$PG_DATA (PG $(cat "$PG_DATA/PG_VERSION"))" || echo '미초기화')"
  if have_cluster; then
    printf '%s리스닝%s     %s\n' "$C_BLU" "$C_OFF" \
      "$(grep -E "^listen_addresses" "$PG_DATA/postgresql.conf" | tail -1 || echo '?')"
    printf '%s포트%s       %s\n' "$C_BLU" "$C_OFF" "$PG_PORT"
  fi
  if server_running; then
    printf '%s상태%s       %s실행 중%s\n' "$C_BLU" "$C_OFF" "$C_GRN" "$C_OFF"
    "$(pgbin pg_ctl)" -D "$PG_DATA" status | sed 's/^/           /'
  else
    printf '%s상태%s       정지\n' "$C_BLU" "$C_OFF"
  fi
  printf '%s자동기동%s   ' "$C_BLU" "$C_OFF"
  if [ -f "$SYSTEMD_UNIT" ]; then echo "systemd --user (pg-local.service)"
  elif crontab -l 2>/dev/null | grep -q 'pg-setup.sh start'; then echo "cron @reboot"
  else echo "없음"; fi
}

cmd_psql() {
  require_binaries; require_cluster
  server_running || die "서버가 실행 중이 아닙니다. '$0 start' 먼저 실행하세요."
  exec "$(pgbin psql)" -h "$PG_DATA" -p "$PG_PORT" -U "$(id -un)" "${@:-postgres}"
}

cmd_logs() {
  require_cluster
  local latest
  latest="$(ls -t "$PG_DATA"/log/*.log 2>/dev/null | head -1 || true)"
  [ -n "$latest" ] || latest="$PG_DATA/server.log"
  [ -f "$latest" ] || die "로그 파일이 없습니다."
  exec tail -f -n 50 "$latest"
}

# ---------------------------------------------------------------- 자동 기동
autostart_on_systemd() {
  command -v systemctl >/dev/null || die "systemctl 이 없습니다. --cron 을 쓰세요."
  mkdir -p "$(dirname "$SYSTEMD_UNIT")"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=PostgreSQL (user-local, pg-setup.sh)
After=network.target

[Service]
Type=forking
Environment=PGDATA=$PG_DATA
ExecStart=$PG_PREFIX/bin/pg_ctl -D $PG_DATA -l $PG_DATA/server.log -w -t 60 start
ExecStop=$PG_PREFIX/bin/pg_ctl -D $PG_DATA -m fast -w -t 60 stop
ExecReload=$PG_PREFIX/bin/pg_ctl -D $PG_DATA reload
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now pg-local.service
  ok "systemd --user 유닛 등록 완료"

  if loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    ok "linger 이미 켜져 있음 — 로그아웃해도 계속 실행됩니다."
  elif loginctl enable-linger "$(id -un)" 2>/dev/null; then
    ok "linger 활성화 — 로그아웃해도 계속 실행됩니다."
  else
    warn "linger 를 켜지 못했습니다 (권한 필요). 로그아웃하면 서버가 내려갑니다."
    warn "  관리자에게 'loginctl enable-linger $(id -un)' 를 요청하거나"
    warn "  '$0 autostart on --cron' 을 쓰세요."
  fi
}

autostart_on_cron() {
  command -v crontab >/dev/null || die "crontab 이 없습니다."
  local self entry current
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  entry="@reboot $self start >/dev/null 2>&1"
  current="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -qF "$self start"; then
    ok "crontab 에 이미 등록됨"
    return
  fi
  printf '%s\n%s\n' "$current" "$entry" | grep -v '^$' | crontab -
  ok "crontab @reboot 등록 완료"
}

autostart_off() {
  if [ -f "$SYSTEMD_UNIT" ]; then
    systemctl --user disable --now pg-local.service 2>/dev/null || true
    rm -f "$SYSTEMD_UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd 유닛 제거"
  fi
  if crontab -l 2>/dev/null | grep -q 'pg-setup.sh start'; then
    crontab -l 2>/dev/null | grep -v 'pg-setup.sh start' | crontab -
    ok "crontab 항목 제거"
  fi
}

cmd_autostart() {
  local action="${1:-}"; shift || true
  local mode=auto
  while [ $# -gt 0 ]; do
    case "$1" in
      --systemd) mode=systemd ;;
      --cron)    mode=cron ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
    shift
  done
  case "$action" in
    on)
      require_binaries; require_cluster
      case "$mode" in
        systemd) autostart_on_systemd ;;
        cron)    autostart_on_cron ;;
        auto)    if command -v systemctl >/dev/null && [ -d "/run/user/$(id -u)" ]
                 then autostart_on_systemd; else autostart_on_cron; fi ;;
      esac ;;
    off) autostart_off ;;
    *)   die "사용법: $0 autostart on|off [--systemd|--cron]" ;;
  esac
}

# ---------------------------------------------------------------- 백업/삭제
cmd_backup() {
  require_binaries; require_cluster
  server_running || die "백업하려면 서버가 실행 중이어야 합니다."
  local out="${1:-$HOME/pg-backup-$(date +%Y%m%d-%H%M%S).sql}"
  info "pg_dumpall → $out"
  "$(pgbin pg_dumpall)" -h "$PG_DATA" -p "$PG_PORT" -U "$(id -un)" -f "$out"
  ok "백업 완료 ($(du -h "$out" | cut -f1))"
}

cmd_uninstall() {
  local force=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=yes ;;
      *) die "알 수 없는 옵션: $1" ;;
    esac
    shift
  done

  cat <<EOF

${C_RED}다음을 영구 삭제합니다:${C_OFF}
  $PG_PREFIX          (바이너리)
  $PG_DATA            (${C_RED}데이터베이스 본체 — 되돌릴 수 없습니다${C_OFF})
  $PG_ENV_FILE        (환경변수 파일)
  자동 기동 등록 (systemd / cron)

micromamba($MAMBA_BIN)와 캐시($MAMBA_ROOT)는 다른 환경에서 쓸 수 있으므로 남깁니다.
EOF
  if have_cluster; then
    printf '\n먼저 백업하려면 취소하고 %s%s backup%s 을 실행하세요.\n' "$C_GRN" "$0" "$C_OFF"
  fi

  if [ "$force" != yes ]; then
    echo
    confirm "정말 삭제하려면 'yes' 를 입력하세요: " || { info "취소했습니다."; return; }
  fi

  server_running && cmd_stop || true
  autostart_off
  rm -rf "$PG_PREFIX" "$PG_DATA" "$PG_ENV_FILE"
  ok "삭제 완료"

  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -qF "$PG_ENV_FILE" "$rc"; then
      warn "$rc 에 남은 source 줄은 직접 지워주세요."
    fi
  done
}

# ---------------------------------------------------------------- 도움말
cmd_help() {
  cat <<EOF
${C_BLU}pg-setup.sh${C_OFF} — sudo 없이 홈 디렉토리에 PostgreSQL 설치·운영

${C_BLU}설치${C_OFF}
  install [옵션]            클라이언트 + 서버 설치 및 초기화
      --client-only           psql 등 클라이언트 도구만 (서버 초기화 안 함)
      --tcp                   localhost TCP 리슨 (기본은 유닉스 소켓 전용)
      --shellrc               ~/.bashrc 에 환경변수 source 줄 추가
      --refresh-mamba         기존 micromamba 를 지우고 다시 내려받음
      --port N                포트 지정 (기본 $PG_PORT)
      --version N             PostgreSQL 메이저 버전 고정 (예: 17)
  configure [--tcp]         postgresql.conf 만 다시 생성 (restart 필요)

${C_BLU}운영${C_OFF}
  start | stop | restart    서버 기동/종료
  reload                    설정만 다시 읽기
  status                    설치·기동·자동기동 상태 요약
  psql [DB]                 psql 접속 (기본 DB: postgres)
  logs                      서버 로그 tail -f
  autostart on|off          재부팅 시 자동 기동 [--systemd|--cron]

${C_BLU}백업·삭제${C_OFF}
  backup [파일]             pg_dumpall 로 전체 덤프
  uninstall [--force]       ~/pg, ~/pgdata 등 전부 삭제

${C_BLU}경로${C_OFF}
  바이너리  $PG_PREFIX/bin
  데이터    $PG_DATA
  환경변수  $PG_ENV_FILE

${C_BLU}환경변수로 기본값 변경${C_OFF}
  PG_PREFIX PG_DATA PG_PORT PG_VERSION PG_SHARED_BUFFERS
  PG_WORK_MEM PG_MAX_CONNECTIONS

  예)  PG_PORT=5440 PG_DATA=~/pgdata-test $0 install

${C_BLU}애플리케이션 접속 (유닉스 소켓)${C_OFF}
  psycopg     psycopg.connect(host="$PG_DATA", port=$PG_PORT, dbname="mydb")
  SQLAlchemy  postgresql://$(id -un)@/mydb?host=$PG_DATA&port=$PG_PORT
EOF
}

# ---------------------------------------------------------------- 진입점
USE_TCP=no

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    configure) USE_TCP=no
               while [ $# -gt 0 ]; do
                 case "$1" in --tcp) USE_TCP=yes ;; *) die "알 수 없는 옵션: $1" ;; esac
                 shift
               done
               write_config ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    reload)    cmd_reload ;;
    status)    cmd_status ;;
    psql)      cmd_psql "$@" ;;
    logs)      cmd_logs ;;
    autostart) cmd_autostart "$@" ;;
    backup)    cmd_backup "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "알 수 없는 명령: $cmd  ('$0 help' 참고)" ;;
  esac
}

main "$@"
