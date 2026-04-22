# Attribution Analytics для Яндекс Метрики — Yandex Cloud Solution

Готовое решение: маркетинговая атрибуция (First / Last / Linear / Time
Decay) на сырых визитах Яндекс Метрики, развёрнутое в твоём каталоге
Yandex Cloud. На выходе — дашборд DataLens, обновляющийся ежедневно.

> Это листинг **Marketplace Solution v1** — развёртывание идёт через
> `terraform apply` из этого репозитория. Native Terraform-product с
> кнопкой «Развернуть» в UI — roadmap v2, требует поддержки со стороны
> команды YC (см. [`V2_TZ.md`](V2_TZ.md)).

---

## Что получаешь

- **Пайплайн в ClickHouse**, обновляющийся раз в сутки:
  `visits_raw` → `visits_prepared` → `visits_combined` → `attribution_results`.
- **Четыре модели атрибуции** в одной таблице `attribution_results`:
  First Touch, Last Touch, Linear, Time Decay (настраиваемый `half_life`).
- **Дашборд DataLens** из семи чартов: три KPI (доход, конверсии,
  среднее число касаний), 100%-стек сравнения моделей, time-series
  топ-источников, grouped bar, сводная таблица источник × модель.
  Три глобальных селектора: Период / Модель / Источник.
- **Инфра-as-code**: Terraform-модуль разворачивает всё в одном каталоге.

Архитектура и таблицы подробно — в [корневом README](../README.md).

---

## Что развёртывается

| Компонент | Зачем |
|-----------|-------|
| Managed Service for ClickHouse | Хранилище визитов и результатов |
| Yandex Data Transfer | Ежедневная выгрузка визитов из Метрики → ClickHouse |
| Cloud Functions | Трансформации (Python 3.11, stdlib) |
| Cloud Scheduler (timer trigger) | Запуск функции по cron (03:00 UTC по умолчанию) |
| Object Storage | Хранение zip-архива функции |
| Lockbox | Пароль ClickHouse (функция читает через IAM-токен) |
| VPC Gateway + route-table | Egress в интернет для функции (Lockbox API) |
| DataLens | Визуализация (connection создаётся пользователем вручную) |

---

## Стоимость

Зависит от размера счётчика Метрики (объёма визитов) и выбранного класса
ClickHouse. Оцени под свою нагрузку через официальный калькулятор
Yandex Cloud:

- **Калькулятор:** <https://yandex.cloud/ru/prices>

Дефолты бандла (Terraform-переменные можно менять):

- ClickHouse: один хост `s3-c2-m8` (2 vCPU, 8 GB RAM) + 50 GB network-SSD
- Cloud Function: 512 MB, ~10 минут в сутки
- Data Transfer: snapshot-режим, без persistent streaming

Для типового счётчика (~100k визитов/день) — порядок величины десятки–сотни
рублей в сутки, основная статья — ClickHouse-хост. Для production-нагрузок
меняй `resource_preset_id` и `disk_size` в `terraform/variables.tf`.

---

## Что нужно иметь ДО развёртывания

1. **Аккаунт Yandex Cloud** с биллингом и каталогом, VPC с подсетью в
   `ru-central1-a`.
2. **IAM-роли** на каталоге у того, кто запускает `terraform apply`:
   `editor`, `iam.serviceAccounts.admin`, `storage.admin`, `mdb.admin`,
   `datatransfer.admin`, `serverless.functions.admin`, `lockbox.admin`.
3. **Счётчик Яндекс Метрики** с настроенной целью конверсии.
4. **OAuth-токен Метрики** с правом `metrika:write` — получить на
   <https://oauth.yandex.ru/>. Токен нужен в двух местах:
   - один раз в UI — при создании Metrika source endpoint (см. ниже);
   - один раз в `scripts/pick_goal.py` — для выбора `goal_id`.
   В Terraform/Lockbox токен **не сохраняется**.
5. **Локальные инструменты:** `terraform ≥ 1.5`, `yc` CLI, `clickhouse-client`,
   `jq`, `python3`, `curl`.

---

## Ручной шаг (v1)

Перед `terraform apply` нужно один раз создать Metrika source endpoint
в YC Console (поле `period` — write-only в публичном API YC, обходного
пути пока нет):

