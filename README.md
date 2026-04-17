# Attribution Analytics для Яндекс Метрики

Готовое решение для анализа атрибуции маркетинговых каналов на данных Яндекс Метрики,
развёртываемое в Яндекс Облаке через YC Data Transfer + Managed ClickHouse + Cloud Functions + DataLens.

---

## Структура репозитория

```
sql/
  01_schema.sql              # DDL всех таблиц ClickHouse (запустить один раз)
  02_prepare_visits.sql      # Шаг 1: visits_raw → visits_prepared
  03_combine_visits.sql      # Шаг 2: сессионная детекция → visits_combined
  05_attribution_models.sql  # Шаг 3: расчёт 4 моделей → attribution_results

functions/
  transform/
    handler.py               # Точка входа Yandex Cloud Function
    requirements.txt         # Нет сторонних зависимостей (ClickHouse — через HTTP API)
    sql/                     # Копии SQL-файлов (синхронизируются scripts/prepare.sh)

tests/
  attribution_math.py        # Python-эталон: derive_source_code, build_chains, 4 модели
  fixtures.py                # Синтетические визиты для тестов
  conftest.py                # pytest-конфигурация (маркер --integration)
  test_attribution_math.py   # 52 юнит-теста (без ClickHouse)
  test_integration.py        # Интеграционные тесты (требуют ClickHouse)

scripts/                     # Автоматизация развёртывания (cleanup / deploy / transfer / smoke / e2e)
terraform/                   # Инфраструктурный слой (protected end-to-end)
pyproject.toml               # pytest-конфигурация
```

---

## Архитектура пайплайна

```
visits_raw  (YC Data Transfer, VersionedCollapsingMergeTree)
    │
    │  02_prepare_visits.sql   {counter_id, goal_id}
    ▼
visits_prepared  (MergeTree)
    │
    │  handler.py: quantile(0.95) межвизитных интервалов → visit_max_timediff
    │  03_combine_visits.sql   {goal_id, visit_max_timediff}
    ▼
visits_combined  (MergeTree, PARTITION BY goal_id)
    │
    │  05_attribution_models.sql  {goal_id, half_life}
    ▼
attribution_results  (ReplacingMergeTree, PARTITION BY goal_id)
```

Пайплайн запускается Cloud Function ежедневно. Каждый шаг идемпотентен:
- `visits_prepared` — `TRUNCATE` перед вставкой
- `visits_combined`, `attribution_results` — `DROP PARTITION {goal_id}` перед вставкой

---

## Таблицы ClickHouse

### `visits_raw`
Заполняется YC Data Transfer. Движок `VersionedCollapsingMergeTree(Sign, VisitVersion)`.

> **Важно:** YC Data Transfer создаёт таблицу с движком `VersionedCollapsingMergeTree`, а не `CollapsingMergeTree`. Схема в `sql/01_schema.sql` соответствует этому факту.

Ключевые поля:
| Поле | Тип | Описание |
|------|-----|----------|
| `CounterID` | UInt32 | Счётчик Метрики |
| `CounterUserIDHash` | UInt64 | Анонимизированный ID посетителя (имя поля от YC Data Transfer) |
| `VisitID` | UInt64 | ID визита |
| `UTCStartTime` | DateTime | Время начала визита (UTC) |
| `VisitVersion` | UInt32 | Версия записи; argMax(field, VisitVersion) берёт актуальное значение при повторной доставке |
| `TrafficSource.*` | Nested | Источники трафика (Model=1 — первичный) |
| `Goals.ID / .Price / .Currency` | Array | Достигнутые цели, цена и валюта |
| `Sign` | Int8 | +1 вставка / −1 отмена |

### `visits_prepared`
Промежуточная таблица. Один ряд = один визит. Пересоздаётся при каждом запуске.

| Поле | Тип | Описание |
|------|-----|----------|
| `SourceCode` | String | Код источника трафика (см. ниже) |
| `Conversions` | UInt32 | Число достижений `goal_id` в этом визите |
| `GoalRevenueCur` | Float64 | `sum(Goals.Price / 1e6)` для `goal_id` в этом визите |

### `visits_combined`
Промежуточная таблица. Один ряд = одна сессионная цепочка (от границы сессии до позиции i).

