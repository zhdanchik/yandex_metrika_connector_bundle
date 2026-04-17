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
| `python3 -m pip install yandexcloud` | SDK для gRPC-вызовов Data Transfer (Metrika-source endpoint) |
| `curl` | для скачивания CA и HTTPS-запросов к ClickHouse в smoke-тесте |

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
- На подсеть настроена таблица маршрутизации (NAT-инстанс или Cloud NAT) для выхода функции в интернет (нужен для обращения к Lockbox API)

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

Проще всего — одна команда полного e2e (cleanup → apply → transfer → smoke):

```bash
ASSUME_YES=1 ./scripts/e2e.sh
```

Или по шагам, если хочется контроля на каждом этапе:

```bash
./scripts/cleanup.sh   # удалить все ресурсы проекта в folder_id (idempotent)
./scripts/deploy.sh    # preflight + terraform init + plan + apply
./scripts/transfer.sh  # создать и активировать Data Transfer через yc CLI
./scripts/smoke.sh     # invoke функции + проверка всех таблиц + топ-5 каналов
```

Все скрипты читают `terraform/terraform.tfvars` и `terraform output`. Секреты никогда не попадают в аргументы команд (т.е. не видны в `ps aux`): они идут через XML-конфиг ClickHouse с `chmod 600`, HTTPS-заголовки, или временные файлы в `mktemp -d $(chmod 700)`.

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
| `scripts/prepare.sh` | Проверяет `yc`/`terraform`/`clickhouse-client`/`jq`, валидирует `terraform.tfvars` (нет placeholder'ов), скачивает Yandex CA → `functions/transform/CA.pem`, синхронизирует `sql/*.sql` в бандл функции |
| `scripts/cleanup.sh` | По префиксу имени (`metrika-attribution-*`) удаляет: триггеры, функции, Data Transfer'ы + endpoint'ы, MDB-кластеры (снимает `deletion_protection`), Lockbox-секреты, Object Storage бакет, сервисные аккаунты; чистит локальный `terraform.tfstate` |
| `scripts/deploy.sh` | Вызывает `prepare.sh`, затем `terraform init → plan → apply` |
| `scripts/transfer.sh` | Забирает секреты из Lockbox, создаёт endpoint-metrika-source + endpoint-clickhouse-target + transfer (SNAPSHOT_ONLY с `period`), активирует, поллит статус до DONE/ERROR |
| `scripts/smoke.sh` | Invoke функции + `curl --cacert CA.pem https://…:8443` к ClickHouse, проверяет `visits_*` + `attribution_results`, печатает топ-5 каналов |
| `scripts/e2e.sh` | Оркестратор: последовательно вызывает cleanup → deploy → transfer → smoke |

Переменные окружения:
- `ASSUME_YES=1` — пропустить все интерактивные подтверждения
- `PERIOD_FROM` / `PERIOD_TO` (YYYY-MM-DD) — диапазон дат снапшота Metrika (по умолчанию последние 30 дней)
- `FOLDER_ID`, `PREFIX`, `BUCKET_NAME` — переопределить значения из tfvars в cleanup.sh

---

### Структура Terraform-модуля

```
terraform/
  versions.tf          # Провайдеры: yandex ~> 0.120, archive ~> 2.4
  variables.tf         # Все входные переменные
  outputs.tf           # Ключевые ID ресурсов
  main.tf              # Корневой модуль: SA, IAM, вызов submodules

  modules/
    lockbox/           # Lockbox-секрет + lockbox.payloadViewer для SA
    clickhouse/        # Managed ClickHouse кластер + DDL (01_schema.sql)
    function/          # Cloud Function + Object Storage + zip-архив кода
    transfer/          # Data Transfer endpoints + трансфер
    scheduler/         # Timer trigger (ежедневный запуск функции)
```

**Поток данных секретов:**

```
terraform.tfvars
  │  clickhouse_password
  │  metrika_oauth_token
  ▼
Lockbox secret  ──── lockbox.payloadViewer ──▶ function SA
  │                                            transfer SA
  │  secret_ref (нативно)
  ▼
Data Transfer endpoint  (читает metrika_oauth_token, clickhouse_password)

  │  LOCKBOX_SECRET_ID (env, не секрет)
  ▼
Cloud Function  ──── IAM token (metadata) ──▶ Lockbox API
                                               (читает clickhouse_password)
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
- **TLS обязателен.** Функция использует HTTPS (`8443`) с проверкой по Yandex CA (`functions/transform/CA.pem`, скачивается `scripts/prepare.sh`). DDL-провизионер `null_resource.schema` использует `verificationMode=strict` с этим же CA (раньше был `mode=none` — исправлено).
- **Пароль не в cmdline.** ClickHouse DDL-провизионер получает пароль через временный XML-конфиг с `chmod 600` — не виден в `ps aux`. Smoke-скрипт отправляет пароль в HTTP-заголовке `X-ClickHouse-Key` поверх TLS, а не через `--password`.
- **Секреты из tfvars никогда не в git.** `.gitignore` исключает `terraform.tfvars`, `*.tfstate*`, `CA.pem`.
- **Сеть.** По умолчанию MDB-кластер имеет публичный IP (`assign_public_ip = true`), чтобы локальный провизионер мог применить DDL. Для prod — установите `false`, а DDL прогоните из внутренней сети (Compute/Jump-host или Cloud Functions). Также рекомендуется указать `security_group_ids` в `module.clickhouse` с whitelist по IP.
- **`CLICKHOUSE_TLS=0` разрешён, но `prepare.sh` явно warn'ит.** Для тестовых окружений с plaintext.

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
