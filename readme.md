# Mail Log Domain Analyzer 📧

[![ShellCheck](https://img.shields.io/badge/ShellCheck-passed-green)](https://github.com/koalaman/shellcheck) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f.svg)](https://www.gnu.org/software/bash/)

Bash-скрипт для анализа логов Postfix. Считает статистику по доменам, адресам,
relay-серверам, маршрутам, объёмам трафика и ошибкам доставки — из файлов
`/var/log/mail.log*`, из журнала systemd или из потока на stdin.

## 🚀 Возможности

### Анализ
| Команда | Что показывает |
|---|---|
| `in` | топ доменов отправителей (успешные доставки) |
| `out` | топ доменов получателей (успешные доставки) |
| `senders` | топ адресов отправителей |
| `recipients` | топ адресов получателей |
| `relay_in` | relay для входящей почты (`local` / `virtual` / `lmtp` / `pipe`) |
| `relay_out` | relay для исходящей почты (транспорт `smtp`) |
| `relay_ips` | топ IP-адресов relay-серверов |
| `routes` | маршруты: домен отправителя → получателя → relay |
| `sizes` | топ доменов отправителей по объёму трафика (МБ) |
| `avg_sizes` | средний размер письма по доменам (КБ) |
| `failed` | все неуспешные доставки (bounced + deferred + expired) |
| `bounced` | только отскоки (`status=bounced`) |
| `deferred` | только отложенные (`status=deferred`) |
| `reasons` | топ причин неуспешной доставки (DSN + ответ сервера) |
| `summary` | сводная статистика за выбранный период |
| `raw` | разобранные записи в TSV — для собственных пайплайнов |

### Временные фильтры ⏰
- `--today` — только сегодняшние письма
- `--last-hour` — за последний час
- `--last-24h` — за последние 24 часа
- `--since EXPR` / `--until EXPR` — произвольное окно (любое выражение GNU `date`:
  `"2 days ago"`, `"2026-08-01 09:00"`, `"last monday"`)

### Форматы вывода 📊
- таблица (по умолчанию) — выровненные колонки с поддержкой UTF-8
- `--csv` — для Excel / Google Sheets, с корректным экранированием
- `--json` — валидный JSON для интеграций
- `--tsv` — «сырые» строки для `cut`, `awk` и прочих утилит

### Источники данных
- файлы `/var/log/mail.log*`, `/var/log/maillog*`, `/var/log/mail/mail.log*` (по умолчанию)
- `--log PATH` — произвольный путь или glob, опцию можно повторять
- `--journal` — `journalctl -u postfix`
- `--stdin` — поток на стандартном вводе
- сжатые файлы `.gz`, `.bz2`, `.xz`, `.zst`, `.Z` распаковываются на лету

## 📋 Требования

- **ОС**: Linux/Unix, Bash 4+
- **awk**: любой — `mawk`, `gawk` или `busybox awk` (скрипт не использует
  GNU-расширения вроде трёхаргументного `match()` или `mktime()`)
- **Утилиты**: `sort`, `date` (GNU), `stat`; для сжатых логов — `gzip` / `bzip2` / `xz` / `zstd`
- **Права**: чтение лог-файлов, обычно нужен `sudo`

## 🛠️ Установка

```bash
git clone https://github.com/Anton-Babaskin/mail_analyzer.sh.git
cd mail_analyzer.sh
chmod +x mail_analyzer.sh
```

## 📖 Использование

```
mail_analyzer.sh <команда> [опции] [файл-лога ...]
```

Полная справка: `./mail_analyzer.sh help`

### Примеры

```bash
# Топ-100 входящих и исходящих доменов
sudo ./mail_analyzer.sh in
sudo ./mail_analyzer.sh out

# Топ-20 получателей за сутки
sudo ./mail_analyzer.sh out -n 20 --last-24h

# Куда уходит трафик и сколько его
sudo ./mail_analyzer.sh sizes --today
sudo ./mail_analyzer.sh avg_sizes

# Разбор проблем доставки
sudo ./mail_analyzer.sh failed --last-hour
sudo ./mail_analyzer.sh reasons --last-24h

# Экспорт
sudo ./mail_analyzer.sh in --today --csv > incoming.csv
sudo ./mail_analyzer.sh routes --last-24h --json > routes.json

# Произвольное окно и свой файл лога
./mail_analyzer.sh summary --log /backup/mail.log.1.gz --since "2026-08-01" --until "2026-08-08"

# Журнал systemd вместо файлов
sudo ./mail_analyzer.sh out --journal --today

# Собственный пайплайн поверх raw
sudo ./mail_analyzer.sh raw --today | awk -F'\t' '$4 == "deferred" { print $8 }' | sort | uniq -c
```

## 📊 Примеры вывода

### Входящие домены

```
=== ТОП-100 ВХОДЯЩИХ ДОМЕНОВ (откуда приходят письма) ===
Количество | Домен отправителя
-----------|---------------------
2          | example.com
2          | gmail.com
1          | mail.ru
```

### Маршруты писем

```
=== ТОП-100 МАРШРУТОВ ПИСЕМ ===
Количество | Отправитель -> Получатель -> Relay
-----------|-----------------------------------
1          | example.com -> yandex.ru -> mx.yandex.ru
1          | gmail.com -> example.com -> virtual
```

### Сводка

```
=== СВОДНАЯ СТАТИСТИКА ===
Метрика                             | Значение
------------------------------------|---------------------
Записей о доставке                  | 8
Успешно доставлено                  | 6
Отскоки (bounced)                   | 1
Отложено (deferred)                 | 1
Доля успешных, %                    | 75.0
Уникальных доменов отправителей     | 3
Общий объём, МБ                     | 2.53
Период (первая запись)              | 2026-08-20 09:00:03
Период (последняя запись)           | 2026-08-20 12:00:01
```

### JSON

```json
{
  "title": "ТОП-100 ИСХОДЯЩИХ ДОМЕНОВ (куда отправляются письма)",
  "generated_at": "2026-08-20 12:20:43",
  "count": 5,
  "rows": [
    {"count": 2, "domain": "example.com"},
    {"count": 1, "domain": "gmail.com"}
  ]
}
```

## 🔧 Как это работает

1. **Выбор источника.** Файлы находятся по glob и читаются от самых старых к самым
   новым (по времени изменения) — это важно, чтобы `qmgr`-строка с отправителем
   встретилась раньше строки о доставке.
2. **Парсинг.** Строка вида `postfix/<transport>[pid]: <QID>: ...` разбирается через
   `index()`/`substr()`, без GNU-расширений awk. Поддерживаются традиционные
   syslog-метки (`Aug 20 12:00:00`), метки RFC 3339 (`2026-08-20T12:00:00+03:00`,
   в том числе с суффиксом `Z`) и префикс приоритета syslog (`<22>`).
3. **Связывание.** `postfix/qmgr` даёт отправителя и размер письма по QID,
   строки `smtp`/`lmtp`/`local`/`virtual`/`pipe` — получателя, relay и статус.
   По `qmgr: <QID>: removed` запись из памяти удаляется, поэтому потребление
   памяти не растёт с размером лога.
4. **Фильтрация.** Временное окно применяется к записям о доставке; `qmgr`-строки
   обрабатываются всегда, иначе на границе окна терялся бы отправитель.
5. **Агрегация и вывод.** Подсчёт, сортировка по убыванию, ограничение `-n`
   и рендер в таблицу / CSV / JSON / TSV.

### Формат `raw`

| # | Поле | Описание |
|---|---|---|
| 1 | `ts` | unix-время записи (0, если метка не разобрана) |
| 2 | `dir` | `in` / `out` / `other` |
| 3 | `transport` | `smtp`, `lmtp`, `local`, `virtual`, `pipe`, `error`, … |
| 4 | `status` | `sent`, `bounced`, `deferred`, `expired` |
| 5 | `from_addr` | адрес отправителя (envelope) |
| 6 | `from_domain` | домен отправителя (`(bounce)` для пустого отправителя) |
| 7 | `to_addr` | адрес получателя |
| 8 | `to_domain` | домен получателя |
| 9 | `relay_host` | имя relay-сервера |
| 10 | `relay_ip` | IP relay-сервера |
| 11 | `size` | размер письма в байтах (`0` — неизвестен) |
| 12 | `dsn` | код DSN |
| 13 | `reason` | ответ сервера для неуспешных доставок |

## ✅ Тесты

```bash
./tests/run_tests.sh
```

Набор из 32 тестов на фикстуре `tests/sample_mail.log`: разбор лога, временные
фильтры, форматы вывода, метки времени, источники данных и коды возврата.
Тесты проходят на `mawk`, `gawk`, `gawk --posix` и `busybox awk` — скрипт
берёт `awk` из `PATH`, так что проверить другую реализацию можно, подставив её
в `PATH` первой.

Линтер:

```bash
shellcheck -s bash mail_analyzer.sh tests/run_tests.sh
```

## ⚠️ Важные замечания

- **Права доступа**: для `/var/log/mail.log*` обычно нужен `sudo`. Если часть
  файлов недоступна, скрипт скажет об этом и продолжит с остальными.
- **Многократные получатели**: Postfix пишет размер письма один раз на очередь,
  поэтому в `sizes` письмо с несколькими получателями учитывается по разу на
  каждую доставку — так же, как оно и уходит в сеть.
- **`in` и `out`** считают все успешные доставки: `in` — по домену отправителя,
  `out` — по домену получателя. На шлюзе-релее это даёт картину «откуда» и «куда»,
  а разделение по транспорту доступно в `relay_in` / `relay_out` и в поле `dir`
  вывода `raw`.
- **Неразобранные метки времени**: при активном фильтре такие записи
  отбрасываются, а их количество печатается в stderr.

## 📝 История изменений

### v2.0.0
- ➕ Команды `senders`, `recipients`, `relay_ips`, `reasons`, `summary`, `raw`,
  `deferred` в дополнение к `in`, `out`, `relay_in`, `relay_out`, `routes`,
  `sizes`, `avg_sizes`, `failed`, `bounced`
- ➕ Временные фильтры `--today`, `--last-hour`, `--last-24h`, `--since`, `--until`
- ➕ Экспорт в CSV, JSON и TSV; ограничение вывода `-n/--top`
- ➕ Источники данных: `--log`, `--journal`, `--stdin`, сжатые логи `.gz/.bz2/.xz/.zst`
- 🐛 Скрипт больше не требует `gawk`: убраны трёхаргументный `match()` и другие
  GNU-расширения, из-за которых на Debian/Ubuntu (где `awk` — это `mawk`)
  анализ падал с `syntax error`
- 🐛 Убрано небезопасное `$(ls -1tr ...)` без кавычек — имена файлов больше не
  разбиваются по пробелам
- 🐛 Записи о доставленных письмах больше не накапливаются в памяти: состояние
  очереди освобождается по `qmgr: removed`
- 🐛 Понятные ошибки и коды возврата вместо пустого вывода: нет логов, нет прав,
  неизвестная команда, некорректная дата
- ➕ Поддержка меток RFC 3339, длинных QID, нескольких инстансов Postfix
- ➕ Набор тестов `tests/run_tests.sh` и чистый `shellcheck`

### v1.0.0
- ✅ Базовый анализ входящих/исходящих доменов
- ✅ Поддержка сжатых логов

## 🤝 Вклад в проект

1. Сделайте fork репозитория
2. Создайте ветку (`git checkout -b feature/amazing-feature`)
3. Убедитесь, что проходят `./tests/run_tests.sh` и `shellcheck -s bash mail_analyzer.sh`
4. Зафиксируйте изменения и отправьте Pull Request

## 📄 Лицензия

MIT — подробности в файле [LICENSE](LICENSE).

## 🔗 Ссылки

- [GitHub Repository](https://github.com/Anton-Babaskin/mail_analyzer.sh)
- [Issues](https://github.com/Anton-Babaskin/mail_analyzer.sh/issues)
- [Postfix Documentation](http://www.postfix.org/documentation.html)

---

⭐ Если проект оказался полезным, поставьте звездочку!
