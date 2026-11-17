# Cluster Fault Tolerance Tests (BATS)

BATS-тесты отказоустойчивости n-нодового кластера (Cluster Service / gRPC API).

## Структура

```
.
├── fault_tolerance/
│   └── tests/
│       ├── *.bats           # тесты (hc, combo, net, netdeg, proc, pwr, raft, stor, stordeg, time)
│       └── load_helper.bash # общий setup/teardown + загрузка helpers
└── functional_tests/
    ├── .env.example         # шаблон переменных окружения
    ├── setup_file.bash      # подгружается bats перед прогоном
    ├── helpers/             # bash-хелперы (grpc, logging, cluster_reset, fault_helpers, ...)
    └── tests/lib/           # bats-support + bats-assert (vendored)
```

Относительные пути между `fault_tolerance/tests/` и `functional_tests/` должны сохраняться — `load_helper.bash` вычисляет `_root_dir = ../../functional_tests`.

## Зависимости (на машине запуска)

- `bats` (bats-core) — бинарь
- `grpcurl`
- `jq`, `ssh`, `scp`
- доступ к 3 нодам кластера по SSH
- заполненный `functional_tests/.env` (скопировать из `.env.example`)

## Запуск

```bash
cp functional_tests/.env.example functional_tests/.env
# заполнить .env реальными значениями (IP нод, credentials, пути к grpcurl)

cd fault_tolerance/tests
bats *.bats
```

## Внимание

Тесты **деструктивные**: сбрасывают кластер, изолируют узлы, блокируют storage.

## Что тестируется

- **HC** — падение процесса cluster-service
- **NET / NETDEG** — сетевая изоляция узлов, деградация сети
- **PROC** — убийство процессов
- **PWR** — отключение питания узлов через power-switch
- **RAFT** — изоляция raft-узлов, потеря кворума
- **STOR / STORDEG** — блокировка/деградация storage, фенсинг, восстановление
- **TIME** — сдвиг времени (NTP), grace period
- **COMBO** — комбинированные сценарии (raft + storage одновременно)
