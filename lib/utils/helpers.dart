import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' show cos, sqrt, asin;
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../models/delivery_stop.dart';

void showErrorSnackBar(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }
}

Future<void> openMap(
    BuildContext context, String address, double? lat, double? lng) async {
  String googleUrl = (lat != null && lng != null)
      ? "https://www.google.com/maps/search/?api=1&query=$lat,$lng?q=$lat,$lng"
      : "https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}";
  if (!await launchUrl(Uri.parse(googleUrl),
      mode: LaunchMode.externalApplication)) {
    showErrorSnackBar(context, 'Could not open Maps');
  }
}

String formatPhone(String phone) {
  String digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length > 10) {
    digits = digits.substring(digits.length - 10);
  }
  if (digits.length == 10) {
    return "(${digits.substring(0, 3)})-${digits.substring(3, 6)}-${digits.substring(6)}";
  }
  return phone;
}

double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
  var p = 0.017453292519943295;
  var c = cos;
  var a = 0.5 -
      c((lat2 - lat1) * p) / 2 +
      c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
  return 12742 * asin(sqrt(a));
}

Future<Map<String, double>?> getCoordinatesFromAddress(String address) async {
  try {
    final url = Uri.parse(
        "https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1");
    final response =
        await http.get(url, headers: {'User-Agent': 'EggDeliveryApp/1.0'});
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is List && data.isNotEmpty) {
        return {
          'lat': double.parse(data[0]['lat']),
          'lng': double.parse(data[0]['lon'])
        };
      }
    }
  } catch (e) {
    /* ignore */
  }
  return null;
}

Future<void> launchFullRoute(
    BuildContext context, List<DeliveryStop> stops) async {
  if (stops.isEmpty) return;
  List<DeliveryStop> pendingStops =
      stops.where((s) => !s.isCompleted).toList();
  if (pendingStops.isEmpty) {
    showErrorSnackBar(context, "All deliveries completed!");
    return;
  }

  int chunkSize = 10;
  List<List<DeliveryStop>> chunks = [];
  for (int i = 0; i < pendingStops.length; i += chunkSize) {
    chunks.add(pendingStops.sublist(i,
        i + chunkSize > pendingStops.length ? pendingStops.length : i + chunkSize));
  }

  if (chunks.length == 1) {
    openMultiStopMap(context, chunks[0]);
  } else {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Choose Route Segment"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < chunks.length; i++)
              ListTile(
                title: Text(
                    "Part ${i + 1} (Stops ${i * chunkSize + 1} - ${(i * chunkSize) + chunks[i].length})"),
                leading: const Icon(Icons.map),
                onTap: () {
                  Navigator.pop(context);
                  openMultiStopMap(context, chunks[i]);
                },
              )
          ],
        ),
      ),
    );
  }
}

Future<void> openMultiStopMap(
    BuildContext context, List<DeliveryStop> segment) async {
  if (segment.isEmpty) return;
  String url = "https://www.google.com/maps/dir/?api=1";
  if (segment.last.latitude != null) {
    url += "&destination=${segment.last.latitude},${segment.last.longitude}";
  } else {
    url += "&destination=${Uri.encodeComponent(segment.last.address)}";
  }
  if (segment.length > 1) {
    List<String> points = [];
    for (int i = 0; i < segment.length - 1; i++) {
      if (segment[i].latitude != null) {
        points.add("${segment[i].latitude},${segment[i].longitude}");
      } else {
        points.add(Uri.encodeComponent(segment[i].address));
      }
    }
    url += "&waypoints=${points.join('|')}";
  }
  url += "&travelmode=driving";
  if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
    showErrorSnackBar(context, "Could not open Maps");
  }
}
