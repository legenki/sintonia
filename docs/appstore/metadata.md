# App Store Connect metadata

Copy these fields into App Store Connect. Character limits are checked by `docs/appstore/check_metadata.py`.

| Field | Value |
|---|---|
| Bundle ID (iOS / iPadOS) | `com.sintonia.app` |
| Bundle ID (macOS) | `com.sintonia.mac` |
| SKU | `sintonia-ios`, `sintonia-mac` |
| Version / build | 1.0.0 (1) |
| Primary category | Health & Fitness |
| Secondary category | Music |
| Privacy Policy URL | https://github.com/legenki/sintonia/blob/main/PRIVACY.md |
| Support URL | https://github.com/legenki/sintonia/issues |
| Marketing URL (optional) | https://github.com/legenki/sintonia |
| Copyright | 2026 _your legal name or company_ |

## App Privacy (nutrition label)

Answer **"No, we do not collect data from this app."** Result: **Data Not Collected.**
No tracking, no third-party SDKs, no network access.

## Age rating questionnaire

Answer **None / No** to every content question: violence, sexual content, profanity, drugs, gambling, horror, medical information, user-generated content, unrestricted web access, messaging, contests.
Expected rating: **4+**.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set in both Info.plists, so App Store Connect will not ask for each build.

---

## English (U.S.) — primary

**Name** (30)
```
Sintonia
```

**Subtitle** (30)
```
Binaural & Isochronic Studio
```

**Promotional text** (170)
```
Shape your own sessions: up to 10 binaural, monaural or isochronic voices plus colored noise, automated over time with curves. Import classic BrainWave Generator presets.
```

**Keywords** (100, comma-separated, no spaces)
```
binaural,beats,isochronic,brainwave,tones,focus,meditation,sleep,noise,theta,alpha,relax,study,bwg
```

**Description** (4000)
```
Sintonia is a brainwave entrainment studio for iPhone, iPad and Mac. It generates binaural, monaural and isochronic tones with stereo colored noise in real time, and lets you design how every parameter evolves across a session.

PLAY
• 18 built-in sessions for Focus, Relax, Sleep, Meditation, Study and Creative work, 30 to 45 minutes long.
• A live stereo oscilloscope shows exactly what you hear, along with the current brainwave band (delta, theta, alpha, beta, gamma) and beat frequency.
• Smart controls for master, tones, noise and noise color. Skip ±30 seconds.
• Lock Screen, Control Center and background playback.
• Headphone-aware: binaural sessions recommend headphones and pause when you unplug them.

CREATE
• Up to 10 voices per preset. Each one is binaural, monaural or isochronic, with sine, sine², triangle, square or smooth-square waveforms.
• Stereo noise from white through pink to brown, with optional pulsing synced to a voice's beat.
• A curve editor for beat, carrier and volume automation, with smooth or linear interpolation, snapping, zoom and brainwave band guides.
• Voice tracking: lock one voice to another voice's carrier or beat by a ratio, for example a pure fifth.
• Hear every edit instantly. Built-in presets stay untouched, and edits are saved as your own copies.

SHARE AND EXPORT
• Import classic BrainWave Generator (.bwg) files, with a clear report of anything that was adjusted.
• Share presets as .sintonia files.
• Export any session to WAV (48 kHz, 24-bit) or M4A (AAC 256 kbps) for listening anywhere.

ON MAC
• Separate Player, Library and Studio windows, plus a menu bar player.
• Choose any output device, drag and drop files to import, and use full keyboard shortcuts.

PRIVATE BY DESIGN
No account, no ads, no tracking, no network access. Everything stays on your device.

A NOTE ON USE
Sintonia is an audio tool for relaxation, focus and experimentation. It is not a medical device and does not diagnose, treat or cure any condition. If you have epilepsy or a history of seizures, talk to a doctor before using rhythmic audio. Do not use it while driving or operating machinery.
```

**What's New** (version 1.0.0)
```
First release of Sintonia.
```

---

## Russian — localization

**Название** (30)
```
Sintonia
```

**Подзаголовок** (30)
```
Бинауральные ритмы и шумы
```

**Рекламный текст** (170)
```
Создавайте свои сессии: до 10 бинауральных, монауральных или изохронных голосов и цветной шум, автоматизация кривыми. Импорт пресетов BrainWave Generator.
```

**Ключевые слова** (100)
```
бинауральные,ритмы,изохронные,тоны,мозг,фокус,медитация,сон,шум,тета,альфа,релакс,учеба,волны
```

