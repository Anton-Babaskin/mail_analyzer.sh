#!/usr/bin/env bash
#
# Тесты для mail_analyzer.sh. Запуск: ./tests/run_tests.sh
# Используется awk из PATH — чтобы проверить другую реализацию, поставьте её в PATH первой.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SCRIPT="./mail_analyzer.sh"
LOG="tests/sample_mail.log"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     ожидалось: %s\n     получено:  %s\n' "$1" "$2" "$3"; }

# check <описание> <ожидаемое> <команда...>
check() {
    local desc="$1" want="$2"; shift 2
    local got
    got=$("$@" 2>/dev/null)
    if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "$want" "$got"; fi
}

# check_status <описание> <ожидаемый-код> <команда...>
check_status() {
    local desc="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "код $want" "код $got"; fi
}

echo "== разбор лога =="
check "in: топ доменов отправителей" \
    "2	example.com
2	gmail.com
1	mail.ru" \
    $SCRIPT in --log "$LOG" --tsv

check "out: топ доменов получателей" \
    "2	example.com
1	gmail.com
1	mail.ru
1	mx1.example.com
1	yandex.ru" \
    $SCRIPT out --log "$LOG" --tsv

check "relay_out: только транспорт smtp" \
    "1	gmail-smtp-in.l.google.com
1	mx.yandex.ru
1	mxs.mail.ru" \
    $SCRIPT relay_out --log "$LOG" --tsv

check "relay_in: local/virtual/lmtp" \
    "1	127.0.0.1
1	local
1	virtual" \
    $SCRIPT relay_in --log "$LOG" --tsv

check "bounced: домены с отскоками" "1	yandex.ru" \
    $SCRIPT bounced --log "$LOG" --tsv

check "deferred: отложенные" "1	slowdomain.tld" \
    $SCRIPT deferred --log "$LOG" --tsv

check "sizes: объём по доменам" \
    "2.00	example.com (2 письма)
0.51	gmail.com (2 письма)
0.02	mail.ru (1 письмо)" \
    $SCRIPT sizes --log "$LOG" --tsv

check "smtpd NOQUEUE reject не попадает в статистику" "8" \
    bash -c "$SCRIPT raw --log $LOG | wc -l | tr -d ' '"

check "пустой отправитель (bounce) помечается отдельно" "1" \
    bash -c "$SCRIPT raw --log $LOG | cut -f6 | grep -c '(bounce)'"

echo "== ограничение вывода =="
check "-n 2 ограничивает вывод" "2" \
    bash -c "$SCRIPT out --log $LOG --tsv -n 2 | wc -l | tr -d ' '"
check "-n 0 выводит всё" "5" \
    bash -c "$SCRIPT out --log $LOG --tsv -n 0 | wc -l | tr -d ' '"

echo "== временные фильтры =="
check "--since отсекает ранние записи" "5" \
    bash -c "$SCRIPT raw --log $LOG --since '2026-08-20 10:00' | wc -l | tr -d ' '"
check "--until отсекает поздние записи" "4" \
    bash -c "$SCRIPT raw --log $LOG --until '2026-08-20 10:20' | wc -l | tr -d ' '"
check "окно --since/--until" "3" \
    bash -c "$SCRIPT raw --log $LOG --since '2026-08-20 09:30' --until '2026-08-20 11:15' | wc -l | tr -d ' '"
check "отправитель не теряется, если qmgr-строка вне окна" "carol@example.com" \
    bash -c "$SCRIPT raw --log $LOG --since '2026-08-20 09:05:11' | head -1 | cut -f5"

echo "== форматы вывода =="
check_status "--json выдаёт валидный JSON" 0 \
    bash -c "$SCRIPT routes --log $LOG --json | python3 -m json.tool"
check_status "--json валиден и при пустом результате" 0 \
    bash -c "$SCRIPT bounced --log $LOG --since 2030-01-01 --json | python3 -m json.tool"
check "--csv экранирует запятые и кавычки" \
    'count,reason
1,"5.0.0 said: 550 ""bad, very bad"""' \
    bash -c "printf 'Aug 20 09:00:00 mx postfix/qmgr[1]: A1: from=<a@b.c>, size=10, nrcpt=1 (queue active)\nAug 20 09:00:01 mx postfix/smtp[2]: A1: to=<b@t.c>, relay=r[1.1.1.1]:25, dsn=5.0.0, status=bounced (said: 550 \"bad, very bad\")\n' | $SCRIPT reasons --stdin --csv"

echo "== метки времени =="
check "RFC 3339 со смещением +03:00" "2026-08-20 09:00:01 UTC" \
    bash -c "printf '2026-08-20T12:00:00+03:00 mx postfix/qmgr[1]: Z1: from=<a@t.t>, size=1, nrcpt=1 (queue active)\n2026-08-20T12:00:01+03:00 mx postfix/smtp[2]: Z1: to=<b@t.t>, relay=r[1.1.1.1]:25, dsn=2.0.0, status=sent (250 ok)\n' | $SCRIPT raw --stdin | cut -f1 | xargs -I{} date -u -d @{} '+%F %T UTC'"

check "RFC 3339 с суффиксом Z" "2026-08-20 10:00:04 UTC" \
    bash -c "printf '2026-08-20T10:00:03Z mx postfix/qmgr[1]: Z2: from=<a@t.t>, size=1, nrcpt=1 (queue active)\n2026-08-20T10:00:04Z mx postfix/smtp[2]: Z2: to=<b@t.t>, relay=r[1.1.1.1]:25, dsn=2.0.0, status=sent (250 ok)\n' | $SCRIPT raw --stdin | cut -f1 | xargs -I{} date -u -d @{} '+%F %T UTC'"

echo "== источники данных =="
check "чтение со stdin" "2	example.com" \
    bash -c "cat $LOG | $SCRIPT in --stdin --tsv -n 1"
check "чтение gzip" "2	example.com" \
    bash -c "tmp=\$(mktemp -d); gzip -c $LOG > \$tmp/mail.log.gz; $SCRIPT in --log \"\$tmp/mail.log.gz\" --tsv -n 1; rm -rf \$tmp"
check "несколько файлов объединяются" "16" \
    bash -c "tmp=\$(mktemp -d); cp $LOG \$tmp/a.log; cp $LOG \$tmp/b.log; $SCRIPT raw --log \"\$tmp/*.log\" | wc -l | tr -d ' '; rm -rf \$tmp"

echo "== обработка ошибок =="
check_status "неизвестная команда -> код 1" 1 $SCRIPT bogus
check_status "неизвестная опция -> код 1"  1 $SCRIPT in --bogus
check_status "нечисловой -n -> код 1"      1 $SCRIPT in -n abc
check_status "некорректная дата -> код 1"  1 $SCRIPT in --since "not a date"
check_status "отсутствующий файл -> код 1" 1 $SCRIPT in --log /nope/nothing.log
check_status "--since позже --until -> код 1" 1 $SCRIPT in --since 2026-01-01 --until 2025-01-01
check_status "две команды сразу -> код 1"  1 $SCRIPT in out
check_status "без аргументов -> код 1"     1 $SCRIPT
check_status "help -> код 0"               0 $SCRIPT help

echo
printf 'Итого: %d успешно, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
