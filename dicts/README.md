# Словари источников

Пять CSV-словарей для резолва кодов Яндекс Метрики в человекочитаемые
русские названия.  Используются в DataLens-представлении
`v_attribution_results` (см. `sql/01_schema.sql`).

## Формат

Каждый файл — UTF-8 CSV с заголовком `id,name_ru`.

- `id`      — числовой ID из поля `TrafficSource.*ID` (UInt8 или UInt16,
             см. конкретный файл).
- `name_ru` — название для отображения в дашборде.

Комментарии (`#`) и пустые строки игнорируются загрузчиком.

## Файлы

| Файл                          | Поле Метрики                          | Тип ID  |
|-------------------------------|---------------------------------------|---------|
| `search_engine_roots.csv`     | `TrafficSource.SearchEngineRootID`    | UInt16  |
| `adv_engines.csv`             | `TrafficSource.AdvEngineID`           | UInt8   |
| `social_networks.csv`         | `TrafficSource.SocialSourceNetworkID` | UInt8   |
| `recommendation_systems.csv`  | `TrafficSource.RecommendationSystemID`| UInt8   |
| `messengers.csv`              | `TrafficSource.MessengerID`           | UInt8   |

## Как это попадает в ClickHouse

1. `scripts/prepare.sh` копирует `dicts/*.csv` в
   `functions/transform/dicts/` — они попадают в ZIP облачной функции.
2. `handler.py` при каждом запуске:
   - создаёт `dict_*` таблицы (если их ещё нет — через 01_schema.sql),
   - `TRUNCATE TABLE dict_*`,
   - построчно парсит CSV и `INSERT INTO dict_* VALUES (...)`.
3. `v_attribution_results` делает `LEFT JOIN` к этим таблицам и
   отдаёт колонку `source_name` с человекочитаемой подписью.

## Что делать, если ID отсутствует в словаре

`v_attribution_results` подставляет fallback вида
`"Поиск: код 1234"` — данные не теряются, просто имя остаётся числом.
Добавьте недостающую пару в CSV и дождитесь следующего запуска функции
(или запустите её вручную).

## Где брать правильные значения

Официальные справочники Яндекс Метрики:

- **Поисковые системы (roots)** —
  <https://yandex.ru/dev/metrika/ru/management/openapi/search_engines/listRootSearchEngines>
- **Рекламные системы** —
  <https://yandex.ru/dev/metrika/ru/management/openapi/adv_engines/listAdvEngines>
- **Соцсети** —
  <https://yandex.ru/dev/metrika/ru/management/openapi/socials/listSocials>
- **Рекомендательные системы** —
  <https://yandex.ru/dev/metrika/ru/management/openapi/recommendation_systems/listRecommendationSystems>
- **Мессенджеры** —
  <https://yandex.ru/dev/metrika/ru/management/openapi/messengers/listMessengers>

Можно выгрузить через API или переписать руками — значений всегда
немного (от 10 до 50 штук на словарь).
