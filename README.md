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

scripts/                     # Dev/test-оркестрация (cleanup / deploy / smoke / e2e) — НЕ едет в Marketplace
terraform/                   # Инфраструктурный слой (всё для Marketplace-бандла здесь)
datalens/
  BUILD_SPEC.md              # Пошаговая инструкция ручной сборки дашборда
  NOTES.md                   # Обоснования решений, известные ограничения, v2 TODO
  dashboard.json             # Экспортированный workbook (результат сборки)
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
| `python3` | для парсинга HCL в lib.sh (никаких pip-зависимостей) |
| `curl` | для скачивания CA и HTTPS-запросов к ClickHouse в smoke-тесте |

> Python SDK `yandexcloud` **больше не нужен**: с переездом Data Transfer в Terraform-модуль все endpoint'ы создаются через провайдер.

**Сетевой доступ к реестру провайдеров.** С 2022 `registry.terraform.io` заблокирован для российских IP. Бандл использует публичное зеркало Yandex Cloud `terraform-mirror.yandexcloud.net`, в котором лежат и `yandex-cloud/yandex`, и нужные нам `hashicorp/archive` + `hashicorp/null`. `scripts/deploy.sh` делает автодетект (пингует registry.terraform.io, при недоступности экспортит `TF_CLI_CONFIG_FILE=terraform/terraformrc.yc-mirror`). Если запускаешь голый `terraform init` вне скриптов — поставь переменную сам:
> ```bash
> export TF_CLI_CONFIG_FILE="$(pwd)/terraform/terraformrc.yc-mirror"
> terraform -chdir=terraform init
> ```
> Если у тебя уже есть свой `~/.terraformrc` с `network_mirror` — скрипт его уважает и ничего не делает.

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

