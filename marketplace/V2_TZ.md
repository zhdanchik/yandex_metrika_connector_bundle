# ТЗ v2: что нужно от команды Yandex Cloud

> **Адресат.** Команда Yandex Cloud (Data Transfer, DataLens, Marketplace).
> **Контекст.** Attribution Analytics bundle для Яндекс Метрики —
> см. [`SOLUTION.md`](SOLUTION.md) и [корневой README](../README.md).
> v1 развёрнут, работает, имеет три ручных шага. v2 — убрать их
> и опубликоваться native Terraform product в Marketplace.

Документ описывает три независимых блока API/продукта, которые нужны
для v2. Блоки можно брать в работу параллельно — между собой они не
зависят. Ниже каждый блок: что не так сейчас, что хочется, acceptance.

---

## Блок A. Metrika source endpoint: поле `period` в публичном API

### Что не так сейчас

[`MetrikaSource`](https://github.com/yandex-cloud/cloudapi/blob/master/yandex/cloud/datatransfer/v1/endpoint/metrika.proto)
в публичном proto содержит только `counter_ids`, `token`,
`streams: {type, columns}`. Поле `period` (диапазон дат для snapshot-выгрузки)
в публичном API отсутствует:

- нет в proto,
- нет в [Terraform-провайдере](https://github.com/yandex-cloud/terraform-provider-yandex/blob/master/yandex/datatransfer_structures.go)
  (проверено в `datatransfer_structures.go`: структура `Metrika` не содержит `Period`),
- нет в Python SDK `yandexcloud`,
- нет в `yc` CLI (`yc datatransfer endpoint create metrika-source …`),
- `Get` на endpoint / transfer не возвращает его ни в одном формате.

При этом:
- UI YC Console сохраняет `period` через приватный API (`POST /endpoints/…`
  с расширенным телом),
- `Transfer.Create` в `SNAPSHOT_ONLY`-режиме **требует** `period` на
  source — без него активация падает с ошибкой
  `current metrica source config not suitable for snapshot: period setting required`.

В итоге весь бандл автоматизируется через Terraform **кроме** одного
ручного клика в UI — создания source endpoint'а с `period`.

### Что хочется

1. **В proto** `yandex.cloud.datatransfer.v1.endpoint.MetrikaSource`
   добавить поле `period`:

   ```proto
   message MetrikaSource {
     repeated int64 counter_ids = 1;
     string token = 2;
     repeated MetrikaStream streams = 3;
     MetrikaPeriod period = 4;        // ← новое
   }

   message MetrikaPeriod {
     google.type.Date from = 1;       // Начало периода, YYYY-MM-DD
     google.type.Date to   = 2;       // Конец (опционально — если не задан, до сегодня)
   }
   ```

   Альтернативно — `google.protobuf.Timestamp` / `string` c валидацией
   формата на сервере; ключевой запрос — само поле должно быть read/write
   через публичный API, формат — на усмотрение команды DT.

2. **В Terraform-провайдере** (`yandex_datatransfer_endpoint`,
   секция `settings.metrika_source`) добавить поддержку блока `period`:

   ```hcl
   resource "yandex_datatransfer_endpoint" "metrika_src" {
     name = "metrika-source"
     settings {
       metrika_source {
         counter_ids = [var.counter_id]
         token { raw = var.metrika_oauth_token }  # или обёртка с lockbox_secret_id

         period {
           from = "2024-01-01"
           to   = "2024-12-31"   # опционально
         }

         stream {
           type    = "VISITS"
           columns = [...]
         }
       }
     }
   }
   ```

3. **В Python SDK** `yandexcloud` — регенерация из обновлённого proto
   (автоматом через build).

4. **В `yc` CLI** — флаг `--period-from / --period-to` для
   `yc datatransfer endpoint create metrika-source`.

5. **`Endpoint.Get`** должен возвращать `period` в ответе (сейчас поле
   даже при создании через UI не видно наружу — это блокирует импорт
   существующих endpoint'ов в Terraform-state через `terraform import`).

### Acceptance

- [ ] В публичном proto есть поле `period` с документированным типом.
- [ ] `yc datatransfer endpoint create metrika-source --period-from ... --period-to ...`
  работает и создаёт endpoint, пригодный для `Transfer.Create` в
  `SNAPSHOT_ONLY`-режиме без ручной доводки в UI.
- [ ] Соответствующий ресурс/блок есть в Terraform-провайдере
  `yandex-cloud/yandex` (версия ≥ указанной в release notes).
- [ ] `Endpoint.Get` возвращает `period` в JSON-ответе.
- [ ] В бандле Attribution Analytics переменная
  `metrika_source_endpoint_id` удалена; `module.transfer` создаёт
  source endpoint целиком через Terraform.

---

## Блок B. DataLens: публичный API импорта воркбука

### Что не так сейчас

- Internal BFF-endpoint `POST /api/internal/v1/workbooks/import/`
  принимает JSON-воркбук, но:
  - приватный (`/internal/`), без публичного SLA,
  - контракт менялся в 2024 (добавилась HMAC-подпись файла на сервере,
    `collectionId` стал nullable),
  - требует уже существующий `workbookId` (нет «создать из файла в одном вызове»).
- В публичном API Yandex Cloud DataLens (OpenAPI на
  [yandex.cloud/api/datalens](https://yandex.cloud/ru/docs/datalens/api-ref/))
  эндпоинта импорта воркбука нет вовсе.
- В Terraform-провайдере ресурс `yandex_datalens_connection` поддерживает
  **только** YDB-backend; варианта под ClickHouse нет. Ресурса
  `yandex_datalens_workbook` / `yandex_datalens_dataset` /
  `yandex_datalens_chart` нет в принципе.
- `yc` CLI — `yc datalens` не существует.

Из-за этого `datalens/dashboard.json` импортируется только вручную
через UI (см. `SOLUTION.md` §«Импорт дашборда»). Любой e2e-сценарий
(в т.ч. Marketplace-кнопка «Развернуть») упирается в ручной клик.

### Что хочется (в порядке приоритета)

1. **Публичный REST-эндпоинт** `POST /datalens/v1/workbooks:import`
   (или аналог в стиле YC OpenAPI): принимает JSON воркбука +
   `collectionId` + опциональный `workbookName`, возвращает
   `workbookId`. Без приватной HMAC-подписи — либо подписываем на
   клиенте детерминированным алгоритмом (публичная спека), либо
   принимаем неподписанный JSON и хешируем на сервере.

2. **Terraform-ресурсы:**

   ```hcl
   resource "yandex_datalens_connection" "ch" {
     name             = "ch_metrika"
     workbook_id      = yandex_datalens_workbook.main.id
     type             = "clickhouse"
     mdb_cluster_id   = var.clickhouse_cluster_id
     username         = var.clickhouse_user
     password         = var.clickhouse_password
     cache_ttl        = 300
     raw_sql_level    = "subselect"
   }

   resource "yandex_datalens_workbook" "main" {
     collection_id = var.datalens_collection_id
     name          = "Дашборд атрибуции"
     import_file   = file("${path.module}/../datalens/dashboard.json")
   }
   ```

   Минимум — `yandex_datalens_workbook` с импортом из файла.
   Connection-ресурс для ClickHouse — тоже очень желательно, иначе
   в workbook.json придётся патчить `connection.id` post-apply.

3. **`yc` CLI:** `yc datalens workbook import --collection-id <id> --file <path>`
   как тонкая обёртка над (1).

### Acceptance

- [ ] В [OpenAPI DataLens](https://yandex.cloud/ru/docs/datalens/api-ref/)
  описан эндпоинт импорта воркбука.
- [ ] `yandex_datalens_workbook` с `import_file` есть в TF-провайдере.
- [ ] `yandex_datalens_connection` поддерживает `type = "clickhouse"`
  (MDB-кластер по id).
- [ ] В бандле Attribution Analytics раздел «Импорт дашборда» сводится
  к одной строке `terraform apply` — ручных кликов в UI нет.
- [ ] Есть ответ, как быть с HMAC-подписью, которая сейчас валидирует
  `dashboard.json` на импорте (либо сервер хеширует сам и валидация
  становится server-side, либо публикуется алгоритм для клиента).

---

## Блок C. Marketplace Terraform Product: wizard c динамическими полями

### Что не так сейчас

- v1 публикуется как «Solution» (статическая ссылка на репо + инструкция
  в `SOLUTION.md`). Пользователь клонирует репо и руками запускает
  `terraform apply`.
- Native Marketplace Terraform product поддерживает wizard-схему
  входных переменных (см.
  [yandex.cloud/marketplace — Partner Portal](https://yandex.cloud/ru/docs/marketplace/concepts/partner-portal))
  в формате YAML со статическими полями: `type: string|number|bool`,
  `enum`, `default`, `description`.
- `goal_id` в нашем бандле выбирается через интерактивный
  [`scripts/pick_goal.py`](../scripts/pick_goal.py): скрипт дёргает
  `GET /management/v1/counter/{id}/goals` Metrika Management API
  (не YC API), фильтрует ретаргетинг/engagement-цели, показывает меню.
  В текущем статическом wizard'е такое не реализовать — пользователь
  должен знать `goal_id` числом заранее и ввести в поле.

### Что хочется

1. **Динамические поля в wizard-схеме Marketplace.** Поддержка
   дропдаунов, заполняемых во время заполнения формы, на основе:
   - значений других уже введённых полей (зависимость
     `counter_id → goal_id`),
   - внешнего API-вызова (Metrika Management API — не YC, важный нюанс).

   Вариант реализации A (предпочтительный): разрешить в wizard-схеме
   поле типа `dynamic_select` с URL-шаблоном и mapping'ом:

   ```yaml
   - name: goal_id
     type: dynamic_select
     depends_on: [counter_id, metrika_oauth_token]
     fetch:
       url: https://api-metrika.yandex.net/management/v1/counter/{{counter_id}}/goals
       headers:
         Authorization: OAuth {{metrika_oauth_token}}
       response_path: $.goals[*]
       filter: 'is_retargeting == 0 && type != "depth" && type != "number"'
       value_field: id
       label_field: name
   ```

   Вариант B: разрешить wizard'у исполнять sandbox'нутый Python-скрипт
   (формат `pick_goal.py`) перед `terraform apply` и писать результат
   во временный tfvars. Тяжелее в безопасности — не настаиваем.

2. **Передача чувствительных полей (OAuth-токен Метрики) в wizard.**
   Сейчас ближайший аналог — `sensitive: true` поле, которое попадает
   в `TF_VAR_*` на стороне деплой-раннера Marketplace. Запрос —
   гарантия, что такое поле:
   - не пишется в журналы Marketplace,
   - не остаётся в state артефакте после удаления продукта пользователем.

3. **Условные/зависимые поля в wizard-схеме.** Пример —
   `metrika_source_endpoint_id` должен появиться в форме **только если**
   ещё не поддержан блок A (fallback до v2a). После того как блок A
   сделан — это поле исчезает, и вместо него появляются
   `metrika_oauth_token` + `period_from` / `period_to`.

4. **Публикация product.** Классический флоу через Partner Portal
   ([yandex.cloud/marketplace-partners](https://yandex.cloud/ru/marketplace-partners)):
   - git-репозиторий с модулем + тэг версии,
   - `manifest.yaml` с метаданными (название, категории, логотип, прайсинг),
   - `inputs.yaml` (wizard-схема),
   - `README.ru.md` / `README.en.md` для листинга.

### Acceptance

- [ ] Marketplace Partner Portal поддерживает `dynamic_select` поле
  с внешним HTTP-вызовом (или документированный workaround).
- [ ] В бандле Attribution Analytics — `marketplace/manifest.yaml`,
  `marketplace/inputs.yaml`, который задекларирован с
  `counter_id + metrika_oauth_token → goal_id` как зависимым дропдауном.
- [ ] При развёртывании через Marketplace-кнопку «Развернуть»
  пользователь не открывает терминал — всё делается в UI.
- [ ] OAuth-токен Метрики, введённый в форме, не персистится в
  артефактах Marketplace после удаления продукта.

---

## Блок D. Общие acceptance-критерии v2

- [ ] Блоки A, B, C зарелизены в публичном API / TF-провайдере /
  Marketplace Portal с документацией.
- [ ] Бандл Attribution Analytics переведён на v2-поверхности:
  - в `terraform/` нет переменной `metrika_source_endpoint_id`
    (блок A),
  - раздел «Импорт дашборда» в `SOLUTION.md` сводится к одной строке
    (блок B),
  - в `marketplace/` добавлены `manifest.yaml` + `inputs.yaml` (блок C).
- [ ] `scripts/pick_goal.py` остаётся как dev-утилита
  (запуск из CLI без wizard'а) — удалять не нужно.
- [ ] В корневом README пункт Part E помечен `[x] v2 (native TF product)`.
- [ ] e2e-сценарий «новый пользователь → дашборд с данными» укладывается
  в ≤ 15 минут без терминала (медиана, без учёта snapshot'а Data Transfer).

---

## Приоритизация и зависимости

```
A (Metrika period)  ──┐
                      │
B (DataLens import) ──┼──▶  C (Marketplace wizard) ──▶ v2 publish
                      │
                     C может стартовать параллельно с A и B,
                     но листинг в Marketplace имеет смысл
                     только когда A+B готовы (иначе пользователь
                     всё равно попадает в ручные шаги).
```

- **A** — минимально инвазивное изменение: поле в proto + проброс
  в TF-провайдер. Ожидаем быстрый разовый патч.
- **B** — самое объёмное: требует публикации внутреннего API наружу
  с SLA и решения про HMAC-подпись. Есть риск, что команда DataLens
  возьмёт это в v2.X своего roadmap'а с отдельными сроками.
- **C** — зависит от расширения формата wizard-схемы Marketplace; без
  `dynamic_select` бандл публикуется, но теряет главную фишку
  «ввёл счётчик → увидел список целей».

---

## Контакты и обратная связь

- Issue-трекер бандла: <https://github.com/zhdanchik/yandex_metrika_connector_bundle/issues>
- По каждому блоку разумно открыть отдельный issue в соответствующем
  репозитории YC (cloudapi / terraform-provider-yandex /
  marketplace-partners) со ссылкой на этот документ.

Если у команды YC появятся уточняющие вопросы по use-case (зачем нам
именно эти поля, как ходит OAuth-токен, какие лимиты Metrika API
в фоне) — весь контекст уже есть в корневом
[README](../README.md) и [`SOLUTION.md`](SOLUTION.md), дублировать
его сюда не стали.
