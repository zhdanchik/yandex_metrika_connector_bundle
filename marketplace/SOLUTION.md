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

> ### ⚠ Сильная рекомендация: создай отдельный каталог под это решение
>
> Все скрипты (особенно `cleanup.sh`) работают по префиксу имён внутри
> заданного каталога и выдают широкие IAM-роли. **Не разворачивай это
> в каталог с production-ресурсами.** Создай новый пустой каталог:
>
> ```bash
> yc resource-manager folder create --name metrika-attribution
> yc resource-manager folder list   # запомни id нового каталога — это будет folder_id
> ```
>
> Если что-то пойдёт не так — снести можно одной командой:
> `yc resource-manager folder delete --id <folder_id>`.

**В Yandex Cloud:**

1. Аккаунт с биллингом, привязанным к этому каталогу.
2. VPC-сеть и подсеть **в зоне `ru-central1-a`** (Terraform их не создаёт —
   использует существующие). Если их нет — создай:
   ```bash
   yc vpc network create --name metrika-net --folder-id <folder_id>
   yc vpc subnet  create --name metrika-subnet --folder-id <folder_id> \
       --network-name metrika-net --zone ru-central1-a --range 10.0.0.0/24
   ```
   Получить ID существующих:
   ```bash
   yc vpc network list --folder-id <folder_id>
   yc vpc subnet  list --folder-id <folder_id>
   ```
   > Если у тебя есть подсеть только в зоне `-b`/`-c`/`-d` — поменяй `zone`
   > в `terraform/modules/clickhouse/main.tf` (поле `host.zone`)
   > и убедись, что подсеть из той же зоны.

3. **IAM-роли на каталоге** для того, кто запускает `terraform apply`:
   `editor`, `iam.serviceAccounts.admin`, `storage.admin`, `mdb.admin`,
   `datatransfer.admin`, `serverless.functions.admin`, `lockbox.admin`.

   > **Если ты не администратор каталога** — попроси админа выдать роли.
   > Пример команды для админа (повторить для каждой роли):
   > ```bash
   > yc resource-manager folder add-access-binding <folder_id> \
   >     --role editor --subject userAccount:<твой_user_id>
   > ```
   > `editor` — широкая роль, поэтому особенно важно использовать
   > отдельный каталог (см. выше).

**В Яндекс Метрике:**

4. **Счётчик** с настроенной **целью конверсии**. Цель настраивается в
   Метрика → Настройка → Цели. Без цели атрибуцию считать не от чего.
5. **OAuth-токен Метрики с правом `metrika:write`**:
   - Зарегистрируй OAuth-приложение: <https://oauth.yandex.ru/client/new>
     → в разделе «Доступы» отметь **Яндекс Метрика → metrika:write**.
   - Получи токен: открой
     `https://oauth.yandex.ru/authorize?response_type=token&client_id=<твой_client_id>`
     в браузере — Яндекс выдаст токен в URL после редиректа.
   - Именно `write`: `metrika:read` недостаточно, Data Transfer падает с
     403 на активации.
   - Токен нужен **два раза**:
     - в YC Console при создании Metrika source endpoint (Шаг 1),
     - локально при запуске `scripts/pick_goal.py` (Шаг 3).
   - **В Terraform и Lockbox токен не сохраняется** — он живёт только
     на стороне YC Data Transfer и на твоей машине.

**Локальные инструменты:**

