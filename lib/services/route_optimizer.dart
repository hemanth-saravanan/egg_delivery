import 'dart:convert';
import 'dart:math' show cos, sqrt, asin, min, max, exp, Random;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/delivery_stop.dart';
import '../utils/helpers.dart';

class RouteOptimizer {
  Future<List<DeliveryStop>> optimizeRoute(
    List<DeliveryStop> stops,
    Function(String) onStatusUpdate,
    Function(String) onError,
  ) async {
    if (stops.isEmpty) return stops;

    final prefs = await SharedPreferences.getInstance();
    bool useCurrentStart = prefs.getBool('use_current_start') ?? true;
    String startAddress = prefs.getString('start_address') ?? "";
    bool useEndAddress = prefs.getBool('use_end_address') ?? false;
    bool useCurrentEnd = prefs.getBool('use_current_end') ?? true;
    String endAddress = prefs.getString('end_address') ?? "";

    double? startLat, startLng;
    double? endLat, endLng;

    onStatusUpdate("Resolving Locations...");

    try {
      if (useCurrentStart) {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          throw Exception("Enable GPS for Start Location!");
        }
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied) {
          throw Exception("Location permission denied.");
        }

        Position pos = await Geolocator.getCurrentPosition();
        startLat = pos.latitude;
        startLng = pos.longitude;
      } else {
        if (startAddress.isEmpty) {
          throw Exception("Set Start Address in Settings");
        }
        var coords = await getCoordinatesFromAddress(startAddress);
        if (coords == null) {
          throw Exception("Start Address not found");
        }
        startLat = coords['lat'];
        startLng = coords['lng'];
      }

