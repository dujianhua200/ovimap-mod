import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/models/map_label.dart';

const double kLat = 32.1264;
const double kLon = 114.0913;
List<MapLabel> _labels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: kLat, lon: kLon, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: kLat, lon: kLon + 0.001, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 3, lat: kLat, lon: kLon + 0.002, lineGroupId: 'g'),
    ];
String _roadsJson() => jsonEncode({
      'elements': [
        {
          'type': 'way',
          'geometry': [
            {'lat': kLat, 'lon': kLon - 0.002},
            {'lat': kLat, 'lon': kLon + 0.003},
          ],
          'tags': {'highway': 'trunk', 'name': '主干道'},
        },
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('debug2', () async {
    final dir = Directory.systemTemp.createTempSync('dbg2');
    final cache = BasemapCache(dir);
    final requestedHosts = <String>[];
    OverpassClient.httpGetOverride = (url, {headers}) async {
      requestedHosts.add(url.host);
      if (url.host == 'ovp.mydomain.example') {
        return http.Response(_roadsJson(), 200);
      }
      throw const HttpException('mock: 内置境外端点不可达');
    };
    final data = await BasemapFetcher.fetchFor(
      _labels(),
      rangeM: 300,
      cache: cache,
      useTdt: false,
      overpassEndpoints: 'https://ovp.mydomain.example/\nhttps://ovp.mydomain.example/',
    );
    // ignore: avoid_print
    print('ROADS state=${data.report.roads.state} count=${data.roads.length} err=${data.report.roads.error}');
    // ignore: avoid_print
    print('BLD state=${data.report.buildings.state} err=${data.report.buildings.error}');
    // ignore: avoid_print
    print('PLC state=${data.report.places.state} err=${data.report.places.error}');
    OverpassClient.httpGetOverride = null;
    dir.deleteSync(recursive: true);
  });
}