1. Перейдите на [oauth.yandex.ru](https://oauth.yandex.ru/) и создайте приложение с правом `metrika:write` (именно write — Data Transfer требует этот scope для активации Metrika source endpoint'а; `metrika:read` недостаточно).
2. Сохраните выданный токен — понадобится дважды:
   - один раз при создании Metrika source endpoint в YC Console (см. «Ручной шаг: Metrika source endpoint»),
   - один раз при запуске `scripts/pick_goal.py` (см. ниже). После этого токен нигде не хранится — в Terraform/Lockbox его нет.

**Параметры счётчика и цели**

- **Номер счётчика** — виден в URL интерфейса Метрики (`metrika.yandex.ru/list/counter/<ID>`). Впиши в `terraform.tfvars` как `counter_id`.
- **ID цели** — не ищи вручную в UI. Запусти `python3 scripts/pick_goal.py` после заполнения `counter_id` — скрипт сходит в Metrika Management API, покажет список целей счётчика с именами/типами и впишет выбранный `goal_id` в `terraform.tfvars`. Токен используется для одного HTTPS-запроса и не персистится.

```bash
cd terraform/ && cp terraform.tfvars.example terraform.tfvars
# заполни folder_id, network_id, subnet_id, counter_id, function_bucket_name, clickhouse_password
python3 ../scripts/pick_goal.py   # интерактивный выбор goal_id
# или:  METRIKA_OAUTH_TOKEN=xxx python3 ../scripts/pick_goal.py --non-interactive --goal-name "Покупка"
```

---

### Шаг 2 — Подготовить сеть

Кластер ClickHouse создаётся в приватной подсети. Cloud Function подключается к той же сети через `connectivity.network_id`. Убедитесь, что:

- VPC и подсеть созданы в нужном каталоге
- Cloud Function должна достучаться до Lockbox (`payload.lockbox.api.cloud.yandex.net`) — для этого подсеть должна иметь egress в интернет через NAT. **Этим занимается `module "network"`** — создаёт `yandex_vpc_gateway` (shared egress) + `yandex_vpc_route_table` с маршрутом `0.0.0.0/0 → gateway` и привязывает route-table к `var.subnet_id` через `null_resource` + `yc vpc subnet update` (сам `yandex_vpc_subnet` не управляется Terraform'ом — он принадлежит пользователю)

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

# Metrika source endpoint — создаётся один раз вручную в YC Console,
# см. раздел «Ручной шаг» ниже. После создания вставь сюда id (dte...).
metrika_source_endpoint_id = "dte..."

# Глобально уникальное имя бакета (латиница, цифры, дефисы)
function_bucket_name = "metrika-attribution-fn-<random-suffix>"

# Секреты — можно задать также через переменные окружения:
# export TF_VAR_clickhouse_password="..."
clickhouse_password  = "StrongP@ssw0rd"
```

> **Безопасность.** Не коммитьте `terraform.tfvars` в git — добавьте его в `.gitignore`.
> Альтернатива: передавайте чувствительные значения через переменные окружения `TF_VAR_*`.

---

### Шаг 4 — Запустить развёртывание

> Единственный ручной шаг — один раз создать Metrika-source endpoint в UI (поле `period` отсутствует в публичном API YC — см. ниже «Ручной шаг: Metrika source endpoint»). ID этого endpoint'а (`dte...`) становится обязательной Terraform-переменной `metrika_source_endpoint_id`.

Полный e2e в одну команду (cleanup → deploy-with-snapshot → smoke):

```bash
ASSUME_YES=1 ./scripts/e2e.sh
```

Или по шагам, если хочется контроля:

```bash
./scripts/cleanup.sh   # удалить все проект-ресурсы (UI-source сохраняется автоматически)
./scripts/deploy.sh    # preflight + terraform apply; SNAPSHOT_ONLY transfer активируется sync-режимом
./scripts/smoke.sh     # invoke функции + проверка всех таблиц
```

`deploy.sh` прогоняет один `terraform apply`, который создаёт всю инфру (NAT, ClickHouse, function, Lockbox, DT endpoint + transfer) и **синхронно ждёт завершения снапшота** (`on_create_activate_mode = "sync_activate"`).

Все скрипты читают `terraform/terraform.tfvars` и `terraform output`. Секреты **никогда не попадают в аргументы команд** (не видны в `ps aux`): XML-конфиг ClickHouse с `chmod 600`, HTTPS-заголовки, env-переменные, временные файлы в `mktemp -d` с `chmod 700`.

После `deploy.sh` Terraform выведет:

```
clickhouse_host       = "rc1a-xxxx.mdb.yandexcloud.net"
clickhouse_cluster_id = "c9q..."
clickhouse_db_name    = "metrika"
clickhouse_db_user    = "analyst"
function_id           = "d4e..."
lockbox_secret_id     = "e6q..."
transfer_id           = "dtt..."
trigger_id            = "..."
```

---

### Что делают скрипты

Скрипты — **dev/test-обвязка**, в Marketplace-бандл не едут. Весь прод-путь — `terraform apply`.

| Скрипт | Действия |
|--------|----------|
| `scripts/lib.sh` | Общие хелперы: логирование (`log`/`ok`/`warn`/`die`/`hdr`), `require_bin`, `tfvar_get` (HCL-парсер), `confirm`, `refresh_yc_token` (перед каждым терраформ/yc-вызовом — IAM-токены живут ~12ч) |
| `scripts/pick_goal.py` | Интерактивный выбор `goal_id`: читает `counter_id` из tfvars, спрашивает OAuth-токен Метрики (`metrika:write`), дёргает `GET /management/v1/counter/{id}/goals`, фильтрует ретаргетинг/engagement-цели, показывает нумерованное меню и переписывает `goal_id` в tfvars. Токен используется один раз и не сохраняется. Флаги: `--non-interactive --goal-name "..."` для автоматизации, `--show-all` чтобы не прятать `depth`/`number`, `--print-only` чтобы не трогать tfvars. Stdlib-only, без pip-зависимостей |
| `scripts/prepare.sh` | Preflight: проверяет `yc`/`terraform`/`clickhouse-client`/`jq`/`python3`/`curl`; валидирует `terraform.tfvars` (нет placeholder'ов + все обязательные ключи включая `metrika_source_endpoint_id`); скачивает Yandex CA → `functions/transform/CA.pem`; синхронизирует `sql/*.sql` в бандл функции (источник истины — `sql/`) |
| `scripts/cleanup.sh` | По префиксу имени (`metrika-attribution-*`) удаляет: триггеры, функции, Data Transfer'ы + endpoint'ы, MDB-кластеры (снимает `deletion_protection`), Lockbox-секреты, route-table'ы + VPC gateway'и (с отвязкой подсети), Object Storage бакет (через `yc storage s3api` на IAM-токене пользователя — без статик-ключей), сервисные аккаунты; чистит локальный `terraform.tfstate`. Автоматически читает `metrika_source_endpoint_id` из tfvars и сохраняет этот UI-source от удаления (можно переопределить через `KEEP_SOURCE_ID`) |
| `scripts/deploy.sh` | Вызывает `prepare.sh`, затем `terraform init → plan → apply`. Всё — Terraform: NAT, DT endpoint, transfer (активируется + поллится до DONE через `null_resource` в модуле). Никаких out-of-band шагов после apply |
| `scripts/smoke.sh` | Invoke функции + `curl --cacert CA.pem https://…:8443` к ClickHouse. Берёт `transfer_id` из `terraform output` и, если `visits_raw` пустая, создаёт `VIEW visits_raw AS SELECT * FROM visits_<transfer_id>`. Проверяет все пайплайн-таблицы, кросс-модельный инвариант (`sum(visits)` одинакова у всех 4 моделей), печатает топ-5 каналов |
| `scripts/e2e.sh` | Оркестратор: cleanup → deploy → smoke |

Переменные окружения:

| Переменная | Скрипт(ы) | Назначение |
|-----------|----------|------------|
| `ASSUME_YES=1` | все | пропустить все интерактивные подтверждения |
| `KEEP_SOURCE_ID=<dte...>` | `cleanup.sh` | переопределить: по умолчанию сохраняется `metrika_source_endpoint_id` из tfvars. Установи в `""` чтобы удалить и его |
| `FOLDER_ID`, `PREFIX`, `BUCKET_NAME` | `cleanup.sh` | переопределить значения из tfvars |

---

### Структура Terraform-модуля

```
terraform/
  versions.tf          # Провайдеры: yandex ~> 0.120, archive ~> 2.4
  variables.tf         # Все входные переменные (включая metrika_source_endpoint_id)
  outputs.tf           # clickhouse_host/_cluster_id/_db_name/_db_user, function_id, lockbox_secret_id, transfer_id, trigger_id
  main.tf              # Корневой модуль: SA, IAM, вызов submodules

  modules/
    network/           # yandex_vpc_gateway (shared_egress) + route-table + привязка к var.subnet_id
    lockbox/           # Lockbox-секрет с clickhouse_password + lockbox.payloadViewer для function SA
    clickhouse/        # Managed ClickHouse + DDL (strict TLS via Yandex CA, пароль в chmod-600 XML)
    function/          # Cloud Function + Object Storage + zip-архив кода
    transfer/          # ClickHouse-target endpoint + SNAPSHOT_ONLY transfer (source передаётся по id)
    scheduler/         # Timer trigger (ежедневный запуск функции)
```

Привязка route-table к пользовательской подсети (`var.subnet_id`) — через `null_resource` + `yc vpc subnet update` в `module.network`. Полноценный `yandex_vpc_subnet` не подходит: подсеть принадлежит пользователю, мы её не создаём.

**Поток данных секретов:**

```
terraform.tfvars (или $TF_VAR_*)
  │  clickhouse_password
  ▼
Lockbox secret  ──── lockbox.payloadViewer ──▶ function SA

  │
  ▼
Data Transfer ClickHouse-target endpoint
  (clickhouse_password передан в провайдер в памяти процесса terraform,
   не попадает в tfstate в открытом виде — sensitive = true)

OAuth-токен Метрики вводится ОДИН РАЗ при создании source endpoint'а
в YC Console и живёт на стороне Yandex Cloud. В Terraform/Lockbox
он больше НЕ ЛЕЖИТ.

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
| Новый `goal_id` | `python3 scripts/pick_goal.py` (перепишет tfvars), затем `terraform apply` |

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

- **Секреты хранятся в Lockbox.** `clickhouse_password` попадает в Lockbox из `terraform.tfvars` (или `TF_VAR_*`) и извлекается функцией через IAM-токен. В env-переменных функции пароля нет. OAuth-токен Метрики в Lockbox не хранится вовсе — он вводится один раз в UI при создании Metrika source endpoint'а и остаётся на стороне YC Data Transfer.
- **TLS обязателен с проверкой сертификата.** Функция использует HTTPS (`8443`) с проверкой по Yandex CA (`functions/transform/CA.pem`, скачивается `scripts/prepare.sh` один раз и бандлится в zip — не TOFU на cold start). DDL-провизионер `null_resource.schema` использует `verificationMode=strict` с этим же CA.
- **Пароли не в cmdline.** ClickHouse DDL-провизионер получает пароль через временный XML-конфиг с `chmod 600` — не виден в `ps aux`. `smoke.sh` отправляет пароль в HTTP-заголовке `X-ClickHouse-Key` поверх TLS. В Data Transfer endpoint'е пароль идёт через провайдер (sensitive-переменная, не пишется в tfstate открытым текстом). `cleanup.sh` ходит в Object Storage через `yc storage s3api` с твоим же IAM-токеном — без статик-ключей.
- **IAM-токены обновляются.** `scripts/lib.sh:refresh_yc_token` делает `yc iam create-token` перед каждым `terraform`/`yc`-вызовом (добавлено после инцидента с истечением токена посреди `apply`). Работает с OAuth/SA-key профилем; «сырой» IAM-токен в `yc config` → не сможет обновиться, нужен `yc init`.
- **Секреты из tfvars никогда не в git.** `.gitignore` исключает `terraform.tfvars`, `*.tfstate*`, `CA.pem`.
- **Сеть.** По умолчанию MDB-кластер имеет публичный IP (`assign_public_ip = true`) — нужен для локального DDL-провизионера. Для prod установите `false`, DDL прогоните из VPC (Jump-host). Также рекомендуется задать `security_group_ids` в `module.clickhouse` с whitelist по IP.
- **Lockbox-ретраи.** Функция ретраит запросы к metadata + Lockbox с экспоненциальным бэкоффом (2/4/8/16с) — закрывает окно stale DNS на cold start в VPC.
- **`CLICKHOUSE_TLS=0` разрешён, но `prepare.sh` явно `warn`'ит.** Для тестовых окружений с plaintext.

---

## Ручной шаг: Metrika source endpoint

Поле `period` (диапазон дат для snapshot-загрузки Metrika) полностью **write-only в публичном API YC**:
- Нет в [публичном proto](https://github.com/yandex-cloud/cloudapi/blob/master/yandex/cloud/datatransfer/v1/endpoint/metrika.proto) (`MetrikaSource`/`MetrikaStream` содержат только `counter_ids`, `token`, `streams: {type, columns}`)
- Нет в Terraform-провайдере (проверено в `datatransfer_structures.go`), Python SDK `yandexcloud`, `yc` CLI
- `Get` не отдаёт его ни с endpoint'а, ни с трансфера

При этом `CreateTransfer` в SNAPSHOT-режиме требует period на source. UI сохраняет его через приватный API. Мы этот путь не используем — приватный API не стабилизирован, завтра может поломаться, в Marketplace так отдавать нельзя.

**Рабочая схема** (~30 секунд ручного клика в UI — один раз на жизнь бандла):

1. Создай Metrika-source endpoint в YC Console:
   - `https://console.yandex.cloud/folders/<folder_id>/data-transfer/endpoints` → **Создать endpoint**
   - Направление: **Источник**, База: **Metrica**
   - Счётчик: `<counter_id>`
   - Токен: OAuth-токен Метрики (с правом `metrika:write` — read недостаточно, DT падает с 403 на активации)
   - **Период выгрузки данных: Начало / Конец**
   - Stream: **Визиты** + нужные поля (см. список ниже)
   - Сохрани — получишь id вида `dte...`

2. Пропиши id в `terraform.tfvars`:
   ```hcl
   metrika_source_endpoint_id = "dte..."
   ```

3. `./scripts/deploy.sh` — Terraform создаст ClickHouse-target + transfer поверх твоего UI-source'а и синхронно дождётся завершения snapshot'а.

4. `./scripts/smoke.sh` — проверка пайплайна.

**Колонки Visits stream** (минимально нужные для текущей логики атрибуции):
`CounterUserIDHash`, `UTCStartTime`, `Duration`, `TrafficSource.Model`, `TrafficSource.ID`, `TrafficSource.StartTime`, `TrafficSource.SearchEngineID`, `TrafficSource.AdvEngineID`, `TrafficSource.SocialSourceNetworkID`, `TrafficSource.RecommendationSystemID`, `TrafficSource.MessengerID`, `TrafficSource.ClickBannerID`, `TrafficSource.ClickTargetType`, `Goals.ID`, `Goals.Serial`, `Goals.EventTime`, `Goals.Price`, `Goals.Currency`, `EPurchase.ID`, `EPurchase.Revenue`.

**Cleanup сохраняет source автоматически**: `scripts/cleanup.sh` читает `metrika_source_endpoint_id` из tfvars и не трогает этот endpoint. Чтобы всё-таки удалить: `KEEP_SOURCE_ID="" ./scripts/cleanup.sh`.

---

## Troubleshooting

| Симптом | Причина и фикс |
|---------|---------------|
| `terraform apply`: `The token has expired` | Истёк IAM-токен за время долгого apply. Скрипты уже делают `yc iam create-token` перед каждым вызовом. Если через `scripts/deploy.sh` — просто перезапусти. Если руками — `export YC_TOKEN=$(yc iam create-token)` перед `terraform apply`. |
| `ERROR: The bucket you tried to delete is not empty.` | cleanup.sh чистит объекты и multipart uploads через `yc storage s3api` (который ходит с твоим IAM-токеном, а не со стороннего SA). Если всё равно не удаляется — вручную: `yc storage s3api list-objects --bucket <name>` + `yc storage s3api delete-object --bucket <name> --key <key>`. |
| `CreateTransfer`: `current metrica source config not suitable for snapshot: period setting required` | Period не задан на Metrika source endpoint'е. Перепроверь в UI, что у endpoint'а по id `metrika_source_endpoint_id` заполнены «Период выгрузки данных: Начало/Конец». |
| `terraform apply` висит на `yandex_datatransfer_transfer.main` | При `on_create_activate_mode = "sync_activate"` apply ждёт окончания snapshot'а. Для больших счётчиков это 10–30 мин. Проверь прогресс: `yc datatransfer transfer get $(terraform -chdir=terraform output -raw transfer_id)`. |
| Функция: `Lockbox error: <urlopen error [Errno -3] Temporary failure in name resolution>` | NAT не подключён к подсети, или DNS stale на cold start. `module "network"` должен был навесить route-table — проверь: `yc vpc subnet get --id <id> --format json \| jq .route_table_id`. Retry в `handler.py` должен добить за 2–16с. |
| `smoke.sh`: `visits_raw rows: 0` | Smoke-тест автоматически создаёт `VIEW visits_raw AS SELECT * FROM visits_<transfer_id>` — `transfer_id` берётся из `terraform output`. Если всё равно пусто — snapshot завершился с ошибкой; смотри `yc datatransfer transfer get $TRANSFER_ID`. |
| `smoke.sh`: все `conv=0` и топ каналов тоже `0` | Это не баг пайплайна — просто по выбранному `goal_id` не было конверсий в этом срезе данных. Смок сортирует топ по `visits` в этом случае + показывает колонки `visits`/`conv`/`revenue` по всем 4 моделям с проверкой cross-model инварианта `sum(visits)`. Проверь `SELECT arrayJoin(Goals.ID), count() FROM visits_raw GROUP BY 1 ORDER BY 2 DESC LIMIT 20` — там реальные id целей. |
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

## DataLens-дашборд

В репо зафиксирован готовый `datalens/dashboard.json` — экспорт воркбука
DataLens со всей логикой: подключение к ClickHouse, три датасета на
таблицах `attribution_results` / `visits_combined` + touchpoints-subselect,
семь чартов (3 KPI, 100%-стек, time-series, grouped bar, сводная таблица),
три глобальных селектора (Период / Модель / Источник) с прописанными
Связями.

**Что ты получаешь после импорта:**

- Индикаторы за период: атрибутированный доход, конверсии, среднее число
  касаний до конверсии.
- Сравнение 4 моделей (First / Last / Linear / Time Decay) в стек-баре
  и группированных столбцах — видно, как разные модели по-разному
  кредитуют источники.
- Time-series топ-источников для выбранной модели — переключи модель,
  график перестроится.
- Сводная таблица источник × модель × метрика с heat-gradient по конверсиям.

Полный рецепт сборки — в [`datalens/BUILD_SPEC.md`](datalens/BUILD_SPEC.md),
обоснования решений и v2-TODO — в [`datalens/NOTES.md`](datalens/NOTES.md).

### Импорт дашборда

Выполняется один раз после `terraform apply`. Terraform не автоматизирует
этот шаг — ни `yandex_datalens_connection`, ни API для CH в DataLens
пока не поддерживаются Terraform-провайдером (см. [раздел «Что в
будущих версиях»](datalens/NOTES.md#v2--на-сортировку)).

1. Получи ссылку на форму импорта:
   ```bash
   terraform -chdir=terraform output -raw datalens_import_url
   # → https://datalens.yandex.cloud/workbooks/import?folderId=<folder_id>
   ```
2. Открой ссылку в браузере. DataLens откроет диалог **Импортировать
   воркбук** в нужном каталоге.
3. Выбери файл `datalens/dashboard.json` из репо. Укажи название
   и коллекцию (можно создать новую «Атрибуция Метрики»).
4. На шаге привязки подключения: DataLens покажет пустое
   **ClickHouse connection** — нажми «Создать новое» / «Привязать»,
   выбери свой кластер из выпадашки (`terraform output -raw
   clickhouse_cluster_id` — для сверки) и введи:
   - **Имя пользователя**: `terraform output -raw clickhouse_db_user`
     (по умолчанию `analyst`).
   - **Пароль**: тот же, что в `terraform.tfvars` / Lockbox.
   - **Уровень SQL-запросов**: `Подзапросы` (нужно для датасета
     `ds_chains`, даже если Sankey-чарт сейчас не используется).
5. Подтверди импорт. Все три датасета автоматически привяжутся к
   созданному подключению, чарты и дашборд откроются с данными.

После импорта на дашборде «Атрибуция Метрики — Витрина» крути
селекторы Период / Модель / Источник — всё интерактивно.

### Что пошло не так: troubleshooting импорта

| Симптом | Причина и фикс |
|---------|----------------|
| «Workbook data hash validation failed» | Кто-то редактировал `datalens/dashboard.json` руками. Файл подписан серверным HMAC — любое изменение ломает импорт. Перевыгрузи из DataLens после правок (см. [BUILD_SPEC §10](datalens/BUILD_SPEC.md#10-экспорт-и-коммит)). |
| Кластер не виден в выпадашке при создании подключения | Не включён `access.data_lens = true` на MDB-кластере. Проверь: `yc managed-clickhouse cluster get <cluster_id> --format json \| jq .config.access.data_lens`. Если `false` — `terraform apply` должен был выставить флаг; возможно, drift. |
| «Permission denied» при импорте | У пользователя нет роли `datalens.instances.user` в организации или `datalens.admin` на целевой коллекции. Выдай через YC Identity Hub. |
| Датасеты привязались, но чарты красные («Connection error») | Пароль при создании подключения был введён неверно. Открой подключение → проверь пароль → сохрани. Чарты автоматически переподтянутся. |
| Дашборд импортировался, но селекторы ничего не фильтруют | Редкий баг — Связи не переехали. В редакторе дашборда → **Связи** → проверь, что три селектора привязаны к чартам (схема должна совпадать с [BUILD_SPEC §9](datalens/BUILD_SPEC.md#9-глобальные-селекторы)). |
| Хочу поправить dashboard.json | Не редактируй файл напрямую (хэш-валидация). Импортируй в свой воркбук → поправь в UI → **Экспортировать** → закоммить новый файл. См. [BUILD_SPEC §10](datalens/BUILD_SPEC.md#10-экспорт-и-коммит). |

### Авто-импорт (roadmap)

Пока что импорт — ручной клик в UI. Auto-import через internal BFF
(`POST /api/internal/v1/workbooks/import/`) технически возможен, но
endpoint приватный, без публичного SLA, контракт менялся в 2024
(hash-валидация, nullable collectionId). Подпишемся на него только
в Part E, с обязательным fallback'ом «ретраим через UI при поломке».

### Пересборка дашборда

Если нужно изменить чарт или добавить новый:

1. Импортируй текущий `datalens/dashboard.json` в чистый воркбук
   (см. выше).
2. Внеси правки в UI.
3. Экспортируй воркбук, перезапиши `datalens/dashboard.json`.
4. Закоммить изменения — хэш пересчитается на сервере, импорт
   продолжит работать.

> **Не редактируй `dashboard.json` руками** — hash-валидация
> сломает импорт. Всё, что выглядит редактируемым (названия
> полей, SQL датасетов, JS чарт-редактора) — правится через UI.

---

## Статус разработки

- [x] **Part A** — Ядро трансформаций (SQL + Cloud Function + тесты)
- [x] **Part B** — Terraform-модуль (протестирован end-to-end на реальном кластере YC)
- [x] **Part C** — Выбор цели конверсии (`scripts/pick_goal.py` — интерактивный picker)
- [x] **Part D** — DataLens-дашборд (`datalens/dashboard.json` + BUILD_SPEC + NOTES)
- [ ] **Part E** — Упаковка в Marketplace
