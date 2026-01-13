import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/delivery_stop.dart';
import '../services/route_optimizer.dart';
import '../services/sheets_service.dart';
import '../utils/helpers.dart';
import 'settings_page.dart';

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
  bool _isDarkMode = false;

  late SheetsService _sheetsService;
  final RouteOptimizer _routeOptimizer = RouteOptimizer();

  @override
  void initState() {
    super.initState();
    _loadSettingsAndFetch();
  }

  Future<void> _loadSettingsAndFetch() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      scriptUrl = prefs.getString('script_link') ?? "";
      messageTemplate = prefs.getString('msg_template') ??
          "Hi! Your {dozens} dozen eggs have been delivered.";
      useWhatsApp = prefs.getBool('use_whatsapp') ?? false;
      _isDarkMode = prefs.getBool('is_dark_mode') ?? false;
    });

    if (scriptUrl.isEmpty) {
      // Script URL is missing; UI will display the setup button.
    } else {
      _sheetsService = SheetsService(scriptUrl);
      await _fetchData();
    }
  }

  Future<void> _fetchData() async {
    if (scriptUrl.isEmpty) return;

    setState(() {
      isLoading = true;
      statusMessage = "Syncing with Sheet...";
    });

    try {
      final newStops = await _sheetsService.fetchSpreadsheetData();
      if (!mounted) return;
      setState(() {
        stops = newStops;
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, "Error syncing. Check Script URL.");
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          statusMessage = "";
        });
      }
    }
  }

  Future<void> _markAsComplete(DeliveryStop stop) async {
    setState(() {
      stop.isCompleted = true;
      stop.isTexted = false;
    });
    await _sheetsService.markAsComplete(stop.originalRowIndex);
  }

  Future<void> _sendTextAndMarkRed(DeliveryStop stop) async {
    String message =
        messageTemplate.replaceAll("{dozens}", stop.dozens.toString());
    String cleanPhone = stop.phone.replaceAll(RegExp(r'[^\d+]'), '');
    Uri uri;
    if (useWhatsApp) {
      uri = Uri.parse(
          "https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}");
    } else {
      uri =
          Uri(scheme: 'sms', path: cleanPhone, queryParameters: {'body': message});
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!mounted) return;
    setState(() {
      stop.isTexted = true;
      stop.isCompleted = true;
    });

    await _sheetsService.markAsTexted(stop.originalRowIndex);
  }



  Future<void> _optimizeRoute() async {
    setState(() {
      isLoading = true;
    });
    try {
      final optimizedStops = await _routeOptimizer.optimizeRoute(
        stops,
        (message) {
          if (mounted) setState(() => statusMessage = message);
        },
        (message) {
          if (mounted) showErrorSnackBar(context, message);
        },
      );
      if (!mounted) return;
      setState(() {
        stops = optimizedStops;
      });
      showErrorSnackBar(context, "Route Optimized! 🚀");
    } catch (e) {
      // Error is already shown by the onError callback
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          statusMessage = "";
        });
      }
    }
  }

  Future<void> _syncOrderToSheet() async {
    if (scriptUrl.isEmpty) return;
    setState(() {
      isLoading = true;
      statusMessage = "Updating Sheet...";
    });
    try {
      await _sheetsService.syncOrderToSheet(stops);
      for (int i = 0; i < stops.length; i++) {
        stops[i].originalRowIndex = i + 2;
      }
      if (mounted) showErrorSnackBar(context, "Spreadsheet updated! 📄");
    } catch (e) {
      if (mounted) showErrorSnackBar(context, "Update failed. Check Script.");
    } finally {
      setState(() {
        isLoading = false;
        statusMessage = "";
      });
    }
  }

  void _resetRouteOrder() {
    setState(() {
      stops.sort((a, b) => a.originalRowIndex.compareTo(b.originalRowIndex));
    });
    showErrorSnackBar(context, "Route reset to spreadsheet order.");
  }

  void _navigateToSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (context) => const SettingsPage()));
    _loadSettingsAndFetch();
  }

  Future<void> _openMap(String address, double? lat, double? lng) async {
    String googleUrl = (lat != null && lng != null)
        ? "https://www.google.com/maps/search/?api=1&query=$lat,$lng"
        : "https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}";
    if (!await launchUrl(Uri.parse(googleUrl),
        mode: LaunchMode.externalApplication)) {
      if (mounted) showErrorSnackBar(context, 'Could not open Maps');
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
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.white,
      appBar: AppBar(
        title: const Text('Egg Run 🥚',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _isDarkMode ? Colors.grey[850] : Colors.teal[100],
        foregroundColor: _isDarkMode ? Colors.white : Colors.black,
        actions: [
          IconButton(
              icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode),
              onPressed: () async {
                setState(() => _isDarkMode = !_isDarkMode);
                final prefs = await SharedPreferences.getInstance();
                prefs.setBool('is_dark_mode', _isDarkMode);
              },
              tooltip: "Toggle Theme"),
          IconButton(
              icon: const Icon(Icons.save_alt),
              onPressed: _syncOrderToSheet,
              tooltip: "Save Order to Sheet"),
          IconButton(
              icon: const Icon(Icons.restore),
              onPressed: _resetRouteOrder,
              tooltip: "Reset Order"),
          IconButton(
              icon: const Icon(Icons.auto_awesome), onPressed: _optimizeRoute),
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() {
                  stops = [];
                });
                _fetchData();
              }),
          IconButton(
              icon: const Icon(Icons.settings), onPressed: _navigateToSettings)
        ],
      ),
      body: Stack(
        children: [
          stops.isEmpty && !isLoading
              ? Center(
                  child: ElevatedButton(
                      onPressed: _navigateToSettings,
                      child: const Text("Set up Script in Settings")))
              : Column(children: [
                  if (stops.isNotEmpty)
                    Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8.0),
                        color: _isDarkMode ? Colors.grey[800] : Colors.teal[50],
                        child: ElevatedButton.icon(
                            icon: const Icon(Icons.navigation),
                            label: const Text("START NAVIGATION (ALL STOPS)"),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12)),
                            onPressed: () => launchFullRoute(context, stops))),
                  Expanded(
                      child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: stops.length,
                          itemBuilder: (context, index) {
                            final stop = stops[index];
                            return DeliveryStopCard(
                              stop: stop,
                              index: index,
                              onMarkAsComplete: _markAsComplete,
                              onSendText: _sendTextAndMarkRed,
                              openMap: _openMap,
                              formatPhone: _formatPhone,
                              isDarkMode: _isDarkMode,
                            );
                          }))
                ]),
          if (isLoading)
            Container(
                color: Colors.black54,
                child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(statusMessage,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 18))
                ]))),
        ],
      ),
    );
  }
}

