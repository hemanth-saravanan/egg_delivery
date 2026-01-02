import 'package:flutter/material.dart';

import 'screens/delivery_list_page.dart';

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