6. На своей машине поставь:
   - [`terraform`](https://developer.hashicorp.com/terraform/install) ≥ 1.5
   - [`yc` CLI](https://yandex.cloud/ru/docs/cli/quickstart) (после установки — `yc init` для аутентификации)
   - [`clickhouse-client`](https://clickhouse.com/docs/install) ≥ 21.1
   - `jq`, `python3`, `curl` (обычно уже есть; на macOS — `brew install jq`,
     на Ubuntu — `apt install jq python3 curl`)

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

- `folder_id`, `network_id`, `subnet_id` — id из «Что подготовить», п. 2
- `counter_id` — номер счётчика Метрики (виден в URL интерфейса Метрики:
  `metrika.yandex.ru/list/counter/<ID>`)
- `metrika_source_endpoint_id` — id из Шага 1 (вида `dte...`)
- `function_bucket_name` — **новое** имя бакета Object Storage. Скрипты
  его создадут — **не вписывай существующий бакет**, он будет удалён
  при `cleanup.sh`. Имя должно быть **глобально уникальным среди всех
  пользователей YC** (как в S3): только строчная латиница, цифры, дефисы;
  3–63 символа. Пример: `metrika-attribution-fn-acme-2026`.
- `clickhouse_password` — пароль для пользователя `analyst`. Минимум
  16 символов, буквы разного регистра + цифры + спецсимвол. ClickHouse
  слабый пароль не отвергнет — это твоя ответственность.
- `goal_id` — **не заполняй вручную**, его впишет Шаг 3.

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
./scripts/e2e.sh
```

Скрипт прогонит `terraform apply` и сделает smoke-тест. Apply синхронно
ждёт завершения первого snapshot'а Data Transfer (10–30 минут на крупных
счётчиках) — это нормально.

> **Совет первому запуску:** запусти **без** `ASSUME_YES=1` — скрипт
> покажет план и попросит подтвердить. `ASSUME_YES=1 ./scripts/e2e.sh`
> пропустит все подтверждения; используй только в CI/повторных запусках,
> когда уже знаешь, что именно произойдёт.

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
- ⚠ **ClickHouse-кластер по умолчанию имеет публичный IP**
  (`assign_public_ip = true`) — это нужно для применения DDL с твоей
  машины. Доступ всё равно идёт по TLS с паролем, но на production
  установи `false` в `terraform/modules/clickhouse/main.tf` и применяй
  DDL изнутри VPC (Jump-host). Опционально настрой
  `security_group_ids` с whitelist по IP.

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

> ⚠ **Прочитай этот раздел до запуска `cleanup.sh`.** Скрипт
> необратим, без dry-run и удаляет реальные ресурсы.

### Что делает `cleanup.sh`

- Ищет в указанном `folder_id` все ресурсы с именем, начинающимся на
  префикс **`metrika-attribution-*`**, и удаляет их: триггеры, функции,
  Data Transfer'ы, endpoint'ы, Lockbox-секреты, route-table'ы, VPC-gateway'и,
  сервисные аккаунты.
- Удаляет **ClickHouse-кластер** с подходящим префиксом, **автоматически
  снимая `deletion_protection`** даже если ты его выставлял.
- **Эмптит и удаляет Object Storage бакет** с именем из `function_bucket_name`
  (поиск по точному имени, не по префиксу). Все объекты в нём пропадают.
- Сохраняет Metrika source endpoint из Шага 1 (его создавал человек в UI).
- Удаляет локальный `terraform/.terraform`, `terraform.tfstate*`, `tfplan`.

Подтверждение спрашивается **один раз на всё** — не по каждому ресурсу.

### Безопасный путь — через удаление каталога

Если ты следовал рекомендации и развернул в **отдельный каталог**, проще
и безопаснее снести каталог целиком (никакие prefix-match'и не имеют значения):

```bash
yc resource-manager folder delete --id <folder_id>
```

### Если каталог общий — `cleanup.sh`

```bash
./scripts/cleanup.sh
```

**До запуска проверь, что в каталоге нет твоих ресурсов с именем
`metrika-attribution-*`** — они тоже будут удалены:

```bash
yc resource-manager folder list-resources --id <folder_id> | grep metrika-attribution
```

Дополнительно проверь, что `function_bucket_name` в `terraform.tfvars`
указывает именно на бакет, созданный этим решением (не на
ранее существовавший твой бакет с похожим именем):

```bash
grep function_bucket_name terraform/terraform.tfvars
```

### Чтобы удалить и Metrika source endpoint

По умолчанию endpoint из Шага 1 сохраняется — его создавал человек в UI.
Если хочешь снести и его:

```bash
KEEP_SOURCE_ID="" ./scripts/cleanup.sh
```

### Альтернатива — `terraform destroy`

```bash
terraform -chdir=terraform destroy
```

Удалит только то, что Terraform создавал и видит в `tfstate`. **Не**
удаляет содержимое бакета (если объекты добавлялись вне Terraform) и
**не** снимает `deletion_protection` с ClickHouse автоматически — это
безопаснее, но может потребовать ручных шагов для полной очистки.

---

## Ссылки

- Исходник: <https://github.com/zhdanchik/yandex_metrika_connector_bundle>
- Технические детали: [`../README.md`](../README.md)
- DataLens build spec: [`../datalens/BUILD_SPEC.md`](../datalens/BUILD_SPEC.md)
- Калькулятор YC: <https://yandex.cloud/ru/prices>
