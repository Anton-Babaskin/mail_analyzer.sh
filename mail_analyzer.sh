#!/usr/bin/env bash
#
# mail_analyzer.sh — анализатор логов почтового сервера Postfix.
#
# Считает статистику по доменам, relay-серверам, маршрутам, объёмам трафика
# и ошибкам доставки. Работает с обычными и сжатыми логами, с журналом
# systemd, а также с данными на stdin.
#
# Требует: bash 4+, любой awk (mawk / gawk / busybox awk), sort, date.
#
# Лицензия: MIT

# Программы awk намеренно записаны в одинарных кавычках: $1, $2 и т.д. должны
# попасть в awk как есть, а не раскрыться шеллом.
# shellcheck disable=SC2016

set -euo pipefail

VERSION="2.0.0"
PROGNAME="${0##*/}"

# ---------------------------------------------------------------------------
# Значения по умолчанию
# ---------------------------------------------------------------------------
TOP=100
FORMAT="table"
SHOW_HEADER=1
SINCE_EPOCH=0
UNTIL_EPOCH=0
USE_JOURNAL=0
READ_STDIN=0
COMMAND=""
declare -a LOG_ARGS=()

# Пути, по которым ищутся логи, если ничего не задано явно.
DEFAULT_LOG_GLOBS=(
    "/var/log/mail.log*"
    "/var/log/maillog*"
    "/var/log/mail/mail.log*"
    "/var/log/mail/current"
)

# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------
die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "${2:-1}"
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'USAGE_EOF'
Mail Log Domain Analyzer — анализ логов Postfix.

ИСПОЛЬЗОВАНИЕ
    mail_analyzer.sh <команда> [опции] [файл-лога ...]

КОМАНДЫ
  Домены
    in            топ доменов отправителей (успешно доставленные письма)
    out           топ доменов получателей (успешно доставленные письма)
    senders       топ адресов отправителей
    recipients    топ адресов получателей

  Relay-серверы
    relay_in      relay для входящей почты (local/virtual/lmtp/pipe доставка)
    relay_out     relay для исходящей почты (доставка транспортом smtp)
    relay_ips     топ IP-адресов relay-серверов

  Трафик и маршруты
    routes        топ маршрутов: домен отправителя -> получателя -> relay
    sizes         топ доменов отправителей по объёму трафика (МБ)
    avg_sizes     средний размер письма по доменам отправителей (КБ)

  Проблемы доставки
    failed        все неуспешные доставки (bounced + deferred + expired)
    bounced       только отскоки (status=bounced)
    deferred      только отложенные (status=deferred)
    reasons       топ причин неуспешной доставки

  Прочее
    summary       сводная статистика по всему выбранному периоду
    raw           разобранные записи в TSV (для собственных пайплайнов)
    help          эта справка

ОПЦИИ
    -n, --top N          сколько строк выводить (по умолчанию 100, 0 = все)
        --today          только записи за сегодня
        --last-hour      только за последний час
        --last-24h       только за последние 24 часа
        --since EXPR     с указанного момента (любое выражение GNU date,
                         например "2 days ago", "2026-08-01 09:00")
        --until EXPR     до указанного момента
        --log PATH       файл лога (можно указывать несколько раз, glob разрешён)
        --journal        читать journalctl -u postfix вместо файлов
        --stdin          читать лог со стандартного ввода
        --csv            вывод в формате CSV
        --json           вывод в формате JSON
        --tsv            вывод в формате TSV (без заголовков)
        --no-header      не печатать заголовок таблицы
    -h, --help           показать справку
    -V, --version        показать версию

ПРИМЕРЫ
    mail_analyzer.sh in --today
    mail_analyzer.sh out -n 20 --last-24h
    mail_analyzer.sh routes --since "3 days ago" --json
    mail_analyzer.sh sizes --csv > sizes.csv
    mail_analyzer.sh failed --last-hour
    zcat /backup/mail.log.gz | mail_analyzer.sh summary --stdin

ЗАМЕЧАНИЯ
    * Для чтения /var/log/mail.log* обычно нужны права root (sudo).
    * Файлы читаются от самых старых к самым новым, чтобы корректно
      связать qmgr-записи (отправитель, размер) с доставками по QID.
    * Поддерживаются и традиционные syslog-метки времени ("Aug 20 12:00:00"),
      и метки RFC 3339 ("2026-08-20T12:00:00.123456+03:00").
USAGE_EOF
}

