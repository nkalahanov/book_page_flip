# book_page_flip

Turn pages in real 3D — drag them with a finger, or flip them from code.

[![pub package](https://img.shields.io/pub/v/book_page_flip.svg)](https://pub.dev/packages/book_page_flip)
[![pub likes](https://img.shields.io/pub/likes/book_page_flip)](https://pub.dev/packages/book_page_flip/score)
[![pub points](https://img.shields.io/pub/points/book_page_flip)](https://pub.dev/packages/book_page_flip/score)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

Show your content as an open book, with pages that curl in 3D like real paper.
Readers turn them with a drag — or you flip them from code.

![Animated demo: turning book pages in 3D with a drag or from code](https://raw.githubusercontent.com/nkalahanov/book_page_flip/df3fd064191b8bb30d3083dc44f38edb287c670c/assets/demo.webp)

## ✨ Features

- 📖 True 3D page curl on a real mesh.
- 👆 Turn pages with a drag, or animate from code.
- 🌑 Soft drop shadow and spine shadow add real depth.
- 📄 Paper looks: matte `paper` and glossy `magazine`.
- 🌀 Page-curl presets: gentle, tight, floppy.
- 🎛️ Switch each visual effect on or off.
- 🎮 Controller to go next, back, or to any page.
- 🧩 Pages from any widget, or from decoded images.
- 📐 Fits any size. Runs on all 6 platforms.

## 🚀 Install

```sh
flutter pub add book_page_flip
```

Or add it by hand to `pubspec.yaml`:

```yaml
dependencies:
  book_page_flip: ^0.1.0
```

## ▶️ Quick start

The fastest way is `BookFlip.builder`. You give it a page count and a builder,
and it makes each page for you. No image decoding by hand.

```dart
import 'package:book_page_flip/book_page_flip.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: BookFlip.builder(
            pageCount: 6,
            pageSize: const Size(360, 500),
            pageBuilder: (context, index) => ColoredBox(
              color: Colors.primaries[index % Colors.primaries.length],
              child: Center(
                child: Text(
                  'Page ${index + 1}',
                  style: const TextStyle(fontSize: 48, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

## 📖 Usage

### Pages from widgets

Use `BookFlip.widgets` when you already have a list of widgets. Each one
becomes a page.

```dart
BookFlip.widgets(
  pageSize: const Size(360, 500),
  pages: const [
    Center(child: Text('Once upon a time...')),
    ColoredBox(color: Color(0xFFFFF3E0)),
    ColoredBox(color: Color(0xFFE3F2FD)),
    Center(child: Text('...the end.')),
  ],
)
```

### Pages from decoded images

Already have `ui.Image` pages? Pass them to the `BookFlip` constructor. All
pages must be the same size.

```dart
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;

// Decode one asset into a ui.Image. Do this once, then reuse the result.
Future<ui.Image> decodeAsset(String assetKey) async {
  final data = await rootBundle.load(assetKey);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  return frame.image;
}

// Pass the decoded images straight to BookFlip. You own them:
// dispose each image only after the widget is gone, never before.
Widget buildBook(List<ui.Image> pages) => BookFlip(pages: pages);
```

### Flip from code

Make a `BookFlipController`, give it to the book, and call its methods. It is a
`ChangeNotifier`, so you can show the live position too.

```dart
class Reader extends StatefulWidget {
  const Reader({super.key});

  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> {
  final controller = BookFlipController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: BookFlip.builder(
            controller: controller,
            pageCount: 8,
            pageSize: const Size(360, 500),
            pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () => controller.goToPage(0),
              icon: const Icon(Icons.first_page),
            ),
            IconButton(
              onPressed: () => controller.previousSpread(),
              icon: const Icon(Icons.chevron_left),
            ),
            // Rebuilds the readout whenever the page changes.
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Text(
                'Page ${controller.currentPage + 1} of ${controller.totalPages}',
              ),
            ),
            IconButton(
              onPressed: () => controller.nextSpread(),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }
}
```

### Pick the paper

`BookFlipMaterial` sets how the paper looks. Use a ready-made one, or set your
own dials. Each dial is `0..1`; `thickness` is in logical pixels.

```dart
// Ready-made: matte `paper` (the default) or glossy `magazine`.
BookFlip.builder(
  material: BookFlipMaterial.magazine,
  pageCount: 6,
  pageSize: const Size(360, 500),
  pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
);

// Or tune your own paper.
const myPaper = BookFlipMaterial(
  stiffness: 0.4,
  weight: 0.3,
  gloss: 0.8,
  translucency: 0.1,
  thickness: 1.0,
);
```

### Change the page-curl

`BookFlipCurl` shapes the bend of the turning page, apart from the paper. There
are three presets: `gentle`, `tight`, and `floppy`.

```dart
BookFlip.builder(
  curl: BookFlipCurl.tight,
  pageCount: 6,
  pageSize: const Size(360, 500),
  pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
);

// Or set your own dials (each is 0..1).
const myCurl = BookFlipCurl(bend: 0.6, foldTilt: 0.4, droop: 0.2);
```

### Turn effects on or off

Every effect is on by default. Start from `BookFlipEffects.all` and switch off
what you do not want.

```dart
BookFlip.builder(
  effects: BookFlipEffects.all.copyWith(grain: false, gloss: false),
  pageCount: 6,
  pageSize: const Size(360, 500),
  pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
);
```

The flags are: `gloss`, `grain`, `castShadow`, `spineShadow`, `edge`,
`translucency`.

### Fit the book to its space

`BookFit.contain` (the default) keeps the page shape and never stretches it.
`BookFit.fill` stretches the book to fill the box.

```dart
BookFlip.builder(
  fit: BookFit.fill,
  pageCount: 6,
  pageSize: const Size(360, 500),
  pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
);
```

### Listen to the turn

Three callbacks tell you about each turn. `onFlipStart` also gives the
`FlipDirection`.

```dart
BookFlip.builder(
  pageCount: 6,
  pageSize: const Size(360, 500),
  pageBuilder: (context, i) => Center(child: Text('Page ${i + 1}')),
  onFlipStart: (spread, direction) =>
      debugPrint('leaving spread $spread, going $direction'),
  onFlipEnd: (spread) => debugPrint('resting on spread $spread'),
  onSpreadChanged: (spread) => debugPrint('now showing spread $spread'),
);
```

## 🎛️ Main options

The most useful `BookFlip.builder` knobs:

| Name | Type | Default | What it does |
| --- | --- | --- | --- |
| `pageCount` | `int` | required | How many pages to build. |
| `pageBuilder` | `Widget Function(BuildContext, int)` | required | Builds each page. |
| `pageSize` | `Size` | required | Layout size of one page. |
| `controller` | `BookFlipController?` | `null` | Flip pages from code. |
| `material` | `BookFlipMaterial` | `BookFlipMaterial.paper` | The paper look. |
| `curl` | `BookFlipCurl?` | `null` | Override the page-curl. |
| `effects` | `BookFlipEffects` | `BookFlipEffects.all` | Which effects draw. |
| `fit` | `BookFit` | `BookFit.contain` | How the book fits its box. |
| `pixelRatio` | `double?` | device ratio | How sharp pages are captured. |
| `physics` | `BookFlipPhysics` | `const BookFlipPhysics()` | How a page settles after a drag. |

<details>
<summary>More options</summary>

| Name | Type | Default | What it does |
| --- | --- | --- | --- |
| `maxTextureDimension` | `int` | `4096` | Largest atlas texture size, in pixels. |
| `meshResolution` | `int` | `42` | Mesh columns across a page. Higher is smoother. |
| `onSpreadChanged` | `void Function(int spread)?` | `null` | The resting spread changed. |
| `onFlipStart` | `void Function(int spread, FlipDirection)?` | `null` | A flip began. |
| `onFlipEnd` | `void Function(int spread)?` | `null` | A flip ended. |
| `loadingBuilder` | `WidgetBuilder?` | `null` | Shown while pages load. |
| `errorBuilder` | `WidgetBuilder?` | `null` | Shown if loading fails. |
| `pageLabel` | `Widget Function(BuildContext, int page, int total)?` | `null` | Stamp a page number on every page. |

The default `BookFlip(pages: ...)` constructor takes the same options, plus
`pageAspectRatio` to set the page shape up front.

</details>

## ⚠️ Good to know

- Pages show **two at a time**. This pair is called a *spread*.
- Use an **even** page count. An odd last page has no partner, so it is not shown.
- A book needs **at least 2 pages**.
- Images are decoded once and kept in memory. `BookFlip.builder` does this for you.
- Runs on all 6 platforms: Android, iOS, web, Windows, macOS, and Linux.

## 🤝 Contributing

Issues and pull requests are welcome on
[GitHub](https://github.com/nkalahanov/book_page_flip).

## 📄 License

MIT © 2026 Kalahanov Nikita. See [LICENSE](LICENSE).

A full demo app lives in [`example/`](example/lib/main.dart).
