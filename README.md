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
    requirements.txt         # clickhouse-driver
    sql/                     # Копии SQL-файлов, входящие в zip-архив функции

tests/
  attribution_math.py        # Python-эталон: derive_source_code, build_chains, 4 модели
  fixtures.py                # Синтетические визиты для тестов
  conftest.py                # pytest-конфигурация (маркер --integration)
  test_attribution_math.py   # 52 юнит-теста (без ClickHouse)
  test_integration.py        # Интеграционные тесты (требуют ClickHouse)

terraform/                   # Инфраструктурный слой (в разработке)
pyproject.toml               # pytest-конфигурация
```

---

## Архитектура пайплайна

```
visits_raw  (YC Data Transfer, CollapsingMergeTree)
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
Заполняется YC Data Transfer. Движок `CollapsingMergeTree(Sign)`.

Ключевые поля:
| Поле | Тип | Описание |
|------|-----|----------|
| `CounterID` | UInt32 | Счётчик Метрики |
| `UserIDHash` | UInt64 | Анонимизированный ID посетителя |
| `VisitID` | UInt64 | ID визита |
| `UTCStartTime` | DateTime | Время начала визита (UTC) |
| `VisitVersion` | UInt32 | Версия записи для argMax-дедупликации |
| `TrafficSource.*` | Nested | Источники трафика (Model=1 — первичный) |
| `Goals.ID / .Price / .Currency` | Array | Достигнутые цели, цена и валюта |
| `Sign` | Int8 | +1 вставка / −1 отмена (CollapsingMergeTree) |

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

Переменные окружения (задаются через Terraform):

| Переменная | Описание | По умолчанию |
|-----------|----------|--------------|
| `CLICKHOUSE_HOST` | Хост ClickHouse | — (обязательно) |
| `CLICKHOUSE_PORT` | Порт нативного протокола | 9440 (TLS) / 9000 |
| `CLICKHOUSE_DB` | База данных | `default` |
| `CLICKHOUSE_USER` | Пользователь | `default` |
| `CLICKHOUSE_PASSWORD` | Пароль | — (обязательно) |
| `CLICKHOUSE_TLS` | Использовать TLS (`1`/`0`) | `1` |
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

## Статус разработки

- [x] **Part A** — Ядро трансформаций (SQL + Cloud Function + тесты)
- [ ] **Part B** — Terraform-модуль
- [ ] **Part C** — Выбор цели конверсии (Marketplace wizard)
- [ ] **Part D** — DataLens-дашборд
- [ ] **Part E** — Упаковка в Marketplace
