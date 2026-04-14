# Attribution Analytics для Яндекс Метрики

Готовое решение для анализа атрибуции маркетинговых каналов на данных Яндекс Метрики,
развёртываемое в Яндекс Облаке через YC Data Transfer + Managed ClickHouse + Cloud Functions + DataLens.

---

## Структура репозитория

```
sql/
  01_schema.sql              # DDL всех таблиц ClickHouse (запустить один раз при установке)
  02_build_chains.sql        # Построение цепочек касаний (используется Cloud Function)
  03_attribution_models.sql  # Расчёт 4 моделей атрибуции  (используется Cloud Function)

functions/
  transform/
    handler.py               # Точка входа Yandex Cloud Function
    requirements.txt         # clickhouse-driver
    sql/                     # Копии SQL-файлов, входящие в zip-архив функции
      02_build_chains.sql
      03_attribution_models.sql

tests/
  attribution_math.py        # Python-реализация моделей атрибуции (эталон для тестов)
  fixtures.py                # Синтетические данные для тестов
  conftest.py                # pytest-конфигурация (fixtures для интеграционных тестов)
  test_attribution_math.py   # Юнит-тесты (без ClickHouse, 48 тестов)
  test_integration.py        # Интеграционные тесты (требуют ClickHouse)

terraform/                   # Инфраструктурный слой — Part B (в разработке)
pyproject.toml               # pytest-конфигурация
```

---

## Архитектура трансформаций (Part A)

### Шаг 1 — Схема таблиц (`01_schema.sql`)

| Таблица | Движок | Описание |
|---------|--------|----------|
| `visits_raw` | `CollapsingMergeTree` | Сырые визиты из YC Data Transfer |
| `hits_raw` | `CollapsingMergeTree` | Сырые хиты из YC Data Transfer |
| `sessions_chains` | `ReplacingMergeTree` | Цепочки касаний по каждой конверсии |
| `attribution_first_touch` | `ReplacingMergeTree` | Результаты модели First Touch |
| `attribution_last_touch` | `ReplacingMergeTree` | Результаты модели Last Touch |
| `attribution_linear` | `ReplacingMergeTree` | Результаты модели Linear |
| `attribution_time_decay` | `ReplacingMergeTree` | Результаты модели Time Decay |

> **Важно:** точная схема `visits_raw` / `hits_raw` зависит от версии коннектора
> YC Data Transfer. DDL в `01_schema.sql` — ориентировочный, основан на Logs API v2.
> Уточнить перед первым запуском.

### Шаг 2 — Цепочки касаний (`02_build_chains.sql`)

Параметры (подставляются handler.py):
- `{goal_id}` — ID целевого события
- `{counter_id}` — номер счётчика Метрики
- `{lookback_days}` — окно атрибуции в днях (по умолчанию 90)

Логика:
1. Нормализует канал для каждого визита (UTM > TrafficSource > Referer > direct)
2. Находит конвертирующие визиты (те, где `has(GoalsID, goal_id)`)
3. Для каждой конверсии собирает все визиты ClientID за `lookback_days` дней
4. Нумерует касания хронологически (position 1 = самое старое)

### Шаг 3 — Модели атрибуции (`03_attribution_models.sql`)

Параметры:
- `{goal_id}` — ID цели
- `{half_life}` — период полураспада для Time Decay в днях (по умолчанию 7.0)

| Модель | Логика |
|--------|--------|
| **First Touch** | 100% кредита первому касанию (position = 1) |
| **Last Touch** | 100% кредита последнему касанию (is_converting = 1) |
| **Linear** | Кредит распределяется поровну: 1/N на каждое касание |
| **Time Decay** | Вес ∝ 2^(−days_before_conv / half_life), нормализован в сумму = 1 |

### Нормализация каналов

```
UTM source + medium  →  '{utm_source} / {utm_medium}'
UTM source only      →  '{utm_source} / organic'
TrafficSource = ad   →  'paid / cpc'
TrafficSource = organic → 'organic / organic'
TrafficSource = social  → '{referer_domain} / social'
Referer domain only  →  '{referer_domain} / referral'
Иначе               →  'direct / none'
```

---

## Cloud Function

**Точка входа:** `functions/transform/handler.py`

Переменные окружения (задаются через Terraform):

| Переменная | Описание | По умолчанию |
|-----------|----------|--------------|
| `CLICKHOUSE_HOST` | Хост ClickHouse | — (обязательно) |
| `CLICKHOUSE_PORT` | Порт нативного протокола | 9440 (TLS) |
| `CLICKHOUSE_DB` | База данных | `default` |
| `CLICKHOUSE_USER` | Пользователь | `default` |
| `CLICKHOUSE_PASSWORD` | Пароль | — (обязательно) |
| `CLICKHOUSE_TLS` | Использовать TLS | `1` |
| `COUNTER_ID` | Номер счётчика Метрики | — (обязательно) |
| `GOAL_ID` | ID цели конверсии | — (обязательно) |
| `LOOKBACK_DAYS` | Окно атрибуции (дней) | `90` |
| `HALF_LIFE_DAYS` | Полураспад Time Decay (дней) | `7.0` |

---

## Тесты

### Юнит-тесты (без ClickHouse)

```bash
pip install pytest
pytest tests/test_attribution_math.py -v
```

48 тестов, покрывают:
- Нормализацию каналов (`derive_channel`)
- Построение цепочек (`build_chains`): порядок позиций, флаг is_converting,
  окно атрибуции, повторные конверсии
- Все 4 модели атрибуции: корректность весов, граничные случаи
- Кросс-модельные инварианты: сумма кредитов = количество конверсий

### Интеграционные тесты (требуют ClickHouse)

```bash
# Запустить ClickHouse локально
docker run -d -p 9000:9000 clickhouse/clickhouse-server

# Запустить тесты
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