class DeliveryStopCard extends StatelessWidget {
  final DeliveryStop stop;
  final int index;
  final Function(DeliveryStop) onMarkAsComplete;
  final Function(DeliveryStop) onSendText;
  final Function(String, double?, double?) openMap;
  final String Function(String) formatPhone;
  final bool isDarkMode;

  const DeliveryStopCard({
    super.key,
    required this.stop,
    required this.index,
    required this.onMarkAsComplete,
    required this.onSendText,
    required this.openMap,
    required this.formatPhone,
    required this.isDarkMode,
  });

  @override
  Widget build(BuildContext context) {
    Color bgColor = isDarkMode ? Colors.grey[800]! : Colors.white;
    Color borderColor = Colors.transparent;
    Color avatarColor = Colors.teal;
    Color textColor = isDarkMode ? Colors.white : Colors.black87;
    Color phoneColor = isDarkMode ? Colors.blue[200]! : Colors.blueGrey;

    if (stop.isTexted) {
      bgColor = isDarkMode ? const Color(0xFF3B1010) : Colors.red[50]!;
      borderColor = isDarkMode ? Colors.red.shade700 : Colors.red.shade300;
      avatarColor = Colors.red;
      textColor = isDarkMode ? Colors.grey[400]! : Colors.grey;
    } else if (stop.isCompleted) {
      bgColor = isDarkMode ? const Color(0xFF103B10) : Colors.green[50]!;
      borderColor = isDarkMode ? Colors.green.shade700 : Colors.green.shade300;
      avatarColor = Colors.green;
      textColor = isDarkMode ? Colors.grey[400]! : Colors.grey;
    }

    return Card(
      elevation: 2,
      color: bgColor,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: (stop.isTexted || stop.isCompleted)
            ? BorderSide(color: borderColor, width: 2)
            : BorderSide.none,
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
                    child: Text(
                      "${index + 1}",
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () =>
                            openMap(stop.address, stop.latitude, stop.longitude),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              fit: FlexFit.loose,
                              child: Text(
                                stop.address,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: textColor,
                                  height: 1.1,
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 4.0),
                              child: Icon(
                                Icons.map,
                                size: 20,
                                color: Colors.blueAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.deepOrange,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              "${stop.dozens} DOZEN",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                children: [
                                  InkWell(
                                    onTap: () => onSendText(stop),
                                    child: Row(
                                      children: [
                                        Icon(Icons.message,
                                            size: 16, color: phoneColor),
                                        const SizedBox(width: 4),
                                        Text(
                                          formatPhone(stop.phone),
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: phoneColor,
                                            decoration: TextDecoration.underline,
                                            decorationStyle:
                                                TextDecorationStyle.dotted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    stop.name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                ],
                              ),
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
                    color: (stop.isCompleted && !stop.isTexted)
                        ? Colors.green
                        : Colors.grey[300],
                  ),
                  onPressed: () => onMarkAsComplete(stop),
                ),
              ],
            ),
            if (stop.notes.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(8),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: isDarkMode ? Colors.brown[900] : Colors.yellow[100],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDarkMode ? Colors.orange.shade900 : Colors.yellow.shade600, width: 0.5),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        stop.notes,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
