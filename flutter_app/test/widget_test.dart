import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ArxivReader shell renders starter panels', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ArxivReaderApp());
    await tester.pump();

    expect(find.text('Daily astro-ph reader'), findsOneWidget);
    expect(find.text('Paper Queue'), findsOneWidget);
    expect(find.text('Choose Date'), findsOneWidget);
    expect(find.text('Summarize All Papers'), findsOneWidget);
  });

  test('cache size includes nested cache files and formats bytes', () async {
    final directory = await Directory.systemTemp.createTemp('arxiv-cache-test');
    addTearDown(() => directory.delete(recursive: true));
    final nested = Directory('${directory.path}/pdfs');
    await nested.create();
    await File(
      '${directory.path}/paper_states.json',
    ).writeAsBytes(List<int>.filled(512, 0));
    await File(
      '${nested.path}/paper.pdf',
    ).writeAsBytes(List<int>.filled(1536, 0));

    final size = await AppCacheService().cacheSizeBytes(
      overridePath: directory.path,
    );

    expect(size, 2048);
    expect(AppCacheService.formatStorageSize(size), '2.0 KB');
  });

  testWidgets('Settings page opens and shows new controls', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ArxivReaderApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Default topics'), findsOneWidget);
    expect(find.text('Gemini API key'), findsOneWidget);
    expect(find.text('Gemini model'), findsOneWidget);
    expect(find.text('Test Gemini connection'), findsOneWidget);
    expect(find.text('OpenAI API key'), findsNothing);
    expect(find.text('Cache folder'), findsOneWidget);
    expect(find.text('Clear Cache'), findsOneWidget);
    expect(find.textContaining('Cache size:'), findsOneWidget);

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini API key'), findsNothing);
    expect(find.text('OpenAI API key'), findsOneWidget);
    expect(find.text('OpenAI model'), findsOneWidget);
    expect(find.text('Test OpenAI connection'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Launch app at login'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Launch app at login'), findsOneWidget);
    expect(find.text('Auto-fetch papers on launch'), findsNothing);
    expect(find.text('Auto-summarize matched papers'), findsNothing);
  });
}