| Поле | Тип | Описание |
|------|-----|----------|
| `history.VisitID` | Array(UInt64) | VisitID каждого касания цепочки |
| `history.SourceCode` | Array(String) | SourceCode каждого касания |
| `history.UTCStartTime` | Array(DateTime) | Время каждого касания |
| `history.EventType` | Array(String) | `'2_VISIT'` или `'0_NULL'` (сентинел) |
| `history.Conversions` | Array(Float64) | Конверсии на каждом касании |
| `Conversions` | Float64 | = `history.Conversions[-1]` |
| `GoalRevenueCur` | Float64 | Выручка последнего визита цепочки |

### `attribution_results`
Итоговая таблица. Один ряд = одна комбинация (модель, дата, канал).

| Поле | Тип | Описание |
|------|-----|----------|
| `attribution_type` | LowCardinality(String) | `first_touch` / `last_touch` / `linear` / `time_decay` |
| `start_date` | Date | Дата последнего визита цепочки |
| `source_code` | String | Код канала |
| `visits` | Float64 | Атрибутированные визиты |
| `conversions` | Float64 | Атрибутированные конверсии |
| `revenue` | Float64 | Атрибутированная выручка (в валюте цели) |

---

## Кодировка источников трафика (SourceCode)

Воспроизводит логику `analyse_channels_chain.py` из [yandex_metrika_connector_cases](https://github.com/zhdanchik/yandex_metrika_connector_cases).
Основана на официальных типах `TraficSourceID` Яндекс Метрики:

| TraficSourceID | Код | Описание |
|----------------|-----|----------|
| −1 | `"-1"` | Внутренние переходы |
| 0 | `"0"` | Прямые заходы |
| 1 | `"1"` | Переходы по ссылкам на сайтах |
| 2 | `"2_{SearchEngineID}"` | Из поисковых систем (2_621=Яндекс, 2_1=Google) |
| 3 | `"3_{AdvEngineID}"` | Переходы по рекламе (3_1=Яндекс Директ, 3_2=Google Ads) |
| 3 + баннер | `"3_1_{ClickTargetType}"` | Яндекс Директ с типом баннера |
| 4 | `"4"` | С сохранённых страниц |
| 5 | `"5"` | Не определён |
| 6 | `"6"` | По внешним ссылкам |
| 7 | `"7"` | С почтовых рассылок |
| 8 | `"8_{SocialSourceNetworkID}"` | Из соцсетей (8_1=VK, 8_2=FB, 8_3=OK) |
| 9 | `"9_{RecommendationSystemID}"` | Из рекомендательных систем |
| 10 | `"10_{MessengerID}"` | Из мессенджеров |
| 11 | `"11"` | По QR-коду |

---

## Сессионная детекция (`03_combine_visits.sql`)

Воспроизводит `metr_combine_insert_final_query` из `analyse_channels_chain.py`.

1. Три потока событий на пользователя объединяются через `UNION ALL`:
   - **Реальные визиты** — тип `'2_VISIT'`
   - **Сентинелы на разрывах** — тип `'0_NULL'` вставляется между визитами, если пауза > `visit_max_timediff` секунд
   - **Финальный сентинел** — `'0_NULL'` после последнего визита каждого пользователя
2. Все события сортируются по `(UTCStartTime, EventType)`. `'0_NULL'` < `'2_VISIT'` лексикографически → сентинелы всегда предшествуют визитам с тем же временем.
3. Для каждой позиции `i` находится последний сентинел до `i` — это граница сессии.
4. Массив событий нарезается от границы до `i` — получается цепочка касаний текущей сессии.
5. Строки, где последний элемент — сентинел (`SourceCode = 'null'`), отбрасываются.

**`visit_max_timediff`** вычисляется handler.py как 95-й перцентиль межвизитных интервалов по `visits_prepared`. Если данных недостаточно — используется запасное значение 1800 секунд (30 минут).

---

## Модели атрибуции (`05_attribution_models.sql`)

Все четыре модели читают `visits_combined` напрямую.
Один `INSERT` на модель вычисляет все три метрики за один проход.

| Модель | `attribution_type` | Логика |
|--------|-------------------|--------|
| **First Touch** | `first_touch` | 100% кредита `history.SourceCode[1]` (первое касание) |
| **Last Touch** | `last_touch` | 100% кредита `history.SourceCode[-1]` (последнее касание) |
| **Linear** | `linear` | Кредит поровну: `chain_val / N` на каждое касание |
| **Time Decay** | `time_decay` | Вес `2^(−d / half_life)`, нормализован внутри цепочки; `d` — дней до конца цепочки |

Метрики:
- **visits** — 1 на каждую цепочку (все цепочки)
- **conversions** — `Conversions` последнего визита (только конвертирующие цепочки, остальные вносят 0)
- **revenue** — `GoalRevenueCur` последнего визита (аналогично)

`start_date` = `toDate(history.UTCStartTime[-1])` — дата конечного визита цепочки.

---

## Cloud Function

**Точка входа:** `functions/transform/handler.py`

Функция обращается к ClickHouse через **HTTP API** (порт 8443 для TLS), используя только стандартную библиотеку Python (`urllib`, `ssl`). Сторонних зависимостей нет.

Пароль ClickHouse никогда не хранится в переменных окружения — функция получает его из Lockbox в runtime через IAM-токен метадата-сервиса.

Переменные окружения (задаются через Terraform):

| Переменная | Описание | По умолчанию |
|-----------|----------|--------------|
| `CLICKHOUSE_HOST` | Хост ClickHouse | — (обязательно) |
| `CLICKHOUSE_HTTP_PORT` | HTTPS-порт ClickHouse HTTP API | `8443` (TLS) / `8123` |
| `CLICKHOUSE_DB` | База данных | `default` |
| `CLICKHOUSE_USER` | Пользователь | `default` |
| `CLICKHOUSE_TLS` | Использовать TLS (`1`/`0`) | `1` |
| `LOCKBOX_SECRET_ID` | ID секрета Lockbox с паролем ClickHouse | — (обязательно) |
| `COUNTER_ID` | Номер счётчика Метрики | — (обязательно) |
| `GOAL_ID` | ID цели конверсии | — (обязательно) |
| `HALF_LIFE_DAYS` | Полураспад Time Decay (дней) | `7.0` |

---

## Тесты

### Юнит-тесты (без ClickHouse)

```bash
pip install pytest
pytest tests/test_attribution_math.py -v
```

52 теста, покрывают:
- `derive_source_code` — все типы TraficSourceID включая граничные случаи
- `build_chains` — порядок позиций, флаг `is_converting`, окно lookback, повторные конверсии
- Все 4 модели атрибуции: корректность весов, пустые цепочки, граничные случаи
- Кросс-модельные инварианты: сумма кредитов = число конверсий

### Интеграционные тесты (требуют ClickHouse)

```bash
docker run -d -p 9000:9000 clickhouse/clickhouse-server

pytest --integration tests/test_integration.py -v
```

Переменные окружения: `TEST_CH_HOST`, `TEST_CH_PORT`, `TEST_CH_USER`, `TEST_CH_PASSWORD`.

---

## Развёртывание (Terraform)

### Требования

| Инструмент | Версия |
|-----------|--------|
| Terraform | ≥ 1.5 |
| Yandex Cloud CLI (`yc`) | последняя |
| `clickhouse-client` | ≥ 21.1 (для применения DDL-схемы) |
| `jq` | для парсинга JSON-ответов yc |
| `python3` | для парсинга HCL и escape'а паролей в XML |
| `yandexcloud` (pip) | Python SDK для gRPC-вызовов Data Transfer — Metrika-source endpoint нет ни в REST-шлюзе YC, ни в `yc` CLI (только в SDK). Установка через **venv** — см. ниже |
| `curl` | для скачивания CA и HTTPS-запросов к ClickHouse в smoke-тесте |

### Установка `yandexcloud` (Python SDK)

Современные Python (3.12+) блокируют системный `pip install` (PEP 668 — «externally-managed-environment»), поэтому используй venv:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install yandexcloud
```

Активируй venv в той же сессии, где запускаешь `./scripts/transfer.sh` или `./scripts/e2e.sh`. Если предпочитаешь `pipx`/`uv` — тоже ок, главное чтобы `python3 -c 'import yandexcloud'` в текущей оболочке отрабатывал без ошибок. `prepare.sh` явно проверяет это и не даст запуститься без SDK.

Аутентификация Terraform выполняется через `yc iam create-token` или сервисный аккаунт с ключом (см. [документацию провайдера](https://terraform-provider.yandexcloud.net/)).

> **Внимание: IAM-токен живёт ~12 часов.** Скрипты в `scripts/` перед каждым вызовом `terraform` / `yc` сами делают `yc iam create-token` и экспортируют `YC_TOKEN`, чтобы длинный `apply` не упал посреди исполнения. Это работает, пока профиль `yc` (в `~/.config/yandex-cloud/config.yaml`) сам может получать новые токены — т.е. настроен через SA key file (`yc config set service-account-key …`) или OAuth-токен. Если профиль использует «сырой» IAM-токен (`yc config set token …`), он истекает вместе с первой неудачной попыткой — сначала `yc init` или переключись на SA-ключ.

---

### Необходимые IAM-роли для того, кто запускает `terraform apply`

| Роль | Зачем |
|------|-------|
| `editor` на каталоге | создание большинства ресурсов |
| `iam.serviceAccounts.admin` | создание SA и назначение ролей |
| `storage.admin` | Object Storage бакет для zip функции |
| `mdb.admin` | Managed ClickHouse кластер |
| `datatransfer.admin` | Data Transfer |
| `serverless.functions.admin` | Cloud Functions |
| `lockbox.admin` | Lockbox секрет |

---

### Шаг 1 — Получить учётные данные

**OAuth-токен Яндекс Метрики**

1. Перейдите на [oauth.yandex.ru](https://oauth.yandex.ru/) и создайте приложение с правом `metrika:read`.
2. Сохраните выданный токен — он понадобится как `metrika_oauth_token`.

**Параметры счётчика и цели**

В интерфейсе Яндекс Метрики найдите:
- **Номер счётчика** — виден в URL (`metrika.yandex.ru/list/counter/<ID>`)
- **ID цели** — в разделе «Цели» → кликните на цель → ID в URL

---

### Шаг 2 — Подготовить сеть

Кластер ClickHouse создаётся в приватной подсети. Cloud Function подключается к той же сети через `connectivity.network_id`. Убедитесь, что:

- VPC и подсеть созданы в нужном каталоге
- Cloud Function должна достучаться до Lockbox (`payload.lockbox.api.cloud.yandex.net`) — для этого подсеть должна иметь egress в интернет через NAT (**этим занимается `scripts/ensure_nat.sh` — запускается автоматически из `deploy.sh`**, создаёт shared-egress gateway + route-table и привязывает её к подсети)

Получить ID нужных ресурсов:

```bash
yc vpc network list --folder-id <folder_id>
yc vpc subnet list   --folder-id <folder_id>
```

---

### Шаг 3 — Создать `terraform.tfvars`

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
```

Файл `terraform/terraform.tfvars.example`:

```hcl
folder_id    = "b1g..."          # ID каталога YC
network_id   = "enpb..."         # ID VPC-сети
subnet_id    = "e9b..."          # ID подсети (зона ru-central1-a)

counter_id   = 12345678          # Номер счётчика Метрики
goal_id      = 42                # ID цели конверсии

# Глобально уникальное имя бакета (латиница, цифры, дефисы)
function_bucket_name = "metrika-attribution-fn-<random-suffix>"

# Секреты — можно задать также через переменные окружения:
# export TF_VAR_clickhouse_password="..."
# export TF_VAR_metrika_oauth_token="..."
clickhouse_password  = "StrongP@ssw0rd"
metrika_oauth_token  = "y0_AgAAAA..."
```

> **Безопасность.** Не коммитьте `terraform.tfvars` в git — добавьте его в `.gitignore`.
> Альтернатива: передавайте чувствительные значения через переменные окружения `TF_VAR_*`.

---

### Шаг 4 — Запустить развёртывание

> Единственный ручной шаг до автоматизации: один раз создать Metrika-source endpoint в UI (поле `period` отсутствует в публичном API YC — см. ниже «Известное ограничение»). После этого всё — в скриптах.

Полный e2e в одну команду (cleanup → deploy → transfer → smoke):

```bash
ASSUME_YES=1 EXISTING_SOURCE_ID=<dte...> ./scripts/e2e.sh
```

Или по шагам, если хочется контроля на каждом этапе:

```bash
KEEP_SOURCE_ID=<dte...> ./scripts/cleanup.sh    # удалить все проект-ресурсы, кроме UI-source
./scripts/deploy.sh                              # preflight + terraform apply + ensure_nat.sh
EXISTING_SOURCE_ID=<dte...> ./scripts/transfer.sh  # target + transfer через SDK (gRPC)
./scripts/smoke.sh                               # invoke функции + проверка всех таблиц
```

Все скрипты читают `terraform/terraform.tfvars` и `terraform output`. Секреты **никогда не попадают в аргументы команд** (не видны в `ps aux`): XML-конфиг ClickHouse с `chmod 600`, HTTPS-заголовки, env-переменные, временные файлы в `mktemp -d` с `chmod 700`.

После `deploy.sh` Terraform выведет:

```
clickhouse_host       = "rc1a-xxxx.mdb.yandexcloud.net"
clickhouse_cluster_id = "c9q..."
clickhouse_db_name    = "metrika"
clickhouse_db_user    = "analyst"
function_id           = "d4e..."
lockbox_secret_id     = "e6q..."
trigger_id            = "..."
```

---

### Что делают скрипты

| Скрипт | Действия |
|--------|----------|
| `scripts/lib.sh` | Общие хелперы: логирование (`log`/`ok`/`warn`/`die`/`hdr`), `require_bin`, `tfvar_get` (HCL-парсер), `confirm`, `refresh_yc_token` (перед каждым терраформ/yc-вызовом — IAM-токены живут ~12ч) |
| `scripts/prepare.sh` | Preflight: проверяет `yc`/`terraform`/`clickhouse-client`/`jq`/`python3`/`curl` + импорт `yandexcloud` SDK; валидирует `terraform.tfvars` (нет placeholder'ов + все обязательные ключи); скачивает Yandex CA → `functions/transform/CA.pem`; синхронизирует `sql/*.sql` в бандл функции (источник истины — `sql/`) |
| `scripts/cleanup.sh` | По префиксу имени (`metrika-attribution-*`) удаляет: триггеры, функции, Data Transfer'ы + endpoint'ы, MDB-кластеры (снимает `deletion_protection`), Lockbox-секреты, Object Storage бакет (через `s3_empty.py`), сервисные аккаунты; чистит локальный `terraform.tfstate`. `KEEP_SOURCE_ID=<id>` сохраняет UI-созданный Metrika-source |
| `scripts/s3_empty.py` | Опустошает Object Storage бакет через AWS SigV4 на чистой Python stdlib (без `aws-cli`). Поднимает одноразовый static access key через `yc iam access-key create` и удаляет его после |
| `scripts/deploy.sh` | Вызывает `prepare.sh`, затем `terraform init → plan → apply`. После apply автоматически запускает `ensure_nat.sh` (нужен для Cloud Function → Lockbox) |
| `scripts/ensure_nat.sh` | Создаёт shared-egress gateway + route-table с маршрутом `0.0.0.0/0 → gateway` и привязывает её к подсети. Идемпотентно — переиспользует существующие ресурсы. Пробует разные варианты флагов `yc vpc gateway create` для совместимости с разными версиями CLI |
| `scripts/setup_transfer.py` | Через `yandexcloud` SDK (gRPC): создаёт Metrika-source endpoint (или использует существующий по `EXISTING_SOURCE_ID`) + ClickHouse-target endpoint + transfer (SNAPSHOT_ONLY) + активирует + поллит статус. Поддерживает probe-режимы: `PROBE_ENDPOINT_ID=<id>` и `PROBE_TRANSFER_ID=<id>` — дампит wire-bytes proto и подсвечивает unknown-поля с датами |
| `scripts/transfer.sh` | Тонкая обёртка над `setup_transfer.py`: читает секреты из Lockbox, чистит старые endpoint'ы (кроме `EXISTING_SOURCE_ID`), передаёт всё в Python через env-переменные (не через argv — не видно в `ps aux`), поллит статус до DONE |
| `scripts/smoke.sh` | Invoke функции + `curl --cacert CA.pem https://…:8443` к ClickHouse. Автоматически создаёт `VIEW visits_raw` над реальной таблицей Data Transfer (`visits_<transfer_id>`). Проверяет все пайплайн-таблицы, кросс-модельный инвариант (`sum(visits)` одинакова у всех 4 моделей), печатает топ-5 каналов |
| `scripts/e2e.sh` | Оркестратор: cleanup → deploy → transfer → smoke |

Переменные окружения:

| Переменная | Скрипт(ы) | Назначение |
|-----------|----------|------------|
| `ASSUME_YES=1` | все | пропустить все интерактивные подтверждения |
| `PERIOD_FROM` / `PERIOD_TO` (YYYY-MM-DD) | `transfer.sh` | диапазон дат снапшота Metrika (по умолчанию последние 30 дней). Игнорируется при `EXISTING_SOURCE_ID` — период уже на UI-созданном endpoint'е |
| `EXISTING_SOURCE_ID=<dte...>` | `transfer.sh` | не создавать Metrika-source (взять из UI) — см. «Известное ограничение» |
| `KEEP_SOURCE_ID=<dte...>` | `cleanup.sh` | сохранить один endpoint поверх cleanup'а (чтобы UI-source пережил пересборку) |
| `FOLDER_ID`, `PREFIX`, `BUCKET_NAME` | `cleanup.sh` | переопределить значения из tfvars |
| `PROBE_ENDPOINT_ID` / `PROBE_TRANSFER_ID` | `setup_transfer.py` | режим интроспекции wire-bytes, не выполняет Create |
| `PERIOD_FIELD_NUMBER` / `PERIOD_FROM_TAG` / `PERIOD_TO_TAG` | `setup_transfer.py` | переопределить догадку по номеру поля при инжекции period как unknown field (по умолчанию 4 / 1 / 2) |

---

### Структура Terraform-модуля

```
terraform/
  versions.tf          # Провайдеры: yandex ~> 0.120, archive ~> 2.4
  variables.tf         # Все входные переменные (+ ca_cert_path для DDL-TLS)
  outputs.tf           # clickhouse_host/_cluster_id/_db_name/_db_user, function_id, lockbox_secret_id, trigger_id
  main.tf              # Корневой модуль: SA, IAM, вызов submodules

  modules/
    lockbox/           # Lockbox-секрет + lockbox.payloadViewer для SA
    clickhouse/        # Managed ClickHouse + DDL (strict TLS via Yandex CA, пароль в chmod-600 XML)
    function/          # Cloud Function + Object Storage + zip-архив кода
    transfer/          # (не используется) — Data Transfer endpoints вынесены в scripts/setup_transfer.py
    scheduler/         # Timer trigger (ежедневный запуск функции)
```

Cloud NAT (`yandex_vpc_gateway` + `yandex_vpc_route_table` + binding к подсети) создаётся **не через terraform**, а через `scripts/ensure_nat.sh` — не хотелось управлять через tf-провайдер чужой подсетью, которую пользователь передаёт как `subnet_id`.

**Поток данных секретов:**

```
terraform.tfvars (или $TF_VAR_*)
  │  clickhouse_password
  │  metrika_oauth_token
  ▼
Lockbox secret  ──── lockbox.payloadViewer ──▶ function SA
                                               transfer SA

  │  через yc lockbox payload get (в scripts/transfer.sh)
  ▼
Data Transfer endpoints (metrika-source + clickhouse-target)
  создаются через yandexcloud Python SDK (gRPC),
  секреты идут в env-переменных Python-процесса (не в argv)

  │  LOCKBOX_SECRET_ID (env-переменная функции, не секрет)
  ▼
Cloud Function  ──── IAM token (metadata 169.254.169.254) ──▶ Lockbox API
                     (через shared-egress NAT из подсети)
                                               │
                                               ▼
                                    читает clickhouse_password,
                                    ретраи 2/4/8/16с на DNS/net ошибки
```

---

### Пересоздание ресурсов

| Что изменилось | Действие |
|---------------|---------|
| Код функции (`functions/transform/`) | `terraform apply` — zip пересобирается автоматически |
| Схема БД (`sql/01_schema.sql`) | `terraform apply` — `null_resource.schema` перезапускается |
| Пароль ClickHouse | Обновить в Lockbox вручную **и** `terraform apply` |
| Новый `goal_id` | Обновить `terraform.tfvars`, `terraform apply` |

> **Примечание о деплое функции.** Если Terraform не подхватывает изменения кода (плановый hash совпадает со старым),
> создайте версию функции вручную через YC CLI:
> ```bash
> cd functions/transform
> zip -r /tmp/fn.zip .
> yc serverless function version create \
>   --function-id <function_id> \
>   --runtime python311 \
>   --entrypoint handler.handler \
>   --memory 512m \
>   --execution-timeout 10m \
>   --source-path /tmp/fn.zip
> ```

---

### Удаление

```bash
terraform destroy
```

> Если `deletion_protection = true` на ClickHouse кластере — сначала установите его в `false`.

---

## Безопасность

Все чувствительные точки задокументированы явно:

- **Секреты хранятся в Lockbox.** `clickhouse_password` и `metrika_oauth_token` попадают в Lockbox из `terraform.tfvars` (или `TF_VAR_*`) и извлекаются функцией/скриптами через IAM-токен. В env-переменных функции их нет.
- **TLS обязателен с проверкой сертификата.** Функция использует HTTPS (`8443`) с проверкой по Yandex CA (`functions/transform/CA.pem`, скачивается `scripts/prepare.sh` один раз и бандлится в zip — не TOFU на cold start). DDL-провизионер `null_resource.schema` использует `verificationMode=strict` с этим же CA (раньше был `mode=none` — исправлено в этой сессии, см. `terraform/modules/clickhouse/main.tf`).
- **Пароли не в cmdline.** ClickHouse DDL-провизионер получает пароль через временный XML-конфиг с `chmod 600` — не виден в `ps aux` (раньше был через `--password "$CH_PASSWORD"` — исправлено). `smoke.sh` отправляет пароль в HTTP-заголовке `X-ClickHouse-Key` поверх TLS. `setup_transfer.py` — через env-переменные Python-процесса. `s3_empty.py` — через AWS-env с одноразовым ключом.
- **IAM-токены обновляются.** `scripts/lib.sh:refresh_yc_token` делает `yc iam create-token` перед каждым `terraform`/`yc`-вызовом (добавлено после инцидента с истечением токена посреди `apply`). Работает с OAuth/SA-key профилем; «сырой» IAM-токен в `yc config` → не сможет обновиться, нужен `yc init`.
- **Секреты из tfvars никогда не в git.** `.gitignore` исключает `terraform.tfvars`, `*.tfstate*`, `CA.pem`, `.venv/`.
- **Сеть.** По умолчанию MDB-кластер имеет публичный IP (`assign_public_ip = true`) — нужен для локального DDL-провизионера. Для prod установите `false`, DDL прогоните из VPC (Jump-host). Также рекомендуется задать `security_group_ids` в `module.clickhouse` с whitelist по IP.
- **Lockbox-ретраи.** Функция ретраит запросы к metadata + Lockbox с экспоненциальным бэкоффом (2/4/8/16с) — закрывает окно stale DNS на cold start в VPC.
- **`CLICKHOUSE_TLS=0` разрешён, но `prepare.sh` явно `warn`'ит.** Для тестовых окружений с plaintext.

---

## Известное ограничение: Metrika source endpoint создаётся руками

Поле `period` (диапазон дат для snapshot-загрузки Metrika) полностью **write-only в публичном API YC**:
- Нет в [публичном proto](https://github.com/yandex-cloud/cloudapi/blob/master/yandex/cloud/datatransfer/v1/endpoint/metrika.proto) (`MetrikaSource`/`MetrikaStream` содержат только `counter_ids`, `token`, `streams: {type, columns}`)
- Нет в Python SDK `yandexcloud`, Terraform-провайдере, `yc` CLI
- `Get` не отдаёт его ни с endpoint'а, ни с трансфера — проверено через wire-дамп (`PROBE_ENDPOINT_ID` / `PROBE_TRANSFER_ID`)

При этом `CreateTransfer` в SNAPSHOT-режиме требует period на source. UI сохраняет его через приватный API.

**Рабочая схема** (~30 секунд ручного в UI на весь цикл):

1. Один раз создай Metrika-source endpoint в UI Console:
   - https://console.yandex.cloud/folders/{folder_id}/data-transfer/endpoints → **Создать endpoint**
   - Направление: **Источник**, База: **Metrica**
   - Счётчик: `{counter_id}`
   - Токен: OAuth-токен Метрики
   - **Период выгрузки данных: Начало `{PERIOD_FROM}`, Конец `{PERIOD_TO}`**
   - Stream: **Визиты** + нужные поля
   - Запомни id (вида `dte...`)

2. Запусти остальное:
   ```bash
   EXISTING_SOURCE_ID=<dte...> ./scripts/transfer.sh
   ```
   Скрипт создаст target endpoint, создаст transfer поверх твоего UI-source, активирует, опросит статус до DONE.

3. После DONE:
   ```bash
   ./scripts/smoke.sh
   ```

**Важно для `cleanup.sh`**: передавай `KEEP_SOURCE_ID=<id>`, чтобы UI-source пережил очистку:

```bash
KEEP_SOURCE_ID=<dte...> ./scripts/cleanup.sh
```

---

## Troubleshooting

| Симптом | Причина и фикс |
|---------|---------------|
| `terraform apply`: `The token has expired` | Истёк IAM-токен за время долгого apply. Скрипты уже делают `yc iam create-token` перед каждым вызовом. Если через `scripts/deploy.sh` — просто перезапусти. Если руками — `export YC_TOKEN=$(yc iam create-token)` перед `terraform apply`. |
| `ERROR: The bucket you tried to delete is not empty.` | `yc storage bucket delete` не умеет force. `cleanup.sh` вызывает `scripts/s3_empty.py` (SigV4 на stdlib) с временным static access key — без `aws-cli`. |
| `scripts/prepare.sh`: `missing Python dependency: yandexcloud` | PEP 668 блокирует системный pip. Поставь через venv: `python3 -m venv .venv && source .venv/bin/activate && pip install yandexcloud`. |
| `ERROR: unknown flag: --shared-egress-gateway` в `ensure_nat.sh` | Флаги `yc vpc gateway create` отличаются между версиями CLI. Скрипт пробует три варианта по очереди. Если все три упали — run `yc vpc gateway create --help` и скинь актуальный синтаксис. |
| `CreateTransfer`: `current metrica source config not suitable for snapshot: period setting required` | Период не пробросился на endpoint. `period` write-only в публичном API. Используй `EXISTING_SOURCE_ID=<dte...>` — ссылайся на UI-созданный source, см. «Известное ограничение». |
| Функция: `Lockbox error: <urlopen error [Errno -3] Temporary failure in name resolution>` | NAT не подключён к подсети, или DNS stale на cold start. `scripts/ensure_nat.sh` запускается из `deploy.sh` автоматически. Если упало — проверь: `yc vpc subnet get --id <id> --format json \| jq .route_table_id`. Retry в `handler.py` должен добить за 2–16с. |
| `smoke.sh`: `visits_raw rows: 0`, список таблиц показывает `visits_<transfer_id>` | YC Data Transfer создаёт таблицу с именем `visits_<id_трансфера>`. `smoke.sh` сам создаёт `VIEW visits_raw AS SELECT * FROM visits_<id_трансфера>` — проверь что кандидат не `visits_combined`/`visits_prepared` (эвристика уже их исключает). |
| `smoke.sh`: все `conv=0` и топ каналов тоже `0` | Это не баг пайплайна — просто по выбранному `goal_id` не было конверсий в этом срезе данных. Смок теперь сортирует топ по `visits` в этом случае + показывает колонки `visits`/`conv`/`revenue` по всем 4 моделям с проверкой cross-model инварианта `sum(visits)`. Проверь `SELECT arrayJoin(Goals.ID), count() FROM visits_raw GROUP BY 1 ORDER BY 2 DESC LIMIT 20` — там реальные id целей. |
| `terraform apply` не подхватывает изменения кода функции | Hash в `archive_file` может совпасть. Удали `/tmp/<fn_name>-function.zip` или используй `yc serverless function version create` вручную — см. раздел «Пересоздание ресурсов». |

---

## Совместимость и известные особенности

### YC Data Transfer создаёт `VersionedCollapsingMergeTree`
Трансфер создаёт таблицу `visits_raw` с движком `VersionedCollapsingMergeTree(Sign, VisitVersion)`, а не `CollapsingMergeTree`. Схема в `sql/01_schema.sql` учитывает это. Поле для анонимизированного ID посетителя называется `CounterUserIDHash` (не `UserIDHash`).

### ClickHouse 25.x: изменение типа `UInt64 - UInt64`
Начиная с ClickHouse 25.x, выражение `UInt64 - UInt64` возвращает `Int64`. Это ломает конструкцию `if(cond, toUInt64(0), UInt64 - UInt64)` с ошибкой:
```
Code: 386. DB::Exception: There is no supertype for types UInt64, Int64
```
Все `toUInt64(0)` в `if`-выражениях рядом с арифметикой `UInt64-UInt64` заменены на `toInt64(0)` (см. `03_combine_visits.sql` и `_VISIT_MAX_TIMEDIFF_QUERY` в `handler.py`).

### Точки с запятой в `-- комментариях` SQL
Парсер `_split_statements()` в `handler.py` разбивает SQL-файл на отдельные выражения по символу `;`. Точки с запятой внутри `-- строчных комментариев` игнорируются. Не добавляйте `;` внутри `--`-комментариев в SQL-файлах функции — это приведёт к ошибке `Code: 62. DB::Exception: Empty query`.

### ClickHouse: HTTP API вместо native TCP
Функция обращается к ClickHouse через HTTPS-порт `8443` (HTTP API), а не через нативный TCP (`9440`). Это позволяет избежать зависимостей от `clickhouse-driver` и обойти баг, при котором драйвер неправильно обнаруживал `INSERT` в SQL-файлах с комментариями в начале, обрезал запрос и отправлял пустую строку на сервер.

---

## Статус разработки

- [x] **Part A** — Ядро трансформаций (SQL + Cloud Function + тесты)
- [x] **Part B** — Terraform-модуль (протестирован end-to-end на реальном кластере YC)
- [ ] **Part C** — Выбор цели конверсии (Marketplace wizard)
- [ ] **Part D** — DataLens-дашборд
- [ ] **Part E** — Упаковка в Marketplace
