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
| Model | `attribution_type` | string | none | direct | dimension |
| Date | `start_date` | date | none | direct | dimension |
| Channel | `source_code` | string | none | direct | dimension |
| Visits | `visits` | float | sum | direct | measure |
| Conversions | `conversions` | float | sum | direct | measure |
| Revenue | `revenue` | float | sum | direct | measure |

### Calculated fields

| Title | Formula | Тип | Role |
|-------|---------|-----|------|
| Conversion rate | `[Conversions] / [Visits]` | float | measure |
| Revenue per visit | `[Revenue] / [Visits]` | float | measure |
| Model label | `CASE [Model] WHEN 'first_touch' THEN 'First Touch' WHEN 'last_touch' THEN 'Last Touch' WHEN 'linear' THEN 'Linear' WHEN 'time_decay' THEN 'Time Decay' END` | string | dimension |

### Channel label (human-readable кодов источников)

Добавь calculated field `Channel label`:

```
CASE [Channel]
  WHEN '-1' THEN 'Internal'
  WHEN '0'  THEN 'Direct'
  WHEN '1'  THEN 'Referral'
  WHEN '4'  THEN 'Saved pages'
  WHEN '5'  THEN 'Undefined'
  WHEN '6'  THEN 'External links'
  WHEN '7'  THEN 'Email'
  WHEN '11' THEN 'QR code'
  ELSE
    CASE SUBSTR([Channel], 1, 2)
      WHEN '2_' THEN 'Search'
      WHEN '3_' THEN 'Ads'
      WHEN '8_' THEN 'Social'
      WHEN '9_' THEN 'Recommendations'
      WHEN '10' THEN 'Messenger'
      ELSE [Channel]
    END
END
```

### Filters

- `obligatory_filter` на `Date`: default = last 30 days (задаётся в
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
| From | `from_channel` | string | none | dimension |
| To | `to_channel` | string | none | dimension |
| Step | `step` | integer | none | dimension |
| Chain visits | `visits` | integer | sum | measure |
| Chain conversions | `conversions` | float | sum | measure |

---

## 5. Цветовая палитра (обязательно — showcase-эффект)

В **каждом** чарте где есть модель в color/legend → **Colors** → **Manual**:

| Model | Hex |
|-------|-----|
| First Touch | `#4E79A7` (синий) |
| Last Touch | `#E15759` (красный) |
| Linear | `#59A14F` (зелёный) |
| Time Decay | `#B07AA1` (фиолетовый) |

Палитра для каналов — авто (DataLens Retail), но зафиксируй `Direct` как
серый `#9C9C9C` чтобы не путать с рекламой.

---

## 6. Чарты (8 штук)

### Chart 1 — `kpi_revenue`: KPI Attributed Revenue (30d, Linear)

- Type: **Indicator** (Metric)
- Dataset: `ds_attribution`
- Measure: `Revenue`
- Filters: `Model = linear`, `Date = last 30 days`
- Subtitle: «Attributed revenue · Linear · last 30d»
- Format: `₽`, thousands separator, no decimals
- **Secondary comparison** (WoW delta): enable «Compare with previous period»,
  period = «previous 30 days»

### Chart 2 — `kpi_conversions`: KPI Attributed Conversions

- Type: **Indicator**
- Measure: `Conversions`
- Filters: `Model = linear`, `Date = last 30 days`
- Subtitle: «Conversions · Linear · last 30d»
- WoW comparison enabled

### Chart 3 — `kpi_touchpoints`: KPI Avg touchpoints

- **Этот KPI строится на `ds_chains`** — но нам нужно значение из
  `visits_combined` напрямую. Создай третий датасет `ds_touchpoints`
  подзапросом:

  ```sql
  SELECT avg(length(history.SourceCode)) AS avg_touches
  FROM metrika.visits_combined
  WHERE Conversions > 0
    AND toDate(history.UTCStartTime[-1]) >= today() - 30
  ```

- Type: **Indicator**, measure: `avg_touches`, format: `0.0`
- Subtitle: «Avg touchpoints to conversion · last 30d»

### Chart 4 — `ch_model_mix`: Stacked 100% bar — channel mix across 4 models

- Type: **Bar chart (100% stacked)**
- Dataset: `ds_attribution`
- X: `Model label`
- Y: `Conversions`
- Colors: `Channel label`
- Filters: `Date = last 30 days`; лимит top-5 каналов по Linear-модели
  (через `Filter top/bottom` на `Channel label` by `Conversions` where `Model = linear`)
- Title: «Channel mix across attribution models»
- Subtitle: «How differently each model credits channels»

### Chart 5 — `ch_time_series`: Time series — daily conversions by model

- Type: **Line chart**
- Dataset: `ds_attribution`
- X: `Date`
- Y: `Conversions`
- Colors: `Model label` (use manual palette)
- Filters: `Date = last 90 days`
- Title: «Attributed conversions over time»
- Subtitle: «All 4 models, daily»
- Y-axis: linear, no log scale
- Smooth: off (показываем реальные дневные колебания)

### Chart 6 — `ch_channel_grouped`: Grouped bar — top-10 channels × 4 models

- Type: **Bar chart (grouped)**
- Dataset: `ds_attribution`
- X: `Channel label` (top-10 by `sum([Conversions])` where `Model = linear`)
- Y: `Conversions`
- Colors: `Model label` (manual palette)
- Filters: `Date = last 30 days`
- Title: «Top channels: disagreement between models»
- Sort: by Linear-Conversions desc

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

- Title: «Customer journey: channel → channel»
- Subtitle: «Top transitions between touchpoints, last 30d (min 5 visits)»

### Chart 8 — `ch_pivot`: Master pivot table

- Type: **Pivot table**
- Dataset: `ds_attribution`
- Rows: `Channel label`
- Columns: `Model label`
- Measures: `Visits`, `Conversions`, `Revenue` (три цифры в ячейке)
- Filters: `Date = last 30 days`
- Subtotals: row totals on, column totals on
- Conditional formatting: heat gradient на `Conversions` по столбцу
- Title: «Channel × model: all metrics»

---

## 7. Dashboard layout

Создай dashboard внутри workbook'а, title: `Metrika Attribution — Showcase`.

**Грид 24-column, высоты строк = 4 units.**

| Row | Charts | Layout (x, y, w, h) |
|-----|--------|---------------------|
| 1 (KPI) | `kpi_revenue`, `kpi_conversions`, `kpi_touchpoints` | (0,0,8,4) (8,0,8,4) (16,0,8,4) |
| 2 | `ch_model_mix` (left), `ch_time_series` (right) | (0,4,12,8) (12,4,12,8) |
| 3 | `ch_channel_grouped` (full width) | (0,12,24,8) |
| 4 | `ch_sankey` (full width) | (0,20,24,10) |
| 5 | `ch_pivot` (full width) | (0,30,24,12) |

**Глобальные селекторы** (в верхней части дашборда, до KPI-ряда):

1. **Date range** — default: last 30 days. Dataset field: `Date`.
   Связать со всеми чартами кроме `ch_time_series` (у него свой период).
2. **Model** — single-select, default: `Linear`. Dataset field: `Model label`.
   Связать с `kpi_revenue`, `kpi_conversions`, `ch_pivot`, `ch_channel_grouped`.
   **Не связывать** с `ch_model_mix` и `ch_time_series` (они всегда показывают все модели).
3. **Channel** — multi-select, dataset field: `Channel label`.
   Связать со всеми чартами кроме `ch_sankey` (у него свой датасет с другими полями).

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
