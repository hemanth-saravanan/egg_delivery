import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/google_apps_script.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _scriptController = TextEditingController();
  final _msgController = TextEditingController();
  final _sheetNameController = TextEditingController();
  bool _useWhatsApp = false;

  // Route Settings
  bool _useCurrentStart = true;
  final _startAddrController = TextEditingController();
  bool _useEndAddress = false;
  bool _useCurrentEnd = true;
  final _endAddrController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
  }

  Future<void> _loadCurrentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _scriptController.text = prefs.getString('script_link') ?? "";
      _msgController.text = prefs.getString('msg_template') ??
          "Hi! Your {dozens} dozen eggs have been delivered.";
      _sheetNameController.text = prefs.getString('sheet_name') ?? "Sheet1";
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
      await prefs.setString('sheet_name', _sheetNameController.text.trim());
      await prefs.setBool('use_whatsapp', _useWhatsApp);

      await prefs.setBool('use_current_start', _useCurrentStart);
      await prefs.setString('start_address', _startAddrController.text.trim());
      await prefs.setBool('use_end_address', _useEndAddress);
      await prefs.setBool('use_current_end', _useCurrentEnd);
      await prefs.setString('end_address', _endAddrController.text.trim());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Settings Saved!"), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showDialog(
            context: context,
            builder: (context) => AlertDialog(
                title: const Text("Error"),
                content: Text(e.toString()),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("OK"))
                ]));
      }
    }
  }

  void _showHelp(String title, String content) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
            title: Text(title, style: const TextStyle(color: Colors.teal)),
            content: SingleChildScrollView(
                child: Text(content, style: const TextStyle(fontSize: 16))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Close"))
            ]));
  }

  void _copyScript() {
    String sheetName = _sheetNameController.text.trim();
    if (sheetName.isEmpty) sheetName = "Sheet1";
    String code =
        googleScriptCode.replaceAll('getSheetByName("Sheet1")', 'getSheetByName("$sheetName")');
    Clipboard.setData(ClipboardData(text: code)).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Script copied to clipboard! 📋")));
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
                            "A: Name\nB: Address\nC: Phone\nD: Dozens\nE: Notes\nF: Coordinates\n"),
                        icon: const Icon(Icons.table_chart),
                        label: const Text("View Required Sheet Format"))),
                const Divider(),
                const SizedBox(height: 10),
                Row(children: [
                  const Text("1. Google Script URL",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                      icon: const Icon(Icons.help_outline, color: Colors.blue),
                      onPressed: () => _showHelp("How to set up Script",
                          "1. Make your Google Sheet according to required format\n2. Extensions > Apps Script.\n3. Paste code (Copy button ->).\n4. Deploy > New deployment > Web app.\n5. Access: 'Anyone'.\n6. Deploy & Copy URL.")),
                  TextButton.icon(
                      onPressed: _copyScript,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text("COPY SCRIPT"),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.teal,
                          textStyle: const TextStyle(fontWeight: FontWeight.bold)))
                ]),
                TextField(
                    controller: _scriptController,
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: "https://script.google.com/..."),
                    maxLines: 2),
                const SizedBox(height: 10),
                TextField(
                    controller: _sheetNameController,
                    decoration: const InputDecoration(
                        labelText: "Sheet Tab Name (e.g. Sheet1)",
                        border: OutlineInputBorder())) ,
                const SizedBox(height: 20),
                const Text("2. Message Template",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    maxLines: 2),
                const SizedBox(height: 20),
                SwitchListTile(
                    title: const Text("Use WhatsApp"),
                    value: _useWhatsApp,
                    onChanged: (val) => setState(() => _useWhatsApp = val)),
                const Divider(),
                const SizedBox(height: 10),
                const Text("3. Route Optimization",
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                const Text("Start Location:",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                CheckboxListTile(
                    title: const Text("Use Current Address as Start"),
                    value: _useCurrentStart,
                    onChanged: (val) => setState(() => _useCurrentStart = val!)),
                if (!_useCurrentStart)
                  TextField(
                      controller: _startAddrController,
                      decoration: const InputDecoration(
                          labelText: "Start Address",
                          border: OutlineInputBorder())) ,
                const SizedBox(height: 10),
                const Text("End Location:",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                CheckboxListTile(
                    title: const Text("Use End Address"),
                    value: _useEndAddress,
                    onChanged: (val) => setState(() => _useEndAddress = val!)),
                if (_useEndAddress) ...[
                  CheckboxListTile(
                      title: const Text("Use Current Address as End"),
                      value: _useCurrentEnd,
                      onChanged: (val) =>
                          setState(() => _useCurrentEnd = val!)),
                  if (!_useCurrentEnd)
                    TextField(
                        controller: _endAddrController,
                        decoration: const InputDecoration(
                            labelText: "End Address",
                            border: OutlineInputBorder())) ,
                ],
                const SizedBox(height: 30),
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                        onPressed: _saveSettings,
                        child: const Text("SAVE SETTINGS"))),
              ]))),
    );
  }
}
