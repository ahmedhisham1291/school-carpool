import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/dropdown.dart';
import '../helpers/test_app.dart';

const List<AppDropdownItem<String>> _areas = <AppDropdownItem<String>>[
  AppDropdownItem<String>('maadi', 'المعادي'),
  AppDropdownItem<String>('nasr', 'مدينة نصر'),
  AppDropdownItem<String>('zayed', 'الشيخ زايد'),
  AppDropdownItem<String>('october', '6th of October'),
];

/// City -> Area as on the address and browse screens.
class _Pair extends StatefulWidget {
  const _Pair();

  @override
  State<_Pair> createState() => _PairState();
}

class _PairState extends State<_Pair> {
  String? city;
  String? area;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: <Widget>[
          AppDropdownMenu<String>(
            key: const Key('city'),
            label: 'City',
            value: city,
            items: const <AppDropdownItem<String>>[AppDropdownItem<String>('cairo', 'Cairo'), AppDropdownItem<String>('giza', 'Giza')],
            onSelected: (String v) => setState(() {
              city = v;
              area = null;
            }),
          ),
          AppDropdownMenu<String>(
            key: Key('area.${city ?? ''}'),
            label: 'Area',
            value: area,
            items: city == 'cairo' ? _areas.sublist(0, 2) : (city == 'giza' ? _areas.sublist(2) : const <AppDropdownItem<String>>[]),
            pinnedLast: const AppDropdownItem<String>('other', 'Not listed'),
            onSelected: city == null ? null : (String v) => setState(() => area = v),
          ),
        ],
      ),
    ),
  );
}

void main() {
  group('AppDropdownMenu.filter', () {
    test('words start a word of the label; Arabic spelling and "ال" ignored', () {
      List<String> ids(String q) => AppDropdownMenu.filter<String>(_areas, q).map((AppDropdownItem<String> i) => i.value).toList();
      expect(ids(''), <String>['maadi', 'nasr', 'zayed', 'october']);
      expect(ids('معادي'), <String>['maadi']); // without "ال"
      expect(ids('مدينه'), <String>['nasr']); // taa marbuta typed as haa
      expect(ids('شيخ زا'), <String>['zayed']);
      expect(ids('OCT'), <String>['october']);
      expect(ids('xyz'), isEmpty);
    });

    test('the pinned item stays last whatever is typed', () {
      const AppDropdownItem<String> pinned = AppDropdownItem<String>('other', 'Not listed');
      final List<AppDropdownItem<String>> out = AppDropdownMenu.filter<String>(_areas, 'xyz', pinned: pinned);
      expect(out.single.value, 'other');
      expect(AppDropdownMenu.filter<String>(_areas, '', pinned: pinned).last.value, 'other');
    });
  });

  testWidgets('the child waits for its parent, and a new parent clears it', (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(const _Pair(), locale: AppLocales.english));
    await tester.pumpAndSettle();
    expect(dropdownEnabled(tester, const Key('area.')), isFalse);

    await pickFromDropdown(tester, const Key('city'), 'Cairo');
    expect(dropdownEnabled(tester, const Key('area.cairo')), isTrue);
    await pickFromDropdown(tester, const Key('area.cairo'), 'مدينة نصر');
    expect(dropdownText(tester, const Key('area.cairo')), 'مدينة نصر');
    expect(tester.state<_PairState>(find.byType(_Pair)).area, 'nasr');

    // Another city: the area is empty again and lists that city's areas.
    await pickFromDropdown(tester, const Key('city'), 'Giza');
    expect(tester.state<_PairState>(find.byType(_Pair)).area, isNull);
    expect(dropdownText(tester, const Key('area.giza')), isEmpty);
    await tester.tap(find.byKey(const Key('area.giza')));
    await tester.pumpAndSettle();
    expect(find.text('الشيخ زايد'), findsWidgets);
    expect(find.text('مدينة نصر'), findsNothing);
    expect(find.text('Not listed'), findsWidgets);
  });
}
