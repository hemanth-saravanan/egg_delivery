import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/delivery_stop.dart';

class SheetsService {
  final String scriptUrl;

  SheetsService(this.scriptUrl);

  Future<List<DeliveryStop>> fetchSpreadsheetData() async {
    if (scriptUrl.isEmpty) {
      throw Exception("Script URL is empty.");
    }

    final response = await http.get(Uri.parse(scriptUrl));

    if (response.statusCode == 200) {
      List<dynamic> jsonList = jsonDecode(response.body);
      List<DeliveryStop> newStops = [];

      for (var row in jsonList) {
        double? lat;
        double? lng;
        if (row['coords'] != null) {
          String coordRaw = row['coords'].toString().replaceAll('/', '').trim();
          List<String> parts = coordRaw.split(',');
          if (parts.length == 2) {
            lat = double.tryParse(parts[0].trim());
            lng = double.tryParse(parts[1].trim());
          }
        }

        String status = row['status'].toString();
        bool isCompleted = (status == 'complete' || status == 'texted');
        bool isTexted = (status == 'texted');

        newStops.add(DeliveryStop(
          name: row['name'].toString(),
          address: row['address'].toString(),
          phone: row['phone'].toString(),
          dozens: int.tryParse(row['dozens'].toString()) ?? 0,
          notes: row['notes'].toString(),
          originalRowIndex: int.parse(row['originalRow'].toString()),
          latitude: lat,
          longitude: lng,
          isCompleted: isCompleted,
          isTexted: isTexted,
        ));
      }
      newStops.sort((a, b) => a.originalRowIndex.compareTo(b.originalRowIndex));
      return newStops;
    } else {
      throw Exception('Failed to connect to script');
    }
  }

  Future<void> markAsComplete(int rowIndex) async {
    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl),
            body: jsonEncode({"row": rowIndex, "status": "complete"}));
      } catch (e) {
        // silent fail
      }
    }
  }

  Future<void> markAsTexted(int rowIndex) async {
    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl),
            body: jsonEncode({"row": rowIndex, "status": "texted"}));
      } catch (e) {
        // silent fail
      }
    }
  }

  Future<void> syncOrderToSheet(List<DeliveryStop> stops) async {
    if (scriptUrl.isEmpty) return;

    List<int> indices = stops.map((s) => s.originalRowIndex).toList();

    await http.post(Uri.parse(scriptUrl),
        body: jsonEncode({"action": "reorder", "indices": indices}));
  }
}
