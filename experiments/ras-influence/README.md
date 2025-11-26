Микробенчмарк для исследования влияния глубины стека вызовов на точность предсказания Return Address Stack (RAS) в процессорах AMD Zen 4. Конкретная модель процессора - Ryzen 7 7840HS.

Программа измеряет количество промахов предсказателя ветвлений и RAS при рекурсивных вызовах заданной глубины, используя аппаратные счётчики производительности через `perf_event_open`.

## Собираемые метрики

| Счётчик | Источник |
| :-----: | :------: |
| `BRANCH_INSTRUCTIONS` | общее количество инструкций ветвления |
| `BRANCH_MISSES` | промахи предсказателя ветвлений |
| `0xC9` | промахи RAS ([raw-событие AMD Zen 4](https://github.com/torvalds/linux/blob/v6.17-rc7/tools/perf/pmu-events/arch/x86/amdzen4/branch.json#L47-L51)) |

## Требования

- Linux (используется `perf_event_open`, `mlockall`, `ioctl`)
- Процессор AMD Zen 4 (для raw-события `0xC9`)
- [Zig](https://ziglang.org/) 0.15 (компилятор)
- [just](https://github.com/casey/just) 1.46 (сборщик задач)
- Права администратора для системных настроек ядра

## Сборка и запуск

```bash
# Собрать запускаемый файл и дизассемблировать его же.
just build

# Запустить бенчмарк: DEPTH_A и DEPTH_B — две глубины рекурсии для сравнения.
just bench 16 32

# С дополнительными параметрами: AMOUNT — количество вызовов, REPEAT — количество итераций.
just bench 16 32 10000 100

# Очистить артефакты сборки.
just clean
```

При запуске `just bench` автоматически:
1. Переключает CPU governor на `performance`
2. Отключает SMT (Simultaneous Multithreading)
3. Запускает бенчмарк с `chrt -f 99` и `taskset` на выделенном ядре
4. Восстанавливает исходные настройки

## Вывод

Результаты выводятся в формате CSV:

```
--- depth = 16 ---
try_number,total_branches,branch_misses,miss_rate,ras_misses
1,70039,12,0.02,0
2,70039,8,0.01,0
...

--- depth = 32 ---
try_number,total_branches,branch_misses,miss_rate,ras_misses
1,140039,42,0.03,2
2,140039,35,0.02,1
...

--- summary ---
depth=16         avg_branches=70039.00       avg_misses=10.00     avg_miss_rate=0.01%  avg_ras_misses=0.00
depth=32         avg_branches=140039.00      avg_misses=38.50     avg_miss_rate=0.03%  avg_ras_misses=1.50
RAS overflow detected between depth 16 and 32
```

## Параметры

| Параметр | Описание |
| :------: | :------: |
| `DEPTH_A` | Первая глубина рекурсивного вызова функции `task` |
| `DEPTH_B` | Вторая глубина рекурсивного вызова функции `task` |
| `AMOUNT` | Количество последовательных вызовов `task` за одну итерацию (по умолчанию `10000`) |
| `REPEAT` | Количество итераций измерения (по умолчанию `10`) |
| `CORE` | Номер ядра CPU для привязки (по умолчанию `2`, настраивается в `Justfile`) |
