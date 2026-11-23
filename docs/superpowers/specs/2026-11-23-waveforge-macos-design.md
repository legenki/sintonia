# Спецификация дизайна WaveForge (macOS 27)

**Дата:** 2026-11-23  
**Статус:** На ревью у пользователя  
**Базовая версия:** [Спецификация WaveForge iOS 27](file:///Users/andy/.gemini/antigravity/scratch/WaveForge/docs/superpowers/specs/2026-11-22-waveforge-ios-design.md)  
**Рабочее название проекта:** WaveForge  

---

## 1. Обзор и цель проекта

**WaveForge для macOS 27** — нативное настольное приложение для **Mac App Store**, построенное поверх общего DSP-ядра и каталога пресетов iPhone-версии (`WaveForgeCore`), воссоздающее все синтезаторные возможности классического **BrainWave Generator** (`bwgen.com`) в визуальном языке **macOS 27 (Liquid Glass)** с тактильными студийными контролами в традициях **GarageBand**.

### Ключевые задачи продукта
- **Гибридная настольная эргономика («компактный плеер + полноценные рабочие окна»):**
  - Компактное главное окно **Плеера**, которое удобно держать на рабочем столе во время работы или чтения.
  - Отдельные полноценные изменяемые окна macOS для **Библиотеки пресетов** и **Студии / Редактора кривых автоматизации** (с одновременной двухпанельной раскладкой стойки, инспектора и графика).
- **Нативная интеграция с macOS 27:**
  - Иконка и мини-пульт в системном **Menu Bar** (`MenuBarExtra`) для мгновенного `Play/Pause`, контроля текущего ритма в Гц, таймера, переключения пресетов и выбора аудиовыхода.
  - Системное меню macOS с горячими клавишами (`Space`, `⌘1`, `⌘L`, `⌘2`, `⌘E`, `⌘O`, `⌘N`, `⌘←`/`⌘→`, `⌘↑`/`⌘↓`).
  - **Drag-and-drop** файлов `.bwg` и `.waveforge` прямо в окна приложения и открытие двойным кликом из **Finder**.
  - **Выбор конкретного аудиоустройства вывода CoreAudio** прямо внутри приложения + авто-пауза бинауральных программ при отключении наушников.
- **100% оффлайн и готовность к Mac App Store:** локальный синтез в реальном времени без аккаунтов, сети, аналитики и рекламы; полная локализация **EN + RU**; App Sandbox entitlements; `PrivacyInfo.xcprivacy`; не-медицинский wellness-дисклеймер по App Store Guideline 1.4.1.
- **Обратная совместимость с iOS-версией:** существующий iOS-таргет `WaveForge` (`WaveForge` + `WaveForgeTests`) остаётся полностью работоспособным, компилируется под iOS 27.2 без предупреждений (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`) и без деградации iOS-поведения.

### Целевая платформа и ограничения
- **ОС и инструментарий:** **macOS 27.2+** (`Xcode 27.2`), **Swift 6** (`SWIFT_STRICT_CONCURRENCY = complete`), **SwiftUI** + **AVFoundation** + **CoreAudio HAL** + **MediaPlayer**, ноль сторонних зависимостей.
- **Локализация:** **English (`en`)** и **Русский (`ru`)** через общий `App/Resources/Localizable.xcstrings`.

### Явно вне скоупа v1 (macOS)
- Режим «Поверх всех окон» (**Floating / Always on Top**) для окна Плеера.
- Внешние `.wav`-сэмплы звуков природы и пользовательские аудиоподложки.
- Визуальная стробоскопическая стимуляция (AudioStrobe / вспышки экрана).
- Системное расширение **AUv3** / Audio Unit Plug-in (оставлено на v2 поверх `SynthCore`).
- Облачная синхронизация iCloud и пользовательские аккаунты.

---

## 2. Архитектура проекта и таргетов (`project.yml`)

Выбран **Вариант A — два независимых нативных таргета приложений в одном проекте** (`WaveForge` для iOS 27.2 и `WaveForgeMac` для macOS 27.2) с общим Swift-пакетом `WaveForgeCore`, общим аудио-контроллером, общими кроссплатформенными компонентами UI и общей локализацией.

### Матрица таргетов
| Таргет | Тип | Платформа | Bundle ID | Назначение |
|---|---|---|---|---|
| `WaveForge` | `application` | iOS `27.2` | `com.waveforge.app` | Существующее приложение iOS 27 |
| `WaveForgeTests` | `bundle.unit-test` | iOS `27.2` | `com.waveforge.tests` | iOS-тесты рантайма |
| `WaveForgeMac` | `application` | macOS `27.2` | `com.waveforge.mac` | Нативное macOS 27 приложение |
| `WaveForgeMacTests` | `bundle.unit-test` | macOS `27.2` | `com.waveforge.mac.tests` | Нативные тесты macOS-рантайма (выполняются прямо на хосте macOS) |

### Структура каталогов
```text
WaveForge/
├── project.yml                                  # XcodeGen: WaveForge (iOS) + WaveForgeMac (macOS)
├── Packages/WaveForgeCore/                      # Платформонезависимое ядро (iOS 18+ / macOS 15+)
│   ├── Sources/
│   │   ├── SynthCore/                           # Lock-free real-time DSP-движок
│   │   ├── PresetKit/                           # Модели, 18 пресетов, BWGImporter, PresetStore
│   │   └── WaveForgeExport/                     # SessionExporter (WAV/M4A) + AudioRoutePolicy (+ CoreAudio полиси)
│   └── Tests/                                   # SynthCoreTests, PresetKitTests, WaveForgeExportTests
└── App/
    ├── Info.plist                               # iOS Info.plist (управляется project.yml)
    ├── iOS/
    │   └── WaveForgeIOSApp.swift                # @main + WaveForgeRootView только для iOS
    ├── Mac/
    │   ├── Info.plist                           # macOS Info.plist (Finder UTType, категория Music)
    │   ├── WaveForgeMac.entitlements            # App Sandbox + user-selected files read-write
    │   └── WaveForgeMacApp.swift                # @main + сцены Window("player"/"library"/"studio") + MenuBarExtra + Commands
    ├── Sources/
    │   ├── AudioRuntime/                        # Общий аудио-рантайм
    │   │   ├── AudioEngineController.swift      # Условная интеграция AVAudioSession (iOS) / MacAudioDeviceManager (macOS)
    │   │   └── MacAudioDeviceManager.swift      # CoreAudio HAL менеджер (#if os(macOS))
    │   ├── StudioUI/                            # Общие кроссплатформенные компоненты, экраны и хелперы
    │   │   ├── PlatformViewModifiers.swift      # Изоляция iOS-only модификаторов и платформенного haptics
    │   │   ├── Components/                      # StudioTheme, StudioKnob, StudioFader, LEDMeterView, OscilloscopeView, HardwarePickers
    │   │   ├── Player/                          # PlayerView, MiniTimelineScrubber, ExportSheetView, AboutSheetView
    │   │   ├── Studio/                          # StudioRackView (с dual-pane macOS раскладкой), Voice/Noise инспекторы, CurveEditor
    │   │   └── Library/                         # LibraryView, PresetSparklineView, ImportResultAlert
    │   └── MacUI/                               # Эксклюзивный desktop-UI только для WaveForgeMac
    │       ├── MacAppCoordinator.swift          # Общее состояние окон, импорта, алертов и несохранённого черновика Студии
    │       ├── MacPlayerWindowView.swift        # Компактное окно Плеера + выбор аудиовыхода + drop `.bwg`/`.waveforge`
    │       ├── MacLibraryWindowView.swift       # Полноценное окно Библиотеки + двойной клик + drop + экспорт
    │       ├── MacStudioWindowView.swift        # Полноценное окно Студии/Редактора кривых + защита черновика
    │       ├── MacMenuBarView.swift             # Окно MenuBarExtra + иконка/Hz в строке меню
    │       ├── MacOutputDeviceMenu.swift        # Переиспользуемый контрол выбора аудиовыхода CoreAudio
    │       └── MacCommands.swift                # Системное меню macOS и шорткаты
    ├── Resources/
    │   ├── Localizable.xcstrings                # Единая локализация EN + RU (общая для iOS и macOS)
    │   ├── PrivacyInfo.xcprivacy                # Общий privacy manifest (NSPrivacyAccessedAPICategoryDiskSpace 85F4.1)
    │   └── Assets.xcassets                      # Общие ассеты и иконка приложения (macOS + iOS слоты)
    └── Tests/
        ├── AudioRuntimeTests/                   # Тесты iOS-таргета
        └── MacRuntimeTests/                     # Нативные тесты WaveForgeMacTests (CoreAudio, координатор, импорт, локализация)
```

---

## 3. Mac App Store, App Sandbox, ассоциации Finder и приватность

### App Sandbox и права (`App/Mac/WaveForgeMac.entitlements`)
- `com.apple.security.app-sandbox = true` — обязательное требование Mac App Store.
- `com.apple.security.files.user-selected.read-write = true` — доступ к пользовательским файлам через стандартный диалог открытия (`.fileImporter` / `NSOpenPanel`), сохранения (`.fileExporter` / `NSSavePanel`), drag-and-drop и открытие файлов из Finder; доступ к аудиовыводу предоставляется системой без сетевых и микрофонных разрешений (`audio-input` не запрашивается, так как синтезатор только воспроизводит звук).

### Манифест приложения (`App/Mac/Info.plist` через `project.yml`)
Все ключи задаются в `targets.WaveForgeMac.info.properties` в `project.yml`, чтобы `xcodegen generate` оставался полностью идемпотентным:
- `CFBundleDisplayName`: `WaveForge`
- `CFBundleShortVersionString`: `$(MARKETING_VERSION)` (`1.0.0`)
- `CFBundleVersion`: `$(CURRENT_PROJECT_VERSION)` (`1`)
- `LSApplicationCategoryType`: `public.app-category.music`
- `LSMinimumSystemVersion`: `$(MACOSX_DEPLOYMENT_TARGET)` (`27.2`)
- `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` (`com.waveforge.preset` / `.waveforge`), `UTImportedTypeDeclarations` (`com.noromaa.bwg` / `.bwg` c соответствием `public.data`, `public.content`) — двойной клик по файлу `.bwg` или `.waveforge` в **Finder** и перетаскивание на иконку в **Dock** открывают файл в WaveForge.

### Контейнер хранения и приватность
- Пользовательские пресеты хранятся в песочнице по стандартному пути `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first/WaveForge/Presets` через существующий `PresetStore`.
- Общий `App/Resources/PrivacyInfo.xcprivacy` (`NSPrivacyTracking = false`, `NSPrivacyAccessedAPICategoryDiskSpace` с причиной `85F4.1`) автоматически копируется в `WaveForgeMac.app/Contents/Resources/PrivacyInfo.xcprivacy`.
- Экран **«О WaveForge»** (`AboutSheetView`) с дисклеймером App Store Guideline 1.4.1 (non-medical wellness tool) доступен через стандартный пункт главного меню **`WaveForge → О WaveForge`** и кнопку информации в окне Плеера.

---

## 4. Аудио-рантайм macOS: CoreAudio HAL, выбор устройства и авто-пауза

На macOS отсутствует `AVAudioSession`, поэтому маршрутизацией и мониторингом аудиооборудования управляет кроссплатформенный слой внутри `WaveForgeExport` + `AudioRuntime`.

### Чистая политика маршрутов в `WaveForgeExport/AudioRoutePolicy.swift`
Чтобы логика выбора устройства и авто-паузы покрывалась быстрыми юнит-тестами через `swift test`, добавляются чистые типы и функции без импорта CoreAudio:
- `public enum CoreAudioTransportKind: UInt32, Sendable, Equatable` — транспортные типы (`builtIn`, `bluetooth`, `bluetoothLE`, `usb`, `airPlay`, `displayPort`, `hdmi`, `virtual`, `aggregate`, `other`) с маппингом на `AudioOutputRoute` (`.headphones`, `.speaker`, `.other`) с учётом флага подключения проводного джека (`hasWiredHeadphonesConnected`) и эвристик для встроенного выхода.
- `public enum AudioDeviceSelectionPolicy` — детерминированный выбор активного устройства по `selectedDeviceUID`:
  - `nil` → системный выход по умолчанию;
  - сохранённый `UID`, найденный в списке подключённых устройств → это устройство;
  - сохранённый `UID`, отсутствующий среди текущих устройств → откат на системный выход + флаг `didLoseSelectedDevice`;
  - единая проверка `shouldAutoPauseOnMacRouteTransition(previousRoute:newRoute:selectedDeviceWasRemoved:isPlaying:presetHasActiveBinaural:)`: авто-пауза срабатывает тогда и только тогда, когда воспроизводилась бинауральная программа, активный маршрут был `.headphones` (либо выбранный UID наушников отключился), и новое состояние перешло в `.speaker` / `.other` или пропало выбранное устройство наушников.

### Менеджер устройств `App/Sources/AudioRuntime/MacAudioDeviceManager.swift` (`#if os(macOS)`)
- **Модель `AudioOutputDevice: Identifiable, Hashable, Sendable`:**
  - `deviceID: AudioDeviceID` (`UInt32`)
  - `uid: String`
  - `name: String`
  - `route: AudioOutputRoute`
  - `isSystemDefault: Bool`
- **Перечисление устройств:** через `CoreAudio` (`AudioObjectGetPropertyData`) читает `kAudioHardwarePropertyDevices`, фильтрует устройства с выходными потоками (`kAudioDevicePropertyStreamConfiguration` в `kAudioDevicePropertyScopeOutput` с `mNumberChannels > 0`), извлекает `kAudioDevicePropertyDeviceUID`, `kAudioObjectPropertyName`, `kAudioDevicePropertyTransportType`, а для встроенных устройств дополнительно проверяет `kAudioDevicePropertyDataSource` (`'hdpn'` / `'ispk'`) и `kAudioDevicePropertyJackIsConnected` для определения проводных наушников vs встроенных динамиков.
- **Привязка к `AVAudioEngine`:**
  - Для `selectedDeviceUID == nil` либо явного выбора устройства вызывает `AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)` на `engine.outputNode.audioUnit`.
  - Сохраняет выбор пользователя в `UserDefaults` под ключом `waveforge.mac.selectedOutputDeviceUID`.
  - При смене устройства во время воспроизведения мягко обновляет выходной `AudioDeviceID` (с кратким переподключением графа / перезапуском `engine` при смене аппаратной конфигурации) и немедленно пересчитывает `outputRoute`.
- **Слушатели реального времени (`AudioObjectAddPropertyListenerBlock`):**
  - Подписывается на `kAudioHardwarePropertyDevices` и `kAudioHardwarePropertyDefaultOutputDevice` (на `kAudioObjectSystemObject`), а также на `kAudioDevicePropertyDataSource` / `kAudioDevicePropertyJackIsConnected` на активном встроенном устройстве.
  - Все callback'и безопасно переводятся на `@MainActor`, вызывая обновление `availableOutputDevices`, `outputRoute` и проверку `AudioDeviceSelectionPolicy`.

### Интеграция с `AudioEngineController.swift`
- Методы `configureAudioSessionCategory()`, `refreshOutputRoute()`, `registerNotifications()` разделяются чистыми `#if os(iOS)` / `#if os(macOS)` ветками:
  - На **iOS** сохраняется текущий код без изменений (`AVAudioSession.didBecomeInactiveNotification`, `resumptionRecommendationNotification`, `routeChangeNotification`).
  - На **macOS** подключается `MacAudioDeviceManager`: публичные свойства/методы `availableOutputDevices`, `selectedOutputDeviceUID`, `selectOutputDevice(uid:)` (с вариантом `nil` = «Системный выход»).
- Обработка `.AVAudioEngineConfigurationChange` остаётся общей: при переключении устройств (например, `44.1 kHz Bluetooth` ↔ `48 kHz USB DAC`) `AVAudioSourceNode` продолжает генерировать детерминированные `48 kHz Float32 Stereo` в `mainMixerNode`, а контроллер перезапускает граф при необходимости.
- **Медиа-клавиши и Control Center macOS:** на обеих платформах сохраняется интеграция `MPNowPlayingInfoCenter` и `MPRemoteCommandCenter`; на macOS в `updateNowPlayingInfo` дополнительно синхронизируется `MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused` для корректного отображения в системном Now Playing виджете.

---

## 5. Гибридная оконная архитектура, Menu Bar, меню и Drag-and-Drop

### Единый координатор `MacAppCoordinator` (`App/Sources/MacUI/MacAppCoordinator.swift`)
`@MainActor @Observable final class MacAppCoordinator`:
- Владеет единственным экземпляром `PresetStore` (`Application Support/WaveForge/Presets`) и `AudioEngineController` (стартует с `Deep Focus`).
- Управляет общим состоянием между всеми окнами и `MenuBarExtra`:
  - `presetsRevision: Int` — триггер обновления списка пресетов во всех окнах и меню-баре.
  - `activePlayerSheet: PlayerModalSheet?` (`.export` | `.about`) — листы на окне Плеера.
  - `importAlert: ImportAlertContent?`, `importToastPresetName: String?` — результат системного/перетащенного импорта `.bwg` / `.waveforge`.
  - **Защита черновика Студии:** `studioHasUnsavedChanges: Bool`, `studioLoadTrigger: UUID` (или передача запроса смены пресета `pendingPresetSelection: PendingPresetAction?` с диалогом *«Сохранить / Сбросить / Остаться»*, когда пользователь меняет пресет из Библиотеки/Меню/Finder при несохранённых правках в открытой Студии).
  - **Единый вход импорта `handleIncomingURLs(_ urls: [URL])`:** использует существующий `PresetImportCoordinator.importFile(at:into:)` (с балансированным `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()`), поддерживает `.bwg` и `.waveforge`, сохраняет в `PresetStore`, загружает пресет в `engine`, обновляет `presetsRevision` и показывает `ImportResultAlert` или `ImportConfirmationToast`.

### Именованные окна (`Window(id:)` синглтоны в `WaveForgeMacApp.swift`)
1. **Главное окно — Плеер (`Window(Text("WaveForge"), id: "player")`):**
   - Размер по умолчанию: `430 × 700 pt`, минимальный: `380 × 620 pt`, максимальная ширина: `540 pt` (компактная вертикальная форма, не мешает другим окнам на экране).
   - Использует существующий `PlayerView` с адаптированной шапкой: компактный **селектор аудиоустройства** (`MacOutputDeviceMenu`) рядом со статусом наушников, а кнопки «Библиотека» и «Студия» вызывают `openWindow(id: "library")` / `openWindow(id: "studio")`.
   - Экспорт и «О WaveForge» открываются как нативные macOS-sheets прямо на окне Плеера.
   - На окне Плеера включён `.onDrop(of: [.fileURL], isTargeted: ...)` с аккуратной подсветкой Liquid Glass при наведении `.bwg` / `.waveforge` файлов.
   - Настроена `.handlesExternalEvents(matching: ["*"])` и `.onOpenURL`, чтобы открытие файлов из Finder / клик по иконке в Dock не плодили дубликаты окон Плеера.

2. **Окно Библиотеки (`Window(Text("Library"), id: "library")`):**
   - Размер по умолчанию: `780 × 640 pt`, минимальный: `560 × 460 pt`.
   - Адаптивная 2-колоночная сетка карточек на широком окне (переходит в 1 колонку при ширине `< 640 pt`), поле поиска в тулбаре macOS, горизонтальные чипы категорий и кнопка импорта / `+ Новый пресет`.
   - **Действия карточки:** одинарный клик — загрузка пресета в Плеер; двойной клик — загрузка и немедленный запуск воспроизведения; контекстное меню и кнопка опций — **Дублировать**, **Сохранить `.waveforge`…** (нативный `.fileExporter` с предзаполненным именем + `ShareLink`), **Удалить** (только пользовательские).
   - Поддерживает перетаскивание файлов `.bwg` / `.waveforge` прямо в окно Библиотеки (`.onDrop`).

3. **Окно Студии и Редактора кривых (`Window(Text("Studio Rack"), id: "studio")`):**
   - Размер по умолчанию: `1160 × 740 pt`, минимальный: `860 × 600 pt`.
   - **Адаптивная DAW-раскладка в `StudioRackView`:**
     - На настольных окнах шириной `>= 880 pt` (используя `GeometryReader` / `@Environment(\.horizontalSizeClass)` + явный режим `prefersDesktopSplitLayout`) отображается **двухпанельная рабочая область**: сверху панель пресета и 10-голосная стойка микшера; снизу слева панель инспектора **Voice / Noise** (фиксированная ширина `~340–360 pt`), а справа постоянно открытый широкий **Редактор кривых** (`CurveEditorView`).
     - При сужении окна `< 880 pt` мягко переключается на компактную вкладочную раскладку, а на iOS поведение (`portrait` вкладки + `landscape` полноэкранный редактор) остаётся прежним 1-в-1.
   - Полноценный `CurveEditorCanvas` с точным позиционированием мышью/трекпадом, зумом жестом или кнопками `−`/`+`/`1×` и удалением контрольной точки через контекстное меню по правому клику (в дополнение к долгому нажатию).

### Системный Menu Bar (`MenuBarExtra` с `.menuBarExtraStyle(.window)`)
- **Label в строке меню:** векторная иконка волны `waveform.path.ecg`; во время воспроизведения (`engine.isPlaying`) рядом отображается текущая доминантная частота ритма в табличном шрифте (например, `10.0 Hz`).
- **Всплывающая панель (`~310 pt` шириной):**
  - Название активного пресета, цветной бейдж диапазона мозговых волн + частота биений, таймер `currentTime / duration`.
  - Крупная кнопка **Play / Pause** и кнопки перемотки `-30s` / `+30s`.
  - Быстрый слайдер мастер-громкости (`Master`).
  - Меню быстрого выбора пресета (сначала недавние / популярные или разбивка по категориям).
  - Компактное меню переключения аудиоустройства вывода CoreAudio.
  - Кнопки **Открыть Плеер**, **Библиотека**, **Студия** (вызывают `NSApp.activate(ignoringOtherApps: true)` и `openWindow(id:)`) и **Завершить WaveForge**.

### Системное меню macOS (`Commands`) и шорткаты
- **App menu (`WaveForge`):** `О WaveForge` → открывает Плеер (при необходимости) и лист `AboutSheetView`.
- **Файл (`File`):**
  - `⌘N` **Новый пресет** — создаёт шаблон и открывает окно Студии;
  - `⌘O` **Импортировать пресет…** — открывает системный `NSOpenPanel` / `.fileImporter` для `.bwg` и `.waveforge`;
  - `⌘E` **Экспортировать аудио…** — открывает `ExportSheetView` на окне Плеера.
- **Воспроизведение (`Playback`):**
  - `Space` **Воспроизведение / Пауза** *(безопасно через `@FocusedValue(\.isTextInputFocused)` отключается / не перехватывается, когда фокус находится в поиске или редактировании имени/комментария пресета)*;
  - `⌘←` / `⌘→` **Назад / Вперёд 30 с**;
  - `⌘↑` / `⌘↓` **Громкость Master +5% / -5%**;
  - Подменю **Устройство вывода** (`Системный выход` + список всех `availableOutputDevices` с галочкой у активного).
- **Окно (`Window`):**
  - `⌘1` **Плеер**;
  - `⌘L` **Библиотека пресетов**;
  - `⌘2` **Студия и редактор кривых**.

---

## 6. Кроссплатформенный `StudioUI`, локализация EN + RU и краевые случаи

### Отделение от `UIKit` и платформенные модификаторы (`PlatformViewModifiers.swift`)
1. **`StudioControlHaptics` (`StudioTheme.swift`):**
   - `#if os(iOS)`: сохраняет `UIImpactFeedbackGenerator` 1-в-1.
   - `#if os(macOS)`: использует `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` / `.levelChange` для тактильного отклика на трекпадах Force Touch без единого `import UIKit`.
2. **Устранение прямых `import UIKit` в общих файлах:**
   - В `PlayerView.swift`, `MiniTimelineScrubber.swift`, `OscilloscopeView.swift`, `HardwarePickers.swift`, `StudioRackView.swift` локальные `UIImpactFeedbackGenerator` заменяются на `StudioControlHaptics` (или `PlatformHaptics`).
3. **Изоляция iOS-only модификаторов SwiftUI (`PlatformViewModifiers.swift`):**
   - `.wfInlineNavigationBarDark()`, `.wfAlwaysVisibleSearchBar()` — на iOS применяют `.navigationBarTitleDisplayMode(.inline)`, `.toolbarColorScheme(.dark, for: .navigationBar)` и `.navigationBarDrawer(displayMode: .always)`, на macOS являются чистым no-op / нативным тулбаром. Логика `@Environment(\.verticalSizeClass)` и `.fullScreenCover` в `StudioRackView` / `CurveEditorView` / `WaveForgeIOSApp` аккуратно разделена платформенными директивами.
4. **Эргономика мыши и трекпада:**
   - В `StudioKnob` и `StudioFader` добавляется hover-подсветка и поддержка клавиш-модификаторов (`Option` / `Shift`) для точной подстройки `0.2×` наряду с удержанием, а также двойной клик для сброса к значению по умолчанию.
   - В `ExportSheetView` на macOS рядом с `ShareLink` добавляется кнопка **«Сохранить как…»** (`.fileExporter` с подготовленным `ExportAudioFileDocument` для `.wav` и `.m4a`).
   - В `LibraryView` для каждого пресета на macOS доступен прямой экспорт `.waveforge` через `.fileExporter` («Сохранить `.waveforge`…») в дополнение к `ShareLink`.

### Краевые случаи и локализация
- **Горячее отключение наушников / смена устройства:** если активное выбранное устройство исчезло во время бинаурального воспроизведения, воспроизведение ставится на паузу, показывается баннер «Наушники отключены», а выбор мягко сбрасывается на системный выход с синхронизацией `AudioEngineController.outputRoute`.
- **Импорт и удаление из нескольких окон:** так как `LibraryView`, `StudioRackView`, `PlayerView` и `MenuBarExtra` читают единые `engine` и `presetsRevision` координатора `MacAppCoordinator`, любое сохранение, импорт или удаление мгновенно отражается во всех открытых окнах.
- **Полная локализация EN + RU (`App/Resources/Localizable.xcstrings`):** добавляются все новые строки macOS (пункты меню, заголовки окон, Menu Bar, «Системный выход (по умолчанию)», «Устройство вывода», «Сохранить как…», подсказка drag-and-drop, диалог защиты несохранённого черновика при переключении пресета) с сохранением всех существующих iOS-переводов.

---

## 7. Стратегия тестирования и верификации

1. **Модульные тесты ядра `WaveForgeCore` (`swift test --disable-sandbox`):**
   - Сохранение всех 47 существующих тестов (`SynthCoreTests`, `PresetKitTests`, `WaveForgeExportTests`).
   - Новые тесты в `WaveForgeExportTests`: классификация `CoreAudioTransportKind` (проводные наушники со встроенным джеком vs динамики, Bluetooth A2DP/LE, USB-ЦАП, AirPlay, DisplayPort), резолвер `AudioDeviceSelectionPolicy` (сохранённый UID, fallback при отключении) и `shouldAutoPauseOnMacRouteTransition`.
2. **Нативные тесты macOS-приложения `WaveForgeMacTests` (`xcodebuild test` на macOS 27.2):**
   - В отличие от iOS Simulator (заблокированного `CoreSimulatorService` в песочнице), таргет `WaveForgeMacTests` исполняется **нативно на хосте macOS**:
     - жизненный цикл `AudioEngineController` на macOS и синхронизация `NowPlaying` / `LiveOverrides`;
     - работа `MacAudioDeviceManager` (перечисление выходных устройств без сбоев даже при пустом/виртуальном окружении, сохранение/откат UID);
     - `MacAppCoordinator`: импорт `.bwg` и `.waveforge` (включая `ImportReport` и отклонённые некорректные файлы), обновление `presetsRevision`, защита несохранённого черновика Студии;
     - проверка наличия ключей EN и RU для новых macOS-строк.
3. **Двойная строгая компиляция (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`):**
   - Сборка `WaveForgeMac` и прогон `WaveForgeMacTests` под `macosx27.2` (с проверкой `PrivacyInfo.xcprivacy` и `WaveForgeMac.entitlements` в бандле `.app`).
   - Контрольная сборка `WaveForge` + `WaveForgeTests` под `iphonesimulator27.2` для подтверждения отсутствия регрессий в iPhone-версии.
