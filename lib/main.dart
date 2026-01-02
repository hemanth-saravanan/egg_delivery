import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' show cos, sqrt, asin, min, max, exp, Random;

// --- THE NEW GOOGLE APPS SCRIPT CODE (Includes doGet) ---
const String _googleScriptCode = r'''
// 1. READ DATA (Fetch rows + Colors)
function doGet(e) {

  //Edit Sheet1 to be the name of the sheet with your data
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("Sheet1");
  var lastRow = sheet.getLastRow();
  
  // If sheet is empty, return empty list
  if (lastRow < 2) {
    return ContentService.createTextOutput(JSON.stringify([]))
      .setMimeType(ContentService.MimeType.JSON);
  }

  // Get all data and all background colors in one batch
  // We assume columns A-F (1-6)
  var range = sheet.getRange(2, 1, lastRow - 1, 6);
  var values = range.getValues();
  var backgrounds = range.getBackgrounds();

  var data = [];

  for (var i = 0; i < values.length; i++) {
    var color = backgrounds[i][0].toLowerCase(); // Check color of Column A
    var status = "pending";

    // Map specific colors to status
    // #b6d7a8 is the Light Green we use
    // #ea9999 is the Light Red we use
    if (color == "#b6d7a8") status = "complete";
    if (color == "#ea9999") status = "texted";

    data.push({
      "name": values[i][0],
      "address": values[i][1],
      "phone": values[i][2],
      "dozens": values[i][3],
      "notes": values[i][4],
      "coords": values[i][5],
      "status": status,
      "originalRow": i + 2 // Row index for updates
    });
  }

  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

// 2. WRITE DATA (Update Colors OR Reorder)
function doPost(e) {
  var params = JSON.parse(e.postData.contents);
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("Sheet1");

  // --- ACTION: REORDER ---
  if (params.action == "reorder") {
    var indices = params.indices; // Array of original row numbers
    var lastRow = sheet.getLastRow();
    if (lastRow < 2) return ContentService.createTextOutput(JSON.stringify({"status": "success"}));

    var range = sheet.getRange(2, 1, lastRow - 1, 6);
    var values = range.getValues();
    var backgrounds = range.getBackgrounds();
    
    // Map: RowIndex -> {val, bg}
    var rowMap = {};
    for (var i = 0; i < values.length; i++) {
      rowMap[i + 2] = { "val": values[i], "bg": backgrounds[i] };
    }
    
    var newValues = [];
    var newBg = [];
    
    // Reconstruct based on new order
    for (var k = 0; k < indices.length; k++) {
      var idx = indices[k];
      if (rowMap[idx]) {
        newValues.push(rowMap[idx].val);
        newBg.push(rowMap[idx].bg);
        delete rowMap[idx];
      }
    }
    // Append leftovers (inactive/missing rows)
    for (var key in rowMap) {
      newValues.push(rowMap[key].val);
      newBg.push(rowMap[key].bg);
    }
    
    range.setValues(newValues);
    range.setBackgrounds(newBg);
    
    return ContentService.createTextOutput(JSON.stringify({"status": "success"}));
  }

  // --- ACTION: STATUS UPDATE ---
  var rowIndex = params.row;
  var action = params.status;
  var range = sheet.getRange(rowIndex, 1, 1, 6);
  
  if (action == "texted") range.setBackground("#ea9999");
  else range.setBackground("#b6d7a8");

  return ContentService.createTextOutput(JSON.stringify({"status": "success"}));
}
''';

void main() {
  runApp(const EggDeliveryApp());
}

class EggDeliveryApp extends StatelessWidget {
  const EggDeliveryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Egg Delivery',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const DeliveryListPage(),
    );
  }
}

class DeliveryStop {
  final String name;
  final String address;
  final String phone;
  final int dozens;
  final String notes;
  
  double? latitude;
  double? longitude;
  
  bool isCompleted; // Green
  bool isTexted;    // Red
  int originalRowIndex;

