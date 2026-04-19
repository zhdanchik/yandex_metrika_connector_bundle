# DataLens dashboard build spec

Этот документ — **пошаговая инструкция** для ручной сборки showcase-дашборда
в Yandex DataLens UI. Одноразовая операция: собрал по spec'у → экспортнул
workbook → закоммитил `datalens/dashboard.json` → все последующие пользователи
импортят экспорт без модификаций.

> **Почему нельзя сгенерить JSON автоматом.** Экспорт-файл содержит `hash`
> (HMAC, подписанный серверным секретом `exportDataVerificationKey`). На импорте
> сервер проверяет подпись. Любой handcrafted/edited JSON → импорт падает.
> Единственный валидный путь — собрать в UI и экспортнуть. См.
> [datalens-meta-manager/workbook-import](https://github.com/datalens-tech/datalens-meta-manager/blob/main/src/controllers/workbook-import/start-workbook-import/index.ts).

---

## 0. Предусловия

Прогон `terraform apply` должен быть выполнен, и в кластере должны быть
данные (после первого запуска `scripts/smoke.sh`). Нужны значения из
`terraform output`:

```bash
terraform -chdir=terraform output clickhouse_cluster_id  # c9q...
terraform -chdir=terraform output clickhouse_db_name     # metrika
terraform -chdir=terraform output clickhouse_db_user     # analyst
```

На кластере уже включено `access.data_lens = true` — в выпадашке DataLens
кластер появится без дополнительных настроек со стороны MDB.

---

## 1. Collection + Workbook

1. Открой https://datalens.yandex.cloud → Collections → **Create collection**
   → name: `Metrika Attribution`.
2. Внутри коллекции → **Create workbook** → name: `Attribution dashboard`.

Все следующие объекты создаются внутри этого workbook'а — так они одним
файлом уедут в `dashboard.json` при экспорте.

---

## 2. Connection (единственный ручной шаг под пользователя)

Внутри workbook'а → **Add** → **Connection** → **Managed Service for ClickHouse**.

| Поле | Значение |
|------|----------|
| Cluster | выбери из dropdown по `clickhouse_cluster_id` |
| Username | `analyst` (или `clickhouse_db_user`) |
| Password | ClickHouse password (тот же, что в Lockbox) |
| Raw SQL level | **Subselect** (нужно для Sankey-датасета) |
| Cache TTL | 300 (5 минут — дашборд интерактивный) |

Имя connection: `ch_metrika`.

> На импорте чужого workbook'а этот шаг выполнит конечный пользователь:
> DataLens попросит «привязать connection» и покажет dropdown его кластеров.

---

## 3. Dataset #1: `ds_attribution` (основной)

**Source:** table `attribution_results`.

### Поля (fields)

| Title | Source | Тип | Agg | Calc | Role |
|-------|--------|-----|-----|------|------|
| Модель атрибуции | `attribution_type` | string | none | direct | dimension |
| Дата | `start_date` | date | none | direct | dimension |
| Источник атрибуции | `source_code` | string | none | direct | dimension |
| Число визитов | `visits` | float | sum | direct | measure |
| Число конверсий | `conversions` | float | sum | direct | measure |
| Доход | `revenue` | float | sum | direct | measure |

### Calculated fields

| Title | Formula | Тип | Role |
|-------|---------|-----|------|
| Конверсия, % | `[Число конверсий] / [Число визитов]` | float | measure |
| Доход на визит | `[Доход] / [Число визитов]` | float | measure |
| Доход на конверсию | `[Доход] / [Число конверсий]` | float | measure |
| Название модели атрибуции | см. ниже | string | dimension |
| Название источника атрибуции | см. ниже | string | dimension |

**Название модели атрибуции:**

```
CASE [Модель атрибуции]
  WHEN 'first_touch' THEN 'Первый клик'
  WHEN 'last_touch' THEN 'Последний клик'
  WHEN 'linear' THEN 'Линейная'
  WHEN 'time_decay' THEN 'Затухающая'
END
```

**Название источника атрибуции:**

```
CASE [Источник атрибуции]
  WHEN '-1' THEN 'Внутренние переходы'
  WHEN '0'  THEN 'Прямые заходы'
  WHEN '1'  THEN 'Переходы с сайтов'
  WHEN '4'  THEN 'Сохраненные страницы'
  WHEN '5'  THEN 'Не определено'
  WHEN '6'  THEN 'Внешние переходы'
  WHEN '7'  THEN 'E-mail'
  WHEN '11' THEN 'QR коды'
  ELSE
    CASE SUBSTR([Источник атрибуции], 1, 2)
      WHEN '2_' THEN 'Поиск'
      WHEN '3_' THEN 'Реклама'
      WHEN '8_' THEN 'Социальные сети'
      WHEN '9_' THEN 'Рекомендательные системы'
      WHEN '10' THEN 'Мессенджеры'
      ELSE [Источник атрибуции]
    END
END
```

### Filters

- `obligatory_filter` на `Дата`: default = last 30 days (задаётся в
  Filters секции датасета, не в конкретном чарте).

---

## 4. Dataset #2: `ds_chains` (для Sankey)

**Source:** `SELECT` subquery (нужно `Raw SQL level = Subselect` в connection).

Сам запрос агрегирует парные переходы между позициями в цепочке:

```sql
SELECT
    history.SourceCode[i]   AS from_channel,
    history.SourceCode[i+1] AS to_channel,
    position(toString(i)) AS step,
    count() AS visits,
    sum(Conversions) AS conversions
FROM (
    SELECT
        history.SourceCode,
        Conversions,
        arrayJoin(range(1, length(history.SourceCode))) AS i
    FROM metrika.visits_combined
    WHERE length(history.SourceCode) >= 2
)
GROUP BY from_channel, to_channel, step
HAVING visits >= 5           -- шум обрежь
ORDER BY step, visits DESC
```

### Поля

| Title | Source | Тип | Agg | Role |
|-------|--------|-----|-----|------|
| Откуда | `from_channel` | string | none | dimension |
| Куда | `to_channel` | string | none | dimension |
| Шаг | `step` | integer | none | dimension |
| Визиты цепочки | `visits` | integer | sum | measure |
| Конверсии цепочки | `conversions` | float | sum | measure |

---

## 5. Цветовая палитра (обязательно — showcase-эффект)

В **каждом** чарте где есть модель в color/legend → **Colors** → **Manual**:

| Модель | Hex |
|--------|-----|
| Первый клик | `#4E79A7` (синий) |
| Последний клик | `#E15759` (красный) |
| Линейная | `#59A14F` (зелёный) |
| Затухающая | `#B07AA1` (фиолетовый) |

Палитра для источников — авто (DataLens Retail), но зафиксируй `Прямые заходы`
серым `#9C9C9C` чтобы не путать с рекламой.

---

## 6. Чарты (8 штук)

### Chart 1 — `kpi_revenue`: KPI «Атрибутированный доход» (30д, Линейная)

- Type: **Indicator** (Metric)
- Dataset: `ds_attribution`
- Measure: `Доход`
- Filters: `Название модели атрибуции = Линейная`, `Дата = последние 30 дней`
- Subtitle: «Атрибутированный доход · Линейная · 30д»
- Format: `₽`, разделитель тысяч, без дробной части
- **Secondary comparison** (WoW delta): включи «Сравнение с предыдущим периодом»,
  период = «предыдущие 30 дней»

### Chart 2 — `kpi_conversions`: KPI «Атрибутированные конверсии»

- Type: **Indicator**
- Measure: `Число конверсий`
- Filters: `Название модели атрибуции = Линейная`, `Дата = последние 30 дней`
- Subtitle: «Конверсии · Линейная · 30д»
- WoW comparison включён

### Chart 3 — `kpi_touchpoints`: KPI «Среднее число касаний до конверсии»

- **Этот KPI строится на отдельном датасете** — нужно значение из
  `visits_combined` напрямую. Создай третий датасет `ds_touchpoints`
  подзапросом (Raw SQL level = Subselect):

  ```sql
  SELECT avg(length(history.SourceCode)) AS avg_touches
  FROM metrika.visits_combined
  WHERE Conversions > 0
    AND toDate(history.UTCStartTime[-1]) >= today() - 30
  ```

  Поле `avg_touches` → title: `Среднее число касаний`, float, agg `avg`.

- Type: **Indicator**, measure: `Среднее число касаний`, format: `0.0`
- Subtitle: «Среднее число касаний до конверсии · 30д»

### Chart 4 — `ch_model_mix`: Stacked 100% bar — распределение источников по моделям

- Type: **Bar chart (100% stacked)**
- Dataset: `ds_attribution`
- X: `Название модели атрибуции`
- Y: `Число конверсий`
- Colors: `Название источника атрибуции`
- Filters: `Дата = последние 30 дней`; лимит top-5 источников по модели «Линейная»
  (через `Filter top/bottom` на `Название источника атрибуции` by `Число конверсий`
  where `Название модели атрибуции = Линейная`)
- Title: «Распределение источников по моделям атрибуции»
- Subtitle: «Как по-разному модели атрибутируют каналы»

### Chart 5 — `ch_time_series`: Time series — ежедневные конверсии по моделям

- Type: **Line chart**
- Dataset: `ds_attribution`
- X: `Дата`
- Y: `Число конверсий`
- Colors: `Название модели атрибуции` (применить manual-палитру из §5)
- Filters: `Дата = последние 90 дней`
- Title: «Атрибутированные конверсии во времени»
- Subtitle: «Все 4 модели, ежедневно»
- Y-axis: linear, без log scale
- Smoothing: выкл (показываем реальные дневные колебания)

### Chart 6 — `ch_channel_grouped`: Grouped bar — top-10 источников × 4 модели

- Type: **Bar chart (grouped)**
- Dataset: `ds_attribution`
- X: `Название источника атрибуции` (top-10 by `sum([Число конверсий])`
  where `Название модели атрибуции = Линейная`)
- Y: `Число конверсий`
- Colors: `Название модели атрибуции` (manual-палитра)
- Filters: `Дата = последние 30 дней`
- Title: «Топ источников: расхождения между моделями»
- Sort: по «Линейная»-Число конверсий desc

### Chart 7 — `ch_sankey`: Sankey touch chains (Chart Editor)

Sankey в Wizard **нет** — делаем через Chart Editor (custom JS).

1. Workbook → **Add** → **Chart Editor** → template: **Custom JS**.
2. Linked dataset: `ds_chains`.
3. Tabs (вкладки кода):

**`params`** tab:

```json
{
  "chart_name": "Touch chains sankey",
  "max_steps": 3
}
```

**`url`** tab — оставь пустым (данные читаем через `Editor.getLoadedData()`).

**`js`** tab:

```js
// Source: ds_chains grouped by (from_channel, to_channel, step)
const data = Editor.getLoadedData();
const rows = data?.[0]?.rows ?? [];
const maxStep = 3;  // показываем 3 перехода максимум

const nodes = new Map();  // "step:channel" -> index
const links = [];

function nodeId(step, ch) {
    const k = `${step}:${ch}`;
    if (!nodes.has(k)) nodes.set(k, { id: nodes.size, name: ch, step });
    return nodes.get(k).id;
}

for (const row of rows) {
    const [from, to, step, visits] = row;
    if (step > maxStep) continue;
    links.push({
        source: nodeId(step, from),
        target: nodeId(step + 1, to),
        value: Number(visits),
    });
}

module.exports = {
    data: {
        nodes: [...nodes.values()],
        links,
    },
};
```

**`ui`** tab:

```json
{
  "controls": []
}
```

**`graph`** tab (chart config, передаётся в d3-sankey-рендер):

```json
{
  "chart": { "type": "sankey" },
  "series": [{
    "type": "sankey",
    "data": "{{data}}",
    "nodeAlign": "left",
    "nodeWidth": 12,
    "nodePadding": 8
  }],
  "tooltip": { "enabled": true }
}
```

**`shared`** tab — оставь пустым (нет state'а между tabs).

> Если Chart Editor type `d3_node` не рендерит sankey «из коробки», альтернатива —
> использовать публичный `d3-sankey` через CDN в `js` tab:
>
> ```js
> const d3 = require('https://cdn.jsdelivr.net/npm/d3@7/+esm');
> const d3sankey = require('https://cdn.jsdelivr.net/npm/d3-sankey@0.12/+esm');
> // ...собрать SVG вручную и вернуть через module.exports.html
> ```
>
> Этот fallback зависит от того, разрешает ли DataLens editor-runtime external
> modules. Если нет — оставить sankey как placeholder с пометкой «build in v2».

- Title: «Путь клиента: источник → источник»
- Subtitle: «Топ переходов между касаниями, 30д (мин 5 визитов)»

### Chart 8 — `ch_pivot`: Сводная таблица по источникам и моделям

- Type: **Pivot table**
- Dataset: `ds_attribution`
- Rows: `Название источника атрибуции`
- Columns: `Название модели атрибуции`
- Measures: `Число визитов`, `Число конверсий`, `Доход`, `Доход на конверсию`
  (4 цифры в ячейке)
- Filters: `Дата = последние 30 дней`
- Subtotals: row totals on, column totals on
- Conditional formatting: heat gradient на `Число конверсий` по столбцу
- Title: «Источник × модель: все метрики»

---

## 7. Dashboard layout

Создай dashboard внутри workbook'а, title: `Атрибуция Метрики — Showcase`.

**Грид 24-column, высоты строк = 4 units.**

| Row | Charts | Layout (x, y, w, h) |
|-----|--------|---------------------|
| 1 (KPI) | `kpi_revenue`, `kpi_conversions`, `kpi_touchpoints` | (0,0,8,4) (8,0,8,4) (16,0,8,4) |
| 2 | `ch_model_mix` (слева), `ch_time_series` (справа) | (0,4,12,8) (12,4,12,8) |
| 3 | `ch_channel_grouped` (full width) | (0,12,24,8) |
| 4 | `ch_sankey` (full width) | (0,20,24,10) |
| 5 | `ch_pivot` (full width) | (0,30,24,12) |

**Глобальные селекторы** (в верхней части дашборда, до KPI-ряда):

1. **Период** — default: последние 30 дней. Dataset field: `Дата`.
   Связать со всеми чартами кроме `ch_time_series` (у него свой период — 90д).
2. **Модель** — single-select, default: `Линейная`. Dataset field:
   `Название модели атрибуции`. Связать с `kpi_revenue`, `kpi_conversions`,
   `ch_pivot`, `ch_channel_grouped`. **Не связывать** с `ch_model_mix` и
   `ch_time_series` (они всегда показывают все 4 модели).
3. **Источник** — multi-select, dataset field: `Название источника атрибуции`.
   Связать со всеми чартами кроме `ch_sankey` (у него свой датасет с полями
   `Откуда`/`Куда`).

---

## 8. Экспорт и коммит

1. В workbook'е → **⋯ menu → Export**.
2. Скачанный файл положи как `datalens/dashboard.json` в корне репо.
3. Коммить:
   ```bash
   git add datalens/dashboard.json
   git commit -m "datalens: add exported dashboard.json"
   ```

---

## 9. Проверка: импорт в другом folder'е

Чтобы убедиться, что workbook портируем, создай второй folder (или используй
прод-окружение):

1. Прогони `terraform apply` в новом folder'е (тот же `clickhouse_cluster_id`
   получится другой).
2. Открой `terraform output datalens_import_url` и перейди по ссылке.
3. Import workbook → выбери `datalens/dashboard.json`.
4. На шаге привязки connection — выбери новый кластер из dropdown.
5. Открой dashboard — все чарты должны работать без ошибок.

Если хоть один чарт красный — импорт сломан, пишем issue.

---

## 10. Changelog на будущие версии

- **v2**: расширить `source_code` — добавить `ClickID`/кампании из Директа
  (требует пересборки `visits_prepared` с новыми полями)
- **v2**: real sankey через native DataLens Chart (как только появится в Wizard)
- **v2**: cohort-анализ — когорты по дате первого касания
- **v3**: ROAS-калькулятор — требует поле `cost` от пользователя (не из Метрики)
