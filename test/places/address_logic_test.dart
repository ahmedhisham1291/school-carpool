import 'package:cloud_firestore/cloud_firestore.dart' show GeoPoint;
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/features/places/place_models.dart';

void main() {
  group('AddressRules (same rules as the server)', () {
    test('street', () {
      expect(AddressRules.street(''), AddressFieldProblem.required);
      expect(AddressRules.street('x'), AddressFieldProblem.tooShort);
      expect(AddressRules.street('شارع 9'), isNull);
      expect(AddressRules.street('  Road   9 '), isNull);
      expect(AddressRules.street('<b>'), AddressFieldProblem.characters);
      expect(AddressRules.street('a' * 121), AddressFieldProblem.tooLong);
    });

    test('building: digits and letters, up to 10', () {
      expect(AddressRules.building(''), AddressFieldProblem.required);
      expect(AddressRules.building('12'), isNull);
      expect(AddressRules.building('12ب'), isNull);
      expect(AddressRules.building('B4'), isNull);
      expect(AddressRules.building('12345678901'), AddressFieldProblem.tooLong);
      expect(AddressRules.building('-12'), AddressFieldProblem.characters);
    });

    test('optional fields and a typed district', () {
      expect(AddressRules.shortExtra(''), isNull);
      expect(AddressRules.shortExtra('3'), isNull);
      expect(AddressRules.shortExtra('12345678901'), AddressFieldProblem.tooLong);
      expect(AddressRules.landmark(''), isNull);
      expect(AddressRules.landmark('x'), AddressFieldProblem.tooShort);
      expect(AddressRules.districtText(''), AddressFieldProblem.required);
      expect(AddressRules.districtText('الحي الجديد'), isNull);
    });
  });

  group('HomeAddress', () {
    const HomeAddress a = HomeAddress(
      governorate: 'cairo',
      placeAreaId: 'osm-r1',
      placeAreaNameAr: 'المعادي',
      placeAreaNameEn: 'Maadi',
      placeDistrictId: 'osm-n10',
      placeDistrictNameAr: 'دجلة',
      placeDistrictNameEn: 'Degla',
      street: 'Road 9',
      building: '12',
    );

    test('sends IDs and text only; a typed district sends its text', () {
      expect(a.toJson(), <String, Object?>{
        'governorate': 'cairo',
        'placeAreaId': 'osm-r1',
        'placeDistrictId': 'osm-n10',
        'street': 'Road 9',
        'building': '12',
        'floor': '',
        'apartment': '',
        'landmark': '',
      });
      const HomeAddress typed = HomeAddress(governorate: 'cairo', placeAreaId: 'osm-r1', street: 'Road 9', building: '12', districtText: 'الحي الجديد');
      expect(typed.toJson()['placeDistrictId'], isNull);
      expect(typed.toJson()['districtText'], 'الحي الجديد');
    });

    test('label in the app language', () {
      expect(a.label('en'), '12 Road 9, Degla, Maadi');
      expect(a.label('ar'), '12 Road 9، دجلة، المعادي');
    });

    test('reads homes/{uid}.address; an older home has none', () {
      final HomeLocation home = HomeLocation.fromMap(<String, Object?>{
        'location': const GeoPoint(29.96, 31.25),
        'address': <String, Object?>{
          'governorate': 'cairo', 'placeAreaId': 'osm-r1', 'placeAreaNameEn': 'Maadi', 'placeDistrictId': null,
          'districtText': 'الحي الجديد', 'street': 'Road 9', 'building': '12',
        },
      });
      expect(home.address?.placeAreaId, 'osm-r1');
      expect(home.address?.placeDistrictId, isNull);
      expect(home.address?.districtText, 'الحي الجديد');
      expect(HomeLocation.fromMap(const <String, Object?>{'location': GeoPoint(29.96, 31.25)}).address, isNull);
      expect(HomeAddress.fromMap(const <String, Object?>{'street': 'x'}), isNull);
    });
  });

  test('sortByName ignores "ال" and hamza forms', () {
    final List<String> sorted = sortByName(<String>['الزمالك', 'أكتوبر', 'المعادي', 'دجلة'], (String s) => s);
    expect(sorted, <String>['أكتوبر', 'دجلة', 'الزمالك', 'المعادي']);
  });
}
