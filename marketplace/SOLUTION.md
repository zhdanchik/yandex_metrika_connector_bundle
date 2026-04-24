# Attribution Analytics для Яндекс Метрики — Yandex Cloud Solution

Готовое решение: маркетинговая атрибуция (First / Last / Last Significant /
Linear / Time Decay) на сырых визитах Яндекс Метрики, развёрнутое в твоём
каталоге Yandex Cloud. На выходе — дашборд DataLens, обновляющийся
ежедневно. Развёртывание — `terraform apply` из этого репозитория.

---

## Что ты получаешь

- **Пайплайн в ClickHouse**, обновляющийся раз в сутки:
  `visits_raw` → `visits_prepared` → `visits_combined` → `attribution_results`.
- **Пять моделей атрибуции** в одной таблице `attribution_results`:
  First Touch, Last Touch, Last Significant, Linear, Time Decay
  (настраиваемый `half_life`).
- **Дашборд DataLens** (9 чартов): три KPI (доход, конверсии, среднее
  число касаний), 100%-стек сравнения моделей, time-series топ-источников,
  grouped bar, прямые vs ассоциированные конверсии, матрица переходов
  «откуда → куда», сводная таблица источник × модель. Три глобальных
  селектора: Период / Модель / Источник.
- **Инфра-as-code**: Terraform-модуль разворачивает всё в одном каталоге.

Архитектура и таблицы подробно — в [корневом README](../README.md).

---

## Что развёртывает Terraform

| Компонент | Зачем |
|-----------|-------|
| Managed Service for ClickHouse | Хранилище визитов и результатов |
| Yandex Data Transfer | Ежедневная выгрузка визитов из Метрики → ClickHouse |
| Cloud Functions | Трансформации (Python 3.11, stdlib) |
| Cloud Scheduler (timer trigger) | Запуск функции по cron (03:00 UTC по умолчанию) |
| Object Storage | Хранение zip-архива функции |
| Lockbox | Пароль ClickHouse |
| VPC Gateway + route-table | Egress в интернет для функции (доступ к Lockbox API) |

> **DataLens-дашборд импортируется вручную** после `terraform apply` —
> см. раздел «Импорт дашборда» ниже. Terraform его не создаёт: публичного
> API для импорта воркбука DataLens пока нет.

---

## Стоимость

Зависит от объёма визитов твоего счётчика и выбранного класса ClickHouse.
Оцени под свою нагрузку:

- **Калькулятор Yandex Cloud:** <https://yandex.cloud/ru/prices>

Дефолты бандла (меняются в `terraform/variables.tf`):

- ClickHouse: один хост `s3-c2-m8` (2 vCPU, 8 GB RAM) + 50 GB network-SSD
- Cloud Function: 512 MB, ~10 минут в сутки
- Data Transfer: snapshot-режим, без persistent streaming

Для типового счётчика (~100k визитов/день) порядок величины — десятки-сотни
рублей в сутки; основная статья — ClickHouse-хост. Для production
меняй `resource_preset_id` и `disk_size`.

---

## Что подготовить до начала

**В Yandex Cloud:**

1. Аккаунт с биллингом и каталогом.
2. VPC и подсеть в зоне `ru-central1-a` (Terraform их не создаёт —
   использует существующие).
3. IAM-роли на каталоге у того, кто запускает `terraform apply`:
   `editor`, `iam.serviceAccounts.admin`, `storage.admin`, `mdb.admin`,
   `datatransfer.admin`, `serverless.functions.admin`, `lockbox.admin`.

**В Яндекс Метрике:**

4. Счётчик с настроенной целью конверсии.
5. OAuth-токен с правом `metrika:write` — получить на
   <https://oauth.yandex.ru/>. Именно `write`: `metrika:read` недостаточно,
   Data Transfer падает с 403 на активации. Токен нужен дважды:
   - один раз в YC Console — при создании Metrika source endpoint (Шаг 1),
   - один раз локально — при запуске `scripts/pick_goal.py` (Шаг 3).

   **В Terraform и Lockbox токен не сохраняется.** Он живёт только
   на стороне YC Data Transfer и на твоей машине.

**Локальные инструменты:**

6. `terraform ≥ 1.5`, `yc` CLI, `clickhouse-client`, `jq`, `python3`, `curl`.

---

## Развёртывание — 4 шага

### Шаг 1. Создай Metrika source endpoint в YC Console (один раз, ~30 сек)

Поле «Период выгрузки» отсутствует в публичном API Yandex Cloud, поэтому
source endpoint создаётся через UI. Terraform поверх него строит всё
остальное.