      if (useEndAddress) {
        if (useCurrentEnd) {
          if (useCurrentStart && startLat != null) {
            endLat = startLat;
            endLng = startLng;
          } else {
            Position pos = await Geolocator.getCurrentPosition();
            endLat = pos.latitude;
            endLng = pos.longitude;
          }
        } else {
          if (endAddress.isEmpty) {
            throw Exception("Set End Address in Settings");
          }
          var coords = await getCoordinatesFromAddress(endAddress);
          if (coords == null) {
            throw Exception("End Address not found");
          }
          endLat = coords['lat'];
          endLng = coords['lng'];
        }
      }
    } catch (e) {
      onError(e.toString());
      rethrow;
    }

    List<DeliveryStop> activeStops = [];
    List<DeliveryStop> inactiveStops = [];
    for (var stop in stops) {
      if (!stop.isCompleted &&
          stop.latitude != null &&
          stop.longitude != null) {
        activeStops.add(stop);
      } else {
        inactiveStops.add(stop);
      }
    }

    if (activeStops.isEmpty) {
      onError("No active stops found.");
      return inactiveStops;
    }

    onStatusUpdate("Optimizing...");

    int n = activeStops.length;
    List<List<double>> distMatrix =
        List.generate(n, (_) => List.filled(n, 0.0));
    List<double> startDist = List.filled(n, 0.0);
    List<double> endDist = List.filled(n, 0.0);
    bool usedApi = false;

    if (n < 100) {
      try {
        onStatusUpdate("Fetching Traffic Data...");
        List<String> coords = [];
        coords.add("$startLng,$startLat");
        for (var s in activeStops) {
          coords.add("${s.longitude},${s.latitude}");
        }
        if (endLat != null) coords.add("$endLng,$endLat");

        String url =
            "https://router.project-osrm.org/table/v1/driving/${coords.join(';')}?annotations=duration";
        final response = await http.get(Uri.parse(url));

        if (response.statusCode == 200) {
          var data = jsonDecode(response.body);
          List<dynamic> durations = data['durations'];

          for (int i = 0; i < n; i++) {
            startDist[i] = (durations[0][i + 1] as num).toDouble();
            for (int j = 0; j < n; j++) {
              distMatrix[i][j] = (durations[i + 1][j + 1] as num).toDouble();
            }
            if (endLat != null) {
              endDist[i] = (durations[i + 1][n + 1] as num).toDouble();
            }
          }
          usedApi = true;
        }
      } catch (e) {
        print("OSRM API Failed: $e");
      }
    }

    if (!usedApi) {
      onStatusUpdate("Optimizing (Distance)...");
      for (int i = 0; i < n; i++) {
        startDist[i] = calculateDistance(
            startLat!, startLng!, activeStops[i].latitude!, activeStops[i].longitude!);
        for (int j = 0; j < n; j++) {
          if (i == j) {
            distMatrix[i][j] = 0.0;
          } else {
            distMatrix[i][j] = calculateDistance(
                activeStops[i].latitude!,
                activeStops[i].longitude!,
                activeStops[j].latitude!,
                activeStops[j].longitude!);
          }
        }
        if (endLat != null) {
          endDist[i] = calculateDistance(activeStops[i].latitude!,
              activeStops[i].longitude!, endLat, endLng!);
        }
      }
    } else {
      onStatusUpdate("Optimizing (Drive Time)...");
    }

    List<int> bestIndices = _solveTSP(n, startDist, distMatrix, endDist);

    List<DeliveryStop> optimizedStops =
        bestIndices.map((i) => activeStops[i]).toList();

    return [...optimizedStops, ...inactiveStops];
  }

  List<int> _solveTSP(
    int n,
    List<double> startDist,
    List<List<double>> distMatrix,
    List<double> endDist,
  ) {
    double getRouteDistance(List<int> indices) {
      if (indices.isEmpty) return 0.0;
      double total = startDist[indices[0]];
      for (int i = 0; i < indices.length - 1; i++) {
        total += distMatrix[indices[i]][indices[i + 1]];
      }
      if (endDist.isNotEmpty) {
        total += endDist[indices.last];
      }
      return total;
    }

    List<int> nnIndices = _nearestNeighbor(n, startDist, distMatrix);

    Random random = Random();
    List<int> globalBestIndices = List.from(nnIndices);
    double globalBestDist = getRouteDistance(nnIndices);

    int maxRestarts = 20;
    Stopwatch stopwatch = Stopwatch()..start();
    int timeLimitMillis = 4000;

    for (int attempt = 0; attempt < maxRestarts; attempt++) {
      if (stopwatch.elapsedMilliseconds > timeLimitMillis) break;

      List<int> solverIndices;
      if (attempt == 0) {
        solverIndices = List.from(nnIndices);
      } else {
        solverIndices = List.generate(n, (index) => index);
        solverIndices.shuffle(random);
      }

      double currentDist = getRouteDistance(solverIndices);
      double bestDistLocal = currentDist;
      List<int> bestIndicesLocal = List.from(solverIndices);

      double temperature = 150.0;
      double coolingRate = 0.9999;
      int maxIter = 500000;

      for (int i = 0; i < maxIter; i++) {
        if (temperature < 0.01) break;

        double moveType = random.nextDouble();

        if (moveType < 0.5) {
          int p1 = random.nextInt(n);
          int p2 = random.nextInt(n);
          if (p1 == p2) continue;
          int start = min(p1, p2);
          int end = max(p1, p2);

          _reverseIndices(solverIndices, start, end);
          double newDist = getRouteDistance(solverIndices);

          if (newDist < currentDist ||
              exp(-(newDist - currentDist) / temperature) >
                  random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            _reverseIndices(solverIndices, start, end);
          }
        } else if (moveType < 0.9) {
          int blockSize = 1 + random.nextInt(6);
          if (n < blockSize + 1) blockSize = 1;

          int itemIdx = random.nextInt(n - blockSize + 1);

          List<int> block = [];
          for (int k = 0; k < blockSize; k++) {
            block.add(solverIndices[itemIdx + k]);
          }

          solverIndices.removeRange(itemIdx, itemIdx + blockSize);

          int targetIdx = random.nextInt(solverIndices.length + 1);
          solverIndices.insertAll(targetIdx, block);

          double newDist = getRouteDistance(solverIndices);

          if (newDist < currentDist ||
              exp(-(newDist - currentDist) / temperature) >
                  random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            solverIndices.removeRange(targetIdx, targetIdx + blockSize);
            solverIndices.insertAll(itemIdx, block);
          }
        } else {
          int p1 = random.nextInt(n);
          int p2 = random.nextInt(n);
          if (p1 == p2) continue;

          int temp = solverIndices[p1];
          solverIndices[p1] = solverIndices[p2];
          solverIndices[p2] = temp;

          double newDist = getRouteDistance(solverIndices);

          if (newDist < currentDist ||
              exp(-(newDist - currentDist) / temperature) >
                  random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            int temp = solverIndices[p1];
            solverIndices[p1] = solverIndices[p2];
            solverIndices[p2] = temp;
          }
        }
        temperature *= coolingRate;
      }

      if (bestDistLocal < globalBestDist) {
        globalBestDist = bestDistLocal;
        globalBestIndices = bestIndicesLocal;
      }
    }
    return globalBestIndices;
  }

  List<int> _nearestNeighbor(
    int n,
    List<double> startDist,
    List<List<double>> distMatrix,
  ) {
    List<int> indices = [];
    Set<int> visited = {};
    int lastIndex = -1;

    for (int k = 0; k < n; k++) {
      int best = -1;
      double minD = double.infinity;
      for (int i = 0; i < n; i++) {
        if (!visited.contains(i)) {
          double d = (lastIndex == -1) ? startDist[i] : distMatrix[lastIndex][i];
          if (d < minD) {
            minD = d;
            best = i;
          }
        }
      }
      indices.add(best);
      visited.add(best);
      lastIndex = best;
    }
    return indices;
  }

  void _reverseIndices(List<int> indices, int i, int k) {
    while (i < k) {
      int temp = indices[i];
      indices[i] = indices[k];
      indices[k] = temp;
      i++;
      k--;
    }
  }
}