# Перевод выражения даты в unix-время.
to_epoch() {
    local expr="$1" out
    if ! out=$(date -d "$expr" +%s 2>/dev/null); then
        die "не удалось разобрать дату: '$expr' (требуется GNU date)"
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
parse_args() {
    local arg
    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            in|out|senders|recipients|relay_in|relay_out|relay_ips|routes|sizes|\
            avg_sizes|failed|bounced|deferred|reasons|summary|raw)
                [ -n "$COMMAND" ] && die "команда уже задана: '$COMMAND' (лишний аргумент '$arg')"
                COMMAND="$arg"
                ;;
            help|-h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$PROGNAME" "$VERSION"
                exit 0
                ;;
            -n|--top)
                [ $# -ge 2 ] || die "опция $arg требует аргумент"
                shift
                TOP="$1"
                ;;
            --top=*) TOP="${arg#*=}" ;;
            --today)      SINCE_EPOCH=$(to_epoch "today 00:00:00") ;;
            --last-hour)  SINCE_EPOCH=$(to_epoch "1 hour ago") ;;
            --last-24h)   SINCE_EPOCH=$(to_epoch "24 hours ago") ;;
            --since)
                [ $# -ge 2 ] || die "опция $arg требует аргумент"
                shift
                SINCE_EPOCH=$(to_epoch "$1")
                ;;
            --since=*) SINCE_EPOCH=$(to_epoch "${arg#*=}") ;;
            --until)
                [ $# -ge 2 ] || die "опция $arg требует аргумент"
                shift
                UNTIL_EPOCH=$(to_epoch "$1")
                ;;
            --until=*) UNTIL_EPOCH=$(to_epoch "${arg#*=}") ;;
            --log)
                [ $# -ge 2 ] || die "опция $arg требует аргумент"
                shift
                LOG_ARGS+=("$1")
                ;;
            --log=*) LOG_ARGS+=("${arg#*=}") ;;
            --journal)   USE_JOURNAL=1 ;;
            --stdin)     READ_STDIN=1 ;;
            --csv)       FORMAT="csv" ;;
            --json)      FORMAT="json" ;;
            --tsv)       FORMAT="tsv" ;;
            --no-header) SHOW_HEADER=0 ;;
            --)
                shift
                while [ $# -gt 0 ]; do LOG_ARGS+=("$1"); shift; done
                break
                ;;
            -*)
                die "неизвестная опция: '$arg' (см. $PROGNAME help)"
                ;;
            *)
                if [ -z "$COMMAND" ]; then
                    die "неизвестная команда: '$arg' (см. $PROGNAME help)"
                fi
                LOG_ARGS+=("$arg")
                ;;
        esac
        shift
    done

    case "$TOP" in *[!0-9]*) die "некорректное значение --top: '$TOP'";; esac

    if [ "$SINCE_EPOCH" -gt 0 ] && [ "$UNTIL_EPOCH" -gt 0 ] && \
       [ "$SINCE_EPOCH" -gt "$UNTIL_EPOCH" ]; then
        die "--since позже, чем --until"
    fi
}

# ---------------------------------------------------------------------------
# Источники логов
# ---------------------------------------------------------------------------

# Раскрывает glob-шаблоны и оставляет только читаемые обычные файлы.
collect_files() {
    local pattern path
    local -a found=()
    for pattern in "$@"; do
        # shellcheck disable=SC2206  # glob-раскрытие здесь намеренное
        local -a expanded=( $pattern )
        for path in "${expanded[@]}"; do
            [ -f "$path" ] || continue
            found+=("$path")
        done
    done
    [ ${#found[@]} -gt 0 ] || return 0
    printf '%s\n' "${found[@]}"
}

# Сортирует файлы по времени изменения: от старых к новым.
sort_by_mtime() {
    local f mtime
    while IFS= read -r f; do
        mtime=$(stat -c %Y -- "$f" 2>/dev/null || printf '0')
        printf '%s\t%s\n' "$mtime" "$f"
    done | sort -n -k1,1 | cut -f2-
}

# Печатает содержимое одного файла, распаковывая при необходимости.
emit_file() {
    local f="$1"
    case "$f" in
        *.gz|*.Z)  if have gzip;  then gzip  -cd -- "$f"; else die "нужен gzip для $f";  fi ;;
        *.bz2)     if have bzip2; then bzip2 -cd -- "$f"; else die "нужен bzip2 для $f"; fi ;;
        *.xz|*.lzma) if have xz;  then xz    -cd -- "$f"; else die "нужен xz для $f";    fi ;;
        *.zst)     if have zstd;  then zstd  -cd -q -- "$f"; else die "нужен zstd для $f"; fi ;;
        *)         cat -- "$f" ;;
    esac
}