1. YC Console → **Data Transfer → Endpoints → Создать**
2. Направление: **Источник**, база: **Metrica**
3. Заполни:
   - **Счётчик:** `<counter_id>`
   - **Токен:** OAuth-токен Метрики с правом `metrika:write`
   - **Период выгрузки данных:** Начало / Конец
   - **Stream:** Визиты + поля (список в корневом
     [README §«Ручной шаг: Metrika source endpoint»](../README.md#ручной-шаг-metrika-source-endpoint))
4. **Сохрани** → получишь id вида `dte...`. Он понадобится в Шаге 2.

### Шаг 2. Клонируй репо и заполни переменные

```bash
git clone https://github.com/zhdanchik/yandex_metrika_connector_bundle.git
cd yandex_metrika_connector_bundle/terraform
cp terraform.tfvars.example terraform.tfvars
```

Открой `terraform.tfvars` и заполни:

- `folder_id`, `network_id`, `subnet_id` — твои YC-ресурсы
- `counter_id` — номер счётчика Метрики
- `metrika_source_endpoint_id` — id из Шага 1 (`dte...`)
- `function_bucket_name` — **глобально уникальное** имя Object Storage бакета
- `clickhouse_password` — пароль для пользователя `analyst`

### Шаг 3. Выбери цель конверсии

```bash
python3 ../scripts/pick_goal.py
```

Скрипт спросит OAuth-токен Метрики, покажет список целей счётчика и
впишет выбранный `goal_id` в `terraform.tfvars`. Токен используется
один раз и нигде не сохраняется.

Для CI — без интерактива:

```bash
METRIKA_OAUTH_TOKEN=xxx python3 ../scripts/pick_goal.py \
  --non-interactive --goal-name "Покупка"
```

### Шаг 4. Разверни

```bash
cd ..
ASSUME_YES=1 ./scripts/e2e.sh
```

Скрипт прогонит `terraform apply` и сделает smoke-тест. Apply синхронно
ждёт завершения первого snapshot'а Data Transfer (10–30 минут на крупных
счётчиках) — это нормально.

Если нужен контроль по шагам:

```bash
./scripts/deploy.sh   # preflight + terraform apply
./scripts/smoke.sh    # invoke функции + проверка таблиц
```

Подробный разбор — [README §«Развёртывание»](../README.md#развёртывание-terraform).

---

## Импорт дашборда DataLens (после `terraform apply`, один раз)

1. Открой <https://datalens.yandex.cloud/collections>.
2. Создай коллекцию → **Создать → Воркбук** → **Импорт из файла** →
   выбери `datalens/dashboard.json` из репо.
3. В созданном воркбуке открой подключение **`ch_metrika`** и заполни:
   - **Кластер** — свой из выпадашки (значение из
     `terraform -chdir=terraform output -raw clickhouse_cluster_id`)
   - **Пользователь** — `analyst`
   - **Пароль** — тот же, что в `terraform.tfvars`
   - **Уровень SQL-запросов** — `Подзапросы`
4. **Проверить подключение** → **Сохранить**. Чарты оживут автоматически.

Детали и troubleshooting — [`datalens/BUILD_SPEC.md`](../datalens/BUILD_SPEC.md)
и [README §«Импорт дашборда»](../README.md#импорт-дашборда).

---

## Безопасность

- **`clickhouse_password`** попадает в Lockbox; функция читает его
  через IAM-токен метадата-сервиса. В env-переменных функции пароля нет.
- **OAuth-токен Метрики** в Terraform и Lockbox не попадает — живёт
  только на стороне YC Data Transfer (введён в UI в Шаге 1).
- **TLS обязателен** (HTTPS `8443` с проверкой по Yandex CA).
- **Пароли не попадают в cmdline**: XML-конфиг `chmod 600` для DDL,
  HTTP-заголовок для smoke-теста, sensitive TF-переменная для Data Transfer.
- **`terraform.tfvars`, `*.tfstate*`, `CA.pem`** — в `.gitignore`.

Полный разбор — [README §«Безопасность»](../README.md#безопасность).

---

## Частые проблемы

| Симптом | Быстрая диагностика |
|---------|--------------------|
| `CreateTransfer: period setting required` | Не заполнен период в Metrika source endpoint — открой его в UI, укажи Начало/Конец. |
| `apply` висит на `yandex_datatransfer_transfer` | Нормально: apply ждёт завершения первого snapshot'а (10–30 мин на крупных счётчиках). Прогресс: `yc datatransfer transfer get $(terraform -chdir=terraform output -raw transfer_id)`. |
| В DataLens кластер не виден в выпадашке подключения | На MDB-кластере не выставлен `access.data_lens`. Проверь: `yc managed-clickhouse cluster get <id> --format json \| jq .config.access.data_lens`. |

Полная таблица — [README §«Troubleshooting»](../README.md#troubleshooting)
и [импорт дашборда](../README.md#что-пошло-не-так-troubleshooting-импорта).

---

## Удаление

```bash
./scripts/cleanup.sh
# либо: terraform -chdir=terraform destroy
```

`cleanup.sh` **сохраняет Metrika source endpoint** (его создавал человек
в UI в Шаге 1). Чтобы снести и его:

```bash
KEEP_SOURCE_ID="" ./scripts/cleanup.sh
```

---

## Ссылки

- Исходник: <https://github.com/zhdanchik/yandex_metrika_connector_bundle>
- Технические детали: [`../README.md`](../README.md)
- DataLens build spec: [`../datalens/BUILD_SPEC.md`](../datalens/BUILD_SPEC.md)
- Калькулятор YC: <https://yandex.cloud/ru/prices>
