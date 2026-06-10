# План: устранение конфликтов идентичности между форками reLayout

> Для агента, работающего на ветке `claude/secrets-fork-conflicts-jztq81`.
> Цель: убрать захардкоженную инфраструктуру владельца (`vladforfutdinov`) так, чтобы любой форк собирался/релизился под своей идентичностью без правки исходников. Секреты (credentials) уже изолированы по форкам — их не трогаем.

## Контекст и принцип

- **Секреты не трогаем.** `DEVELOPER_ID_CERT_*`, `AC_API_*`, `TAP_DEPLOY_KEY`, `SPARKLE_ED_PRIVATE_KEY` уже в GitHub Actions Secrets, в репо их нет, конфликтов не создают.
- **Конфликты дают публичные, но привязанные к владельцу значения** (bundle id, домен, feed URL, owner/repo, tap, git-автор). Их нужно **параметризовать**, а не прятать в secrets.
- **Образец уже есть:** `.github/workflows/build.yml:134,138` использует `${GITHUB_REPOSITORY}` — приводим остальное к тому же стилю.
- Значения по умолчанию должны давать текущее поведение апстрима, чтобы существующий релиз `vladforfutdinov` не сломался.

## Источник истины для конфигурации

Ввести единый набор параметров:

| Переменная | Назначение | Default (апстрим) |
|---|---|---|
| `RELAYOUT_BUNDLE_ID` | base bundle id (dev добавляет `.dev`) | `com.vladforfutdinov.relayout` |
| `RELAYOUT_DISPLAY_NAME` | имя приложения | `reLayout` |
| `RELAYOUT_REPO_SLUG` | `owner/repo` для ссылок/URL | `vladforfutdinov/reLayout` |
| `RELAYOUT_FEED_URL` | Sparkle `SUFeedURL` | `https://relayout.forfutdinov.com/appcast.xml` |
| `RELAYOUT_SU_PUBLIC_KEY` | Sparkle `SUPublicEDKey` (парный к secret) | `5nsZXP2I7Da5DGBzVPpGrqAkYSXxFZcHMllmtiO7ymY=` |
| `RELAYOUT_TAP_REPO` | Homebrew tap `owner/name` | `vladforfutdinov/homebrew-relayout` |

- В CI задавать через **repository variables** (`vars.*`) с fallback на default.
- Локально — env-переменные, читаемые `scripts/build.sh`.

## Шаги

### 1. `scripts/build.sh` — сделать источником параметров
- Файл: `scripts/build.sh:31,33`.
- Заменить хардкод `BUNDLE_ID`/`DISPLAY_NAME` на чтение `RELAYOUT_BUNDLE_ID`/`RELAYOUT_DISPLAY_NAME` с текущими значениями как default. `.dev`-суффикс сохранить для dev-сборки.
- Здесь же экспортировать `RELAYOUT_FEED_URL`, `RELAYOUT_SU_PUBLIC_KEY`, `RELAYOUT_REPO_SLUG` для шага патча Info.plist.

### 2. `macos/Info.plist` — патчить при сборке, не хранить inline
- Файл: `macos/Info.plist:10` (`CFBundleIdentifier`), `:49` (`SUFeedURL`), `:51` (`SUPublicEDKey`).
- Вариант: оставить в plist значения-плейсхолдеры и подставлять реальные в `build.sh` (через `PlistBuddy`/`sed`) из переменных шага 1. Bundle id уже выставляется сборкой — убедиться, что `SUFeedURL`/`SUPublicEDKey` тоже идут из переменных, а не из закоммиченных строк.
- **Важно:** `SUPublicEDKey` и `SPARKLE_ED_PRIVATE_KEY` — пара. Документировать, что меняются вместе.

### 3. `macos/main.swift` — ссылки на репозиторий
- Файлы: `macos/main.swift:1098`, `macos/main.swift:1188`.
- Захардкожен `vladforfutdinov/reLayout`. Вынести в одну константу (напр. `repoSlug`/`aboutURL`), значение которой подставляется при сборке из `RELAYOUT_REPO_SLUG` (через генерируемый Swift-сниппет или `-D`/Info.plist-ключ). Минимально — единая константа в одном месте.

### 4. Windows-порт — ссылки на репозиторий
- Файлы: `windows/WinTray.swift:14` (`aboutURL`), `windows/WinSettings.swift:88` (SysLink).
- Свести к одной константе, согласованной с `RELAYOUT_REPO_SLUG`.

### 5. Homebrew cask
- Файл: `packaging/homebrew/relayout.rb.tmpl:5,6,9,17`.
- `url`/`verified`/`homepage` параметризовать от `RELAYOUT_REPO_SLUG`; `plist`-путь (`:17`) — от `RELAYOUT_BUNDLE_ID`.
- Файл: `packaging/homebrew/update-cask.sh:16` — `TAP_REPO` уже читается из env (`${TAP_REPO:-vladforfutdinov/homebrew-relayout}`); подавать `RELAYOUT_TAP_REPO` из CI.

### 6. CI workflow
- Файл: `.github/workflows/build.yml:145-146`.
- Git-автор аппкаста захардкожен (`Volodymyr Forfutdinov` / noreply). Заменить на `github-actions[bot]` (`41898282+github-actions[bot]@users.noreply.github.com`) или на `${{ github.actor }}`.
- Прокинуть `vars.*` в шаги сборки (bundle id, feed url, su public key, repo slug, tap repo) с fallback на default-значения апстрима.
- Проверить, что download-URL/gh-pages-логика (`:134,138`) остаётся на `${GITHUB_REPOSITORY}` — она уже корректна.

### 7. Документация
- `docs/RELEASING.md` — добавить раздел «Настройка форка»: какие repo variables задать, что `SUPublicEDKey` меняется в паре с `SPARKLE_ED_PRIVATE_KEY`, как указать свой tap/домен.
- `docs/ARCHITECTURE.md:6-11` — дополнить список build env vars новыми переменными.
- `README.md:3,30,33` — пометить домен/`brew install`/release-ссылку как значения апстрима (либо оставить, явно отметив, что в форке заменяются).

## Чего НЕ делать
- Не переносить публичные значения (bundle id, домен, repo slug, public key) в GitHub Secrets — они не приватные; место им в repo variables/env.
- Не менять и не ротировать существующие секреты.
- Не ломать default-поведение апстрима: при незаданных переменных всё должно собираться как сейчас.

## Проверка
- `./scripts/build.sh` без переменных → bundle id и Info.plist идентичны текущим (diff пустой по смыслу).
- Сборка с `RELAYOUT_BUNDLE_ID=com.example.test RELAYOUT_REPO_SLUG=example/fork ...` → итоговый `Info.plist`, About-ссылки и каска ссылаются на `example`, без следов `vladforfutdinov`.
- `swift test` / `./scripts/run-tests.sh` — зелёные.
- `grep -rn "vladforfutdinov\|forfutdinov\.com"` по `macos/`, `windows/`, `packaging/`, `scripts/`, `.github/` → остаются только default-значения в одном-двух местах (build.sh/workflow defaults), не разбросаны по коду.

## Коммит/пуш
- Ветка: `claude/secrets-fork-conflicts-jztq81` (создать локально, если нет).
- Коммит с понятным сообщением (напр. «Parameterize fork-specific identity (bundle id, repo, Sparkle feed, tap)»).
- `git push -u origin claude/secrets-fork-conflicts-jztq81`. **PR не создавать**, пока пользователь явно не попросит.