# Определяет источник данных до запуска пайплайна, чтобы ошибки доступа
# не терялись в середине конвейера и возвращался корректный код выхода.
SOURCE_MODE=""
declare -a SOURCE_FILES=()

resolve_sources() {
    if [ "$READ_STDIN" -eq 1 ]; then
        SOURCE_MODE="stdin"
        return
    fi

    if [ "$USE_JOURNAL" -eq 1 ]; then
        have journalctl || die "journalctl не найден"
        SOURCE_MODE="journal"
        return
    fi

    local -a patterns=()
    if [ ${#LOG_ARGS[@]} -gt 0 ]; then
        patterns=("${LOG_ARGS[@]}")
    else
        patterns=("${DEFAULT_LOG_GLOBS[@]}")
    fi

    local files f
    files=$(collect_files "${patterns[@]}" | sort_by_mtime)

    if [ -n "$files" ]; then
        local skipped=0
        while IFS= read -r f; do
            if [ -r "$f" ]; then
                SOURCE_FILES+=("$f")
            else
                skipped=1
                printf '%s: нет прав на чтение %s\n' "$PROGNAME" "$f" >&2
            fi
        done <<< "$files"

        if [ ${#SOURCE_FILES[@]} -eq 0 ]; then
            die "все найденные файлы недоступны для чтения (попробуйте sudo $PROGNAME $COMMAND)"
        fi
        [ "$skipped" -eq 1 ] && printf '%s: часть файлов пропущена из-за прав доступа\n' "$PROGNAME" >&2
        SOURCE_MODE="files"
        return
    fi

    if [ ${#LOG_ARGS[@]} -gt 0 ]; then
        die "не найдено ни одного файла лога: ${LOG_ARGS[*]}"
    fi

    # Логи по умолчанию не найдены — возможно, данные подаются на stdin.
    if [ ! -t 0 ]; then
        printf '%s: логи не найдены, читаю стандартный ввод\n' "$PROGNAME" >&2
        SOURCE_MODE="stdin"
        return
    fi

    printf '%s: логи не найдены в: %s\n' "$PROGNAME" "${DEFAULT_LOG_GLOBS[*]}" >&2
    printf 'Укажите путь явно:  %s %s --log /path/to/mail.log\n' "$PROGNAME" "$COMMAND" >&2
    printf 'Или передайте stdin: cat mail.log | %s %s --stdin\n' "$PROGNAME" "$COMMAND" >&2
    printf 'Или читайте журнал:  %s %s --journal\n' "$PROGNAME" "$COMMAND" >&2
    exit 1
}

# Отдаёт весь поток логов на stdout.
read_logs() {
    case "$SOURCE_MODE" in
        stdin)
            cat
            ;;
        journal)
            local -a jargs=(-u postfix -u postfix@- --no-pager -o short-iso)
            # Берём час запаса: точную отсечку делает awk, а запас нужен, чтобы
            # в выборку попали qmgr-строки, связывающие QID с отправителем.
            [ "$SINCE_EPOCH" -gt 0 ] && jargs+=(--since "@$((SINCE_EPOCH - 3600))")
            [ "$UNTIL_EPOCH" -gt 0 ] && jargs+=(--until "@$UNTIL_EPOCH")
            journalctl "${jargs[@]}"
            ;;
        files)
            local f
            for f in "${SOURCE_FILES[@]}"; do
                emit_file "$f"
            done
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Разбор лога
#
# На выходе — TSV со следующими полями:
#   1 ts          unix-время записи
#   2 dir         направление: in | out | other
#   3 transport   smtp / lmtp / local / virtual / pipe / error / ...
#   4 status      sent / bounced / deferred / expired
#   5 from_addr   адрес отправителя (envelope)
#   6 from_domain домен отправителя
#   7 to_addr     адрес получателя
#   8 to_domain   домен получателя
#   9 relay_host  имя relay-сервера
#  10 relay_ip    IP relay-сервера
#  11 size        размер письма в байтах (0 — неизвестен)
#  12 dsn         код DSN
#  13 reason      текст ответа сервера (для неуспешных доставок)
#
# Реализация намеренно использует только POSIX-возможности awk: трёхаргументный
# match() и mktime() есть лишь в gawk, а на Debian/Ubuntu awk — это mawk.
# ---------------------------------------------------------------------------
PARSER_AWK='
BEGIN {
    FS = " "
    OFS = "\t"
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mlist, " ")
    for (i = 1; i <= 12; i++) mnum[mlist[i]] = i
}

# --- работа со временем -----------------------------------------------------

function days_from_civil(y, m, d,   era, yoe, doy, doe, yy) {
    yy = (m <= 2) ? y - 1 : y
    era = (yy >= 0 ? yy : yy - 399)
    era = int(era / 400)
    yoe = yy - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}

function civil_to_epoch(y, m, d, H, M, S) {
    return days_from_civil(y, m, d) * 86400 + H * 3600 + M * 60 + S
}

# "Aug 20 12:00:00" — год в syslog не пишется, поэтому берём текущий,
# а если получилось будущее (лог пережил смену года) — предыдущий.
function ts_syslog(mon, day, tm,   t, e) {
    sub(/^<[0-9]+>/, "", mon)
    if (!(mon in mnum)) return -1
    split(tm, t, ":")
    e = civil_to_epoch(cur_year, mnum[mon], day + 0, t[1] + 0, t[2] + 0, t[3] + 0) - tz_off
    if (e > now + 86400) e = civil_to_epoch(cur_year - 1, mnum[mon], day + 0, t[1] + 0, t[2] + 0, t[3] + 0) - tz_off
    return e
}

# "2026-08-20T12:00:00.123456+03:00" / "...Z" / "2026-08-20 12:00:00"
function ts_iso(s,   p, dpart, tpart, d, t, off, sign, oh, om, e) {
    sub(/^<[0-9]+>/, "", s)
    p = index(s, "T")
    if (p == 0) p = index(s, " ")
    if (p == 0) return -1
    dpart = substr(s, 1, p - 1)
    tpart = substr(s, p + 1)
    split(dpart, d, "-")
    off = 0
    if (tpart ~ /Z$/) {
        sub(/Z$/, "", tpart)
    } else if (match(tpart, /[+-][0-9][0-9]:?[0-9][0-9]$/)) {
        sign = (substr(tpart, RSTART, 1) == "-") ? -1 : 1
        oh = substr(tpart, RSTART + 1, 2) + 0
        om = substr(tpart, RSTART + RLENGTH - 2, 2) + 0
        off = sign * (oh * 3600 + om * 60)
        tpart = substr(tpart, 1, RSTART - 1)
    } else {
        off = tz_off
    }
    split(tpart, t, ":")
    e = civil_to_epoch(d[1] + 0, d[2] + 0, d[3] + 0, t[1] + 0, t[2] + 0, int(t[3] + 0))
    return e - off
}

# --- разбор полей postfix ---------------------------------------------------

# Значение вида key=<...>
function angle(line, key,   p, v, q) {
    p = index(line, " " key "=<")
    if (p == 0) return ""
    v = substr(line, p + length(key) + 3)
    q = index(v, ">")
    if (q == 0) return ""
    return substr(v, 1, q - 1)
}

# Значение вида key=... до запятой или пробела
function val(line, key,   p, v) {
    p = index(line, " " key "=")
    if (p == 0) return ""
    v = substr(line, p + length(key) + 2)
    if (match(v, /[,;]|[ \t]/)) v = substr(v, 1, RSTART - 1)
    return v
}

# Текст в скобках после status=... — ответ удалённого сервера
function status_reason(line,   p, v, q, depth, i, c) {
    p = index(line, " status=")
    if (p == 0) return ""
    v = substr(line, p + 8)
    q = index(v, "(")
    if (q == 0) return ""
    v = substr(v, q + 1)
    depth = 1
    for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1)
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) return substr(v, 1, i - 1) }
    }
    return v
}