  DeliveryStop({
    required this.name,
    required this.address,
    required this.phone,
    required this.dozens,
    required this.notes,
    required this.originalRowIndex,
    this.latitude,
    this.longitude,
    this.isCompleted = false,
    this.isTexted = false,
  });
}

class DeliveryListPage extends StatefulWidget {
  const DeliveryListPage({super.key});

  @override
  State<DeliveryListPage> createState() => _DeliveryListPageState();
}

class _DeliveryListPageState extends State<DeliveryListPage> {
  List<DeliveryStop> stops = [];
  bool isLoading = false;
  String statusMessage = "";

  String scriptUrl = "";
  String messageTemplate = "";
  bool useWhatsApp = false;

  @override
  void initState() {
    super.initState();
    _loadSettingsAndFetch();
  }

  Future<void> _loadSettingsAndFetch() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      scriptUrl = prefs.getString('script_link') ?? "";
      messageTemplate = prefs.getString('msg_template') ?? "Hi! Your {dozens} dozen eggs have been delivered.";
      useWhatsApp = prefs.getBool('use_whatsapp') ?? false;
    });

    if (scriptUrl.isEmpty) {
      Future.delayed(Duration.zero, () => _navigateToSettings());
    } else {
      await fetchSpreadsheetData();
    }
  }

  // --- UPDATED FETCH: USES JSON FROM SCRIPT (READS COLORS) ---
  Future<void> fetchSpreadsheetData() async {
    if (scriptUrl.isEmpty) return;
    setState(() { isLoading = true; statusMessage = "Syncing with Sheet..."; });

    try {
      // We now GET from the Script URL, not the CSV
      final response = await http.get(Uri.parse(scriptUrl));
      
      if (response.statusCode == 200) {
        // Handle 302 Redirects manually if needed (Apps Script usually redirects)
        // Note: http package usually follows redirects automatically.
        
        // PARSE JSON
        List<dynamic> jsonList = jsonDecode(response.body);
        
        List<DeliveryStop> newStops = [];
        
        for (var row in jsonList) {
          // Parse Coordinates
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

          // Determine Status from Script
          String status = row['status'].toString(); // "complete", "texted", or "pending"
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

        // Ensure stops are sorted by their spreadsheet row order initially
        newStops.sort((a, b) => a.originalRowIndex.compareTo(b.originalRowIndex));

        setState(() { stops = newStops; isLoading = false; statusMessage = ""; });
      } else {
        throw Exception('Failed to connect to script');
      }
    } catch (e) {
      setState(() { isLoading = false; statusMessage = ""; });
      _showErrorSnackBar("Error syncing. Check Script URL.");
    }
  }

  Future<void> _markAsComplete(DeliveryStop stop) async {
    setState(() { stop.isCompleted = true; stop.isTexted = false; });
    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl), body: jsonEncode({
          "row": stop.originalRowIndex, "status": "complete"
        }));
      } catch (e) { /* silent fail */ }
    }
  }

  Future<void> _sendTextAndMarkRed(DeliveryStop stop) async {
    String message = messageTemplate.replaceAll("{dozens}", stop.dozens.toString());
    String cleanPhone = stop.phone.replaceAll(RegExp(r'[^\d+]'), '');
    Uri uri;
    if (useWhatsApp) {
      uri = Uri.parse("https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}");
    } else {
      uri = Uri(scheme: 'sms', path: cleanPhone, queryParameters: {'body': message});
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);

    setState(() { stop.isTexted = true; stop.isCompleted = true; });

    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl), body: jsonEncode({
          "row": stop.originalRowIndex, "status": "texted"
        }));
      } catch (e) { /* silent fail */ }
    }
  }

  Future<void> _launchFullRoute() async {
    if (stops.isEmpty) return;
    List<DeliveryStop> pendingStops = stops.where((s) => !s.isCompleted).toList();
    if (pendingStops.isEmpty) { _showErrorSnackBar("All deliveries completed!"); return; }

    int chunkSize = 10;
    List<List<DeliveryStop>> chunks = [];
    for (int i = 0; i < pendingStops.length; i += chunkSize) {
      chunks.add(pendingStops.sublist(i, i + chunkSize > pendingStops.length ? pendingStops.length : i + chunkSize));
    }

    if (chunks.length == 1) {
      _openMultiStopMap(chunks[0]);
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
                  title: Text("Part ${i + 1} (Stops ${i * chunkSize + 1} - ${(i * chunkSize) + chunks[i].length})"),
                  leading: const Icon(Icons.map),
                  onTap: () { Navigator.pop(context); _openMultiStopMap(chunks[i]); },
                )
            ],
          ),
        ),
      );
    }
  }

  Future<void> _openMultiStopMap(List<DeliveryStop> segment) async {
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
         if (segment[i].latitude != null) points.add("${segment[i].latitude},${segment[i].longitude}");
         else points.add(Uri.encodeComponent(segment[i].address));
      }
      url += "&waypoints=${points.join('|')}";
    }
    url += "&travelmode=driving";
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) _showErrorSnackBar("Could not open Maps");
  }

  Future<void> _optimizeRoute() async {
    if (stops.isEmpty) return;
    
    // Load Route Settings
    final prefs = await SharedPreferences.getInstance();
    bool useCurrentStart = prefs.getBool('use_current_start') ?? true;
    String startAddress = prefs.getString('start_address') ?? "";
    bool useEndAddress = prefs.getBool('use_end_address') ?? false;
    bool useCurrentEnd = prefs.getBool('use_current_end') ?? true;
    String endAddress = prefs.getString('end_address') ?? "";

    double? startLat, startLng;
    double? endLat, endLng;

    setState(() { isLoading = true; statusMessage = "Resolving Locations..."; });

    // 1. Resolve Start Location
    if (useCurrentStart) {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) { _showErrorSnackBar("Enable GPS for Start Location!"); setState(() => isLoading = false); return; }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) { setState(() => isLoading = false); return; }
      
      Position pos = await Geolocator.getCurrentPosition();
      startLat = pos.latitude; startLng = pos.longitude;
    } else {
      if (startAddress.isEmpty) { _showErrorSnackBar("Set Start Address in Settings"); setState(() => isLoading = false); return; }
      var coords = await _getCoordinatesFromAddress(startAddress);
      if (coords == null) { _showErrorSnackBar("Start Address not found"); setState(() => isLoading = false); return; }
      startLat = coords['lat']; startLng = coords['lng'];
    }

    // 2. Resolve End Location (if used)
    if (useEndAddress) {
      if (useCurrentEnd) {
        // If we just got GPS for start, reuse it (assuming round trip from current location)
        if (useCurrentStart && startLat != null) {
          endLat = startLat; endLng = startLng;
        } else {
          Position pos = await Geolocator.getCurrentPosition();
          endLat = pos.latitude; endLng = pos.longitude;
        }
      } else {
        if (endAddress.isEmpty) { _showErrorSnackBar("Set End Address in Settings"); setState(() => isLoading = false); return; }
        var coords = await _getCoordinatesFromAddress(endAddress);
        if (coords == null) { _showErrorSnackBar("End Address not found"); setState(() => isLoading = false); return; }
        endLat = coords['lat']; endLng = coords['lng'];
      }
    }

    List<DeliveryStop> activeStops = [];
    List<DeliveryStop> inactiveStops = [];
    for (var stop in stops) {
      if (!stop.isCompleted && stop.latitude != null && stop.longitude != null) activeStops.add(stop);
      else inactiveStops.add(stop);
    }
    if (activeStops.isEmpty) { setState(() { stops = inactiveStops; isLoading = false; }); _showErrorSnackBar("No active stops found."); return; }

    setState(() => statusMessage = "Optimizing...");
    
    // Allow UI to update
    await Future.delayed(const Duration(milliseconds: 50));

    // --- PRECOMPUTE DISTANCES (Optimization for Speed) ---
    // We try to fetch real-world "Drive Time" from OSRM API.
    // If that fails, we fall back to "Straight Line Distance".
    int n = activeStops.length;
    List<List<double>> distMatrix = List.generate(n, (_) => List.filled(n, 0.0));
    List<double> startDist = List.filled(n, 0.0);
    List<double> endDist = List.filled(n, 0.0); // Distance from Stop -> End
    bool usedApi = false;

    // 1. Try OSRM API (Time-based optimization)
    // OSRM Demo server has limits, so we only try if stops < 100
    if (n < 100) {
      try {
        setState(() => statusMessage = "Fetching Traffic Data...");
        List<String> coords = [];
        // OSRM expects "lng,lat"
        coords.add("$startLng,$startLat"); // Index 0: Start
        for (var s in activeStops) coords.add("${s.longitude},${s.latitude}");
        // If end address exists, add it as the last coordinate
        if (endLat != null) coords.add("$endLng,$endLat");

        String url = "https://router.project-osrm.org/table/v1/driving/${coords.join(';')}?annotations=duration";
        final response = await http.get(Uri.parse(url));

        if (response.statusCode == 200) {
          var data = jsonDecode(response.body);
          List<dynamic> durations = data['durations'];
          
          // Map OSRM matrix to our internal structures
          // durations indices: 0=Start, 1..N=Stops, N+1=End (if exists)
          for (int i = 0; i < n; i++) {
            startDist[i] = (durations[0][i + 1] as num).toDouble(); // From Current(0) to Stop(i+1)
            for (int j = 0; j < n; j++) {
              distMatrix[i][j] = (durations[i + 1][j + 1] as num).toDouble(); // From Stop(i+1) to Stop(j+1)
            }
            if (endLat != null) {
              endDist[i] = (durations[i + 1][n + 1] as num).toDouble(); // From Stop(i+1) to End(N+1)
            }
          }
          usedApi = true;
        }
      } catch (e) {
        // Silent fail, will use fallback
        print("OSRM API Failed: $e");
      }
    }

    // 2. Fallback to Haversine (Distance-based optimization)
    if (!usedApi) {
      setState(() => statusMessage = "Optimizing (Distance)...");
      for (int i = 0; i < n; i++) {
        startDist[i] = _calculateDistance(startLat!, startLng!, activeStops[i].latitude!, activeStops[i].longitude!);
        for (int j = 0; j < n; j++) {
          if (i == j) distMatrix[i][j] = 0.0;
          else distMatrix[i][j] = _calculateDistance(activeStops[i].latitude!, activeStops[i].longitude!, activeStops[j].latitude!, activeStops[j].longitude!);
        }
        if (endLat != null) endDist[i] = _calculateDistance(activeStops[i].latitude!, activeStops[i].longitude!, endLat, endLng!);
      }
    } else {
      setState(() => statusMessage = "Optimizing (Drive Time)...");
    }

    // Helper to calculate total distance of a permutation
    double getRouteDistance(List<int> indices) {
      if (indices.isEmpty) return 0.0;
      double total = startDist[indices[0]];
      for (int i = 0; i < indices.length - 1; i++) {
        total += distMatrix[indices[i]][indices[i+1]];
      }
      if (endLat != null) {
        total += endDist[indices.last];
      }
      return total;
    }

    // 1. Nearest Neighbor Construction (Initial Guess)
    List<int> currentIndices = [];
    Set<int> visited = {};
    int lastIndex = -1;
    
    for (int k = 0; k < n; k++) {
      int best = -1;
      double minD = double.infinity;
      for (int i = 0; i < n; i++) {
        if (!visited.contains(i)) {
          double d = (lastIndex == -1) ? startDist[i] : distMatrix[lastIndex][i];
          if (d < minD) { minD = d; best = i; }
        }
      }
      currentIndices.add(best);
      visited.add(best);
      lastIndex = best;
    }

    // 2. Heavy-Duty Simulated Annealing (Hybrid Genetic-Style)
    // To approach the "True Global Minimum", we use multiple restarts with
    // different initializations (Greedy vs Random) and a mix of move operators.
    Random random = Random();
    
    // Keep track of the absolute best found across all attempts
    List<int> globalBestIndices = List.from(currentIndices);
    double globalBestDist = getRouteDistance(currentIndices);
    
    // Configuration for "Deep" Search
    // We trade time for quality. 
    int maxRestarts = 20; 
    Stopwatch stopwatch = Stopwatch()..start();
    int timeLimitMillis = 4000; // Allow up to 4 seconds of pure crunching

    for (int attempt = 0; attempt < maxRestarts; attempt++) {
      // If we've spent too much time, stop restarting
      if (stopwatch.elapsedMilliseconds > timeLimitMillis) break;

      List<int> solverIndices;
      if (attempt == 0) {
        // Attempt 0: Start with Nearest Neighbor (Greedy)
        solverIndices = List.from(currentIndices);
      } else {
        // Other Attempts: Start with Random Shuffle (Diversity)
        // This ensures we explore completely different route structures.
        solverIndices = List.generate(n, (index) => index);
        solverIndices.shuffle(random);
      }

      double currentDist = getRouteDistance(solverIndices);
      double bestDistLocal = currentDist;
      List<int> bestIndicesLocal = List.from(solverIndices);

      double temperature = 150.0;
      double coolingRate = 0.9999; // Slower cooling for deeper search
      int maxIter = 500000;

      for (int i = 0; i < maxIter; i++) {
        if (temperature < 0.01) break;

        // Move Strategy:
        // 50% 2-Opt (Reverse Segment) - Untangles crossings
        // 40% Or-Opt (Relocate Block) - Fixes bad ordering/clustering
        // 10% Swap (Exchange 2 stops) - Perturbation
        double moveType = random.nextDouble();

        if (moveType < 0.5) {
          // --- 2-OPT (Reverse Segment) ---
          int p1 = random.nextInt(n);
          int p2 = random.nextInt(n);
          if (p1 == p2) continue;
          int start = min(p1, p2);
          int end = max(p1, p2);

          _reverseIndices(solverIndices, start, end);
          double newDist = getRouteDistance(solverIndices);
          
          if (newDist < currentDist || exp(-(newDist - currentDist) / temperature) > random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            _reverseIndices(solverIndices, start, end); // Revert
          }
        } else if (moveType < 0.9) {
          // --- OR-OPT (Relocate Block) ---
          // Move a block of 1 to 6 stops to a new location
          int blockSize = 1 + random.nextInt(6); 
          if (n < blockSize + 1) blockSize = 1;

          int itemIdx = random.nextInt(n - blockSize + 1);
          
          // Extract block
          List<int> block = [];
          for(int k=0; k<blockSize; k++) block.add(solverIndices[itemIdx + k]);
          
          // Remove block
          solverIndices.removeRange(itemIdx, itemIdx + blockSize);
          
          // Insert block at new random location
          int targetIdx = random.nextInt(solverIndices.length + 1);
          solverIndices.insertAll(targetIdx, block);

          double newDist = getRouteDistance(solverIndices);
          
          if (newDist < currentDist || exp(-(newDist - currentDist) / temperature) > random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            // Revert
            solverIndices.removeRange(targetIdx, targetIdx + blockSize);
            solverIndices.insertAll(itemIdx, block);
          }
        } else {
          // --- SWAP (Exchange Two Stops) ---
          int p1 = random.nextInt(n);
          int p2 = random.nextInt(n);
          if (p1 == p2) continue;
          
          int temp = solverIndices[p1];
          solverIndices[p1] = solverIndices[p2];
          solverIndices[p2] = temp;
          
          double newDist = getRouteDistance(solverIndices);
          
          if (newDist < currentDist || exp(-(newDist - currentDist) / temperature) > random.nextDouble()) {
            currentDist = newDist;
            if (currentDist < bestDistLocal) {
              bestDistLocal = currentDist;
              bestIndicesLocal = List.from(solverIndices);
            }
          } else {
            // Revert
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
    
    // Reconstruct the stop list from the best result across all restarts
    List<DeliveryStop> optimizedStops = globalBestIndices.map((i) => activeStops[i]).toList();
    
    setState(() { stops = [...optimizedStops, ...inactiveStops]; isLoading = false; statusMessage = ""; });
    _showErrorSnackBar("Route Optimized! 🚀");
  }

  Future<void> _syncOrderToSheet() async {
    if (scriptUrl.isEmpty) return;
    setState(() { isLoading = true; statusMessage = "Updating Sheet..."; });
    try {
      // Send the list of original row indices in their current (optimized) order
      List<int> indices = stops.map((s) => s.originalRowIndex).toList();
      
      await http.post(Uri.parse(scriptUrl), body: jsonEncode({
        "action": "reorder", "indices": indices
      }));
      
      // Update local indices since sheet is now reordered (Rows start at 2)
      for (int i = 0; i < stops.length; i++) stops[i].originalRowIndex = i + 2;
      
      _showErrorSnackBar("Spreadsheet updated! 📄");
    } catch (e) {
      _showErrorSnackBar("Update failed. Check Script.");
    } finally {
      setState(() { isLoading = false; statusMessage = ""; });
    }
  }

  void _resetRouteOrder() {
    setState(() {
      stops.sort((a, b) => a.originalRowIndex.compareTo(b.originalRowIndex));
    });
    _showErrorSnackBar("Route reset to spreadsheet order.");
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
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    var p = 0.017453292519943295;
    var c = cos;
    var a = 0.5 - c((lat2 - lat1) * p) / 2 + c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * asin(sqrt(a));
  }

  Future<Map<String, double>?> _getCoordinatesFromAddress(String address) async {
    try {
      final url = Uri.parse("https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1");
      final response = await http.get(url, headers: {'User-Agent': 'EggDeliveryApp/1.0'});
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List && data.isNotEmpty) {
          return {'lat': double.parse(data[0]['lat']), 'lng': double.parse(data[0]['lon'])};
        }
      }
    } catch (e) { /* ignore */ }
    return null;
  }

  void _navigateToSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsPage()));
    _loadSettingsAndFetch();
  }
  void _showErrorSnackBar(String message) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2))); }
  Future<void> _openMap(String address, double? lat, double? lng) async {
    String googleUrl = (lat != null && lng != null) ? "https://www.google.com/maps/search/?api=1&query=$lat,$lng?q=$lat,$lng" : "https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}";
    if (!await launchUrl(Uri.parse(googleUrl), mode: LaunchMode.externalApplication)) _showErrorSnackBar('Could not open Maps');
  }
  String _formatPhone(String phone) {
    String digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) digits = digits.substring(digits.length - 10);
    if (digits.length == 10) return "(${digits.substring(0, 3)})-${digits.substring(3, 6)}-${digits.substring(6)}";
    return phone; 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Egg Run 🥚', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.teal[100],
        actions: [
          IconButton(icon: const Icon(Icons.save_alt), onPressed: _syncOrderToSheet, tooltip: "Save Order to Sheet"),
          IconButton(icon: const Icon(Icons.restore), onPressed: _resetRouteOrder, tooltip: "Reset Order"),
          IconButton(icon: const Icon(Icons.auto_awesome), onPressed: _optimizeRoute),
          IconButton(
            icon: const Icon(Icons.refresh), 
            onPressed: () { setState(() { stops = []; isLoading = true; statusMessage = "Syncing..."; }); fetchSpreadsheetData(); }
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: _navigateToSettings)
        ],
      ),
      body: Stack(
        children: [
          stops.isEmpty && !isLoading ? Center(child: ElevatedButton(onPressed: _navigateToSettings, child: const Text("Set up Script in Settings"))) : Column(
            children: [
              if (stops.isNotEmpty) Container(width: double.infinity, padding: const EdgeInsets.all(8.0), color: Colors.teal[50], child: ElevatedButton.icon(icon: const Icon(Icons.navigation), label: const Text("START NAVIGATION (ALL STOPS)"), style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)), onPressed: _launchFullRoute)),
              Expanded(child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80), itemCount: stops.length, itemBuilder: (context, index) {
                  final stop = stops[index];
                  Color bgColor = Colors.white; Color borderColor = Colors.transparent; Color avatarColor = Colors.teal; Color textColor = Colors.black87;
                  if (stop.isTexted) { bgColor = Colors.red[50]!; borderColor = Colors.red.shade300; avatarColor = Colors.red; textColor = Colors.grey; }
                  else if (stop.isCompleted) { bgColor = Colors.green[50]!; borderColor = Colors.green.shade300; avatarColor = Colors.green; textColor = Colors.grey; }
                  return Card(
                    elevation: 2, color: bgColor, margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: (stop.isTexted || stop.isCompleted) ? BorderSide(color: borderColor, width: 2) : BorderSide.none),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10), child: Column(children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(padding: const EdgeInsets.only(top: 4.0), child: CircleAvatar(radius: 12, backgroundColor: avatarColor, child: Text("${index + 1}", style: const TextStyle(color: Colors.white, fontSize: 11)))),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          InkWell(onTap: () => _openMap(stop.address, stop.latitude, stop.longitude), child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Flexible(fit: FlexFit.loose, child: Text(stop.address, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: textColor, height: 1.1))), const Padding(padding: EdgeInsets.only(left: 4.0), child: Icon(Icons.map, size: 20, color: Colors.blueAccent))])),
                          const SizedBox(height: 8),
                          Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.orange.shade200)), child: Text("${stop.dozens} DOZEN", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.deepOrange))), const SizedBox(width: 8), Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(children: [InkWell(onTap: () => _sendTextAndMarkRed(stop), child: Row(children: [const Icon(Icons.message, size: 16, color: Colors.blueGrey), const SizedBox(width: 4), Text(_formatPhone(stop.phone), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.blueGrey, decoration: TextDecoration.underline, decorationStyle: TextDecorationStyle.dotted))])), const SizedBox(width: 8), Text(stop.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor))])) )])
                        ])),
                        IconButton(iconSize: 40, padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: Icon(Icons.check_circle, color: (stop.isCompleted && !stop.isTexted) ? Colors.green : Colors.grey[300]), onPressed: () => _markAsComplete(stop))
                      ]),
                      if (stop.notes.isNotEmpty) Container(margin: const EdgeInsets.only(top: 10), padding: const EdgeInsets.all(8), width: double.infinity, decoration: BoxDecoration(color: Colors.yellow[100], borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.yellow.shade600, width: 0.5)), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18), const SizedBox(width: 6), Expanded(child: Text(stop.notes, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)))]))
                    ]))
                  );
                }))
            ]
          ),
          if (isLoading) Container(color: Colors.black54, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(color: Colors.white), const SizedBox(height: 16), Text(statusMessage, style: const TextStyle(color: Colors.white, fontSize: 18))]))),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget { const SettingsPage({super.key}); @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> {
  final _scriptController = TextEditingController(); 
  final _msgController = TextEditingController(); 
  bool _useWhatsApp = false;
  
  // Route Settings
  bool _useCurrentStart = true;
  final _startAddrController = TextEditingController();
  bool _useEndAddress = false;
  bool _useCurrentEnd = true;
  final _endAddrController = TextEditingController();

  @override void initState() { super.initState(); _loadCurrentSettings(); }
  Future<void> _loadCurrentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { 
      _scriptController.text = prefs.getString('script_link') ?? ""; 
      _msgController.text = prefs.getString('msg_template') ?? "Hi! Your {dozens} dozen eggs have been delivered."; 
      _useWhatsApp = prefs.getBool('use_whatsapp') ?? false;
      _useCurrentStart = prefs.getBool('use_current_start') ?? true;
      _startAddrController.text = prefs.getString('start_address') ?? "";
      _useEndAddress = prefs.getBool('use_end_address') ?? false;
      _useCurrentEnd = prefs.getBool('use_current_end') ?? true;
      _endAddrController.text = prefs.getString('end_address') ?? "";
    });
  }
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('script_link', _scriptController.text.trim()); 
      await prefs.setString('msg_template', _msgController.text); 
      await prefs.setBool('use_whatsapp', _useWhatsApp);
      
      await prefs.setBool('use_current_start', _useCurrentStart);
      await prefs.setString('start_address', _startAddrController.text.trim());
      await prefs.setBool('use_end_address', _useEndAddress);
      await prefs.setBool('use_current_end', _useCurrentEnd);
      await prefs.setString('end_address', _endAddrController.text.trim());

      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Settings Saved!"), backgroundColor: Colors.green)); Navigator.pop(context); }
    } catch (e) { if (mounted) showDialog(context: context, builder: (context) => AlertDialog(title: const Text("Error"), content: Text(e.toString()), actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: const Text("OK"))])); }
  }
  void _showHelp(String title, String content) { showDialog(context: context, builder: (context) => AlertDialog(title: Text(title, style: const TextStyle(color: Colors.teal)), content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 16))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))])); }
  void _copyScript() { Clipboard.setData(ClipboardData(text: _googleScriptCode)).then((_) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Script copied to clipboard! 📋"))); }); }
  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: Padding(padding: const EdgeInsets.all(16.0), child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: TextButton.icon(onPressed: () => _showHelp("Spreadsheet Format", "A: Name\nB: Address\nC: Phone\nD: Dozens\nE: Notes\nF: Coordinates\n"), icon: const Icon(Icons.table_chart), label: const Text("View Required Sheet Format"))),
          const Divider(), const SizedBox(height: 10),
          Row(children: [const Text("1. Google Script URL", style: TextStyle(fontWeight: FontWeight.bold)), IconButton(icon: const Icon(Icons.help_outline, color: Colors.blue), onPressed: () => _showHelp("How to set up Script", "1. Make your Google Sheet according to required format\n2. Extensions > Apps Script.\n3. Paste code (Copy button ->).\n4. Deploy > New deployment > Web app.\n5. Access: 'Anyone'.\n6. Deploy & Copy URL.")), TextButton.icon(onPressed: _copyScript, icon: const Icon(Icons.copy, size: 16), label: const Text("COPY SCRIPT"), style: TextButton.styleFrom(foregroundColor: Colors.teal, textStyle: const TextStyle(fontWeight: FontWeight.bold)))]),
          TextField(controller: _scriptController, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "https://script.google.com/..."), maxLines: 2),
          const SizedBox(height: 20), const Text("2. Message Template", style: TextStyle(fontWeight: FontWeight.bold)), TextField(controller: _msgController, decoration: const InputDecoration(border: OutlineInputBorder()), maxLines: 2),
          const SizedBox(height: 20), SwitchListTile(title: const Text("Use WhatsApp"), value: _useWhatsApp, onChanged: (val) => setState(() => _useWhatsApp = val)),
          
          const Divider(), const SizedBox(height: 10),
          const Text("3. Route Optimization", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          const Text("Start Location:", style: TextStyle(fontWeight: FontWeight.bold)),
          CheckboxListTile(title: const Text("Use Current Address as Start"), value: _useCurrentStart, onChanged: (val) => setState(() => _useCurrentStart = val!)),
          if (!_useCurrentStart) TextField(controller: _startAddrController, decoration: const InputDecoration(labelText: "Start Address", border: OutlineInputBorder())),
          
          const SizedBox(height: 10),
          const Text("End Location:", style: TextStyle(fontWeight: FontWeight.bold)),
          CheckboxListTile(title: const Text("Use End Address"), value: _useEndAddress, onChanged: (val) => setState(() => _useEndAddress = val!)),
          if (_useEndAddress) ...[
            CheckboxListTile(title: const Text("Use Current Address as End"), value: _useCurrentEnd, onChanged: (val) => setState(() => _useCurrentEnd = val!)),
            if (!_useCurrentEnd) TextField(controller: _endAddrController, decoration: const InputDecoration(labelText: "End Address", border: OutlineInputBorder())),
          ],

          const SizedBox(height: 30), SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saveSettings, child: const Text("SAVE SETTINGS"))),
      ]))),
    );
  }
}