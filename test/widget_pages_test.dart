import 'package:book_page_flip/book_page_flip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'BookFlip.builder captures widget pages and mounts a real BookFlip',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip.builder(
                    pageCount: 4,
                    pageSize: const Size(200, 280),
                    pageBuilder: (context, i) => ColoredBox(
                      color: Colors.white,
                      child: Center(child: Text('Page $i')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.byType(BookFlip), findsNothing);

        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(find.byType(BookFlip), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'BookFlip.builder rejects fewer than two pages',
    (tester) async {
      expect(
        () => BookFlip.builder(
          pageCount: 1,
          pageSize: const Size(200, 280),
          pageBuilder: (context, i) => const SizedBox(),
        ),
        throwsAssertionError,
      );
    },
  );

  testWidgets(
    'BookFlip.builder bakes a 1-based pageLabel onto each page',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip.builder(
                    pageCount: 4,
                    pageSize: const Size(200, 280),
                    pageBuilder: (context, i) =>
                        const ColoredBox(color: Colors.white),
                    pageLabel: (context, page, total) => Align(
                      alignment: Alignment.bottomRight,
                      child: Text('$page / $total'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.text('1 / 4'), findsOneWidget);
        expect(find.text('4 / 4'), findsOneWidget);

        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.byType(BookFlip), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'BookFlip.builder survives a pageCount change mid-capture (no RangeError)',
    (tester) async {
      await tester.runAsync(() async {
        Widget build(int count) => MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 400,
                    height: 280,
                    child: BookFlip.builder(
                      pageCount: count,
                      pageSize: const Size(200, 280),
                      pageBuilder: (context, i) =>
                          const ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
              ),
            );

        await tester.pumpWidget(build(4));
        await tester.pumpWidget(build(6));
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(BookFlip), findsOneWidget);
      });
    },
  );

  testWidgets(
    'BookFlip.widgets builds a book from a widget list',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip.widgets(
                    pageSize: const Size(200, 280),
                    pages: const <Widget>[
                      ColoredBox(color: Colors.white),
                      ColoredBox(color: Colors.black),
                      ColoredBox(color: Colors.white),
                      ColoredBox(color: Colors.black),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.byType(BookFlip), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