1. YC Console → **Data Transfer → Endpoints → Создать**
2. Направление: **Источник**, база: **Metrica**
3. Укажи `counter_id`, OAuth-токен (`metrika:write`), период выгрузки
4. Stream **Визиты** с полями (см. список в корневом
   [README §«Ручной шаг: Metrika source endpoint»](../README.md#ручной-шаг-metrika-source-endpoint))
5. Сохрани → получишь id вида `dte...` → впиши в `terraform.tfvars`
   как `metrika_source_endpoint_id`

**В v2 этого шага не будет** — это пункт A в [`V2_TZ.md`](V2_TZ.md).

---

## Как развернуть

```bash
# 1. Клонируем репо
git clone https://github.com/zhdanchik/yandex_metrika_connector_bundle.git
cd yandex_metrika_connector_bundle

# 2. Заполняем переменные
cd terraform && cp terraform.tfvars.example terraform.tfvars
# отредактируй folder_id, network_id, subnet_id, counter_id,
# function_bucket_name, metrika_source_endpoint_id, clickhouse_password

# 3. Выбираем цель конверсии (интерактивно, без записи токена)
python3 ../scripts/pick_goal.py
# либо в CI: METRIKA_OAUTH_TOKEN=xxx python3 ../scripts/pick_goal.py \
#   --non-interactive --goal-name "Покупка"

# 4. Разворачиваем (preflight → terraform apply → smoke)
cd .. && ASSUME_YES=1 ./scripts/e2e.sh
```

`e2e.sh` делает: `cleanup` (опционально) → `deploy` (preflight + Terraform +
синхронное ожидание snapshot'а Data Transfer) → `smoke` (invoke функции +
проверка всех таблиц + кросс-модельный инвариант).

Шаги отдельно — в корневом [README §«Развёртывание»](../README.md#развёртывание-terraform).

---

## Импорт дашборда DataLens (ручной, один раз)

После успешного `terraform apply`:

1. Открой <https://datalens.yandex.cloud/collections>.
2. Создай коллекцию → **Создать → Воркбук** → **Импорт из файла** →
   выбери `datalens/dashboard.json`.
3. В созданном воркбуке открой connection `ch_metrika` → укажи свой
   `clickhouse_cluster_id` (из `terraform output`), пользователя
   `analyst`, пароль из `terraform.tfvars` → Сохранить.

Подробно (с troubleshooting) — [`datalens/BUILD_SPEC.md`](../datalens/BUILD_SPEC.md)
и корневой [README §«Импорт дашборда»](../README.md#импорт-дашборда).

**В v2 импорт будет автоматизирован** — пункт B в [`V2_TZ.md`](V2_TZ.md).

---

## Безопасность

- `clickhouse_password` попадает в Lockbox, функция читает его через
  IAM-токен metadata-сервиса — в env-переменных функции пароля нет.
- OAuth-токен Метрики живёт только на стороне YC Data Transfer, введён
  один раз в UI. В Terraform/Lockbox его нет.
- TLS обязателен (HTTPS `8443` с проверкой по Yandex CA).
- Пароли не попадают в cmdline (XML-конфиг `chmod 600` для DDL, HTTP-header
  для smoke-теста, sensitive TF-переменная для Data Transfer).
- `terraform.tfvars`, `*.tfstate*`, `CA.pem` — в `.gitignore`.

Полный разбор — корневой [README §«Безопасность»](../README.md#безопасность).

---

## Частые проблемы

| Симптом | Быстрая диагностика |
|---------|--------------------|
| `CreateTransfer: period setting required` | Не заполнен период в Metrika source endpoint — открой его в UI, укажи Начало/Конец. |
| `apply` висит на `yandex_datatransfer_transfer` | Нормально: `sync_activate` ждёт завершения snapshot'а (10–30 мин для крупных счётчиков). Прогресс: `yc datatransfer transfer get $(terraform -chdir=terraform output -raw transfer_id)`. |
| В DataLens кластер не виден в выпадашке | `access.data_lens` не выставлен. Проверь: `yc managed-clickhouse cluster get <id> --format json \| jq .config.access.data_lens`. |

Полная таблица — корневой [README §«Troubleshooting»](../README.md#troubleshooting)
и [импорт дашборда](../README.md#что-пошло-не-так-troubleshooting-импорта).

---

## Удаление

```bash
./scripts/cleanup.sh
# либо: terraform -chdir=terraform destroy
```

`cleanup.sh` автоматически **сохраняет** Metrika source endpoint (его
создавал человек в UI). Чтобы снести и его:
`KEEP_SOURCE_ID="" ./scripts/cleanup.sh`.

---

## Roadmap v2

Отдельный документ — [`V2_TZ.md`](V2_TZ.md). Коротко:

- **A.** API Metrika source endpoint с полем `period` → устранить ручной шаг.
- **B.** Публичный API DataLens для импорта воркбука → автоматизировать
  импорт дашборда.
- **C.** Native Marketplace Terraform product + wizard с интегрированным
  `pick_goal` (dropdown целей по введённому OAuth-токену).

Требует поддержки со стороны команды Yandex Cloud — ТЗ в `V2_TZ.md`.

---

## Ссылки

- Исходник: <https://github.com/zhdanchik/yandex_metrika_connector_bundle>
- Dev-README (полные технические детали): [`../README.md`](../README.md)
- DataLens build spec: [`../datalens/BUILD_SPEC.md`](../datalens/BUILD_SPEC.md)
- Калькулятор YC: <https://yandex.cloud/ru/prices>
