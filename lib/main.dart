import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Needed for Clipboard
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' show cos, sqrt, asin, min, max, exp, Random;

// --- THE GOOGLE APPS SCRIPT CODE TO COPY ---
const String _googleScriptCode = r'''
function doPost(e) {
  var params = JSON.parse(e.postData.contents);
  var rowIndex = params.row;
  var action = params.status;

  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("Sheet1"); 
  
  // Highlight Columns A to F (1 to 6)
  var range = sheet.getRange(rowIndex, 1, 1, 6);
  
  if (action == "texted") {
    range.setBackground("#ea9999"); // Light Red
  } else {
    range.setBackground("#b6d7a8"); // Light Green
  }

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

// --- DATA MODEL ---
class DeliveryStop {
  final String name;
  final String address;
  final String phone;
  final int dozens;
  final String notes;
  
  double? latitude;
  double? longitude;
  
  bool isCompleted; // Green Status
  bool isTexted;    // Red Status
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

  String sheetUrl = "";
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
      sheetUrl = prefs.getString('sheet_link') ?? "";
      scriptUrl = prefs.getString('script_link') ?? "";
      messageTemplate = prefs.getString('msg_template') ?? "Hi! Your {dozens} dozen eggs have been delivered.";
      useWhatsApp = prefs.getBool('use_whatsapp') ?? false;
    });

    if (sheetUrl.isEmpty) {
      Future.delayed(Duration.zero, () => _navigateToSettings());
    } else {
      await fetchSpreadsheetData();
    }
  }

  Future<void> fetchSpreadsheetData() async {
    if (sheetUrl.isEmpty) return;
    setState(() { isLoading = true; statusMessage = "Loading Sheet..."; });

    try {
      final response = await http.get(Uri.parse(sheetUrl));
      if (response.statusCode == 200) {
        List<List<dynamic>> csvTable = const CsvToListConverter().convert(response.body);
        if (csvTable.isNotEmpty) csvTable.removeAt(0); 

        List<DeliveryStop> newStops = [];
        for (int i = 0; i < csvTable.length; i++) {
          var row = csvTable[i];
          if (row.length < 4) continue;

          double? lat;
          double? lng;
          if (row.length > 5) {
            String coordRaw = row[5].toString();
            coordRaw = coordRaw.replaceAll('/', '').trim();
            List<String> parts = coordRaw.split(',');
            if (parts.length == 2) {
              lat = double.tryParse(parts[0].trim());
              lng = double.tryParse(parts[1].trim());
            }
          }

          newStops.add(DeliveryStop(
            name: row[0].toString(),
            address: row[1].toString(),
            phone: row[2].toString(),
            dozens: int.tryParse(row[3].toString()) ?? 0,
            notes: row.length > 4 ? row[4].toString() : "",
            originalRowIndex: i + 2,
            latitude: lat,
            longitude: lng,
          ));
        }

        setState(() { stops = newStops; isLoading = false; statusMessage = ""; });
      } else {
        throw Exception('Failed to load sheet');
      }
    } catch (e) {
      setState(() { isLoading = false; statusMessage = ""; });
      _showErrorSnackBar("Error loading data. Check link.");
    }
  }

  Future<void> _markAsComplete(DeliveryStop stop) async {
    setState(() { 
      stop.isCompleted = true; 
      stop.isTexted = false; 
    });
    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl), body: jsonEncode({
          "row": stop.originalRowIndex,
          "status": "complete"
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

    setState(() {
      stop.isTexted = true;     
      stop.isCompleted = true;  
    });

    if (scriptUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse(scriptUrl), body: jsonEncode({
          "row": stop.originalRowIndex,
          "status": "texted"
        }));
      } catch (e) { /* silent fail */ }
    }
  }

  Future<void> _launchFullRoute() async {
    if (stops.isEmpty) return;
    List<DeliveryStop> pendingStops = stops.where((s) => !s.isCompleted).toList();
    
    if (pendingStops.isEmpty) {
      _showErrorSnackBar("All deliveries completed!");
      return;
    }

    int chunkSize = 9; 
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
                  onTap: () {
                    Navigator.pop(context);
                    _openMultiStopMap(chunks[i]);
                  },
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
      _showErrorSnackBar("Could not open Maps");
    }
  }

  Future<void> _optimizeRoute() async {
    if (stops.isEmpty) return;
    
    setState(() { isLoading = true; statusMessage = "Getting GPS..."; });
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showErrorSnackBar("Enable GPS first!");
      setState(() => isLoading = false);
      return;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
         setState(() => isLoading = false);
         return;
      }
    }
    Position currentPos = await Geolocator.getCurrentPosition();

    List<DeliveryStop> activeStops = [];
    List<DeliveryStop> inactiveStops = [];
    
    for (var stop in stops) {
      if (!stop.isCompleted && stop.latitude != null && stop.longitude != null) {
        activeStops.add(stop);
      } else {
        inactiveStops.add(stop);
      }
    }

    if (activeStops.isEmpty) {
       setState(() { stops = inactiveStops; isLoading = false; });
       _showErrorSnackBar("No active stops with coordinates found.");
       return;
    }

    setState(() => statusMessage = "Rough sorting...");
    List<DeliveryStop> currentPath = [];
    List<DeliveryStop> pool = List.from(activeStops);
    double currLat = currentPos.latitude;
    double currLng = currentPos.longitude;

    while (pool.isNotEmpty) {
      int bestIndex = -1;
      double minDistance = double.infinity;
      for (int i = 0; i < pool.length; i++) {
        double d = _calculateDistance(currLat, currLng, pool[i].latitude!, pool[i].longitude!);
        if (d < minDistance) {
          minDistance = d;
          bestIndex = i;
        }
      }
      currentPath.add(pool[bestIndex]);
      currLat = pool[bestIndex].latitude!;
      currLng = pool[bestIndex].longitude!;
      pool.removeAt(bestIndex);
    }

    setState(() => statusMessage = "Optimizing...");
    double temperature = 1000.0;
    double coolingRate = 0.9995;
    double absoluteTemperature = 0.00001;
    
    List<DeliveryStop> bestPath = List.from(currentPath);
    double bestDistance = _calculateTotalDistance(bestPath, currentPos);
    double currentDistance = bestDistance;
    Random random = Random();

    int iteration = 0;
    while (temperature > absoluteTemperature && iteration < 50000) {
      iteration++;
      int index1 = random.nextInt(currentPath.length);
      int index2 = random.nextInt(currentPath.length);
      if (index1 == index2) continue;

      int start = min(index1, index2);
      int end = max(index1, index2);
      
      _reverseSegment(currentPath, start, end);
      double newDistance = _calculateTotalDistance(currentPath, currentPos);
      double energyDelta = newDistance - currentDistance;
      
      if (energyDelta < 0 || exp(-energyDelta / temperature) > random.nextDouble()) {
        currentDistance = newDistance;
        if (currentDistance < bestDistance) {
          bestDistance = currentDistance;
          bestPath = List.from(currentPath);
        }
      } else {
        _reverseSegment(currentPath, start, end);
      }
      temperature *= coolingRate;
    }

    setState(() {
      stops = [...bestPath, ...inactiveStops];
      isLoading = false;
      statusMessage = "";
    });
    _showErrorSnackBar("Route Optimized! 🚀");
  }
  
  void _reverseSegment(List<DeliveryStop> path, int i, int k) {
    while (i < k) {
      var temp = path[i];
      path[i] = path[k];
      path[k] = temp;
      i++;
      k--;
    }
  }

  double _calculateTotalDistance(List<DeliveryStop> path, Position start) {
    if (path.isEmpty) return 0.0;
    double total = 0;
    total += _calculateDistance(start.latitude, start.longitude, path[0].latitude!, path[0].longitude!);
    for (int i = 0; i < path.length - 1; i++) {
      total += _calculateDistance(path[i].latitude!, path[i].longitude!, path[i+1].latitude!, path[i+1].longitude!);
    }
    return total;
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    var p = 0.017453292519943295;
    var c = cos;
    var a = 0.5 - c((lat2 - lat1) * p) / 2 + c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
    return 12742 * asin(sqrt(a));
  }

  void _navigateToSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsPage()));
    _loadSettingsAndFetch();
  }

  void _showErrorSnackBar(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _openMap(String address, double? lat, double? lng) async {
    String googleUrl = "";
    if (lat != null && lng != null) {
      googleUrl = "https://www.google.com/maps/search/?api=1&query=$lat,$lng?q=$lat,$lng";
    } else {
      googleUrl = "https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}";
    }
    if (!await launchUrl(Uri.parse(googleUrl), mode: LaunchMode.externalApplication)) {
      _showErrorSnackBar('Could not open Maps');
    }
  }

  String _formatPhone(String phone) {
    String digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) {
      digits = digits.substring(digits.length - 10);
    }
    if (digits.length == 10) {
      return "(${digits.substring(0, 3)})-${digits.substring(3, 6)}-${digits.substring(6)}";
    }
    return phone; 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Egg Run 🥚', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.teal[100],
        actions: [
          IconButton(icon: const Icon(Icons.auto_awesome), onPressed: _optimizeRoute),
          IconButton(
            icon: const Icon(Icons.refresh), 
            onPressed: () {
              setState(() { stops = []; isLoading = true; statusMessage = "Reloading..."; });
              fetchSpreadsheetData();
            }
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: _navigateToSettings)
        ],
      ),
      body: Stack(
        children: [
          stops.isEmpty && !isLoading
              ? Center(
                  child: ElevatedButton(
                    onPressed: _navigateToSettings,
                    child: const Text("Set up Links in Settings"),
                  ),
                )
              : Column(
                children: [
                  if (stops.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8.0),
                      color: Colors.teal[50],
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.navigation),
                        label: const Text("START NAVIGATION (ALL STOPS)"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _launchFullRoute,
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount: stops.length,
                        itemBuilder: (context, index) {
                          final stop = stops[index];
                          
                          Color bgColor = Colors.white;
                          Color borderColor = Colors.transparent;
                          Color avatarColor = Colors.teal;
                          Color textColor = Colors.black87;

                          if (stop.isTexted) {
                            bgColor = Colors.red[50]!;
                            borderColor = Colors.red.shade300;
                            avatarColor = Colors.red;
                            textColor = Colors.grey;
                          } else if (stop.isCompleted) {
                            bgColor = Colors.green[50]!;
                            borderColor = Colors.green.shade300;
                            avatarColor = Colors.green;
                            textColor = Colors.grey;
                          }

                          return Card(
                            elevation: 2,
                            color: bgColor,
                            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: (stop.isTexted || stop.isCompleted) 
                                ? BorderSide(color: borderColor, width: 2) 
                                : BorderSide.none
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                              child: Column(
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4.0),
                                        child: CircleAvatar(
                                          radius: 12,
                                          backgroundColor: avatarColor,
                                          child: Text("${index + 1}", style: const TextStyle(color: Colors.white, fontSize: 11)),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // ADDRESS WITH ICON NEXT TO IT
                                            InkWell(
                                              onTap: () => _openMap(stop.address, stop.latitude, stop.longitude),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Flexible(
                                                    fit: FlexFit.loose,
                                                    child: Text(
                                                      stop.address,
                                                      style: TextStyle(
                                                        fontSize: 20, 
                                                        fontWeight: FontWeight.w900,
                                                        color: textColor,
                                                        height: 1.1,
                                                      ),
                                                    ),
                                                  ),
                                                  const Padding(
                                                    padding: EdgeInsets.only(left: 4.0),
                                                    child: Icon(Icons.map, size: 20, color: Colors.blueAccent),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            
                                            const SizedBox(height: 8),
                                            
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.orange[50],
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: Colors.orange.shade200)
                                                  ),
                                                  child: Text(
                                                    "${stop.dozens} DOZ",
                                                    style: const TextStyle(
                                                      fontSize: 14, 
                                                      fontWeight: FontWeight.bold,
                                                      color: Colors.deepOrange,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 15),

                                                InkWell(
                                                  onTap: () => _sendTextAndMarkRed(stop),
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.message, size: 16, color: Colors.blueGrey),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        _formatPhone(stop.phone),
                                                        style: const TextStyle(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w600,
                                                          color: Colors.blueGrey,
                                                          decoration: TextDecoration.underline,
                                                          decorationStyle: TextDecorationStyle.dotted
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),

                                      IconButton(
                                        iconSize: 40,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: Icon(
                                          Icons.check_circle, 
                                          color: (stop.isCompleted && !stop.isTexted) ? Colors.green : Colors.grey[300]
                                        ),
                                        onPressed: () => _markAsComplete(stop),
                                      )
                                    ],
                                  ),

                                  if (stop.notes.isNotEmpty) 
                                    Container(
                                      margin: const EdgeInsets.only(top: 10),
                                      padding: const EdgeInsets.all(8),
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: Colors.yellow[100],
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.yellow.shade600, width: 0.5)
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              stop.notes,
                                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ),
                ],
              ),
          if (isLoading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(statusMessage, style: const TextStyle(color: Colors.white, fontSize: 18))
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- SETTINGS PAGE WITH HELP & COPY ---
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _urlController = TextEditingController();
  final _scriptController = TextEditingController();
  final _msgController = TextEditingController();
  bool _useWhatsApp = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
  }

  Future<void> _loadCurrentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlController.text = prefs.getString('sheet_link') ?? "";
      _scriptController.text = prefs.getString('script_link') ?? "";
      _msgController.text = prefs.getString('msg_template') ?? "Hi! Your {dozens} dozen eggs have been delivered.";
      _useWhatsApp = prefs.getBool('use_whatsapp') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sheet_link', _urlController.text.trim());
      await prefs.setString('script_link', _scriptController.text.trim());
      await prefs.setString('msg_template', _msgController.text);
      await prefs.setBool('use_whatsapp', _useWhatsApp);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Settings Saved!"), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showDialog(context: context, builder: (context) => AlertDialog(
          title: const Text("Error"), content: Text(e.toString()), actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: const Text("OK"))]
        ));
      }
    }
  }

  void _showHelp(String title, String content) {
    showDialog(
      context: context, 
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(color: Colors.teal)),
        content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 16))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
      )
    );
  }

  // --- COPY SCRIPT FUNCTION ---
  void _copyScript() {
    Clipboard.setData(ClipboardData(text: _googleScriptCode)).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Script copied to clipboard! 📋"))
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: TextButton.icon(
                  onPressed: () => _showHelp("Spreadsheet Format", 
                    "Ensure your Google Sheet columns are in this exact order:\n\n"
                    "A: Name\n"
                    "B: Address\n"
                    "C: Phone Number\n"
                    "D: Dozens (Number only)\n"
                    "E: Notes\n"
                    "F: Coordinates (lat, lng)\n\n"
                    "Do not skip columns!"
                  ),
                  icon: const Icon(Icons.table_chart),
                  label: const Text("View Required Sheet Format"),
                ),
              ),
              const Divider(),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text("1. Google Sheet CSV Link", style: TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.help_outline, color: Colors.blue),
                    onPressed: () => _showHelp("How to get CSV Link",
                      "1. Open your Google Sheet.\n"
                      "2. Click 'File' > 'Share' > 'Publish to web'.\n"
                      "3. In the dropdown, select 'Sheet1'.\n"
                      "4. Select 'Comma-separated values (.csv)'.\n"
                      "5. Click Publish & Copy Link."
                    ),
                  )
                ],
              ),
              TextField(controller: _urlController, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "https://docs.google.com/...output=csv"), maxLines: 2),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text("2. Google Script Web App URL", style: TextStyle(fontWeight: FontWeight.bold)),
                  // HELP BUTTON
                  IconButton(
                    icon: const Icon(Icons.help_outline, color: Colors.blue),
                    onPressed: () => _showHelp("How to set up Script",
                      "1. Extensions > Apps Script.\n"
                      "2. Paste code (Copy button ->).\n"
                      "3. Deploy > New deployment > Web app.\n"
                      "4. 'Who has access': 'Anyone'.\n"
                      "5. Deploy & Copy URL."
                    ),
                  ),
                  // COPY SCRIPT BUTTON
                  TextButton.icon(
                    onPressed: _copyScript,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text("COPY SCRIPT"),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.teal,
                      textStyle: const TextStyle(fontWeight: FontWeight.bold)
                    ),
                  ),
                ],
              ),
              TextField(controller: _scriptController, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "https://script.google.com/..."), maxLines: 2),
              const SizedBox(height: 20),
              const Text("3. Message Template", style: TextStyle(fontWeight: FontWeight.bold)),
              TextField(controller: _msgController, decoration: const InputDecoration(border: OutlineInputBorder()), maxLines: 2),
              const SizedBox(height: 20),
              SwitchListTile(title: const Text("Use WhatsApp"), value: _useWhatsApp, onChanged: (val) => setState(() => _useWhatsApp = val)),
              const SizedBox(height: 30),
              SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saveSettings, child: const Text("SAVE SETTINGS"))),
            ],
          ),
        ),
      ),
    );
  }
}