function domain_of(addr,   d, p) {
    if (addr == "") return ""
    d = addr
    while ((p = index(d, "@")) > 0) d = substr(d, p + 1)
    if (d == "") return ""
    d = tolower(d)
    sub(/\.+$/, "", d)
    sub(/^\[/, "", d)
    sub(/\]$/, "", d)
    if (d == addr && index(addr, "@") == 0) return "(local)"
    return (d == "" ? "(local)" : d)
}

function relay_host_of(r,   h, p) {
    if (r == "") return ""
    h = r
    p = index(h, "[")
    if (p > 0) h = substr(h, 1, p - 1)
    else sub(/:[0-9]+$/, "", h)
    return tolower(h)
}

function relay_ip_of(r,   p, v, q) {
    p = index(r, "[")
    if (p == 0) return ""
    v = substr(r, p + 1)
    q = index(v, "]")
    if (q == 0) return ""
    return substr(v, 1, q - 1)
}

function plural(n, one, few, many,   n10, n100) {
    n10 = n % 10; n100 = n % 100
    if (n10 == 1 && n100 != 11) return one
    if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few
    return many
}

function clean(s) {
    gsub(/[\t\r\n]/, " ", s)
    gsub(/  +/, " ", s)
    sub(/^ +/, "", s)
    sub(/ +$/, "", s)
    return s
}