**Описание** (4000)
```
Sintonia — студия синхронизации мозговых ритмов для iPhone, iPad и Mac. Приложение в реальном времени генерирует бинауральные, монауральные и изохронные тоны со стереофоническим цветным шумом и позволяет задать, как меняется каждый параметр на протяжении сессии.

СЛУШАЙТЕ
• 18 встроенных сессий для фокуса, отдыха, сна, медитации, учёбы и творчества, от 30 до 45 минут.
• Живой стереоосциллограф показывает ровно то, что вы слышите, вместе с текущим диапазоном мозговых волн (дельта, тета, альфа, бета, гамма) и частотой биений.
• Регуляторы общей громкости, тонов, шума и цвета шума. Перемотка на ±30 секунд.
• Экран блокировки, Пункт управления и воспроизведение в фоне.
• Учитывает наушники: для бинауральных сессий рекомендует наушники и ставит паузу, если их отключить.

СОЗДАВАЙТЕ
• До 10 голосов в пресете. Каждый — бинауральный, монауральный или изохронный, с формой волны синус, синус², треугольник, меандр или сглаженный меандр.
• Стереошум от белого через розовый к коричневому, с пульсацией в такт биениям выбранного голоса.
• Редактор кривых для автоматизации биений, несущей и громкости: плавная или линейная интерполяция, привязка к сетке, масштаб и подсказки диапазонов.
• Отслеживание голосов: привяжите голос к несущей или биениям другого голоса с коэффициентом, например чистой квинтой.
• Каждое изменение слышно сразу. Встроенные пресеты не меняются: правки сохраняются как ваши копии.

ДЕЛИТЕСЬ И ЭКСПОРТИРУЙТЕ
• Импорт классических файлов BrainWave Generator (.bwg) с понятным отчётом обо всём, что было скорректировано.
• Обмен пресетами в виде файлов .sintonia.
• Экспорт любой сессии в WAV (48 кГц, 24 бит) или M4A (AAC 256 кбит/с).

НА MAC
• Отдельные окна плеера, библиотеки и студии, а также плеер в строке меню.
• Выбор любого устройства вывода, импорт перетаскиванием и полный набор клавиатурных сокращений.

КОНФИДЕНЦИАЛЬНОСТЬ
Без учётной записи, рекламы, отслеживания и доступа к сети. Всё остаётся на вашем устройстве.

ВАЖНО
Sintonia — аудиоинструмент для расслабления, концентрации и экспериментов. Это не медицинское изделие, и оно не диагностирует и не лечит никаких заболеваний. При эпилепсии или судорогах в анамнезе посоветуйтесь с врачом перед использованием ритмичного звука. Не используйте приложение за рулём или при работе с техникой.
```

**Что нового** (1.0.0)
```
Первый выпуск Sintonia.
```

---

## App Review notes

```
Sintonia works fully offline. There is no account, sign-in, in-app purchase or network access.

How to review:
1. Tap Play on the main screen. The default "Deep Focus" preset starts and the oscilloscope animates. Headphones are recommended for binaural presets, but the speaker works too.
2. Tap the library icon (top left) to browse the 18 built-in presets. Tap one to load it.
3. Tap the sliders icon to open Studio, where you can edit voices, noise and automation curves live.
4. Use the share icon to export the session as WAV or M4A.

Background audio (UIBackgroundModes: audio) is used only to keep a session playing while the screen is locked. Sintonia makes no medical claims; the description includes a safety note.
```

---

## Screenshots

| Display | Size (px) | Files |
|---|---|---|
| iPhone 6.9″ (required) | 1320 × 2868 | `screenshots/iphone-6.9/` — player, library, studio, curves |
| iPad 13″ (required, the app supports iPad) | 2064 × 2752 | `screenshots/ipad-13/` — player, library, studio |
| Mac (required for the macOS app) | 2880 × 1800 (16:10) | _not captured yet, see below_ |

App Store Connect scales the 6.9″ and 13″ sets down for smaller devices.

**Mac screenshots:** run the macOS app, start a preset, and open the Player, Library and Studio windows. Press `⌘⇧4`, then `Space`, and click a window to capture it. Place the captures on a 2880 × 1800 canvas, either with a dark background or by arranging the three windows side by side.

## Submission checklist

1. **developer.apple.com → Identifiers:** register the App IDs `com.sintonia.app` and `com.sintonia.mac`. No extra capabilities are needed.
2. **App Store Connect → My Apps → New App:** create one record for iOS and one for macOS with those bundle IDs. Check that the name "Sintonia" is available. If it is taken, use a fallback such as "Sintonia: Brainwave Studio".
3. Fill in the fields above: privacy policy URL, App Privacy ("Data Not Collected"), age rating, categories, EN and RU texts, and screenshots.
4. **Xcode:** run `xcodegen generate`, open `Sintonia.xcodeproj`, choose *Any iOS Device*, then **Product → Archive** → **Distribute App → App Store Connect**. Repeat with the `SintoniaMac` scheme on *Any Mac*.
5. When the builds finish processing, attach them to version 1.0.0, paste the App Review notes, set price and availability, and **Submit for Review**.
6. Optional: invite yourself in **TestFlight** to check the release build on a real device first.
