import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/widgets.dart';
import 'package:nekoproxy/features/tools/backup_page.dart';
import 'package:nekoproxy/services/backup_service.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  testWidgets('备份密码单独成卡，导出和恢复共用一张卡片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const BackupPage()),
      ),
    );

    final passwordCard = find.widgetWithText(SectionCard, '备份密码');
    final operationsCard = find.widgetWithText(SectionCard, '导出与恢复');
    final resetCard = find.widgetWithText(SectionCard, '重置所有数据');
    expect(find.byType(SectionCard), findsNWidgets(3));
    expect(resetCard, findsOneWidget);

    final passwordField = find.descendant(
      of: passwordCard,
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    expect(
      tester.getBottomLeft(passwordCard).dy,
      lessThan(tester.getTopLeft(operationsCard).dy),
    );

    for (final label in ['导出备份文件', '选择备份文件并恢复']) {
      expect(
        find.descendant(of: operationsCard, matching: find.text(label)),
        findsOneWidget,
      );
    }
  });

  testWidgets('加密备份缺少密码时弹窗，输错后可以重试原文件', (tester) async {
    final picker = _BackupPicker();
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    final controller = _BackupController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const BackupPage()),
      ),
    );

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    final restoreButton = find.widgetWithText(FilledButton, '恢复');
    final chooseFile = find.text('选择备份文件并恢复');

    Future<void> pumpDialog() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tester.tap(chooseFile);
    await pumpDialog();
    expect(find.text('该备份已加密，请输入密码'), findsOneWidget);
    expect(tester.widget<TextField>(dialogField).obscureText, isTrue);
    expect(tester.widget<FilledButton>(restoreButton).onPressed, isNull);

    await tester.enterText(dialogField, 'wrong');
    await tester.pump();
    await tester.tap(restoreButton);
    await pumpDialog();
    expect(find.text('密码错误或备份已损坏'), findsOneWidget);

    await tester.enterText(dialogField, 'correct');
    await tester.pump();
    await tester.tap(restoreButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('备份已恢复'), findsOneWidget);
    expect(controller.attemptedPasswords, [null, 'wrong', 'correct']);
    expect(picker.pickCount, 1);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(chooseFile);
    await pumpDialog();
    expect(find.text('密码错误或备份已损坏'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.attemptedPasswords, [null, 'wrong', 'correct', 'wrong']);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '选择备份文件并恢复'),
          )
          .onPressed,
      isNotNull,
    );
  });
}

class _BackupController extends AppController {
  final attemptedPasswords = <String?>[];

  @override
  Future<void> importBackup(String content, {String? password}) async {
    expect(content, 'encrypted backup');
    attemptedPasswords.add(password);
    switch (password) {
      case null:
        throw const BackupPasswordException('该备份已加密，请输入密码');
      case 'correct':
        return;
      default:
        throw const BackupPasswordException('密码错误或备份已损坏');
    }
  }
}

class _BackupPicker extends FilePickerPlatform {
  int pickCount = 0;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickCount++;
    return [_BackupFile()];
  }
}

final class _BackupFile extends PlatformFile {
  @override
  Future<Uint8List> readAsBytes() async => utf8.encode('encrypted backup');

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
