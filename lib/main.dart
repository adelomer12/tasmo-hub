import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/device_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = DeviceStore();
  await store.load();
  runApp(TasmoHubApp(store: store));
}

class TasmoHubApp extends StatelessWidget {
  const TasmoHubApp({super.key, required this.store});
  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1FA3EC); // Tasmota blue
    return MaterialApp(
      title: 'TasmoHub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: HomeScreen(store: store),
    );
  }
}