# --- основной цикл ----------------------------------------------------------

{
    # Дешёвая отсечка: в почтовом логе полно строк dovecot, spamd и прочих.
    if (index($0, "postfix") == 0) next

    # Ищем поле "postfix/<transport>[pid]:" — так разбор не зависит от того,
    # traditional или RFC 3339 формат меток времени и есть ли имя хоста.
    pi = 0
    n = (NF < 9 ? NF : 9)
    for (i = 1; i <= n; i++) {
        if (index($i, "postfix") > 0 && index($i, "/") > 0) { pi = i; break }
    }
    if (pi == 0) next

    # Берём последний компонент "postfix/…/<transport>[pid]:" через index/substr:
    # regexp со слэшем внутри класса символов не переваривает busybox awk.
    transport = $pi
    while ((sp = index(transport, "/")) > 0) transport = substr(transport, sp + 1)
    sub(/\[[0-9]+\]:?$/, "", transport)
    sub(/:$/, "", transport)

    qid = ""
    if (pi + 1 <= NF && $(pi + 1) ~ /^[0-9A-Za-z]+:$/) {
        qid = substr($(pi + 1), 1, length($(pi + 1)) - 1)
        if (qid == "NOQUEUE" || qid == "warning" || qid == "fatal") qid = ""
    }

    # qmgr запоминает отправителя и размер письма для очереди.
    if (transport == "qmgr") {
        if (qid == "") next
        if (index($0, " removed") > 0) {
            delete qfrom[qid]
            delete qsize[qid]
            next
        }
        f = angle($0, "from")
        if (f != "" || index($0, " from=<>") > 0) qfrom[qid] = f
        sz = val($0, "size")
        if (sz != "") qsize[qid] = sz + 0
        next
    }

    # cleanup связывает QID с message-id, отправитель там же не встречается.
    if (transport == "cleanup" || transport == "smtpd" || transport == "postscreen") next

    st = val($0, "status")
    if (st == "") next

    # Метку времени разбираем только здесь: до этого места доходит малая часть
    # строк лога, и на больших файлах экономия заметна.
    # Поля 1 .. pi-2 — время, поле pi-1 — имя хоста.
    nts = pi - 2
    if (nts == 3)      ts = ts_syslog($1, $2, $3)
    else if (nts == 1) ts = ts_iso($1)
    else if (nts == 2) ts = ts_iso($1 " " $2)
    else               ts = -1
    if (ts < 0) ts = 0

    # Временной фильтр применяется только к записям о доставке: строки qmgr
    # обрабатываются всегда, иначе на границе окна терялся бы отправитель.
    if (since > 0 || until > 0) {
        # Время не разобрано — при активном фильтре запись отбрасываем,
        # иначе она молча попала бы в выборку за пределами окна.
        if (ts == 0) { unparsed++; next }
        if (since > 0 && ts < since) next
        if (until > 0 && ts > until) next
    }

    to_addr = angle($0, "to")
    relay   = val($0, "relay")
    dsn     = val($0, "dsn")
    size    = (qid != "" && (qid in qsize)) ? qsize[qid] : 0
    if (size == 0) { sz = val($0, "size"); if (sz != "") size = sz + 0 }
    from_addr = (qid != "" && (qid in qfrom)) ? qfrom[qid] : ""

    rhost = relay_host_of(relay)
    rip   = relay_ip_of(relay)

    if (transport == "smtp")
        dir = (rhost == "" || rhost == "none" || rhost == "local") ? "other" : "out"
    else if (transport == "lmtp" || transport == "local" || transport == "virtual" || transport == "pipe")
        dir = "in"
    else
        dir = "other"

    fd = domain_of(from_addr)
    td = domain_of(to_addr)
    if (from_addr == "") fd = "(bounce)"
    if (to_addr == "")   td = "-"

    emitted++
    print ts, dir, transport, st, \
          (from_addr == "" ? "-" : from_addr), (fd == "" ? "-" : fd), \
          (to_addr == "" ? "-" : to_addr),     (td == "" ? "-" : td), \
          (rhost == "" ? "-" : rhost),         (rip == "" ? "-" : rip), \
          size, (dsn == "" ? "-" : dsn), clean(status_reason($0))
}

END {
    if (unparsed > 0)
        printf "%s: пропущено записей с неразобранной меткой времени: %d\n", progname, unparsed > "/dev/stderr"
}
'

parse_logs() {
    read_logs | awk -v since="$SINCE_EPOCH" \
                    -v until="$UNTIL_EPOCH" \
                    -v progname="$PROGNAME" \
                    -v cur_year="$(date +%Y)" \
                    -v now="$(date +%s)" \
                    -v tz_off="$(date +%z | awk '{s=(substr($0,1,1)=="-")?-1:1; print s*(substr($0,2,2)*3600+substr($0,4,2)*60)}')" \
                    "$PARSER_AWK"
}

# ---------------------------------------------------------------------------
# Вывод результатов
# ---------------------------------------------------------------------------
RENDER_AWK='
BEGIN { FS = "\t" }

# Ширина строки в символах, а не в байтах (продолжающие байты UTF-8 не в счёт).
function dwidth(s,   t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
function pad(s, w,   n, r) { n = w - dwidth(s); r = s; while (n-- > 0) r = r " "; return r }
function rule(w,   r) { r = ""; while (w-- > 0) r = r "-"; return r }

function jesc(s,   out, i, c, n) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\"") out = out "\\\""
        else if (c == "\\") out = out "\\\\"
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else out = out c
    }
    return out
}

function csvesc(s) {
    if (s ~ /[",\n\r]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
    return s
}

function isnum(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) }

{
    if (top > 0 && rows >= top) next
    rows++
    if (swap) { lab[rows] = $1; num[rows] = $2 }
    else      { num[rows] = $1; lab[rows] = $2 }
    for (i = 3; i <= NF; i++) lab[rows] = lab[rows] "\t" $i
}

END {
    if (fmt == "tsv") {
        for (i = 1; i <= rows; i++) print num[i] "\t" lab[i]
        exit
    }

    if (fmt == "csv") {
        if (show_header) print csvesc(k1) "," csvesc(k2)
        for (i = 1; i <= rows; i++) {
            if (swap) print csvesc(lab[i]) "," csvesc(num[i])
            else      print csvesc(num[i]) "," csvesc(lab[i])
        }
        exit
    }

    if (fmt == "json") {
        printf "{\n"
        printf "  \"title\": \"%s\",\n", jesc(title)
        printf "  \"generated_at\": \"%s\",\n", jesc(generated)
        printf "  \"count\": %d,\n", rows
        printf "  \"rows\": ["
        for (i = 1; i <= rows; i++) {
            printf "%s\n    {", (i == 1 ? "" : ",")
            if (swap) {
                printf "\"%s\": \"%s\", ", jesc(k1), jesc(lab[i])
                if (isnum(num[i])) printf "\"%s\": %s", jesc(k2), num[i]
                else               printf "\"%s\": \"%s\"", jesc(k2), jesc(num[i])
            } else {
                if (isnum(num[i])) printf "\"%s\": %s, ", jesc(k1), num[i]
                else               printf "\"%s\": \"%s\", ", jesc(k1), jesc(num[i])
                printf "\"%s\": \"%s\"", jesc(k2), jesc(lab[i])
            }
            printf "}"
        }
        printf "%s]\n}\n", (rows ? "\n  " : "")
        exit
    }

    # table
    w = dwidth(h1)
    for (i = 1; i <= rows; i++) {
        v = swap ? lab[i] : num[i]
        if (dwidth(v) > w) w = dwidth(v)
    }
    if (w < 10) w = 10
    if (show_header) {
        print "=== " title " ==="
        print pad(h1, w) " | " h2
        print rule(w) "-|-" rule(dwidth(h2) < 20 ? 20 : dwidth(h2))
    }
    if (rows == 0) { print "(нет данных)"; exit }
    for (i = 1; i <= rows; i++) {
        if (swap) print pad(lab[i], w) " | " num[i]
        else      print pad(num[i], w) " | " lab[i]
    }
}
'

render() {
    local title="$1" h1="$2" h2="$3" k1="$4" k2="$5" swap="${6:-0}"
    awk -v title="$title" -v h1="$h1" -v h2="$h2" -v k1="$k1" -v k2="$k2" \
        -v fmt="$FORMAT" -v show_header="$SHOW_HEADER" -v top="$TOP" -v swap="$swap" \
        -v generated="$(date '+%Y-%m-%d %H:%M:%S')" \
        "$RENDER_AWK"
}

# Сортировка "число <TAB> подпись" по убыванию числа.
sort_desc() { sort -t "$(printf '\t')" -k1,1nr -k2,2; }

# ---------------------------------------------------------------------------
# Команды
# ---------------------------------------------------------------------------

# count_by <awk-условие> <awk-выражение-ключа>
count_by() {
    parse_logs | awk -F'\t' '
        BEGIN { OFS = "\t" }
        '"$1"' { key = '"$2"'; if (key != "" && key != "-") c[key]++ }
        END { for (k in c) print c[k], k }
    ' | sort_desc
}

cmd_in()         { count_by '$4 == "sent" && $6 != "(bounce)"' '$6' | render "ТОП-$TOP ВХОДЯЩИХ ДОМЕНОВ (откуда приходят письма)" "Количество" "Домен отправителя" "count" "domain"; }
cmd_out()        { count_by '$4 == "sent"' '$8'  | render "ТОП-$TOP ИСХОДЯЩИХ ДОМЕНОВ (куда отправляются письма)" "Количество" "Домен получателя" "count" "domain"; }
cmd_senders()    { count_by '$4 == "sent"' '$5'  | render "ТОП-$TOP ОТПРАВИТЕЛЕЙ" "Количество" "Адрес отправителя" "count" "address"; }
cmd_recipients() { count_by '$4 == "sent"' '$7'  | render "ТОП-$TOP ПОЛУЧАТЕЛЕЙ" "Количество" "Адрес получателя" "count" "address"; }
cmd_relay_in()   { count_by '$2 == "in"  && $4 == "sent"' '$9' | render "ТОП-$TOP RELAY ДЛЯ ВХОДЯЩЕЙ ПОЧТЫ" "Количество" "Relay-сервер" "count" "relay"; }
cmd_relay_out()  { count_by '$2 == "out" && $4 == "sent"' '$9' | render "ТОП-$TOP RELAY ДЛЯ ИСХОДЯЩЕЙ ПОЧТЫ" "Количество" "Relay-сервер" "count" "relay"; }
cmd_relay_ips()  { count_by '$4 == "sent"' '$10' | render "ТОП-$TOP IP RELAY-СЕРВЕРОВ" "Количество" "IP-адрес" "count" "ip"; }
cmd_routes()     { count_by '$4 == "sent"' '$6 " -> " $8 " -> " $9' | render "ТОП-$TOP МАРШРУТОВ ПИСЕМ" "Количество" "Отправитель -> Получатель -> Relay" "count" "route"; }
cmd_bounced()    { count_by '$4 == "bounced"'  '$8' | render "ТОП-$TOP ДОМЕНОВ С ОТСКОКАМИ" "Количество" "Домен получателя" "count" "domain"; }
cmd_deferred()   { count_by '$4 == "deferred"' '$8' | render "ТОП-$TOP ДОМЕНОВ С ОТЛОЖЕННОЙ ДОСТАВКОЙ" "Количество" "Домен получателя" "count" "domain"; }
cmd_failed()     { count_by '$4 != "sent"' '$8 " (" $4 ")"' | render "ТОП-$TOP НЕУДАЧНЫХ ДОСТАВОК" "Количество" "Домен получателя (статус)" "count" "target"; }

cmd_reasons() {
    parse_logs | awk -F'\t' '
        BEGIN { OFS = "\t" }
        $4 != "sent" {
            r = $13
            if (r == "") r = "(без описания)"
            if (length(r) > 110) r = substr(r, 1, 107) "..."
            key = ($12 == "-" ? "" : $12 " ") r
            c[key]++
        }
        END { for (k in c) print c[k], k }
    ' | sort_desc | render "ТОП-$TOP ПРИЧИН НЕУДАЧНОЙ ДОСТАВКИ" "Количество" "DSN и причина" "count" "reason"
}

cmd_sizes() {
    parse_logs | awk -F'\t' '
        BEGIN { OFS = "\t" }
        function plural(n, one, few, many,   n10, n100) {
            n10 = n % 10; n100 = n % 100
            if (n10 == 1 && n100 != 11) return one
            if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few
            return many
        }
        $4 == "sent" && $6 != "-" && $6 != "(bounce)" { bytes[$6] += $11; msgs[$6]++ }
        END {
            for (d in bytes)
                printf "%.2f\t%s (%d %s)\n", bytes[d] / 1048576, d, msgs[d], plural(msgs[d], "письмо", "письма", "писем")
        }
    ' | sort_desc | render "ТОП-$TOP ОТПРАВИТЕЛЕЙ ПО ОБЪЁМУ (МБ)" "Объём, МБ" "Домен отправителя" "megabytes" "domain"
}

cmd_avg_sizes() {
    parse_logs | awk -F'\t' '
        BEGIN { OFS = "\t" }
        function plural(n, one, few, many,   n10, n100) {
            n10 = n % 10; n100 = n % 100
            if (n10 == 1 && n100 != 11) return one
            if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few
            return many
        }
        $4 == "sent" && $6 != "-" && $6 != "(bounce)" && $11 > 0 { bytes[$6] += $11; msgs[$6]++ }
        END {
            for (d in bytes)
                printf "%.1f\t%s (%d %s)\n", bytes[d] / msgs[d] / 1024, d, msgs[d], plural(msgs[d], "письмо", "письма", "писем")
        }
    ' | sort_desc | render "СРЕДНИЙ РАЗМЕР ПИСЬМА ПО ДОМЕНАМ (КБ)" "Размер, КБ" "Домен отправителя" "kilobytes" "domain"
}

cmd_summary() {
    parse_logs | awk -F'\t' '
        BEGIN { OFS = "\t"; min_ts = 0; max_ts = 0 }
        {
            total++
            st[$4]++
            if ($1 > 0) {
                if (min_ts == 0 || $1 < min_ts) min_ts = $1
                if ($1 > max_ts) max_ts = $1
            }
            if ($4 == "sent") {
                sent++
                if ($6 != "-" && $6 != "(bounce)") fdom[$6] = 1
                if ($8 != "-") tdom[$8] = 1
                if ($9 != "-") rel[$9] = 1
                bytes += $11
                if ($11 > 0) sized++
                if ($2 == "in")  inc++
                if ($2 == "out") outc++
            }
        }
        END {
            nf = 0; for (d in fdom) nf++
            nt = 0; for (d in tdom) nt++
            nr = 0; for (d in rel)  nr++
            printf "Записей о доставке\t%d\n", total
            printf "Успешно доставлено\t%d\n", sent + 0
            printf "Отскоки (bounced)\t%d\n", st["bounced"] + 0
            printf "Отложено (deferred)\t%d\n", st["deferred"] + 0
            printf "Просрочено (expired)\t%d\n", st["expired"] + 0
            if (total > 0) printf "Доля успешных, %%\t%.1f\n", 100 * (sent + 0) / total
            printf "Входящая почта (local/virtual/lmtp)\t%d\n", inc + 0
            printf "Исходящая почта (smtp)\t%d\n", outc + 0
            printf "Уникальных доменов отправителей\t%d\n", nf
            printf "Уникальных доменов получателей\t%d\n", nt
            printf "Уникальных relay-серверов\t%d\n", nr
            printf "Общий объём, МБ\t%.2f\n", bytes / 1048576
            if (sized > 0) printf "Средний размер письма, КБ\t%.1f\n", bytes / sized / 1024
            if (min_ts > 0) {
                cmd = "date -d @" min_ts " \"+%Y-%m-%d %H:%M:%S\" 2>/dev/null"
                cmd | getline a; close(cmd)
                cmd = "date -d @" max_ts " \"+%Y-%m-%d %H:%M:%S\" 2>/dev/null"
                cmd | getline b; close(cmd)
                printf "Период (первая запись)\t%s\n", (a == "" ? min_ts : a)
                printf "Период (последняя запись)\t%s\n", (b == "" ? max_ts : b)
            }
        }
    ' | ( TOP=0; render "СВОДНАЯ СТАТИСТИКА" "Метрика" "Значение" "metric" "value" 1 )
}

cmd_raw() { parse_logs; }

# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
main() {
    export LC_ALL=C

    if [ $# -eq 0 ]; then
        usage >&2
        exit 1
    fi

    parse_args "$@"

    if [ -z "$COMMAND" ]; then
        die "не указана команда (см. $PROGNAME help)"
    fi

    have awk  || die "не найден awk"
    have sort || die "не найден sort"
    have date || die "не найден date"

    resolve_sources

    case "$COMMAND" in
        in)         cmd_in ;;
        out)        cmd_out ;;
        senders)    cmd_senders ;;
        recipients) cmd_recipients ;;
        relay_in)   cmd_relay_in ;;
        relay_out)  cmd_relay_out ;;
        relay_ips)  cmd_relay_ips ;;
        routes)     cmd_routes ;;
        sizes)      cmd_sizes ;;
        avg_sizes)  cmd_avg_sizes ;;
        failed)     cmd_failed ;;
        bounced)    cmd_bounced ;;
        deferred)   cmd_deferred ;;
        reasons)    cmd_reasons ;;
        summary)    cmd_summary ;;
        raw)        cmd_raw ;;
        *)          die "неизвестная команда: '$COMMAND'" ;;
    esac
}

main "$@"
